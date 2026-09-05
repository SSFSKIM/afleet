import Foundation
import ClaudeWire

/// One row of the engine's background-task registry as the host mirrors it (parity §20.8).
///
/// The engine never sends the registry as a whole; it sends `task_started`, `task_updated`, `task_progress`,
/// `task_notification` and `background_tasks_changed`, and the host folds them. `listedByEngine` is the one field the
/// engine restates wholesale, and it is a liveness cross-check only: `background_tasks_changed` carries a thinner
/// payload than the registry and omits rows the user has foregrounded, so it may never contradict a status.
public struct RegistryEntry: Hashable, Sendable, Identifiable, Codable {
    /// The engine's `task_id`.
    public let id: String
    public var kind: TaskKind
    public var placement: Placement
    public var description: String
    public var toolUseID: String?
    /// Where the task's output is written. For a `.localBash` row this is a real file the tailer follows; for a
    /// `.localAgent` row it is a symlink into the agent's transcript sidecar, which is read through the ingestion.
    public var outputFile: URL?
    public var status: TaskStatus
    public var startedAt: Date
    public var endedAt: Date?
    /// When any frame naming this task last arrived — the host's clock, not the engine's `end_time`.
    public var lastFrameAt: Date
    /// The host has seen the `task_notification` that hands the result back. Until then the work is unfinished from
    /// the host's point of view even once the status is terminal.
    public var notified: Bool
    public var listedByEngine: Bool
    public var epoch: ProcessEpoch
    public var summary: String?
    public var usage: JSONValue?
    /// How many `task_started` frames this id has carried: a re-armed id is one row that ran more than once.
    public var startedCount: Int

    public enum Placement: String, Sendable, Codable { case foreground, background }

    public init(id: String, kind: TaskKind, placement: Placement = .background, description: String = "",
                toolUseID: String? = nil, outputFile: URL? = nil, status: TaskStatus = .running,
                startedAt: Date, endedAt: Date? = nil, lastFrameAt: Date, notified: Bool = false,
                listedByEngine: Bool = false, epoch: ProcessEpoch, summary: String? = nil,
                usage: JSONValue? = nil, startedCount: Int = 0) {
        self.id = id; self.kind = kind; self.placement = placement; self.description = description
        self.toolUseID = toolUseID; self.outputFile = outputFile; self.status = status
        self.startedAt = startedAt; self.endedAt = endedAt; self.lastFrameAt = lastFrameAt
        self.notified = notified; self.listedByEngine = listedByEngine; self.epoch = epoch
        self.summary = summary; self.usage = usage; self.startedCount = startedCount
    }
}

/// The host's copy of the engine's background-task registry, folded from the task frames of one session.
///
/// It is a value: Task 8's reducer folds frames into it, and C4's dormancy rule reads `liveWork(asOf:)` — a session
/// with live work is never dormant, whatever its transcript's last mtime says.
public struct RegistryMirror: Hashable, Sendable {
    public private(set) var entries: [String: RegistryEntry]

    public init() { entries = [:] }

    // MARK: - Folding frames

    /// Folds `task_started`, `task_updated`, `task_progress`, `task_notification` and `background_tasks_changed`.
    /// Every other system subtype is ignored. Returns the task ids the frame touched.
    @discardableResult
    public mutating func apply(_ frame: SystemFrame, at now: Date, epoch: ProcessEpoch) -> [String] {
        switch frame {
        case .taskStarted(let started):
            var entry = existing(started.taskID, kind: TaskKind(wire: started.taskType ?? "local_bash"), at: now, epoch: epoch)
            entry.kind = TaskKind(wire: started.taskType ?? "local_bash")
            entry.placement = started.isBackgrounded == true ? .background : .foreground
            entry.description = started.description
            if let toolUseID = started.toolUseID { entry.toolUseID = toolUseID }
            entry.status = .running
            entry.notified = false
            entry.endedAt = nil
            entry.startedCount += 1
            entry.startedAt = now
            entry.epoch = epoch
            entry.lastFrameAt = now
            entries[entry.id] = entry
            return [entry.id]

        case .taskUpdated(let updated):
            var entry = existing(updated.taskID, kind: .localBash, at: now, epoch: epoch)
            let patch = updated.patch
            if let status = patch["status"]?.stringValue { entry.status = TaskStatus(wire: status) }
            if let end = patch["end_time"]?.intValue { entry.endedAt = Date(timeIntervalSince1970: Double(end) / 1000) }
            if let description = patch["description"]?.stringValue { entry.description = description }
            entry.lastFrameAt = now
            entries[entry.id] = entry
            return [entry.id]

        case .taskProgress(let progress):
            var entry = existing(progress.taskID, kind: .localAgent, at: now, epoch: epoch)
            entry.description = progress.description
            if let toolUseID = progress.toolUseID { entry.toolUseID = toolUseID }
            entry.lastFrameAt = now
            entries[entry.id] = entry
            return [entry.id]

        case .taskNotification(let notification):
            var entry = existing(notification.taskID, kind: .localBash, at: now, epoch: epoch)
            entry.status = TaskStatus(wire: notification.status)     // already normalised by the engine
            entry.notified = true
            entry.summary = notification.summary
            if let usage = notification.usage { entry.usage = usage }
            if !notification.outputFile.isEmpty { entry.outputFile = URL(fileURLWithPath: notification.outputFile) }
            if let toolUseID = notification.toolUseID { entry.toolUseID = toolUseID }
            if entry.endedAt == nil { entry.endedAt = now }
            entry.lastFrameAt = now
            entries[entry.id] = entry
            return [entry.id]

        case .backgroundTasksChanged(let changed):
            var listed: Set<String> = []
            for task in changed.tasks.arrayValue ?? [] {
                guard let id = task["task_id"]?.stringValue else { continue }
                listed.insert(id)
                var entry = existing(id, kind: TaskKind(wire: task["task_type"]?.stringValue ?? "local_bash"), at: now, epoch: epoch)
                if entries[id] == nil, let description = task["description"]?.stringValue { entry.description = description }
                entry.listedByEngine = true
                entry.lastFrameAt = now
                entries[id] = entry
            }
            for id in entries.keys where !listed.contains(id) { entries[id]?.listedByEngine = false }
            return listed.sorted()

        default:
            return []
        }
    }

    /// `tool_progress` is a heartbeat: it proves the task is still being worked, and says nothing else the registry
    /// does not already hold. It never creates a row — an id the mirror has not seen has no registry state to move.
    public mutating func apply(toolProgress: ToolProgressFrame, at now: Date) {
        guard let id = toolProgress.taskID, entries[id] != nil else { return }
        entries[id]?.lastFrameAt = now
    }

    /// The Bash tool's own result sentence: "Command running in background with ID: <id>. Output is being written to:
    /// <path>. …". It binds the output file before any task frame names it, which is what lets the tailer start at the
    /// first byte the command writes.
    public mutating func observe(bashToolResult text: String, toolUseID: String, at now: Date, epoch: ProcessEpoch) {
        guard let id = Self.field(of: text, after: "with ID: "),
              let path = Self.field(of: text, after: "Output is being written to: ") else { return }
        var entry = existing(id, kind: .localBash, at: now, epoch: epoch)
        entry.outputFile = URL(fileURLWithPath: path)
        entry.toolUseID = toolUseID
        entry.placement = .background
        entry.lastFrameAt = now
        entries[id] = entry
    }

    // MARK: - Queries

    /// Work the host must not call finished: anything still running, and anything started whose `task_notification`
    /// has not arrived. `now` is the caller's clock; the predicate does not age, so a task is live until a frame ends
    /// it, never because time passed.
    public func liveWork(asOf now: Date) -> [RegistryEntry] {
        entries.values
            .filter { $0.status == .running || !$0.notified }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    /// Rows the host may forget: notified, terminal, unlisted by the engine, and older than `grace` past their end.
    public func evictable(asOf now: Date, grace: TimeInterval = 30) -> [String] {
        entries.values
            .filter { $0.notified && $0.status != .running && !$0.listedByEngine }
            .filter { ($0.endedAt ?? $0.lastFrameAt).addingTimeInterval(grace) < now }
            .map(\.id)
            .sorted()
    }

    public func entry(forToolUse id: String) -> RegistryEntry? {
        entries.values.filter { $0.toolUseID == id }.sorted { $0.id < $1.id }.first
    }

    // MARK: - Internals

    /// The row for `id`, or a fresh minimal one. A frame may name a task the host never saw start — a resumed session,
    /// or a `background_tasks_changed` that arrives before its `task_started` — and dropping it would lose live work.
    private func existing(_ id: String, kind: TaskKind, at now: Date, epoch: ProcessEpoch) -> RegistryEntry {
        entries[id] ?? RegistryEntry(id: id, kind: kind, startedAt: now, lastFrameAt: now, epoch: epoch)
    }

    /// The text between `anchor` and the sentence that follows it. The engine's sentence ends each field with `". "`,
    /// and neither an id nor a path contains that pair.
    private static func field(of text: String, after anchor: String) -> String? {
        guard let anchored = text.range(of: anchor) else { return nil }
        let rest = text[anchored.upperBound...]
        var value = Substring("")
        if let stop = rest.range(of: ". ") { value = rest[..<stop.lowerBound] } else { value = rest }
        while value.hasSuffix(".") { value = value.dropLast() }
        return value.isEmpty ? nil : String(value)
    }
}
