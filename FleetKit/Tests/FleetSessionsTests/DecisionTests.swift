import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// Answers and the event fan-out, through the supervisor and nothing else. Every one of these runs against the
/// scripted handle: an engine that asks a decision on cue, and a write that fails on cue, are not things a replay of
/// a recording can be made to do.
final class DecisionTests: XCTestCase {
    private var rigs: [Rig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.shutdown(); await rig.tearDown() }
        rigs = []
    }

    // MARK: - The fixture

    private func readyChannel() async throws -> (Rig, ChannelSupervisor, ScriptedProcessHandle) {
        let rig = try Rig()
        rigs.append(rig)
        rig.useScriptedHandle(terminateReturns: TerminationReport(exit: .code(0, stderrTail: ""), steps: []))
        let supervisor = rig.supervisor(session: SessionID(), origin: .owned(.connecting))
        try await supervisor.spawn(reason: .open)
        let state = await supervisor.state
        XCTAssertEqual(state.origin, .owned(.ready))
        return (rig, supervisor, rig.scriptedHandles.last!)
    }

    private static let allow = InboundAnswer.permission(.allow(updatedInput: nil, updatedPermissions: nil,
                                                               classification: nil))

    /// An `InboundRequest` built with ClaudeWire's public initialiser over a decoded `can_use_tool` payload.
    private func request(_ id: String, epoch: ProcessEpoch) throws -> InboundRequest {
        let raw: JSONValue = .object([
            "subtype": .string("can_use_tool"),
            "tool_name": .string("Bash"),
            "input": .object(["command": .string("echo hi")]),
            "tool_use_id": .string("toolu_\(id)"),
        ])
        let typed = try JSONDecoder().decode(CanUseToolRequest.self, from: raw.canonicalData())
        return InboundRequest(id: RequestID(rawValue: id), epoch: epoch, receivedAt: .now,
                              payload: .canUseTool(typed), raw: raw)
    }

    private func waitForDecisions(_ supervisor: ChannelSupervisor, _ count: Int,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await supervisor.state.pendingDecisions.count == count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(count) pending decision(s)", file: file, line: line)
    }

    private func isAllow(_ answer: InboundAnswer) -> Bool {
        if case .permission(.allow) = answer { return true }
        return false
    }

    // MARK: - Tests

    func testAnswerResolvesAPendingDecisionOnlyAfterTheProcessAccepts() async throws {
        let (rig, supervisor, handle) = try await readyChannel()
        let r = try request("d-1", epoch: handle.epoch)

        handle.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        let pending = await supervisor.state.pendingDecisions
        XCTAssertEqual(pending.map(\.id), [r.id])
        XCTAssertEqual(pending.first?.subtype, "can_use_tool")
        XCTAssertEqual(pending.first?.epoch, handle.epoch)
        await supervisor.drainEligibility()
        let verdict = await rig.fleet.verdict(of: supervisor.key)
        XCTAssertEqual(verdict, .blocked(.pendingDecision), "a pending decision blocks the reap")

        try await supervisor.answer(r.id, Self.allow)
        XCTAssertEqual(handle.answers.map(\.id), [r.id])
        XCTAssertTrue(isAllow(handle.answers[0].answer))
        let empty = await supervisor.state.pendingDecisions
        XCTAssertTrue(empty.isEmpty)

        // An id nobody asked about never reaches the process.
        await XCTAssertThrowsLifecycleError(.decisionGone(RequestID(rawValue: "never-asked"))) {
            try await supervisor.answer(RequestID(rawValue: "never-asked"), Self.allow)
        }
        XCTAssertEqual(handle.answers.count, 1)
        XCTAssertEqual(handle.consumed, [r.id])
    }

    func testAnAnswerWhoseWriteFailsIsConsumedAndReported() async throws {
        let (rig, supervisor, handle) = try await readyChannel()
        let r = try request("d-1", epoch: handle.epoch)
        handle.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        let failure = ScriptedWriteFailure("the pipe is gone")
        handle.answerError = failure
        await XCTAssertThrowsLifecycleError(.answerFailed(r.id, reason: String(describing: failure))) {
            try await supervisor.answer(r.id, Self.allow)
        }

        let after = await supervisor.state.pendingDecisions
        XCTAssertTrue(after.isEmpty, "the id is consumed on a failed write, exactly as ClaudeProcess.answer consumes it")
        XCTAssertEqual(handle.consumed, [r.id])
        XCTAssertTrue(handle.answers.isEmpty)

        // A retry finds nothing to retry, and reaches no process.
        await XCTAssertThrowsLifecycleError(.decisionGone(r.id)) {
            try await supervisor.answer(r.id, Self.allow)
        }
        XCTAssertEqual(handle.consumed, [r.id], "the second answer never reached the process")

        await supervisor.drainEligibility()
        let verdict = await rig.fleet.verdict(of: supervisor.key)
        XCTAssertEqual(verdict, .eligible, "the channel is reapable again rather than blocked forever")
        XCTAssertEqual(rig.diagnostics.answerWriteFailures.map(\.id), ["d-1"])
        XCTAssertEqual(rig.diagnostics.answerWriteFailures.first?.reason, String(describing: failure))
    }

    func testAnExitEmptiesPendingDecisions() async throws {
        let (_, supervisor, handle) = try await readyChannel()
        let r = try request("d-1", epoch: handle.epoch)
        handle.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        handle.push(.exited(.signal(9, stderrTail: ""), handle.epoch))
        try await waitForDecisions(supervisor, 0)

        await XCTAssertThrowsLifecycleError(.decisionGone(r.id)) {
            try await supervisor.answer(r.id, Self.allow)
        }
        XCTAssertTrue(handle.answers.isEmpty)
        XCTAssertTrue(handle.consumed.isEmpty)
    }

    func testAnsweringACancelledDecisionThrowsDecisionGone() async throws {
        let (_, supervisor, handle) = try await readyChannel()
        let r = try request("d-1", epoch: handle.epoch)
        handle.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        handle.push(.requestCancelled(r.id, handle.epoch))
        try await waitForDecisions(supervisor, 0)

        await XCTAssertThrowsLifecycleError(.decisionGone(r.id)) {
            try await supervisor.answer(r.id, Self.allow)
        }
        XCTAssertTrue(handle.answers.isEmpty, "a request the engine withdrew is never answered")
    }

    func testADuplicateAnswerThrowsDecisionGone() async throws {
        let (_, supervisor, handle) = try await readyChannel()
        let r = try request("d-1", epoch: handle.epoch)
        handle.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        try await supervisor.answer(r.id, Self.allow)
        await XCTAssertThrowsLifecycleError(.decisionGone(r.id)) {
            try await supervisor.answer(r.id, Self.allow)
        }
        XCTAssertEqual(handle.answers.count, 1)
    }

    func testAnAnswerFromAnOlderEpochThrowsDecisionGoneAfterARespawn() async throws {
        let (rig, supervisor, first) = try await readyChannel()
        let r = try request("d-1", epoch: first.epoch)
        first.push(.request(r))
        try await waitForDecisions(supervisor, 1)

        first.push(.exited(.code(1, stderrTail: ""), first.epoch))
        first.finish()
        try await waitForDecisions(supervisor, 0)

        try await rig.waitForSleeper(due: ChannelSupervisor.backoffs[0])
        await rig.clock.advance(by: .seconds(1))
        try await rig.waitUntil(supervisor, "the respawn to reach ready") { $0.origin == .owned(.ready) }
        XCTAssertEqual(rig.scriptedHandles.count, 2)
        let second = rig.scriptedHandles[1]
        XCTAssertEqual(second.epoch, first.epoch.next())

        await XCTAssertThrowsLifecycleError(.decisionGone(r.id)) {
            try await supervisor.answer(r.id, Self.allow)
        }
        XCTAssertTrue(first.answers.isEmpty)
        XCTAssertTrue(second.answers.isEmpty)
        let pending = await supervisor.state.pendingDecisions
        XCTAssertTrue(pending.isEmpty)
    }

    func testTwoEventSubscribersSeeTheSameFrames() async throws {
        let (rig, supervisor, handle) = try await readyChannel()

        let first = EventCollector(await supervisor.events())
        let second = EventCollector(await supervisor.events())

        let r = try request("d-1", epoch: handle.epoch)
        handle.push(.requestCancelled(RequestID(rawValue: "c-1"), handle.epoch))
        handle.push(.requestCancelled(RequestID(rawValue: "c-2"), handle.epoch))
        handle.push(.requestCancelled(RequestID(rawValue: "c-3"), handle.epoch))
        handle.push(.request(r))

        try await first.waitFor(4)
        try await second.waitFor(4)
        XCTAssertEqual(first.ids, ["c-1", "c-2", "c-3", "d-1"])
        XCTAssertEqual(second.ids, first.ids)
        let pending = await supervisor.state.pendingDecisions
        XCTAssertEqual(pending.count, 1)

        // A stream taken after the fact sees only what follows it.
        let third = EventCollector(await supervisor.events())
        handle.push(.requestCancelled(RequestID(rawValue: "c-4"), handle.epoch))
        try await third.waitFor(1)
        XCTAssertEqual(third.ids, ["c-4"])
        try await first.waitFor(5)

        await rig.shutdown()
        try await first.waitForEnd()
        try await second.waitForEnd()
        try await third.waitForEnd()
    }
}

/// One subscriber of `ChannelSupervisor.events()`.
private final class EventCollector: Sendable {
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<WireEvent>) {
        let box = Box()
        self.box = box
        task = Task {
            for await event in stream { box.append(EventCollector.identifier(of: event)) }
            box.finish()
        }
    }
    private let box: Box
    final class Box: @unchecked Sendable {   // `lock` serialises both fields
        private let lock = NSLock()
        private var _ids: [String] = []
        private var _ended = false
        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
        func append(_ id: String) { locked { _ids.append(id) } }
        func finish() { locked { _ended = true } }
        var ids: [String] { locked { _ids } }
        var ended: Bool { locked { _ended } }
    }

    var ids: [String] { box.ids }

    static func identifier(of event: WireEvent) -> String {
        switch event {
        case .requestCancelled(let id, _): return id.rawValue
        case .request(let r): return r.id.rawValue
        default: return String(describing: event.kind)
        }
    }

    func waitFor(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if box.ids.count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(count) event(s); saw \(box.ids)", file: file, line: line)
    }

    func waitForEnd(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if box.ended { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the stream was never finished", file: file, line: line)
    }
}

/// `LifecycleError` is Hashable, so the expectation is the value itself and not a description of it.
func XCTAssertThrowsLifecycleError(_ expected: LifecycleError, file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
    } catch let error as LifecycleError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
