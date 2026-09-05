import Foundation
import AfleetCore
@testable import FleetSessions

/// What a scripted registry record says about the process that wrote it.
enum ProcStartField {
    /// The token `ProcessLiveness` would compute for the pid — the CLI's own format.
    case correct
    /// The field is missing, so liveness must fall back to the `startedAt` window.
    case absent
    /// Exactly this string, whatever it is.
    case literal(String)
}

/// Writes the three holder sources into a `ScratchConfigHome` the way the CLI writes them.
///
/// A pid used for a live holder is the *test's own* pid: it is alive, its start time is knowable, and no test may
/// signal or inspect a process it did not start. A pid used for a dead holder is 2_147_483_000, which is above every
/// pid macOS will hand out and is therefore never live.
final class ScriptedHolderFiles: @unchecked Sendable {   // `lock` serialises every file mutation
    static let livePID: Int32 = ProcessInfo.processInfo.processIdentifier
    static let deadPID: Int32 = 2_147_483_000

    let home: ScratchConfigHome
    private let lock = NSLock()
    private var _onStopJob: (@Sendable (String) -> Void)?
    private var _stopRemovesWorker = true
    private var _agentsListsJobs = true

    init(home: ScratchConfigHome) { self.home = home }

    /// Runs after `stop <short>` has rewritten the files, so a test can kill the helper process standing in for the
    /// worker the CLI would have ended.
    var onStopJob: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStopJob }
        set { lock.lock(); _onStopJob = newValue; lock.unlock() }
    }

    /// A `stop` that leaves the worker named in the roster: the handoff that never completes.
    var stopRemovesWorker: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopRemovesWorker }
        set { lock.lock(); _stopRemovesWorker = newValue; lock.unlock() }
    }

    /// An `agents --json` that omits the jobs: the CLI exited zero and the roster names the worker, but the listing
    /// the sidebar reads does not have it.
    var agentsListsJobs: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _agentsListsJobs }
        set { lock.lock(); _agentsListsJobs = newValue; lock.unlock() }
    }

    var root: URL { home.url }

    // MARK: - The registry

    func writeRegistry(pid: Int32, sessionID: SessionID, kind: String = "interactive", entrypoint: String? = "cli",
                       startedAt: Double? = nil, procStart: ProcStartField = .correct, status: String? = nil,
                       waitingFor: String? = nil, name: String? = nil, cwd: URL? = nil) throws {
        var record: [String: Any] = [
            "pid": Int(pid),
            "sessionId": sessionID.description,
            "cwd": (cwd ?? root).path(percentEncoded: false),
            "startedAt": startedAt ?? (Date().timeIntervalSince1970 * 1000),
            "kind": kind,
        ]
        if let entrypoint { record["entrypoint"] = entrypoint }
        if let status { record["status"] = status }
        if let waitingFor { record["waitingFor"] = waitingFor }
        if let name { record["name"] = name }
        switch procStart {
        case .correct: if let token = ProcessLiveness.procStartToken(for: pid) { record["procStart"] = token }
        case .absent: break
        case .literal(let value): record["procStart"] = value
        }
        try write(record, to: root.appending(path: "sessions/\(pid).json"))
    }

    func removeRegistry(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root.appending(path: "sessions/\(pid).json"))
    }

    /// Every registry record on disk right now, for the `agents --json` stand-in.
    func registryRecords() -> [RegistryRecord] {
        lock.lock(); defer { lock.unlock() }
        let directory = root.appending(path: "sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.sorted().compactMap { name in
            (try? Data(contentsOf: directory.appending(path: name))).flatMap(RegistryRecord.decode)
        }
    }

    // MARK: - Jobs and the roster

    /// Writes `jobs/<short>/state.json` and, when `pid` is given, names the worker in the roster.
    func writeJob(short: String, state: String = "working", sessionID: SessionID? = nil,
                  resumeSessionID: SessionID? = nil, cwd: URL? = nil, pid: Int32? = nil) throws {
        var record: [String: Any] = ["state": state, "template": "bg", "cwd": (cwd ?? root).path(percentEncoded: false)]
        if let sessionID { record["sessionId"] = sessionID.description }
        if let resumeSessionID { record["resumeSessionId"] = resumeSessionID.description }
        try FileManager.default.createDirectory(at: root.appending(path: "jobs/\(short)"),
                                                withIntermediateDirectories: true)
        try write(record, to: root.appending(path: "jobs/\(short)/state.json"))
        if let pid {
            try mutateRoster { workers in
                var worker: [String: Any] = ["pid": Int(pid)]
                if let token = ProcessLiveness.procStartToken(for: pid) { worker["procStart"] = token }
                workers[short] = worker
            }
        }
    }

    /// Names a worker in the roster on its own, for a test that needs the job file and the roster entry to appear
    /// at different moments.
    func addRosterWorker(short: String, pid: Int32) throws {
        try mutateRoster { workers in
            var worker: [String: Any] = ["pid": Int(pid)]
            if let token = ProcessLiveness.procStartToken(for: pid) { worker["procStart"] = token }
            workers[short] = worker
        }
    }

    /// Takes a worker out of the roster on its own: the daemon's half of a `stop` the CLI has already returned
    /// from, so a test can place the removal after something else it is watching for.
    func removeRosterWorker(short: String) throws {
        try mutateRoster { $0.removeValue(forKey: short) }
    }

    /// What `claude stop <short>` does to the files: the job goes terminal and its worker leaves the roster.
    func stopJob(short: String) throws {
        let file = root.appending(path: "jobs/\(short)/state.json")
        var record = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        record["state"] = "stopped"
        try write(record, to: file)
        if stopRemovesWorker { try mutateRoster { $0.removeValue(forKey: short) } }
        onStopJob?(short)
    }

    func jobShorts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ((try? FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "jobs").path(percentEncoded: false))) ?? []).filter { !$0.hasPrefix(".") }
    }

    func job(_ short: String) -> JobRecord? {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: root.appending(path: "jobs/\(short)/state.json"))).flatMap(JobRecord.decode)
    }

    func rosterWorkers() -> [String: RosterRecord.Worker] {
        lock.lock(); defer { lock.unlock() }
        return (try? Data(contentsOf: root.appending(path: "daemon/roster.json")))
            .flatMap(RosterRecord.decode)?.workers ?? [:]
    }

    // MARK: - Internals

    private func mutateRoster(_ change: (inout [String: Any]) -> Void) throws {
        let file = root.appending(path: "daemon/roster.json")
        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        var workers = document["workers"] as? [String: Any] ?? [:]
        change(&workers)
        document["workers"] = workers
        document["updatedAt"] = Date().timeIntervalSince1970 * 1000
        try write(document, to: file)
    }

    /// Deliberately *not* atomic. An atomic write is a rename, and a rename fires the observer's directory source;
    /// a TUI editing its own record in place does not. Writing straight to the path keeps both cases honest: a new
    /// file still fires the source, an overwritten one does not, and only the poll can see it.
    private func write(_ object: [String: Any], to file: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }
}
