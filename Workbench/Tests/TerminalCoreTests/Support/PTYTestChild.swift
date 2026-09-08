import Darwin
import Foundation
import Synchronization
import TerminalCore
import XCTest

/// Everything the pty has produced so far. A test that has to write while it reads cannot take
/// the stream twice — `AsyncStream` admits one consumer — so one task drains it into here and
/// the test reads snapshots.
final class PTYOutputRecorder: Sendable {
    private let bytes = Mutex(Data())

    func append(_ data: Data) {
        bytes.withLock { $0.append(data) }
    }

    var snapshot: Data {
        bytes.withLock { $0 }
    }
}

enum PTYTestChild {
    enum Failure: Error {
        case outputEnded
        case timedOut
        case spawnRefused
    }

    /// Every config home the engine may be using, derived from the values handed in. Pure: it
    /// reads no global state and writes nothing, so the rule it encodes can be tested without a
    /// test ever creating a directory to find out (spec §7.8, contract X9).
    ///
    /// `CLAUDE_CONFIG_DIR` is the one that moves. When it is set it *is* the config home, and a
    /// root derived only from the home directory would miss it entirely.
    static func configHomeRoots(homeDirectory: URL, environment: [String: String]) -> [URL] {
        var roots = [
            homeDirectory.appending(path: ".claude"),
            URL(filePath: "/tmp/afleet-fixtures/config-home"),
        ]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            roots.append(URL(filePath: configured))
        }
        return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// Pure: whether `candidate` is at or under any of `roots`. A sibling whose name merely begins
    /// with a root's name is not inside it.
    static func isForbidden(_ candidate: URL, roots: [URL]) -> Bool {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return roots.contains { contains(resolved, within: $0) }
    }

    static func temporaryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let temporaryRoot = try canonicalURL(fileManager.temporaryDirectory)
        let root = temporaryRoot
            .appending(path: "terminal-core-tests")
            .appending(path: UUID().uuidString)
        // Checked before anything is created, so a rule that is wrong cannot leave a directory
        // behind in a config home while it is being found out.
        let forbiddenRoots = configHomeRoots(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        guard !isForbidden(root, roots: forbiddenRoots) else {
            throw XCTSkip("temporary test root resolved inside a config home")
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func request(
        cwd: URL,
        script: String,
        environment: [String: String] = [:]
    ) -> PTYSpawnRequest {
        PTYSpawnRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            cwd: cwd,
            environment: environment,
            size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
            terminal: TerminalDescription(term: "xterm-256color"),
            stopPolicy: .report
        )
    }

    static func output(
        from events: AsyncStream<PTYEvent>,
        until marker: String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var output = Data()
                for await event in events {
                    guard case let .output(bytes) = event else { continue }
                    output.append(bytes)
                    if output.range(of: Data(marker.utf8)) != nil {
                        return output
                    }
                }
                throw Failure.outputEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw Failure.timedOut
            }
            guard let first = try await group.next() else {
                throw Failure.outputEnded
            }
            group.cancelAll()
            return String(decoding: first, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        }
    }

    /// A deadline for a step that must not block. Under a blocking implementation the step never
    /// returns and this throws instead of leaving the test to hang.
    static func withDeadline<Value: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure.timedOut
            }
            guard let first = try await group.next() else {
                throw Failure.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    /// A guard clause for a script that is meant to sit idle: the session outlives this test
    /// process, so a child that is never reaped would otherwise stay on the machine.
    static func selfTerminating(after seconds: Int, _ script: String) -> String {
        "( sleep \(seconds); kill -KILL $$ ) &\n" + script
    }

    static func record(_ events: AsyncStream<PTYEvent>) -> (PTYOutputRecorder, Task<Void, Never>) {
        let recorder = PTYOutputRecorder()
        let task = Task {
            for await event in events {
                guard case let .output(data) = event else { continue }
                recorder.append(data)
            }
        }
        return (recorder, task)
    }

    static func waitUntil(
        seconds: Double,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard condition() else { throw Failure.timedOut }
    }

    /// Runs a script through a bare `posix_spawn` — no descriptor policy of any kind — and
    /// returns its trimmed standard output. This stands in for the spawners this layer does not
    /// own, which is where a descriptor flag, and only a descriptor flag, is what protects.
    static func plainlySpawnedOutput(script: String) throws -> String {
        var channel: [Int32] = [-1, -1]
        guard pipe(&channel) == 0 else { throw Failure.spawnRefused }
        let readEnd = channel[0]
        var writeEnd = channel[1]
        defer {
            _ = Darwin.close(readEnd)
            if writeEnd != -1 { _ = Darwin.close(writeEnd) }
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.spawnRefused }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)

        var pid: pid_t = 0
        let spawned = "/bin/sh".withCString { path in
            script.withCString { scriptArgument -> Int32 in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(path), strdup("-c"), strdup(scriptArgument), nil,
                ]
                defer { argv.forEach { free($0) } }
                return posix_spawn(&pid, path, &actions, nil, &argv, environ)
            }
        }
        guard spawned == 0 else { throw Failure.spawnRefused }

        _ = Darwin.close(writeEnd)
        writeEnd = -1
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(readEnd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer.prefix(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                break
            }
        }
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
        return String(decoding: collected, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func terminateAndReap(_ process: PTYProcess) {
        terminateAndReap(pid: process.processIdentifier)
    }

    static func terminateAndReap(pid: pid_t) {
        guard pid > 1 else { return }
        // The child is the session and process-group leader, so these group signals include the
        // leader and every process its script started. Never signal the bare pid after waiting:
        // the actor may already have reaped it, at which point that pid no longer belongs to us.
        _ = Darwin.kill(-pid, SIGCONT)
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    static func processState(pid: pid_t) -> Int8? {
        var information = kinfo_proc()
        var byteCount = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = name.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &information, &byteCount, nil, 0)
        }
        guard result == 0, byteCount != 0 else { return nil }
        return information.kp_proc.p_stat
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path.withCString({ realpath($0, &resolved) }) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let end = resolved.firstIndex(of: 0) ?? resolved.endIndex
        let bytes = resolved[..<end].map { UInt8(bitPattern: $0) }
        return URL(filePath: String(decoding: bytes, as: UTF8.self))
    }
}
