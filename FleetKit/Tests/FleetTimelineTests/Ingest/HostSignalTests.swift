import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// `StreamIngestion.signal(_:)` — the host's side of the timeline, through the actor the app holds per channel.
///
/// `HostSignal` is what no frame states: the prompt the host wrote, the decision the host answered, the rewind and the
/// relocation the host asked for, the process the host replaced. `WireReducer` reduces all five and until this seam
/// existed nothing constructed one, so a decision card could never leave `.pending` and no turn could ever be
/// attributed `.prompted` however correctly the app answered through the lifecycle API (filed by C6.3 as a
/// `[parent-impact]` against X4 and X5).
///
/// The frames here are recorded fixture bytes replayed through C2's own `WireEventPolicy` (`FixtureWireReplay`), which
/// is how a request reaches a reducer in production; every identifier this file invents is invented.
final class HostSignalTests: XCTestCase {

    // MARK: - Doubles

    /// The channel's tap as a test drives it.
    private final class Tap: @unchecked Sendable {
        let events: AsyncStream<WireEvent>
        private let continuation: AsyncStream<WireEvent>.Continuation
        init() { (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded) }
        func send(_ event: WireEvent) { continuation.yield(event) }
        func finish() { continuation.finish() }
    }

    /// Everything `effects` yielded, in order, consumed by one task.
    private final class EffectLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StreamIngestion.Effect] = []
        private var task: Task<Void, Never>?
        init(_ ingestion: StreamIngestion) {
            let effects = ingestion.effects
            task = Task { [self] in for await effect in effects { lock.withLock { items.append(effect) } } }
        }
        deinit { task?.cancel() }
        var all: [StreamIngestion.Effect] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    // MARK: - Harness

    /// An ingestion opened on an empty main transcript under a temporary config home. The file is empty on purpose:
    /// every assertion here is about the live half, which no record carries.
    private func opened(_ fx: FixtureCorpus.Fixture) async throws -> (StreamIngestion, Tap, EffectLog, TempTree) {
        let tree = try TempTree()
        let main = try tree.write(Data(), session: fx.sessionID, slug: try FixtureWireReplay.slug(of: fx))
        let ingestion = StreamIngestion(session: fx.sessionID, configHome: tree.root, mode: .filePrimary)
        let log = EffectLog(ingestion)
        let tap = Tap()
        try await ingestion.open(file: main, events: tap.events)
        return (ingestion, tap, log, tree)
    }

    /// The tap is a task: an event sent is not an event applied. Polls the overlay under a bound and returns what it
    /// last saw, so a test that never settles fails on its assertion rather than hanging.
    private func settled(_ ingestion: StreamIngestion, within bound: TimeInterval = 2,
                         until predicate: @Sendable (Overlay) -> Bool) async -> Overlay {
        let deadline = Date().addingTimeInterval(bound)
        while true {
            let overlay = await ingestion.overlay
            if predicate(overlay) || Date() >= deadline { return overlay }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The preview half of `settled`.
    private func settledPreview(_ ingestion: StreamIngestion, within bound: TimeInterval = 2,
                                until predicate: @Sendable (StreamingPreview?) -> Bool) async -> StreamingPreview? {
        let deadline = Date().addingTimeInterval(bound)
        while true {
            let preview = await ingestion.preview
            if predicate(preview) || Date() >= deadline { return preview }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// `effects` is consumed by a task, so an effect returned is not yet an effect logged. Polls up to `count` under a
    /// bound and returns what it last saw.
    @discardableResult
    private func logged(_ log: EffectLog, _ count: Int, within bound: TimeInterval = 2) async -> Int {
        let deadline = Date().addingTimeInterval(bound)
        while log.count < count && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return log.count
    }

    /// Long enough for an effect that was going to be published to have been logged. Used only for the negative:
    /// "and nothing else arrived".
    private func quiet() async { try? await Task.sleep(for: .milliseconds(50)) }

    /// The first request the fixture's replay surfaces, and the first `result` frame that is a turn (`numTurns > 0`;
    /// a zero-turn result is a relocation and is attributed as one).
    private func firstRequest(_ steps: [FixtureWireReplay.Step]) -> InboundRequest? {
        for step in steps {
            for event in step.events { if case .request(let request) = event { return request } }
        }
        return nil
    }
    private func firstTurnResult(_ steps: [FixtureWireReplay.Step]) -> WireEvent? {
        for step in steps {
            for event in step.events {
                guard case .frame(.result(let result), _) = event, result.numTurns > 0 else { continue }
                return event
            }
        }
        return nil
    }

    // MARK: - The tests

    /// The filing's first half: an answered decision leaves `pending`, and the effect names the item that moved.
    func testDecisionAnsweredSettlesThePendingItemAndNamesIt() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let request = try XCTUnwrap(firstRequest(try FixtureWireReplay.steps(for: fx)),
                                    "the fixture's replay surfaces no request")

        tap.send(.request(request))
        let pending = await settled(ingestion) { $0.decisions[request.id]?.state == .pending }
        XCTAssertEqual(pending.decisions[request.id]?.state, .pending, "the request opens a pending card")
        let item = try XCTUnwrap(pending.decisions[request.id]?.id)
        let before = await logged(log, 1)                          // the card opening is itself an effect

        let effect = await ingestion.signal(.decisionAnswered(request.id, outcome: .answered(summary: "option-b")))

        await expectEqual(await ingestion.overlay.decisions[request.id]?.state, .answered(outcome: "option-b"),
                          "the card leaves pending through the reducer")
        XCTAssertTrue(effect.changes.contains(.updated(item)), "the effect names the item that moved: \(effect.changes)")
        XCTAssertEqual(effect.applied, [], "a host signal applies no record")
        let logged = await logged(log, before + 1)
        XCTAssertEqual(logged, before + 1, "the change reached the effect stream, not only the return value")
        XCTAssertEqual(log.all.last?.changes, effect.changes, "the published effect is the returned one")
        await ingestion.close()
        tap.finish()
    }

    /// The filing's second half: the turn after a prompt the host sent is attributed to that prompt.
    func testPromptSentAttributesTheFollowingTurn() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let result = try XCTUnwrap(firstTurnResult(try FixtureWireReplay.steps(for: fx)),
                                    "the fixture's replay carries no result frame with turns")
        let uuid = "11111111-1111-4111-8111-111111111111"          // invented: the host's own prompt uuid

        _ = await ingestion.signal(.promptSent(uuid: uuid, at: Date()))
        tap.send(result)

        let overlay = await settled(ingestion) { !$0.turns.isEmpty }
        let turn = try XCTUnwrap(overlay.turns.last)
        XCTAssertEqual(turn.attribution, .prompted(uuid: uuid),
                       "an outstanding prompt claims the turn that follows it")
        await quiet()
        XCTAssertEqual(log.count, 1, "the signal moved nothing on its own; the turn the frame made is the one effect")
        XCTAssertTrue(log.all.contains { $0.changes.contains(.inserted(turn.id)) },
                      "and the turn reached `effects` by name: \(log.all.map(\.changes))")
        await ingestion.close()
        tap.finish()
    }

    /// A signal for a request nobody opened is not an error and not a change: the reducer has no such decision, so
    /// there is nothing to publish and nothing is published.
    func testASignalForAnUnknownRequestPublishesNothing() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let unknown = RequestID(rawValue: "req_invented_0001")      // invented: no frame ever carried it
        let before = log.count

        let effect = await ingestion.signal(.decisionAnswered(unknown, outcome: .allowed))

        XCTAssertEqual(effect.changes, [], "nothing changed, so nothing is reported")
        XCTAssertEqual(effect.applied, [])
        await quiet()
        XCTAssertEqual(log.count, before, "an empty effect is not published")
        await ingestion.close()
        tap.finish()
    }

    /// The same answer twice: the second is a no-op. The host retries and the app raises from more than one place, so
    /// the seam has to be idempotent or a card would flicker on a repeat.
    func testASecondIdenticalAnswerIsIdempotent() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let request = try XCTUnwrap(firstRequest(try FixtureWireReplay.steps(for: fx)),
                                    "the fixture's replay surfaces no request")
        tap.send(.request(request))
        _ = await settled(ingestion) { $0.decisions[request.id]?.state == .pending }

        let first = await ingestion.signal(.decisionAnswered(request.id, outcome: .answered(summary: "option-b")))
        let published = await logged(log, 2)                       // the card opening, then the answer
        let second = await ingestion.signal(.decisionAnswered(request.id, outcome: .answered(summary: "option-b")))

        XCTAssertFalse(first.changes.isEmpty, "the first answer moved the card")
        XCTAssertEqual(second.changes, [], "the second answer moved nothing")
        await quiet()
        XCTAssertEqual(log.count, published, "and published nothing")
        await expectEqual(await ingestion.overlay.decisions[request.id]?.state, .answered(outcome: "option-b"))
        await ingestion.close()
        tap.finish()
    }

    // MARK: - The tap's own fold

    /// The channel's live half is folded here and published here: a message being streamed moves the preview, which is
    /// what the renderer draws between the deltas and the assistant frame that collapses them.
    func testAssistantDeltasPublishPreviewChanges() async throws {
        let fx = try FixtureCorpus.named("plain-two-turn")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }

        var deltas = 0
        for step in try FixtureWireReplay.steps(for: fx) {
            for event in step.events {
                guard case .frame(.streamEvent, _) = event else { continue }
                tap.send(event)
                deltas += 1
            }
        }
        XCTAssertGreaterThan(deltas, 0, "the recording carries stream_event deltas")

        let preview = await settledPreview(ingestion) { $0?.text.isEmpty == false }
        XCTAssertEqual(preview?.text.isEmpty, false, "the deltas assembled a preview the app can read")
        await quiet()
        XCTAssertTrue(log.all.contains { $0.changes.contains(.previewChanged) },
                      "the preview's movement reached `effects`: \(log.all.map(\.changes))")
        await ingestion.close()
        tap.finish()
    }

    /// A `tool_use_summary` labels the cluster of the calls it names, in the overlay, and the label reaches `effects`.
    /// The frame is constructed: no fixture carries one (asserted), and every identifier in it is invented.
    func testAToolUseSummaryPublishesTheClusterLabel() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        XCTAssertTrue(try fx.frames().allSatisfy { if case .toolUseSummary = $0.frame { false } else { true } },
                      "the corpus is still free of tool_use_summary frames; this test's frame is constructed")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let main = LogicalStream(configHome: tree.root, sessionID: fx.sessionID, name: .main)
        let lead = "toolu_invented_0001"
        let line = JSONValue.object([
            "type": .string("tool_use_summary"),
            "summary": .string("afleet invented cluster label"),
            "preceding_tool_use_ids": .array([.string(lead), .string("toolu_invented_0002")]),
            "uuid": .string("22222222-2222-4222-8222-222222222222"),
            "session_id": .string("33333333-3333-4333-8333-333333333333"),
        ])

        tap.send(.frame(FrameDecoder.decode(line: try line.canonicalData()), .first))

        let overlay = await settled(ingestion) { !$0.clusters.isEmpty }
        let cluster = try XCTUnwrap(overlay.clusters[ItemID(stream: main, key: lead)],
                                    "the cluster is keyed by the first call the summary names")
        XCTAssertEqual(cluster.label, "afleet invented cluster label")
        await quiet()
        XCTAssertTrue(log.all.contains { $0.changes.contains(.inserted(cluster.id)) },
                      "the cluster reached `effects` by name: \(log.all.map(\.changes))")
        await ingestion.close()
        tap.finish()
    }

    /// The rule the record half already followed, now the live half's too: an event that moves nothing publishes
    /// nothing. `stderr` is C4's, and the reducer drops it.
    func testATapEventThatMovesNothingPublishesNothing() async throws {
        let fx = try FixtureCorpus.named("ask-user-question")
        let (ingestion, tap, log, tree) = try await opened(fx)
        defer { _ = tree }
        let before = log.count

        tap.send(.stderr("a line the engine printed", .first))       // invented text

        await quiet()
        XCTAssertEqual(log.count, before, "nothing moved, so nothing was published")
        await ingestion.close()
        tap.finish()
    }

    // MARK: - Assertion helpers

    // XCTest's assertions take non-async autoclosures and every query on this actor is `await`; these are the same
    // assertions with the awaits evaluated first.
    private func expectEqual<T: Equatable>(_ a: @autoclosure () async throws -> T,
                                           _ b: @autoclosure () async throws -> T,
                                           _ message: @autoclosure () -> String = "",
                                           file: StaticString = #filePath, line: UInt = #line) async rethrows {
        let x = try await a(), y = try await b()
        XCTAssertEqual(x, y, message(), file: file, line: line)
    }
}
