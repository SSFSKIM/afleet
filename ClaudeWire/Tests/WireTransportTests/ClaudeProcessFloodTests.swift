import XCTest
import AfleetCore
import WireFrames
import WireMCP
import WireDiagnostics
import WireTransport
import WireTestSupport

final class ClaudeProcessFloodTests: XCTestCase {
    /// A suspended consumer: the stand-in must block on its pipe, memory stays bounded, and nothing is lost once we drain.
    func testFloodWithSuspendedConsumerLosesNothingAndBoundsMemory() async throws {
        let h = try Harness()
        let capacity = 256, total = 20_000
        var e = h.env; e.variables["SCRIPTED_CLAUDE_SCENARIO"] = "flood:\(total)"
        let sink = RecordingDiagnostics()
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []), diagnostics: sink, capture: nil, eventBufferCapacity: capacity)
        _ = try await p.spawn()
        try await Task.sleep(for: .seconds(2))                       // consumer suspended: nobody reads p.events
        let buffered = await p.bufferedEventCount; XCTAssertLessThanOrEqual(buffered, capacity)
        let status = await p.status; XCTAssertEqual(status, .running, "the child must still be alive, blocked on its pipe")
        // The discriminating assertion. Neither line above can fail on a bad reader: BoundedChannel enforces its
        // own capacity whatever feeds it, and the `flood` scenario returns to its stdin loop rather than exiting,
        // so the child reads `.running` whether it blocked on the pipe or streamed six megabytes out unimpeded.
        // One inbound frame diagnostic is recorded per line that reaches `receive`, so this counts how far the
        // reader actually got: with back-pressure it is the channel plus what one pipe buffer let through, and a
        // reader that eagerly drained the pipe into unbounded memory would be at or near `total`.
        let consumed = sink.entries.filter { $0.contains("\"direction\":\"inbound\"") && $0.contains("\"event\":\"frame\"") }.count
        XCTAssertLessThan(consumed, capacity * 4, "the reader ran ahead of the suspended consumer: \(consumed) of \(total) frames already read")
        XCTAssertGreaterThanOrEqual(consumed, capacity, "the reader should have filled the channel: \(consumed)")
        var assistants = 0, sawResult = false
        for await ev in p.events {
            if case .frame(.assistant, _) = ev { assistants += 1 }
            if case .frame(.result, _) = ev { sawResult = true; break }
        }
        XCTAssertEqual(assistants, total); XCTAssertTrue(sawResult)
        await p.terminate()
    }
}
