import Foundation
import AfleetCore
import Darwin

/// Is the pid in a record still the process that wrote it? The CLI answers this with the pid's liveness and its
/// own `procStart` token (bundle 12922/44087/44114, the `zm(pid, procStart)` comparison over the registry and
/// `daemon/roster.json`), and so does afleet, because a reused pid must never look like a holder.
public enum ProcessLiveness {
    /// Why the sixty-second window had to decide instead of the token.
    public enum Fallback: Hashable, Sendable {
        case procStartAbsent, procStartUnparseable
        /// `kill(pid, 0)` said the process is live but `proc_pidinfo` would not describe it, so no comparison of
        /// any kind could be made.
        case startTimeUnreadable
    }

    public enum Verdict: Hashable, Sendable {
        /// No such process.
        case dead
        /// The process's start time matches the record's `procStart` token within one second.
        case live
        /// No usable token, but the process started inside the window around the record's `startedAt`.
        case liveByWindow(Fallback)
        /// A live pid whose start time contradicts the record's token: a reused pid.
        case startMismatch
        /// A live pid with neither a usable token nor a `startedAt` — a roster worker with a bad token. Not live.
        case unverifiable

        public var isLive: Bool {
            switch self {
            case .live, .liveByWindow: true
            case .dead, .startMismatch, .unverifiable: false
            }
        }
    }

    /// A verdict together with the fallback the evaluation *took*, which is not the same question: a record with an
    /// unparseable token and a stale `startedAt` is `.dead`, and the reader still has to say why it had to guess.
    public struct Evaluation: Hashable, Sendable {
        public var verdict: Verdict
        public var fallback: Fallback?
        public init(verdict: Verdict, fallback: Fallback? = nil) { self.verdict = verdict; self.fallback = fallback }
    }

    /// `kill(pid, 0)` must succeed, or fail with `EPERM`, which still means a live process; anything else is `.dead`.
    /// Then the process's start time from `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec` is compared with the
    /// record's `procStart`, the CLI's own token (the trimmed `ps -o lstart=` string under `LC_ALL=C TZ=UTC`, e.g.
    /// `Fri Sep  5 03:12:41 2026`), parsed as `EEE MMM d HH:mm:ss yyyy` with `en_US_POSIX` and UTC after collapsing
    /// runs of spaces: within one second is `.live`, anything else `.startMismatch`. Only when `procStart` is absent
    /// or does not parse does the sixty-second window around `startedAt` (milliseconds since the epoch) decide.
    public static func evaluate(pid: Int32, startedAt: Double?, procStart: String?,
                                window: Duration = .seconds(60),
                                startTime: StartTimeReader = ProcessLiveness.startTime(of:)) -> Verdict {
        evaluateInDetail(pid: pid, startedAt: startedAt, procStart: procStart, window: window,
                         startTime: startTime).verdict
    }

    /// How the evaluation learns a pid's start time. Production is `ProcessLiveness.startTime(of:)`; a test injects
    /// one that refuses, which is the only way to exercise a `proc_pidinfo` refusal without touching a process the
    /// test did not start.
    public typealias StartTimeReader = @Sendable (Int32) -> Date?

    /// The same answer with the fallback named, for the reader's diagnostics.
    public static func evaluateInDetail(pid: Int32, startedAt: Double?, procStart: String?,
                                        window: Duration = .seconds(60),
                                        startTime: StartTimeReader = ProcessLiveness.startTime(of:)) -> Evaluation {
        guard pid > 0, isRunning(pid: pid) else { return Evaluation(verdict: .dead) }
        // `kill(pid, 0)` has already said this process is live; only the start-time read failed, so neither the
        // token nor the window can be compared against anything. The checks exist to *refuse* a spawn, so an
        // unreadable live pid counts as a holder — the safe direction — and says why it had to.
        guard let actual = startTime(pid) else {
            return Evaluation(verdict: .liveByWindow(.startTimeUnreadable), fallback: .startTimeUnreadable)
        }
        if let token = procStart?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            if let parsed = parse(token: token) {
                let matches = abs(parsed.timeIntervalSince1970 - actual.timeIntervalSince1970) <= 1
                return Evaluation(verdict: matches ? .live : .startMismatch)
            }
            return Evaluation(verdict: byWindow(actual: actual, startedAt: startedAt, window: window,
                                                reason: .procStartUnparseable),
                              fallback: .procStartUnparseable)
        }
        return Evaluation(verdict: byWindow(actual: actual, startedAt: startedAt, window: window,
                                            reason: .procStartAbsent),
                          fallback: .procStartAbsent)
    }

    public static func isLive(pid: Int32, startedAt: Double?, procStart: String?,
                              window: Duration = .seconds(60),
                              startTime: StartTimeReader = ProcessLiveness.startTime(of:)) -> Bool {
        evaluate(pid: pid, startedAt: startedAt, procStart: procStart, window: window, startTime: startTime).isLive
    }

    /// The process's own start time, or nil when the kernel will not describe it.
    public static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// The token the CLI would write for `pid`: its start time in `ps -o lstart=` shape, the day padded to width
    /// two with a space, under `LC_ALL=C TZ=UTC`.
    public static func procStartToken(for pid: Int32) -> String? {
        startTime(of: pid).map(token(for:))
    }

    /// The same formatting, for a `Date` a test already holds.
    public static func token(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let day = calendar.component(.day, from: date)
        let head = formatter("EEE MMM").string(from: date)
        let tail = formatter("HH:mm:ss yyyy").string(from: date)
        return "\(head) \(String(format: "%2d", day)) \(tail)"
    }

    // MARK: - Internals

    private static let utc = TimeZone(identifier: "UTC")!

    /// A fresh formatter per call: `DateFormatter` is a reference type with no `Sendable` guarantee, and liveness is
    /// asked from every actor in the package.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = format
        return f
    }

    /// `kill(pid, 0)` succeeding, or failing with `EPERM`, both mean a live process; anything else is dead.
    public static func isRunning(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Runs of spaces collapse first: `ps -o lstart=` right-aligns the day in width two.
    static func parse(token: String) -> Date? {
        let collapsed = token.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter("EEE MMM d HH:mm:ss yyyy").date(from: collapsed)
    }

    private static func byWindow(actual: Date, startedAt: Double?, window: Duration, reason: Fallback) -> Verdict {
        guard let startedAt else { return .unverifiable }
        let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        let recorded = startedAt / 1000
        return abs(actual.timeIntervalSince1970 - recorded) <= seconds ? .liveByWindow(reason) : .dead
    }
}

/// One read of every holder source under one config home.
public struct HolderSnapshot: Sendable {
    public var holders: HolderSet
    /// Every `jobs/<short>/state.json` that parsed, live or terminal; `LifecycleAPI.jobs()` reads these.
    public var jobs: [JobShort: JobRecord]
    /// Files under `sessions/` that could not be used: a name that is not `<pid>.json`, or content that did not parse.
    public var skipped: Int

    public init(holders: HolderSet, jobs: [JobShort: JobRecord], skipped: Int) {
        self.holders = holders; self.jobs = jobs; self.skipped = skipped
    }

    /// The roster as `LifecycleAPI.jobs()` answers it: every job that has not gone terminal, joined by short to the
    /// holder that names its worker. One derivation, read by the call and by the published roster signal, so a
    /// surface that listens and a surface that polls cannot be told two different things about the same read.
    public var roster: [JobEntry] {
        jobs.filter { !$0.value.isTerminal }.map { short, record in
            let holder = holders.holders.first { $0.jobShort == short.rawValue }
            return JobEntry(short: short, state: record.state, kind: holder?.kind ?? "bg",
                            sessionID: record.sessionId.flatMap(SessionID.init),
                            cwd: record.cwd.map { URL(filePath: $0) },
                            name: holder?.presence?.name)
        }.sorted { $0.short.rawValue < $1.short.rawValue }
    }
}

public protocol HolderReader: Sendable {
    /// Every holder under the config home right now: registry, roster+jobs, and (when `includeAgentsJSON`) the
    /// CLI listing, reconciled by pid into one holder each.
    ///
    /// `label` names the check this read is serving — `beforeSpawn`, `afterHandshake`, `release`, or `poll` for the
    /// observer's own. It is an explicit parameter rather than ambient context because the label assertions are how
    /// G1 proves the ownership checks ran around every spawn, and a mechanism that can silently blank them is not
    /// good enough for that.
    func read(configHome: ConfigHome, ownPIDs: Set<Int32>, includeAgentsJSON: Bool,
              label: String) async -> HolderSnapshot
}

/// The real reader: three sources off the filesystem and the CLI, reconciled by pid.
public struct FileHolderReader: HolderReader {
    private let verbs: CLIVerbs?
    private let diagnostics: any FleetDiagnosticsSink
    private let startTime: ProcessLiveness.StartTimeReader

    /// `verbs: nil` never runs `agents --json`, whatever the caller asks for; the sink receives the liveness fallbacks.
    /// `startTime` is the seam a test uses to make `proc_pidinfo` refuse.
    public init(verbs: CLIVerbs?, diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics(),
                startTime: @escaping ProcessLiveness.StartTimeReader = ProcessLiveness.startTime(of:)) {
        self.verbs = verbs; self.diagnostics = diagnostics; self.startTime = startTime
    }

    /// `label` carries no default here either. Through the protocol every caller must pass one; a default on the
    /// concrete type would let a direct caller omit it and silently read as a poll, which is the crack the explicit
    /// label was introduced to close.
    public func read(configHome: ConfigHome, ownPIDs: Set<Int32>, includeAgentsJSON: Bool,
                     label: String) async -> HolderSnapshot {
        _ = label
        var skipped = 0
        var byPID: [Int32: Holder] = [:]

        // 1. The registry.
        for record in registryRecords(under: configHome, skipped: &skipped) {
            guard let session = SessionID(record.sessionId) else { skipped += 1; continue }
            let evaluation = ProcessLiveness.evaluateInDetail(pid: record.pid, startedAt: record.startedAt,
                                                              procStart: record.procStart, startTime: startTime)
            // The fallback is diagnosed whenever it was taken, live or not: "the token was missing and the window
            // said no" is exactly as much of a warning as "the window said yes".
            switch evaluation.fallback {
            case .procStartAbsent: diagnostics.record(.procStartAbsent(pid: record.pid))
            case .procStartUnparseable: diagnostics.record(.procStartUnparseable(pid: record.pid))
            case .startTimeUnreadable: diagnostics.record(.startTimeUnreadable(pid: record.pid))
            case nil: break
            }
            guard evaluation.verdict.isLive else { continue }
            byPID[record.pid] = Holder(pid: record.pid, sessionID: session, sources: [.registry], kind: record.kind,
                                       entrypoint: record.entrypoint, jobShort: nil,
                                       isOwnChild: ownPIDs.contains(record.pid),
                                       presence: presence(status: record.status, waitingFor: record.waitingFor,
                                                          name: record.name))
        }

        // 2. The roster and the job states. A job is live only while the roster names its worker with a live pid;
        //    a worker has no `startedAt`, so a bad token there is `.unverifiable` and not a holder.
        let jobs = jobRecords(under: configHome)
        let roster = RosterRecord.decode(contents(of: configHome.root.appending(path: "daemon/roster.json")) ?? Data())
        for (short, worker) in roster?.workers ?? [:] {
            guard let pid = worker.pid else { continue }
            let evaluation = ProcessLiveness.evaluateInDetail(pid: pid, startedAt: nil,
                                                              procStart: worker.procStart, startTime: startTime)
            if evaluation.fallback == .startTimeUnreadable { diagnostics.record(.startTimeUnreadable(pid: pid)) }
            guard evaluation.verdict.isLive else { continue }
            if var merged = byPID[pid] {
                // The same worker seen twice: keep both sources, and take the roster's short so the resolver reads
                // a conversation job as a job and never as a foreign terminal.
                merged.sources.insert(.roster)
                merged.jobShort = short
                byPID[pid] = merged
                continue
            }
            // An exec job carries no session and is a `JobEntry` only, never a channel holder.
            guard let record = jobs[JobShort(rawValue: short)], let id = record.sessionId,
                  let session = SessionID(id) else { continue }
            byPID[pid] = Holder(pid: pid, sessionID: session, sources: [.roster], kind: "bg", entrypoint: nil,
                                jobShort: short, isOwnChild: ownPIDs.contains(pid), presence: nil)
        }

        // 3. `claude agents --json`, matched to what is already known by pid, or by (id, sessionId) to a job.
        if includeAgentsJSON, let verbs, let rows = try? await verbs.agentsJSON() {
            for row in rows {
                if let pid = row.pid, var known = byPID[pid] {
                    known.sources.insert(.agentsJSON)
                    // Only a job row's `id` may set `jobShort`: `Holder.isJob` reads it, so an interactive row that
                    // ever carried an id would silently turn a foreign terminal into a background job.
                    if known.jobShort == nil, row.state != nil || row.kind == "background" { known.jobShort = row.id }
                    if known.presence == nil {
                        known.presence = presence(status: row.status, waitingFor: row.waitingFor, name: row.name)
                    }
                    byPID[pid] = known
                    continue
                }
                if row.pid == nil {
                    // A row with no pid names a job by short; it adds nothing the roster did not already say.
                    if let short = row.id, let match = byPID.first(where: { $0.value.jobShort == short }) {
                        var known = match.value
                        known.sources.insert(.agentsJSON)
                        byPID[match.key] = known
                    }
                    continue
                }
                guard let pid = row.pid, let id = row.sessionId, let session = SessionID(id),
                      ProcessLiveness.isLive(pid: pid, startedAt: row.startedAt, procStart: nil,
                                             startTime: startTime) else { continue }
                byPID[pid] = Holder(pid: pid, sessionID: session, sources: [.agentsJSON], kind: row.kind,
                                    entrypoint: nil, jobShort: row.id, isOwnChild: ownPIDs.contains(pid),
                                    presence: presence(status: row.status, waitingFor: row.waitingFor, name: row.name))
            }
        }

        let holders = byPID.values.sorted { $0.pid < $1.pid }
        return HolderSnapshot(holders: HolderSet(holders: holders, observedAt: Date()), jobs: jobs, skipped: skipped)
    }

    // MARK: - Sources

    /// `<pid>.json` and nothing else.
    private static func isRegistryName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy(\.isASCII) && stem.allSatisfy { $0.isNumber }
    }

    private func registryRecords(under configHome: ConfigHome, skipped: inout Int) -> [RegistryRecord] {
        let directory = configHome.root.appending(path: "sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return [] }
        var records: [RegistryRecord] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            guard Self.isRegistryName(name) else { skipped += 1; continue }
            guard let data = contents(of: directory.appending(path: name)),
                  let record = RegistryRecord.decode(data) else { skipped += 1; continue }
            records.append(record)
        }
        return records
    }

    private func jobRecords(under configHome: ConfigHome) -> [JobShort: JobRecord] {
        let directory = configHome.root.appending(path: "jobs")
        guard let shorts = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return [:] }
        var jobs: [JobShort: JobRecord] = [:]
        for short in shorts where !short.hasPrefix(".") {
            guard let data = contents(of: directory.appending(path: "\(short)/state.json")),
                  let record = JobRecord.decode(data) else { continue }
            jobs[JobShort(rawValue: short)] = record
        }
        return jobs
    }

    private func contents(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count <= fleetRecordSizeLimit else { return nil }
        return data
    }

    private func presence(status: String?, waitingFor: String?, name: String?) -> ForeignPresence? {
        guard let status else { return nil }
        return ForeignPresence(status: status, waitingFor: waitingFor, name: name)
    }
}
