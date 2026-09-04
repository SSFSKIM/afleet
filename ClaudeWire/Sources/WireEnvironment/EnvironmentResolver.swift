import Foundation
import AfleetCore

public struct EnvironmentResolver: Sendable {
    public static let sentinel = "__AFLEET_ENV__"
    public let runner: any ProcessRunner
    public init(runner: any ProcessRunner = FoundationProcessRunner()) { self.runner = runner }

    /// §6.9 capture ladder: interactive login → login → the app's own environment. Never throws.
    ///
    /// The capture is deliberately faithful: every variable the user's shell exports is kept, including
    /// `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME`, which `ConfigHome.derive(from:)` reads back
    /// out of it. Filtering the `CLAUDE*` markers that must never reach a spawned engine happens at
    /// composition time, in `LaunchConfiguration.childEnvironment(over:)` — not here.
    ///
    /// The two shell arms run with a base environment of only TERM, HOME and PATH, so afleet's own markers
    /// cannot propagate through them. `.processFallback` returns this process's environment verbatim.
    public func resolve(shell: String, timeout: Duration = .seconds(5)) async -> ResolvedEnvironment {
        let script = "printf \"\(Self.sentinel)\\0\"; /usr/bin/env -0"
        let base = ["TERM": "dumb", "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        for (mode, args) in [(ResolvedEnvironment.CaptureMode.interactiveLogin, ["-l", "-i", "-c", script]), (.login, ["-l", "-c", script])] {
            guard let out = try? await runner.run(URL(fileURLWithPath: shell), arguments: args, environment: base, timeout: timeout),
                  !out.timedOut, out.exitCode == 0, let vars = Self.parse(out.stdout), !vars.isEmpty else { continue }
            return ResolvedEnvironment(variables: vars, shell: shell, capturedAt: Date(), mode: mode)
        }
        return ResolvedEnvironment(variables: ProcessInfo.processInfo.environment, shell: shell, capturedAt: Date(), mode: .processFallback)
    }

    /// Discards everything up to and including the NUL-terminated sentinel; nil when the sentinel is absent,
    /// and an empty dictionary when nothing survives it — `resolve` treats both as a failed capture,
    /// so a shell whose rc file swallowed or reordered the output falls through the ladder instead of
    /// reporting an empty success. Tokens are kept only when they match `^[A-Za-z_][A-Za-z0-9_]*=`.
    static func parse(_ data: Data) -> [String: String]? {
        let marker = Data((sentinel + "\0").utf8)
        guard let range = data.range(of: marker) else { return nil }
        var vars: [String: String] = [:]
        for token in data[range.upperBound...].split(separator: 0, omittingEmptySubsequences: true) {
            guard let eq = token.firstIndex(of: UInt8(ascii: "=")), eq > token.startIndex else { continue }
            let name = token[token.startIndex..<eq]
            guard isVariableName(name) else { continue }
            vars[String(decoding: name, as: UTF8.self)] = String(decoding: token[token.index(after: eq)...], as: UTF8.self)
        }
        return vars
    }

    /// ASCII-only by design: Swift's `isLetter`/`isNumber` accept Unicode letters and digits, which would
    /// admit names such as `PÄTH` that no shell can export.
    private static func isVariableName(_ bytes: some Collection<UInt8>) -> Bool {
        func isAlpha(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        guard let first = bytes.first, isAlpha(first) || first == UInt8(ascii: "_") else { return false }
        return bytes.allSatisfy { isAlpha($0) || isDigit($0) || $0 == UInt8(ascii: "_") }
    }
}
