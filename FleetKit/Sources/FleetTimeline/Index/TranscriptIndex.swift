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
    /// for each URL it resolved. An update's survivors are decided over this list. A list and not a set: a session has
    /// one file and occasionally two, and hashing a `URL` costs more than scanning two of them.
    private var candidates: [SessionID: [URL]] = [:]
    /// Slug entries under `projects/` that are symlinks, counted by the last build. They are skipped, and skipping them
    /// is parity: the engine's own lookup drops any directory entry whose `Dirent.isDirectory()` is false, which a
    /// symlink's is, so a session under one is a session the CLI itself cannot find. The count is reported so the app can
    /// say so rather than leaving the difference invisible.
    private var symlinkedProjects = 0

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
        symlinkedProjects = 0
        let discovered = await discoverMainFiles()
        try Task.checkCancellation()
        let reads = await readAll(discovered)
        try Task.checkCancellation()

        var entries: [SessionID: IndexEntry] = [:]
        candidates = [:]
        entries.reserveCapacity(reads.count)
        candidates.reserveCapacity(reads.count)
        for (file, entry) in reads {
            candidates[file.sessionID, default: []].append(file.url)
            if let existing = entries[file.sessionID], !supersedes(entry, existing) { continue }
            entries[file.sessionID] = entry
        }
        current = IndexSnapshot(configHome: root, builtAt: Date(), entries: entries)
        diagnostics.record(.indexBuilt(files: reads.count, symlinkedProjectsSkipped: symlinkedProjects, durationMs: milliseconds(since: started)))
        return current
    }

    /// A later `mtime` wins; equal `mtime` is broken by the lexicographically smaller path, so a build's outcome does
    /// not depend on the order the task group happened to finish in.
    private func supersedes(_ candidate: IndexEntry, _ incumbent: IndexEntry) -> Bool {
        if candidate.mtime != incumbent.mtime { return candidate.mtime > incumbent.mtime }
        return candidate.path.path < incumbent.path.path
    }

    /// The read **and** the entry it yields, both inside the task group. `makeEntry` is `nonisolated` and touches no
    /// state of this actor, so building an entry is work the pool can do `concurrency`-wide; leaving it on the actor
    /// serialised every file's scan behind one executor and left the other cores idle for the whole build (gate G2).
    ///
    /// One task per lane rather than one per file, each lane striding through the list: a task and an actor resumption
    /// per file cost more than the file's own two reads, and striding keeps the lanes even without work stealing. The
    /// result's order is the lanes' and not completion order, which changes nothing — `supersedes` is a total order over
    /// `mtime` then path precisely so that the group's ordering cannot reach the outcome.
    private func readAll(_ files: [MainFile]) async -> [(MainFile, IndexEntry)] {
        guard !files.isEmpty else { return [] }
        let reader = self.reader
        return await Self.inParallel(over: files.count, width: min(concurrency, files.count)) { [self] lane, width in
            var built: [(MainFile, IndexEntry)] = []
            var index = lane
            while index < files.count, !Task.isCancelled {
                let file = files[index]
                if let read = try? reader.read(file.url) { built.append((file, makeEntry(file, read))) }
                index += width
            }
            return built
        }
    }

    /// `width` lanes striding through `count` items, run in a detached task and concatenated in lane order.
    ///
    /// Detached deliberately. Awaited inline from a caller whose own task is bound to a serial executor — an XCTest
    /// method, or any `@MainActor` caller — the same group ran at about a third of the machine's width and the build took
    /// twice as long. A cold index's throughput should not depend on who asked for it, so the work is given its own task
    /// and the caller's cancellation is forwarded to it.
    nonisolated private static func inParallel<Element: Sendable>(
        over count: Int, width: Int, _ lane: @escaping @Sendable (Int, Int) -> [Element]
    ) async -> [Element] {
        let work = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: [Element].self) { group in
                for index in 0..<width { group.addTask { lane(index, width) } }
                var out: [Element] = []
                out.reserveCapacity(count)
                for await result in group { out.append(contentsOf: result) }
                return out
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private struct MainFile: Sendable { let url: URL; let slug: String; let sessionID: SessionID; var sessionDirectory = true }

    /// Top-level directories of `projects/` only, and inside each only `<uuid>.jsonl` files. Never descends further.
    ///
    /// The file level is listed by name rather than by `URL`: a `URL` per listed entry, standardised and then taken apart
    /// again by `TranscriptPath.resolve`, cost more than every transcript's read put together. The name decides, and a
    /// `URL` is built only for a name that is a main transcript. A slug that is a symlink is skipped, which is the
    /// engine's own rule — its `readdir` loop drops any entry whose `Dirent.isDirectory()` is false (2.1.258
    /// `cli.pretty.js:13753-13755`), and a symlink's is.
    private func discoverMainFiles() async -> [MainFile] {
        let manager = FileManager.default
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard let slugs = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var directories: [URL] = []
        for slugURL in slugs {
            guard (try? slugURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                if (try? slugURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { symlinkedProjects += 1 }
                continue
            }
            directories.append(slugURL)
        }
        // The per-directory listing is `concurrency` lanes wide for the same reason the reads are: on a real home this is
        // five hundred directories and three thousand names, and it was the largest serial stretch of the build.
        let all = directories
        // The per-directory listing is `concurrency` lanes wide for the same reason the reads are: on a real home this is
        // five hundred directories and three thousand names, and it was the largest serial stretch of the build.
        let listed = await Self.inParallel(over: all.count, width: min(concurrency, max(1, all.count))) { lane, width in
            var built: [(path: String, file: MainFile)] = []
            var index = lane
            while index < all.count, !Task.isCancelled {
                built.append(contentsOf: Self.mainFiles(in: all[index]))
                index += width
            }
            return built
        }
        // Decorated, because `URL.path` builds a string each time it is asked and a comparison sort asks it a dozen
        // times per element.
        return listed.sorted { $0.path < $1.path }.map(\.file)
    }

    /// One slug directory's main transcripts, with each file's path carried alongside for the sort.
    nonisolated private static func mainFiles(in slugURL: URL) -> [(path: String, file: MainFile)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: slugURL.path) else { return [] }
        // `contentsOfDirectory` reports `/private/var/…` where `resolvingSymlinksInPath` reports `/var/…`; both name one
        // file, so a listed URL is put in the same form as a handed-in one before it is stored. The resolution is the
        // slug directory's and every file in it shares it, so it is made once per directory.
        let canonicalSlug = slugURL.resolvingSymlinksInPath().standardizedFileURL
        let slug = canonicalSlug.lastPathComponent
        let base = canonicalSlug.path
        let entries = Set(names)
        var out: [(path: String, file: MainFile)] = []
        for name in names {
            guard let id = TranscriptPath.mainTranscript(fileName: name) else { continue }
            // A `<sessionId>/subagents/` directory can only exist when `<sessionId>` is itself an entry of this
            // directory, and the listing already says whether it is. Without the hint every file paid a `stat`.
            out.append((base + "/" + name,
                        MainFile(url: canonicalSlug.appendingPathComponent(name), slug: slug, sessionID: id,
                                 sessionDirectory: entries.contains("\(id)"))))
        }
        return out
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
                if !(candidates[id]?.contains(url) ?? false) { candidates[id, default: []].append(url) }
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
            candidates[id] = alive.map(\.url)
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
        for (id, entry) in loaded.entries { candidates[id, default: []].append(entry.path) }
        return loaded
    }

    public func persist() async throws { try await storage.save(current) }

    // MARK: - One entry from one head-and-tail read

    /// Two `BufferScan`s — one over the head's bytes, one over the tail's — and every field comes out of those two
    /// passes. Before this the entry was a dozen grapheme-aware scans over two 64 KiB Swift `String`s, measured at
    /// 19.8 ms per file, which was the whole of the cold build's cost (gate G2).
    nonisolated private func makeEntry(_ file: MainFile, _ headTail: HeadTail) -> IndexEntry {
        let head = BufferScan(headTail.headBytes, keys: Self.headKeys)
        let tail = BufferScan(headTail.tailBytes, keys: Self.tailKeys)
        let aiTitle = tail.lastString("aiTitle")
        let customTitle = tail.lastString("customTitle")
        let summary = tail.lastString("summary")
        let agentName = tail.lastString("agentName")
        let firstPrompt = head.firstPrompt()
        let lastPrompt = tail.lastLineString(type: "last-prompt", key: "lastPrompt")
        let (title, titleSource) = TitlePrecedence.title(agentName: agentName, customTitle: customTitle, aiTitle: aiTitle,
                                                         summary: summary, firstPrompt: firstPrompt, sessionID: file.sessionID)
        let preview = String((lastPrompt ?? summary ?? (firstPrompt.isEmpty ? nil : firstPrompt) ?? "").prefix(200))
        return IndexEntry(
            sessionID: file.sessionID,
            path: file.url,
            slug: file.slug,
            cwd: tail.lastLineString(type: "relocated", key: "relocatedCwd") ?? head.firstLineString("cwd"),
            title: title,
            titleSource: titleSource,
            firstPrompt: firstPrompt.isEmpty ? nil : firstPrompt,
            lastPrompt: lastPrompt,
            preview: preview,
            gitBranch: tail.lastString("gitBranch") ?? head.firstString("gitBranch"),
            tag: tail.lastLineString(type: "tag", key: "tag"),
            agentName: agentName,
            mtime: headTail.mtime,
            size: headTail.size,
            createdAt: head.firstString("timestamp").flatMap(Self.timestamp),
            entrypoint: head.firstString("entrypoint"),
            sessionKind: head.firstString("sessionKind"),
            isSidechain: head.sidechain(),
            teamName: head.firstString("teamName"),
            continuedIn: tail.lastLineString(type: "continued-in", key: "continuedInSessionId").flatMap(SessionID.init),
            clearedToEmpty: tail.clearedToEmpty(),
            hasSubagents: file.sessionDirectory && subagentsPresent(besides: file.url, session: file.sessionID),
            turnCount: nil)
    }

    /// Every key either buffer's pass looks for. `type` is in both because three of the helpers prefilter on it.
    private static let headKeys = ["cwd", "gitBranch", "timestamp", "entrypoint", "sessionKind", "teamName", "isSidechain", "type"]
    private static let tailKeys = ["aiTitle", "customTitle", "summary", "agentName", "gitBranch",
                                   "lastPrompt", "relocatedCwd", "tag", "continuedInSessionId", "type"]

    /// A `<sessionId>/subagents/` directory beside the main file. The directory is noted, never descended.
    nonisolated private func subagentsPresent(besides main: URL, session: SessionID) -> Bool {
        let directory = main.deletingLastPathComponent()
            .appendingPathComponent("\(session)", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The engine writes an ISO 8601 instant in UTC with milliseconds and a `Z` suffix (the shape
    /// `2026-01-02T03:04:05.678Z` has, spelled here with invented digits); a formatter without fractional seconds is
    /// tried second because a
    /// record whose timestamp carries none would otherwise be dropped. The formatters are made per call rather than
    /// cached, because `ISO8601DateFormatter` is a reference type and not `Sendable`.
    ///
    /// That per-call construction is why the canonical shape is parsed arithmetically first: two `ISO8601DateFormatter`s
    /// per file take a process-wide ICU lock, and in the cold build's profile that lock, not the parse, was what the
    /// worker threads were waiting on. The fast path is a strict subset — anything it does not fully validate falls
    /// through to the formatters, which remain the definition of the result.
    private static func timestamp(_ text: String) -> Date? {
        if let quick = zuluTimestamp(text) { return quick }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.sssZ`, and nothing else: every separator checked, every field a
    /// digit, the day checked against the month's length, and the seconds proper (a leap second falls through). The
    /// civil-days arithmetic is the standard one; UTC is the only zone this shape can name.
    private static func zuluTimestamp(_ text: String) -> Date? {
        let u = Array(text.utf8)
        guard u.count == 20 || u.count == 24, u[u.count - 1] == UInt8(ascii: "Z") else { return nil }
        guard u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"), u[10] == UInt8(ascii: "T"),
              u[13] == UInt8(ascii: ":"), u[16] == UInt8(ascii: ":") else { return nil }
        func digits(_ from: Int, _ length: Int) -> Int? {
            var value = 0
            for i in from..<(from + length) {
                let d = Int(u[i]) - 48
                guard (0...9).contains(d) else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) else { return nil }
        var milli = 0
        if u.count == 24 {
            guard u[19] == UInt8(ascii: "."), let value = digits(20, 3) else { return nil }
            milli = value
        }
        guard (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1, day <= lengths[month - 1] else { return nil }
        // Days from 1970-01-01, shifting the year to start in March so a leap day is always last (Howard Hinnant's).
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(seconds) + Double(milli) / 1000)
    }

    private func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}
