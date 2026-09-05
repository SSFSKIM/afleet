import Foundation
import AfleetCore
import ClaudeWire

/// A launch of `Tools/fake-claude/fake-claude` replaying one fixture. `FAKE_CLAUDE_*` names do not begin with `CLAUDE`,
/// so they survive the child-environment scrub; the fixture's own session id is used so `auth_status.session_id` matches.
enum FakeClaudeLaunch {
    static var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var binary: URL { repoRoot.appendingPathComponent("Tools/fake-claude/fake-claude") }
    static func fixture(_ name: String) -> URL { repoRoot.appendingPathComponent("Fixtures").appendingPathComponent(name) }
    static func sessionID(of fixture: String) throws -> SessionID {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: self.fixture(fixture).appendingPathComponent("fixture.json"))) as! [String: Any]
        return SessionID(meta["session_id"] as! String)!
    }
    static func environment(fixture: String, script: URL? = nil, initOverride: URL? = nil, speed: Double = 50) -> ResolvedEnvironment {
        var vars = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        vars["FAKE_CLAUDE_FIXTURE"] = self.fixture(fixture).path
        vars["FAKE_CLAUDE_SPEED"] = String(speed)
        if let script { vars["FAKE_CLAUDE_SCRIPT"] = script.path }
        if let initOverride { vars["FAKE_CLAUDE_INIT"] = initOverride.path }
        return ResolvedEnvironment(variables: vars, shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
    }
    static func launch(fixture: String, cwd: URL, session: SessionStart) -> LaunchConfiguration {
        LaunchConfiguration(binary: binary, cwd: cwd, session: session)
    }
}
