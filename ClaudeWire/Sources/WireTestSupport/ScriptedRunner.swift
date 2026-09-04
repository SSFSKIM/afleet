import Foundation
import WireEnvironment

/// A `ProcessRunner` that hands back canned outputs in order and records the arguments it was asked for.
///
/// Lives here rather than in one test target because two of them need it: `WireEnvironmentTests` drives the
/// capture ladder with it, and `ClaudeWireTests` uses it to hand `VersionGate` a fabricated `--version` string
/// without a second binary on disk. The last output is repeated once the list runs out, so a caller that only
/// cares about the first invocation supplies one element.
public struct ScriptedRunner: ProcessRunner {
    public let outputs: [ProcessOutput]
    public let calls: Recorder
    public init(outputs: [ProcessOutput], calls: Recorder) { self.outputs = outputs; self.calls = calls }

    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []
        public init() {}
        public var invocations: [[String]] { lock.lock(); defer { lock.unlock() }; return storage }
        /// Records one invocation and returns its index, so a caller never reads `invocations` unlocked.
        @discardableResult public func add(_ a: [String]) -> Int { lock.lock(); defer { lock.unlock() }; storage.append(a); return storage.count - 1 }
    }

    public func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        let i = calls.add(arguments)
        return outputs[min(i, outputs.count - 1)]
    }
}
