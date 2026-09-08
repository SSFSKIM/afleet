import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Contract Y1's two kinds, the sent-file row, and D2's raise (spec §8.4, D1, D2, D11, D15).
///
/// Three things are asserted here and each is the thing its deliverable could get wrong quietly:
/// that the app's registry really routes `.decision` and `.sentFile` to this child's rows and to
/// no other kind; that the sent-file row reads its file through the one seam and **degrades**
/// rather than drawing an empty head as if it were the file; and that a decision leaves `.pending`
/// on a **successful** answer and on no other.
///
/// Failure messages carry counts and readings, never a path, a session id or a title (§6.3, §11).
/// Every identifier written here is invented; the only recorded bytes are a committed fixture's,
/// replayed in process.
@MainActor
final class DecisionRowTests: XCTestCase {

    // MARK: - Support

    /// A config home this suite never writes to, for the items it invents. X9: the app side writes
    /// under no config home, and the ingestion rig below builds a scratch one under `TempTree`.
    private static var unwrittenHome: URL {
        FileManager.default.temporaryDirectory.appending(path: "afleet-c6-3-rows-unwritten")
    }

    private static var stream: LogicalStream {
        LogicalStream(configHome: unwrittenHome,
                      sessionID: SessionID("00000000-0000-4000-8000-0000000000f1")!,
                      name: .main)
    }

    private static func sentFile(files: [String], caption: String? = nil,
                                 delivered: Bool? = nil) -> TimelineItem {
        .sentFile(SentFileItem(id: ItemID(stream: stream, key: "invented-sent-file-1"),
                               provenance: Provenance(stream: stream, origin: .wire),
                               toolUseID: "toolu_invented_0001",
                               files: files, caption: caption, delivered: delivered))
    }

    /// A reader that answers whatever the test staged, and records what it was asked for. The
    /// count is the assertion; the paths it was handed are never printed.
    private final class ReaderDouble: FileTextReading {
        private let answer: FileText
        private(set) var reads = 0
        init(_ answer: FileText) { self.answer = answer }
        func read(atPath path: String) -> FileText { reads += 1; return answer }
    }

    // MARK: - The registry fills its two kinds

    /// Y1: the app's own registry routes both kinds to this child's rows, and to nothing else.
    ///
    /// It resolves through `RowRegistry.shared` after building an `AppModel`, because the
    /// registration is the deliverable — a test that registered on a registry of its own would
    /// assert that the views exist and say nothing about whether the app reaches them.
    func testTheAppRegistersBothKindsAndResolvesThemToThisChildsRows() throws {
        _ = AppModel()

        let decision = RowRegistry.shared.view(for: TimelineRow(Self.decisionItem(state: .pending)))
        XCTAssertEqual(ViewTree.values(of: DecisionRowView.self, in: decision).count, 1,
                       "the .decision kind resolved to \(ViewTree.values(of: DecisionRowView.self, in: decision).count) decision row(s), not 1")

        let sent = RowRegistry.shared.view(for: TimelineRow(Self.sentFile(files: ["/invented/a.txt"])))
        XCTAssertEqual(ViewTree.values(of: SentFileRowView.self, in: sent).count, 1,
                       "the .sentFile kind resolved to \(ViewTree.values(of: SentFileRowView.self, in: sent).count) sent-file row(s), not 1")

        // The fence, in the other direction: claiming two kinds claims no third. A kind C6.1 owns
        // still draws C5's placeholder on this branch.
        let opaque = RowRegistry.shared.view(for: TimelineRow(.opaque(OpaqueItem(
            id: ItemID(stream: Self.stream, key: "invented-opaque-1"),
            provenance: Provenance(stream: Self.stream, origin: .file),
            reason: "an unmodelled frame", value: .null))))
        XCTAssertEqual(ViewTree.values(of: PlaceholderRowView.self, in: opaque).count, 1,
                       "a kind this child did not claim no longer draws the placeholder row")
        XCTAssertEqual(ViewTree.values(of: DecisionRowView.self, in: opaque).count, 0,
                       "this child's decision row was reached for a kind it does not own")
    }

    /// The differential clause: one row per item, in order, with both kinds filled.
    ///
    /// The same comparison C6.1's G2 makes, run again with this child's builders installed — and
    /// with a floor on the item count, because an empty timeline would satisfy an equality of two
    /// empty lists. Every row is resolved as well as compared: `RowRegistry.builder(for:)` traps on
    /// a kind with no builder, so resolving all of them is what proves the list is still total.
    func testEveryItemGetsExactlyOneRowAndTheIdsAgree() async throws {
        _ = AppModel()
        let rig = try await IngestionRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.pushPermissionAsk(id: "req_invented_c63_row_0001")
        let pending = await rig.settle { await $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision")

        let items = await rig.ingestion.timeline.items
        XCTAssertGreaterThan(items.count, 1, "the fixture folded \(items.count) item(s); the comparison needs more than a floor of one")
        let rows = items.map(TimelineRow.init)
        XCTAssertEqual(rows.count, items.count, "\(rows.count) row(s) for \(items.count) item(s)")
        XCTAssertTrue(rows.map(\.id) == items.map(\.id), "the rows' ids are not the timeline's ids, in order")

        let decisions = rows.filter { $0.category == .decision }
        XCTAssertEqual(decisions.count, 1, "\(decisions.count) decision row(s) in the folded timeline, not 1")
        for row in rows { _ = RowRegistry.shared.view(for: row) }
    }

    // MARK: - The sent-file row

    /// Item 29's readable half: the caption, the count and the delivery status, plus a head of the
    /// first file — read through the one `FileTextReading` seam and no second one.
    func testTheSentFileRowRendersItsCaptionCountAndStatus() throws {
        let reader = ReaderDouble(.contents("first line\nsecond line"))
        let row = SentFileRowView(row: TimelineRow(Self.sentFile(files: ["/invented/a.txt", "/invented/b.txt"],
                                                                caption: "an invented caption",
                                                                delivered: true)),
                                  reader: reader)
        let texts = CardTree.texts(in: row.body)

        XCTAssertTrue(texts.contains("an invented caption"), "the row drew no caption")
        XCTAssertTrue(texts.contains(SentFileRowView.countReading(2)),
                      "the row drew no count line; it drew \(texts.count) string(s)")
        XCTAssertTrue(texts.contains(SentFileRowView.deliveredReading), "the row drew no delivery status")
        XCTAssertTrue(texts.contains("first line\nsecond line"), "the row drew no head of the first file")
        XCTAssertEqual(reader.reads, 1, "the row read the file \(reader.reads) time(s), not once")
    }

    /// The discriminating half: a file the reader could not read degrades, and the row says so.
    ///
    /// A row that fabricated a preview would draw an empty head — indistinguishable from an empty
    /// file — and the user would be told the engine was sent nothing. Asserted in both directions,
    /// so a row that says *unreadable* about every file cannot pass either.
    func testAnUnreadableFileDegradesRatherThanFabricatingAPreview() throws {
        let unreadable = ReaderDouble(.unreadable)
        let item = Self.sentFile(files: ["/invented/a.txt"], caption: "an invented caption", delivered: false)
        let degraded = CardTree.texts(in: SentFileRowView(row: TimelineRow(item), reader: unreadable).body)
        XCTAssertTrue(degraded.contains(SentFileRowView.unreadableReading), "an unreadable file drew no notice")
        XCTAssertTrue(degraded.contains(SentFileRowView.notDeliveredReading),
                      "an undelivered send drew no status of its own")

        let readable = ReaderDouble(.contents("a line the file really carries"))
        let drawn = CardTree.texts(in: SentFileRowView(row: TimelineRow(item), reader: readable).body)
        XCTAssertTrue(drawn.contains("a line the file really carries"), "a readable file drew no preview")
        XCTAssertFalse(drawn.contains(SentFileRowView.unreadableReading),
                       "a readable file was reported as unreadable")
    }

    // MARK: - D2: the raise

    /// A successful answer moves the item out of `.pending`, through C3's reducer and no view.
    ///
    /// Asserted through `StreamIngestion.timeline` — the one-read view — and on the `Effect` the
    /// fold returned, because the effect is what the channel republishes from. Without the raise
    /// the card stays `.pending` for ever: the engine sends no frame back for an answer.
    func testASuccessfulAnswerRaisesDecisionAnsweredAndTheItemLeavesPending() async throws {
        let rig = try await IngestionRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.pushPermissionAsk(id: "req_invented_c63_raise_0001")
        let pending = await rig.settle { await $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision, so nothing here could leave it")

        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(rig.key)))
        let answering = DecisionAnswering(lifecycle: lifecycle)
        let effects = EffectLog()
        answering.raise = { [ingestion = rig.ingestion] _, signal in
            await effects.record(ingestion.signal(signal))
        }

        let item = try XCTUnwrap(DecisionItem(surfacing: ask, in: rig.key),
                                 "the surfacing initialiser opened no item for the pushed ask")
        answering.send(.allowOnce, on: DecisionCard(item), in: rig.key)
        await answering.whenIdle()

        let state = await rig.ingestion.timeline.overlay.decisions[ask.id]?.state
        XCTAssertEqual(state, .answered(outcome: "allowed"),
                       "the answered decision reads \(state.map(Self.reading) ?? "no state at all"), not answered")

        XCTAssertEqual(effects.count, 1, "the answer raised \(effects.count) signal(s), not 1")
        XCTAssertFalse(effects.changes.isEmpty, "the fold returned an effect carrying no change")
        XCTAssertTrue(effects.changes.contains { if case .overlayChanged = $0 { return true } else { return false } },
                      "the effect's \(effects.changes.count) change(s) carry no overlay change")
    }

    /// The discriminating half: a `perform` that threw leaves the decision `.pending` and raises
    /// **nothing**.
    ///
    /// The break cannot be executed — a raise placed outside the success path answers the wire
    /// identically — so the substitute is a trace assertion on the signal seam: the dangerous path
    /// was never entered (§6.3, Global Constraints). A card marked answered on a refused `perform`
    /// hides a request the engine is still waiting on.
    func testAnAnswerThatFailedRaisesNothingAndLeavesTheItemPending() async throws {
        let rig = try await IngestionRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.pushPermissionAsk(id: "req_invented_c63_raise_0002")
        let pending = await rig.settle { await $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision")

        let lifecycle = LifecycleDouble()
        await lifecycle.always(.failure(.notOwned))
        let answering = DecisionAnswering(lifecycle: lifecycle)
        let effects = EffectLog()
        answering.raise = { [ingestion = rig.ingestion] _, signal in
            await effects.record(ingestion.signal(signal))
        }

        let item = try XCTUnwrap(DecisionItem(surfacing: ask, in: rig.key),
                                 "the surfacing initialiser opened no item for the pushed ask")
        answering.send(.allowOnce, on: DecisionCard(item), in: rig.key)
        await answering.whenIdle()

        XCTAssertEqual(effects.count, 0, "a refused answer raised \(effects.count) signal(s)")
        XCTAssertNotNil(answering.banner, "a refused answer raised no banner either, so nothing told the user")
        let state = await rig.ingestion.timeline.overlay.decisions[ask.id]?.state
        XCTAssertEqual(state, .pending,
                       "a refused answer left the decision reading \(state.map(Self.reading) ?? "no state at all")")
    }

    /// A signal for a request id the fold never saw changes nothing, and publishes nothing.
    ///
    /// That is what makes the two tests above mean something: `StreamIngestion.signal` returns an
    /// empty `Effect` for a no-op by its own contract, so a mis-keyed raise cannot be read as a
    /// successful one.
    func testASignalForAnUnknownRequestIdChangesNothing() async throws {
        let rig = try await IngestionRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.pushPermissionAsk(id: "req_invented_c63_raise_0003")
        let pending = await rig.settle { await $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision")

        let before = await rig.ingestion.timeline.items.count
        let effect = await rig.ingestion.signal(
            .decisionAnswered(RequestID(rawValue: "req_invented_c63_no_such_0009"), outcome: .allowed))

        XCTAssertTrue(effect.changes.isEmpty, "an unknown request id produced \(effect.changes.count) change(s)")
        let after = await rig.ingestion.timeline.items.count
        XCTAssertEqual(after, before, "the timeline moved from \(before) to \(after) item(s) on a no-op signal")
        let state = await rig.ingestion.timeline.overlay.decisions[ask.id]?.state
        XCTAssertEqual(state, .pending, "the real decision was settled by a signal that did not name it")
    }

    // MARK: - Readings, so no assertion prints an engine byte

    private static func reading(_ state: DecisionItem.State) -> String {
        switch state {
        case .pending: "pending"
        case .answered: "answered"
        case .cancelled: "cancelled"
        case .policyAnswered: "policy-answered"
        case .inert: "inert"
        }
    }

    private static func decisionItem(state: DecisionItem.State) -> TimelineItem {
        .decision(DecisionItem(id: ItemID(stream: stream, key: "invented-decision-1"),
                               provenance: Provenance(stream: stream, origin: .wire),
                               requestID: RequestID(rawValue: "req_invented_c63_row_0000"),
                               kind: .permission,
                               title: "an invented ask",
                               state: state,
                               payload: .object(["subtype": .string("can_use_tool")])))
    }
}

// MARK: - Support

/// Every `Effect` a raise produced, and the changes they carried. A class because the raise closure
/// is `@MainActor` and the assertions read it after the round trip.
@MainActor
private final class EffectLog {
    private(set) var effects: [StreamIngestion.Effect] = []
    var count: Int { effects.count }
    var changes: [TimelineChange] { effects.flatMap(\.changes) }
    func record(_ effect: StreamIngestion.Effect) { effects.append(effect) }
}

/// One channel's fold, over a committed fixture's transcript in a scratch config home.
///
/// **`StreamIngestion` directly, rather than `ChannelTimelineModel`.** The model's `signal(_:)` is a
/// forwarder that returns nothing, and D2's clause is about the `Effect` the fold answers with —
/// so the rig holds the ingestion the model would hold and asserts on what it returns. The channel
/// model's own forwarding is C6.1's `ChannelTimelineSeamTests`, and is not restated here.
///
/// X9: `TempTree` canonicalises its root and throws a fixed `XCTSkip` before creating anything if
/// it resolves inside any config home, so nothing here can write into one.
@MainActor
private struct IngestionRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let ingestion: StreamIngestion
    let key: ChannelKey
    let fixture: String
    private let continuation: AsyncStream<WireEvent>.Continuation

    init(fixture: String) async throws {
        self.fixture = fixture
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        guard let main = try Self.mainTranscript(of: fixture) else {
            throw Bail("fixture carries no main transcript")
        }
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)
        let slug = projects.appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: main.slugDirectory, to: slug)
        let path = slug.appending(path: "\(main.session).jsonl")

        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        ingestion = StreamIngestion(session: main.session, configHome: home.configHome.root, mode: .filePrimary)
        let (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        _ = try await ingestion.open(file: path, events: events)
    }

    func finish() { continuation.finish() }

    /// Pushes the fixture's recorded `can_use_tool` ask, re-keyed to an invented request id.
    ///
    /// **Pushed rather than replayed.** `permission-allow` opens `mcp_message` requests the inbound
    /// policy answers itself before its own ask arrives, so waiting on "a decision exists" can
    /// return while every decision present is one no host has to answer. Pushing the one request
    /// under test makes the condition exact: a pending decision, by id.
    func pushPermissionAsk(id: String) throws -> InboundRequest {
        let ask = try request(id: id)
        guard case .request = FixtureRunner.event(for: ask) else {
            throw Bail("the inbound policy does not surface this ask, so nothing would be pending")
        }
        continuation.yield(.request(ask))
        return ask
    }

    func request(id: String) throws -> InboundRequest {
        try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id)
    }

    /// Waits, bounded, for the fold to satisfy `predicate`, and **returns whether it did**, so the
    /// caller asserts the outcome rather than discarding a wedge.
    func settle(_ predicate: (StreamIngestion) async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate(ingestion) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate(ingestion)
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = fixtures.appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, slug)
            }
        }
        return nil
    }
}

/// Why this suite could not run, as a shape and never a path (§11). Private per file, like the two
/// suites that already carry one.
private struct Bail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
