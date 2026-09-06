import Foundation
import AfleetCore
import WireEnvironment
@testable import FleetSessions

/// A `ProcessRunner` that answers an argv pattern with canned output and records every invocation.
///
/// `fake-claude` emulates no CLI verb — no `agents --json`, `stop`, `--bg` or `auth` — so the verbs are exercised
/// here instead, and a rule may mutate the scripted holder files so that `stop` really does remove a worker from the
/// roster and `--bg --resume` really does create a job with the right `resumeSessionId`.
struct ScriptedProcessRunner: DirectoryProcessRunner {
    struct Rule: Sendable {
        var match: @Sendable ([String]) -> Bool
        var respond: @Sendable ([String]) throws -> ProcessOutput
        init(match: @escaping @Sendable ([String]) -> Bool,
             respond: @escaping @Sendable ([String]) throws -> ProcessOutput) {
            self.match = match; self.respond = respond
        }
    }

    /// The invocations, in order, with the environment each was given: "which environment the verb ran in" is a
    /// claim a caller has to be able to assert, and it is invisible in the arguments.
    final class Recorder: @unchecked Sendable {   // `lock` serialises `storage` and `envs`
        private let lock = NSLock()
        private var storage: [[String]] = []
        private var envs: [[String: String]] = []
        private var directories: [URL?] = []
        private var budgets: [Duration] = []
        init() {}
        var invocations: [[String]] { lock.lock(); defer { lock.unlock() }; return storage }
        var environments: [[String: String]] { lock.lock(); defer { lock.unlock() }; return envs }
        /// The working directory each invocation asked for, nil for a verb that named none: "where did the verb
        /// run" is a claim a caller has to be able to assert, and it is invisible in the arguments.
        var directoriesUsed: [URL?] { lock.lock(); defer { lock.unlock() }; return directories }
        /// The timeout each invocation was given. `CLIVerbs` budgets a read differently from a mutation, and which
        /// budget a verb took is invisible in its arguments and in its output.
        var timeouts: [Duration] { lock.lock(); defer { lock.unlock() }; return budgets }
        @discardableResult func add(_ a: [String], environment: [String: String] = [:],
                                    cwd: URL? = nil, timeout: Duration = .zero) -> Int {
            lock.lock(); defer { lock.unlock() }
            storage.append(a); envs.append(environment); directories.append(cwd); budgets.append(timeout)
            return storage.count - 1
        }
        /// How many invocations began with this prefix.
        func count(prefix: [String]) -> Int {
            invocations.filter { $0.starts(with: prefix) }.count
        }
    }

    var rules: [Rule]
    var calls: Recorder

    init(rules: [Rule], calls: Recorder = Recorder()) { self.rules = rules; self.calls = calls }

    func run(_ executable: URL, arguments: [String], environment: [String: String],
             timeout: Duration) async throws -> ProcessOutput {
        try answer(arguments, environment: environment, cwd: nil, timeout: timeout)
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String], cwd: URL,
             timeout: Duration) async throws -> ProcessOutput {
        try answer(arguments, environment: environment, cwd: cwd, timeout: timeout)
    }

    private func answer(_ arguments: [String], environment: [String: String],
                        cwd: URL?, timeout: Duration) throws -> ProcessOutput {
        calls.add(arguments, environment: environment, cwd: cwd, timeout: timeout)
        for rule in rules where rule.match(arguments) { return try rule.respond(arguments) }
        return .exit(1)
    }

    // MARK: - The default script

    /// The verbs C4 runs, answered off the scripted files and mutating them the way the CLI would.
    static func defaultRules(_ files: ScriptedHolderFiles) -> [Rule] {
        [
            Rule(match: { $0.starts(with: ["agents", "--json"]) },
                 respond: { _ in .exit(0, stdout: agentsJSON(files)) }),
            Rule(match: { $0.count == 2 && $0[0] == "stop" },
                 respond: { argv in try files.stopJob(short: argv[1]); return .exit(0) }),
            Rule(match: { $0.count == 3 && $0[0] == "--bg" && $0[1] == "--resume" },
                 respond: { argv in
                     guard let id = SessionID(argv[2]) else { return .exit(1) }
                     try files.writeJob(short: newShort(), state: "working", sessionID: id, resumeSessionID: id,
                                        pid: ScriptedHolderFiles.livePID)
                     return .exit(0)
                 }),
            Rule(match: { $0.count == 3 && $0[0] == "--bg" && $0[1] == "--exec" },
                 respond: { _ in
                     try files.writeJob(short: newShort(), state: "working", pid: ScriptedHolderFiles.livePID)
                     return .exit(0)
                 }),
            Rule(match: { $0 == ["auth", "logout"] }, respond: { _ in .exit(files.authLogoutExitCode) }),
            Rule(match: { $0 == ["auth", "status"] }, respond: { _ in .exit(0, stdout: #"{"loggedIn": false}"#) }),
        ]
    }

    private static func newShort() -> String { "j" + UUID().uuidString.prefix(6).lowercased() }

    /// `printAgentsJson`'s shape: a bare array, job rows first with `id` and `state`, then the registry rows.
    private static func agentsJSON(_ files: ScriptedHolderFiles) -> String {
        var rows: [[String: Any]] = []
        let workers = files.rosterWorkers()
        var jobPIDs: Set<Int32> = []
        for short in (files.agentsListsJobs ? files.jobShorts().sorted() : []) {
            guard let job = files.job(short) else { continue }
            var row: [String: Any] = ["id": short, "cwd": job.cwd ?? "", "kind": "background",
                                      "startedAt": 0, "state": job.state]
            if let pid = workers[short]?.pid { row["pid"] = Int(pid); jobPIDs.insert(pid) }
            if let session = job.sessionId { row["sessionId"] = session }
            rows.append(row)
        }
        for record in files.registryRecords() where !jobPIDs.contains(record.pid) {
            var row: [String: Any] = ["pid": Int(record.pid), "cwd": record.cwd, "kind": record.kind,
                                      "startedAt": record.startedAt, "sessionId": record.sessionId]
            if let name = record.name { row["name"] = name }
            if let status = record.status { row["status"] = status }
            if let waitingFor = record.waitingFor { row["waitingFor"] = waitingFor }
            rows.append(row)
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension ProcessOutput {
    static func exit(_ code: Int32, stdout: String = "", stderr: String = "") -> ProcessOutput {
        ProcessOutput(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: code, timedOut: false)
    }
}
