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
        let p = ClaudeProcess(epoch: .first, launch: LaunchConfiguration(binary: TestPaths.scriptedClaude, cwd: h.cwd, session: .new(SessionID())),
                              environment: e, configHome: ConfigHome(root: h.cwd, source: .environment),
                              mcpServer: AfleetMCPServer(serverVersion: "0.1.0", cwd: h.cwd, tools: []), diagnostics: NullDiagnostics(), capture: nil, eventBufferCapacity: capacity)
        _ = try await p.spawn()
        try await Task.sleep(for: .seconds(2))                       // consumer suspended: nobody reads p.events
        let buffered = await p.bufferedEventCount; XCTAssertLessThanOrEqual(buffered, capacity)
        let status = await p.status; XCTAssertEqual(status, .running, "the child must still be alive, blocked on its pipe")
        var assistants = 0, sawResult = false
        for await ev in p.events {
            if case .frame(.assistant, _) = ev { assistants += 1 }
            if case .frame(.result, _) = ev { sawResult = true; break }
        }
        XCTAssertEqual(assistants, total); XCTAssertTrue(sawResult)
        await p.terminate()
    }
}
