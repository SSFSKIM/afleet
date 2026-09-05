import Foundation
import ClaudeWire

/// The cold index over a config home's transcripts: one head-and-tail read per main file, one entry per logical session.
///
/// Discovery is a full listing of `projects/*/` every time rather than the picker's fan-out by cwd, because afleet lists
/// every project and because a relocated session's file lives under a slug its cwd no longer produces. `<sessionId>/`
/// directories are noted for `hasSubagents` and never descended; `memory/`, `tool-results/`, `.meta.json` sidecars and
/// anything that is not a `<uuid>.jsonl` directly under a slug are ignored.
///
/// Entries are keyed by session id and two files can carry one id — a later snapshot of the session, or the same session
/// at a new slug after a relocation with the old file not yet gone. The actor therefore remembers, per id, every main
/// file it has seen carry that id, and `update(changed:)` decides over that set rather than over the named URLs alone.
public actor TranscriptIndex {
    private let configHome: ConfigHome
    /// The config home with its path's symlinks resolved. One file has more than one spelling on macOS — a directory
    /// listing reports `/private/var/…` where `resolvingSymlinksInPath` reports `/var/…`, and FSEvents reports the
    /// real path — so every URL this actor stores or is handed is put in this one form. Without it the same file would
    /// join `candidates` twice under two spellings and an update would not recognise the entry it already has.
    private let root: URL
    private let storage: any IndexStorage
    private let reader: any HeadTailReading
    private let concurrency: Int
    private let diagnostics: any TimelineDiagnosticsSink
    private var current: IndexSnapshot
    /// Every main file the actor has seen carry an id: filled by `build()` for each file it read and by every `update`
    /// for each URL it resolved. An update's survivors are decided over this set.
    private var candidates: [SessionID: Set<URL>] = [:]

    public init(configHome: ConfigHome,
                storage: any IndexStorage,
                reader: any HeadTailReading = HeadTailReader(),
                concurrency: Int = 16,
                diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics()) {
        self.configHome = configHome
        self.root = configHome.root.resolvingSymlinksInPath().standardizedFileURL
        self.storage = storage
        self.reader = reader
        self.concurrency = max(1, concurrency)
        self.diagnostics = diagnostics
        self.current = IndexSnapshot(configHome: root, builtAt: .distantPast, entries: [:])
    }

    public var snapshot: IndexSnapshot { current }

    public func entry(_ id: SessionID) -> IndexEntry? { current.entries[id] }

    // MARK: - The cold build

    public func build() async throws -> IndexSnapshot {
        let started = Date()
        let discovered = discoverMainFiles()
        let reads = try await readAll(discovered)

        var entries: [SessionID: IndexEntry] = [:]
        candidates = [:]
        for (file, headTail) in reads {
            candidates[file.sessionID, default: []].insert(file.url)
            let entry = makeEntry(file, headTail)
            if let existing = entries[file.sessionID], !supersedes(entry, existing) { continue }
            entries[file.sessionID] = entry
        }
        current = IndexSnapshot(configHome: root, builtAt: Date(), entries: entries)
        diagnostics.record(.indexBuilt(files: reads.count, durationMs: milliseconds(since: started)))
        return current
    }

    /// A later `mtime` wins; equal `mtime` is broken by the lexicographically smaller path, so a build's outcome does
    /// not depend on the order the task group happened to finish in.
    private func supersedes(_ candidate: IndexEntry, _ incumbent: IndexEntry) -> Bool {
        if candidate.mtime != incumbent.mtime { return candidate.mtime > incumbent.mtime }
        return candidate.path.path < incumbent.path.path
    }

    private func readAll(_ files: [MainFile]) async throws -> [(MainFile, HeadTail)] {
        guard !files.isEmpty else { return [] }
        let reader = self.reader
        return try await withThrowingTaskGroup(of: (MainFile, HeadTail?).self) { group in
            var out: [(MainFile, HeadTail)] = []
            var next = 0
            let width = min(concurrency, files.count)
            while next < width { let file = files[next]; group.addTask { (file, try? reader.read(file.url)) }; next += 1 }
            while let (file, headTail) = try await group.next() {
                if let headTail { out.append((file, headTail)) }
                if next < files.count { let file = files[next]; group.addTask { (file, try? reader.read(file.url)) }; next += 1 }
            }
            return out
        }
    }

    private struct MainFile: Sendable { let url: URL; let slug: String; let sessionID: SessionID }

    /// Top-level directories of `projects/` only, and inside each only `<uuid>.jsonl` files. Never descends further.
    private func discoverMainFiles() -> [MainFile] {
        let manager = FileManager.default
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard let slugs = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [MainFile] = []
        for slugURL in slugs {
            guard (try? slugURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let contents = try? manager.contentsOfDirectory(at: slugURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for item in contents {
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
                // `contentsOfDirectory` reports `/private/var/…` where `resolvingSymlinksInPath` reports `/var/…`;
                // both name one file, so a listed URL is put in the same form as a handed-in one before it is stored.
                let url = canonical(item)
                guard let (stream, kind) = TranscriptPath.resolve(url, under: root),
                      case .mainTranscript(let slug) = kind else { continue }
                out.append(MainFile(url: url, slug: slug, sessionID: stream.sessionID))
            }
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - The incremental update

    /// Every URL is resolved first and the decision is made per session id, because two files can carry one id. For each
    /// id a `.mainTranscript` URL named, the pool is `candidates[id] ∪ named`; all of it is stat-ed, the vanished are
    /// dropped, and the entry is rebuilt from the survivor whose `mtime` is latest — whatever order `changed` named the
    /// URLs, and even when the batch named only the file that vanished. Only an id with nothing left is `removed`, so a
    /// session is never `removed` and `added` in one update. Discovery of files whose directory was not named is not
    /// attempted here: the watcher names directories and the app passes the directory's new files.
    public func update(changed: [URL]) async -> IndexDelta {
        let started = Date()
        var namedSessions: [SessionID] = []
        var named: Set<SessionID> = []
        var agentOnly: Set<SessionID> = []
        for given in changed {
            let url = canonical(given)
            guard let (stream, kind) = TranscriptPath.resolve(url, under: root) else { continue }
            let id = stream.sessionID
            switch kind {
            case .mainTranscript:
                if named.insert(id).inserted { namedSessions.append(id) }
                candidates[id, default: []].insert(url)
            case .agentTranscript, .agentMetadata:
                agentOnly.insert(id)
            }
        }

        var delta = IndexDelta()
        for id in namedSessions {
            switch reconcile(id) {
            case .added: delta.added.append(id)
            case .updated: delta.updated.append(id)
            case .removed: delta.removed.append(id)
            case .skipped: break
            }
        }
        for id in agentOnly where !named.contains(id) {
            guard var entry = current.entries[id] else { continue }
            let flag = subagentsPresent(besides: entry.path, session: id)
            guard flag != entry.hasSubagents else { continue }
            entry.hasSubagents = flag
            current.entries[id] = entry
            delta.updated.append(id)
        }

        delta.durationMs = milliseconds(since: started)
        diagnostics.record(.indexUpdated(changed: changed.count, durationMs: delta.durationMs))
        return delta
    }

    private enum Outcome { case added, updated, removed, skipped }

    private func reconcile(_ id: SessionID) -> Outcome {
        var alive: [Stamped] = []
        for url in candidates[id] ?? [] {
            guard let stamp = stamp(url) else { continue }
            alive.append(Stamped(url: url, mtime: stamp.mtime, size: stamp.size))
        }
        let existing = current.entries[id]

        while !alive.isEmpty {
            candidates[id] = Set(alive.map(\.url))
            let winner = pick(alive, preferring: existing?.path)
            if let existing, winner.url == existing.path, winner.mtime == existing.mtime, winner.size == existing.size {
                return .skipped
            }
            guard let (_, kind) = TranscriptPath.resolve(winner.url, under: root),
                  case .mainTranscript(let slug) = kind,
                  let headTail = try? reader.read(winner.url) else {
                alive.removeAll { $0.url == winner.url }
                continue
            }
            current.entries[id] = makeEntry(MainFile(url: winner.url, slug: slug, sessionID: id), headTail)
            return existing == nil ? .added : .updated
        }

        candidates[id] = nil
        return current.entries.removeValue(forKey: id) == nil ? .skipped : .removed
    }

    private struct Stamped { let url: URL; let mtime: Date; let size: Int64 }

    /// The latest `mtime`; a tie goes to the entry's current path, and failing that to the lexicographically smaller one.
    private func pick(_ alive: [Stamped], preferring current: URL?) -> Stamped {
        let latest = alive.lazy.map(\.mtime).max()!
        let top = alive.filter { $0.mtime == latest }
        if let current, let match = top.first(where: { $0.url == current }) { return match }
        return top.min { $0.url.path < $1.url.path }!
    }

    /// The path's symlinks resolved, but never the last component's: a symlinked transcript stays a symlink so the
    /// reader's `O_NOFOLLOW` and this actor's `lstat` can both go on refusing it.
    private func canonical(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    /// `lstat`, not `stat`, and regular files only — the same refusal of a symlink the head-and-tail reader makes with
    /// `O_NOFOLLOW`, and the same arithmetic on `st_mtimespec`, so a stamp taken here compares equal to one the reader took.
    private func stamp(_ url: URL) -> (mtime: Date, size: Int64)? {
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
        guard ok, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return (mtime, Int64(info.st_size))
    }

    // MARK: - Persistence

    /// `storage.load()`; the loaded snapshot is adopted as this index's own only when its config home is this one's.
    public func loadPersisted() async throws -> IndexSnapshot? {
        guard let loaded = try await storage.load() else { return nil }
        guard loaded.configHome.standardizedFileURL == root else { return loaded }
        current = loaded
        candidates = [:]
        for (id, entry) in loaded.entries { candidates[id, default: []].insert(entry.path) }
        return loaded
    }

    public func persist() async throws { try await storage.save(current) }

    // MARK: - One entry from one head-and-tail read

    private func makeEntry(_ file: MainFile, _ headTail: HeadTail) -> IndexEntry {
        let head = headTail.head, tail = headTail.tail
        let aiTitle = HeadTailReader.lastString(tail, key: "aiTitle")
        let customTitle = HeadTailReader.lastString(tail, key: "customTitle")
        let summary = HeadTailReader.lastString(tail, key: "summary")
        let agentName = HeadTailReader.lastString(tail, key: "agentName")
        let firstPrompt = HeadTailReader.firstPrompt(head)
        let lastPrompt = HeadTailReader.lastLineString(tail, type: "last-prompt", key: "lastPrompt")
        let (title, titleSource) = TitlePrecedence.title(agentName: agentName, customTitle: customTitle, aiTitle: aiTitle,
                                                         summary: summary, firstPrompt: firstPrompt, sessionID: file.sessionID)
        let preview = String((lastPrompt ?? summary ?? (firstPrompt.isEmpty ? nil : firstPrompt) ?? "").prefix(200))
        return IndexEntry(
            sessionID: file.sessionID,
            path: file.url,
            slug: file.slug,
            cwd: HeadTailReader.lastLineString(tail, type: "relocated", key: "relocatedCwd")
                ?? HeadTailReader.firstLineString(head, key: "cwd"),
            title: title,
            titleSource: titleSource,
            firstPrompt: firstPrompt.isEmpty ? nil : firstPrompt,
            lastPrompt: lastPrompt,
            preview: preview,
            gitBranch: HeadTailReader.lastString(tail, key: "gitBranch") ?? HeadTailReader.firstString(head, key: "gitBranch"),
            tag: HeadTailReader.lastLineString(tail, type: "tag", key: "tag"),
            agentName: agentName,
            mtime: headTail.mtime,
            size: headTail.size,
            createdAt: HeadTailReader.firstString(head, key: "timestamp").flatMap(Self.timestamp),
            entrypoint: HeadTailReader.firstString(head, key: "entrypoint"),
            sessionKind: HeadTailReader.firstString(head, key: "sessionKind"),
            isSidechain: Self.sidechain(head),
            teamName: HeadTailReader.firstString(head, key: "teamName"),
            continuedIn: HeadTailReader.lastLineString(tail, type: "continued-in", key: "continuedInSessionId").flatMap(SessionID.init),
            clearedToEmpty: Self.clearedToEmpty(tail),
            hasSubagents: subagentsPresent(besides: file.url, session: file.sessionID),
            turnCount: nil)
    }

    /// A `<sessionId>/subagents/` directory beside the main file. The directory is noted, never descended.
    private func subagentsPresent(besides main: URL, session: SessionID) -> Bool {
        let directory = main.deletingLastPathComponent()
            .appendingPathComponent("\(session)", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// True when the head carries an `"isSidechain":true` before any `"isSidechain":false`. Both spellings of the
    /// separator are accepted, because the committed recordings are re-serialised with a space after the colon.
    private static func sidechain(_ head: String) -> Bool {
        func firstOffset(_ value: String) -> Int? {
            ["\"isSidechain\":\(value)", "\"isSidechain\": \(value)"]
                .compactMap { head.range(of: $0, options: .literal).map { head.distance(from: head.startIndex, to: $0.lowerBound) } }
                .min()
        }
        guard let trueAt = firstOffset("true") else { return false }
        guard let falseAt = firstOffset("false") else { return true }
        return trueAt < falseAt
    }

    /// The last `last-prompt` line in the tail, cleared: a null `leafUuid` and an explicit `true`.
    private static func clearedToEmpty(_ tail: String) -> Bool {
        let marks = ["\"type\":\"last-prompt\"", "\"type\": \"last-prompt\""]
        for line in tail.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            guard marks.contains(where: { line.contains($0) }) else { continue }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let object = value.objectValue, object["type"]?.stringValue == "last-prompt" else { continue }
            guard case .null? = object["leafUuid"] else { return false }
            return object["explicit"]?.boolValue == true
        }
        return false
    }

    /// The engine writes `2026-09-04T11:04:10.700Z`; a formatter without fractional seconds is tried second because a
    /// record whose timestamp carries none would otherwise be dropped. The formatters are made per call rather than
    /// cached, because `ISO8601DateFormatter` is a reference type and not `Sendable`.
    private static func timestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}
