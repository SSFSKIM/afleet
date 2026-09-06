import Foundation

/// Tolerant reads of the four holder files. The CLI's own reader is defensive — it drops a mistyped optional field
/// rather than throwing the file away — and so is this one: a wrong-typed *optional* becomes `nil`, and only a
/// missing or mistyped *required* field rejects the file.
private extension KeyedDecodingContainer {
    /// The value when it is present and of the right type; `nil` when it is absent, null, or of any other type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// A file larger than this is skipped unread: no holder record the CLI writes is anywhere near it, and a reader
/// that walks a config home must not be made to allocate by whatever happens to sit under `sessions/`.
public let fleetRecordSizeLimit = 262_144

/// `<configHome>/sessions/<pid>.json` as the CLI writes it (parity 38.2; bundle 2.1.258 registry writer). Read-only:
/// afleet never writes this file, and an unknown key round-trips nowhere because it is dropped on read.
public struct RegistryRecord: Codable, Hashable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    /// Milliseconds since the epoch (bundle 515624).
    public var startedAt: Double
    /// The trimmed `ps -o lstart=` string under `LC_ALL=C TZ=UTC` (bundle 515820).
    public var procStart: String?
    public var version: String?
    /// `interactive` or `bg`.
    public var kind: String
    public var entrypoint: String?
    public var name: String?
    public var nameSource: String?
    public var jobId: String?
    public var parkedJobId: String?
    /// TUI processes carry these five; headless ones never do.
    public var status: String?
    public var waitingFor: String?
    public var state: String?
    public var detail: String?
    public var tempo: String?
    public var messagingSocketPath: String?

    public init(pid: Int32, sessionId: String, cwd: String, startedAt: Double, procStart: String? = nil,
                version: String? = nil, kind: String, entrypoint: String? = nil, name: String? = nil,
                nameSource: String? = nil, jobId: String? = nil, parkedJobId: String? = nil, status: String? = nil,
                waitingFor: String? = nil, state: String? = nil, detail: String? = nil, tempo: String? = nil,
                messagingSocketPath: String? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.startedAt = startedAt
        self.procStart = procStart; self.version = version; self.kind = kind; self.entrypoint = entrypoint
        self.name = name; self.nameSource = nameSource; self.jobId = jobId; self.parkedJobId = parkedJobId
        self.status = status; self.waitingFor = waitingFor; self.state = state; self.detail = detail
        self.tempo = tempo; self.messagingSocketPath = messagingSocketPath
    }

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, version, kind, entrypoint, name, nameSource
        case jobId, parkedJobId, status, waitingFor, state, detail, tempo, messagingSocketPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        startedAt = try c.decode(Double.self, forKey: .startedAt)
        kind = try c.decode(String.self, forKey: .kind)
        cwd = c.lenient(String.self, .cwd) ?? ""
        procStart = c.lenient(String.self, .procStart)
        version = c.lenient(String.self, .version)
        entrypoint = c.lenient(String.self, .entrypoint)
        name = c.lenient(String.self, .name)
        nameSource = c.lenient(String.self, .nameSource)
        jobId = c.lenient(String.self, .jobId)
        parkedJobId = c.lenient(String.self, .parkedJobId)
        status = c.lenient(String.self, .status)
        waitingFor = c.lenient(String.self, .waitingFor)
        state = c.lenient(String.self, .state)
        detail = c.lenient(String.self, .detail)
        tempo = c.lenient(String.self, .tempo)
        messagingSocketPath = c.lenient(String.self, .messagingSocketPath)
    }

    /// `nil` rather than a throw: a file the reader cannot use is skipped and counted, never fatal.
    public static func decode(_ data: Data) -> RegistryRecord? {
        guard data.count <= fleetRecordSizeLimit else { return nil }
        return try? JSONDecoder().decode(RegistryRecord.self, from: data)
    }
}

/// `<configHome>/daemon/roster.json`.
public struct RosterRecord: Codable, Hashable, Sendable {
    public struct Worker: Codable, Hashable, Sendable {
        public var pid: Int32?
        public var procStart: String?
        public init(pid: Int32? = nil, procStart: String? = nil) { self.pid = pid; self.procStart = procStart }
        enum CodingKeys: String, CodingKey { case pid, procStart }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = c.lenient(Int32.self, .pid)
            procStart = c.lenient(String.self, .procStart)
        }
    }
    public var proto: Int?
    public var supervisorPid: Int32?
    public var updatedAt: Double?
    /// Keyed by job short.
    public var workers: [String: Worker]

    public init(proto: Int? = nil, supervisorPid: Int32? = nil, updatedAt: Double? = nil, workers: [String: Worker]) {
        self.proto = proto; self.supervisorPid = supervisorPid; self.updatedAt = updatedAt; self.workers = workers
    }

    enum CodingKeys: String, CodingKey { case proto, supervisorPid, updatedAt, workers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workers = try c.decode([String: Worker].self, forKey: .workers)
        proto = c.lenient(Int.self, .proto)
        supervisorPid = c.lenient(Int32.self, .supervisorPid)
        updatedAt = c.lenient(Double.self, .updatedAt)
    }

    public static func decode(_ data: Data) -> RosterRecord? {
        guard data.count <= fleetRecordSizeLimit else { return nil }
        return try? JSONDecoder().decode(RosterRecord.self, from: data)
    }
}

/// `<configHome>/jobs/<short>/state.json`, the fields C4 reads. `exit-cause` and `exit-detail` are destructive to
/// read and are never opened.
public struct JobRecord: Codable, Hashable, Sendable {
    /// `starting`, `resuming`, `adopted`, `crashed`, `working`, `blocked`, `done`, `failed`, `stopped`.
    public var state: String
    public var tempo: String?
    public var template: String?
    public var backend: String?
    public var sessionId: String?
    public var resumeSessionId: String?
    public var cwd: String?
    public var intent: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var needs: String?

    public static let terminalStates: Set<String> = ["done", "failed", "stopped"]
    public var isTerminal: Bool { Self.terminalStates.contains(state) }

    public init(state: String, tempo: String? = nil, template: String? = nil, backend: String? = nil,
                sessionId: String? = nil, resumeSessionId: String? = nil, cwd: String? = nil, intent: String? = nil,
                createdAt: String? = nil, updatedAt: String? = nil, needs: String? = nil) {
        self.state = state; self.tempo = tempo; self.template = template; self.backend = backend
        self.sessionId = sessionId; self.resumeSessionId = resumeSessionId; self.cwd = cwd; self.intent = intent
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.needs = needs
    }

    enum CodingKeys: String, CodingKey {
        case state, tempo, template, backend, sessionId, resumeSessionId, cwd, intent, createdAt, updatedAt, needs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        tempo = c.lenient(String.self, .tempo)
        template = c.lenient(String.self, .template)
        backend = c.lenient(String.self, .backend)
        sessionId = c.lenient(String.self, .sessionId)
        resumeSessionId = c.lenient(String.self, .resumeSessionId)
        cwd = c.lenient(String.self, .cwd)
        intent = c.lenient(String.self, .intent)
        createdAt = c.lenient(String.self, .createdAt)
        updatedAt = c.lenient(String.self, .updatedAt)
        needs = c.lenient(String.self, .needs)
    }

    public static func decode(_ data: Data) -> JobRecord? {
        guard data.count <= fleetRecordSizeLimit else { return nil }
        return try? JSONDecoder().decode(JobRecord.self, from: data)
    }
}

/// One element of `claude agents --json` (bundle 2.1.258 `printAgentsJson`): a bare array sorted by `startedAt`,
/// job rows carrying `id` and `state`, registry rows carrying neither.
public struct AgentsRow: Codable, Hashable, Sendable {
    public var pid: Int32?
    /// The job short, on a job row only.
    public var id: String?
    public var cwd: String
    /// `background` or `interactive`.
    public var kind: String
    public var startedAt: Double
    public var sessionId: String?
    public var name: String?
    public var status: String?
    public var waitingFor: String?
    /// `working`, `blocked`, `done`, `failed`, `stopped`; absent on an interactive registry row.
    public var state: String?

    public init(pid: Int32? = nil, id: String? = nil, cwd: String, kind: String, startedAt: Double,
                sessionId: String? = nil, name: String? = nil, status: String? = nil, waitingFor: String? = nil,
                state: String? = nil) {
        self.pid = pid; self.id = id; self.cwd = cwd; self.kind = kind; self.startedAt = startedAt
        self.sessionId = sessionId; self.name = name; self.status = status; self.waitingFor = waitingFor
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case pid, id, cwd, kind, startedAt, sessionId, name, status, waitingFor, state
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        startedAt = try c.decode(Double.self, forKey: .startedAt)
        cwd = c.lenient(String.self, .cwd) ?? ""
        pid = c.lenient(Int32.self, .pid)
        id = c.lenient(String.self, .id)
        sessionId = c.lenient(String.self, .sessionId)
        name = c.lenient(String.self, .name)
        status = c.lenient(String.self, .status)
        waitingFor = c.lenient(String.self, .waitingFor)
        state = c.lenient(String.self, .state)
    }

    /// The rows of one `agents --json` array; an element that does not decode is dropped, not fatal.
    public static func decodeArray(_ data: Data) -> [AgentsRow] {
        guard let elements = try? JSONDecoder().decode([FailableRow].self, from: data) else { return [] }
        return elements.compactMap(\.row)
    }

    private struct FailableRow: Decodable {
        let row: AgentsRow?
        init(from decoder: any Decoder) throws { row = try? AgentsRow(from: decoder) }
    }
}
