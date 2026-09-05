import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Gate G2's correctness half: one entry per logical session, the engine's title precedence, the relocated cwd
/// overriding the recorded one, subagent files counted but not listed, `.meta.json` and `memory/` ignored, and
/// `update(changed:)` re-reading only what changed — asserted by a counting reader, never by timing.
final class TranscriptIndexTests: XCTestCase {

    // MARK: - The tree

    /// Every fixture copy gets an explicit modification date, because a `touch` that appended a record would change the
    /// file's content and its census. The two fixtures that are a second snapshot of a session another fixture already
    /// recorded are placed last and dated a second later, so each shared id's entry carries the later snapshot.
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let laterDate = baseDate.addingTimeInterval(1)
    private static let laterSnapshots: Set<String> = ["resume-no-replay", "session-mirror-resume"]
    /// The two fixtures whose session id a later snapshot also carries, so their file wins no entry.
    private static let shadowed: Set<String> = ["plain-two-turn", "session-mirror-relocation"]
    /// The two synthetic fixtures: invented bytes with no `entrypoint` line.
    private static let syntheticNames = ["dialog-fable-overage", "dialog-refusal-fallback"]

    private struct Tree {
        let temp: TempTree
        /// fixture name → the main transcript placed under a slug of the same name.
        let mains: [String: URL]
        let fixtures: [String: FixtureCorpus.Fixture]
    }

    private func corpusTree() throws -> Tree {
        let temp = try TempTree()
        let all = try FixtureCorpus.all()
        var withMain: [FixtureCorpus.Fixture] = []
        for fixture in all where try fixture.transcriptFiles().contains(where: { if case .mainTranscript = $0.1 { return true } else { return false } }) {
            withMain.append(fixture)
        }
        let ordered = withMain.filter { !Self.laterSnapshots.contains($0.name) }
            + withMain.filter { Self.laterSnapshots.contains($0.name) }

        var mains: [String: URL] = [:]
        var fixtures: [String: FixtureCorpus.Fixture] = [:]
        for fixture in ordered {
            let main = try temp.add(fixture, slug: fixture.name)
            try temp.setModificationDate(main, Self.laterSnapshots.contains(fixture.name) ? Self.laterDate : Self.baseDate)
            mains[fixture.name] = canonical(main)
            fixtures[fixture.name] = fixture
        }

        // Two neighbours the index must ignore: a memory directory under one slug and a stray text file under another.
        let memory = temp.projects.appendingPathComponent("plain-two-turn", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("invented note, not an engine byte\n".utf8).write(to: memory.appendingPathComponent("MEMORY.md"))
        try Data("invented note, not an engine byte\n".utf8)
            .write(to: temp.projects.appendingPathComponent("control-shapes", isDirectory: true).appendingPathComponent("notes.txt"))

        return Tree(temp: temp, mains: mains, fixtures: fixtures)
    }

    /// The one spelling of a path the index stores: FSEvents reports `/private/var/…` where `TMPDIR` says `/var/…`,
    /// so an expectation built from a `TempTree` URL has to be put in the same form before it is compared.
    private func canonical(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    private func makeIndex(_ temp: TempTree,
                           reader: any HeadTailReading = HeadTailReader(),
                           storage: any IndexStorage = InMemoryIndexStorage(),
                           diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics()) -> TranscriptIndex {
        TranscriptIndex(configHome: ConfigHome(root: temp.root, source: .environment),
                        storage: storage, reader: reader, diagnostics: diagnostics)
    }

    // MARK: - Discovery

    func testOneEntryPerLogicalSessionAndNothingElse() async throws {
        let tree = try corpusTree()
        let notices = RecordingTimelineDiagnostics()
        let index = makeIndex(tree.temp, diagnostics: notices)
        let snapshot = try await index.build()

        XCTAssertEqual(tree.mains.count, 17, "the corpus places seventeen main transcripts")
        XCTAssertEqual(Set(snapshot.entries.keys), Set(tree.fixtures.values.map(\.sessionID)),
                       "entry ids must be exactly the corpus's main-file session ids")
        XCTAssertEqual(snapshot.entries.count, 15,
                       "fifteen logical sessions: plain-two-turn/resume-no-replay and session-mirror-relocation/-resume each share one id")

        // Nothing but a `<slug>/<uuid>.jsonl` won an entry: no memory file, no stray text file, no agent transcript,
        // no `.meta.json` — and each shared id carries the later snapshot's path.
        var expectedPaths: Set<URL> = []
        for (name, url) in tree.mains where !Self.shadowed.contains(name) { expectedPaths.insert(url) }
        XCTAssertEqual(Set(snapshot.entries.values.map(\.path)), expectedPaths)

        let plain = try XCTUnwrap(tree.fixtures["plain-two-turn"])
        let relocation = try XCTUnwrap(tree.fixtures["session-mirror-relocation"])
        XCTAssertEqual(snapshot.entries[plain.sessionID]?.path, tree.mains["resume-no-replay"])
        XCTAssertEqual(snapshot.entries[plain.sessionID]?.slug, "resume-no-replay")
        XCTAssertEqual(snapshot.entries[relocation.sessionID]?.path, tree.mains["session-mirror-resume"])
        XCTAssertEqual(snapshot.entries[relocation.sessionID]?.slug, "session-mirror-resume")

        let withSubagents = Set(snapshot.entries.values.filter(\.hasSubagents).map(\.sessionID))
        let expectedSubagents = Set(try ["explore-depth-1", "nested-depth-2"].map { try XCTUnwrap(tree.fixtures[$0]).sessionID })
        XCTAssertEqual(withSubagents, expectedSubagents)

        XCTAssertTrue(notices.notices.contains { if case .indexBuilt(let files, _, _) = $0 { return files == 17 } else { return false } },
                      "one indexBuilt notice naming the seventeen files read: \(notices.notices)")
    }

    // MARK: - Symlinks under `projects/`

    /// A symlinked slug directory is skipped and counted; a symlinked transcript inside a real slug is refused.
    ///
    /// Skipping the directory is parity, not an omission: the engine's own session lookup iterates `projects/` with
    /// `withFileTypes` and drops any entry whose `Dirent.isDirectory()` is false (2.1.258 `cli.pretty.js:13753-13755`),
    /// which a symlink's is, so a session reached only through one is a session the CLI itself cannot find. Refusing the
    /// file is the reader's `O_NOFOLLOW`, which is the engine's `isFile()` check at line 13937. Both targets are real and
    /// readable here — asserted before the build — so neither absence can be an accident of the tree.
    func testASymlinkedSlugIsSkippedAndCountedAndASymlinkedTranscriptIsRefused() async throws {
        let manager = FileManager.default
        let temp = try TempTree()
        let all = try FixtureCorpus.all()
        let visible = try XCTUnwrap(all.first { $0.name == "plain-two-turn" })
        let behindDirectory = try XCTUnwrap(all.first { $0.name == "control-shapes" })
        let behindFile = try XCTUnwrap(all.first { $0.name == "exit-plan-mode" })
        _ = try temp.add(visible, slug: "visible")

        // A real directory outside `projects/`, holding a real transcript, reachable only through a symlinked slug.
        let outside = temp.root.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let staged = try temp.add(behindDirectory, slug: "staging")
        try manager.moveItem(at: staged, to: outside.appendingPathComponent("\(behindDirectory.sessionID).jsonl"))
        try manager.removeItem(at: temp.projects.appendingPathComponent("staging", isDirectory: true))
        let symlinkedSlug = temp.projects.appendingPathComponent("symlinked-slug", isDirectory: true)
        try manager.createSymbolicLink(at: symlinkedSlug, withDestinationURL: outside)

        // A real transcript outside `projects/`, reachable only through a symlink named like a main transcript.
        let stagedFile = try temp.add(behindFile, slug: "staging")
        let outsideFile = temp.root.appendingPathComponent("outside-transcript.jsonl")
        try manager.moveItem(at: stagedFile, to: outsideFile)
        try manager.removeItem(at: temp.projects.appendingPathComponent("staging", isDirectory: true))
        let symlinkedTranscript = temp.projects.appendingPathComponent("visible", isDirectory: true)
            .appendingPathComponent("\(behindFile.sessionID).jsonl")
        try manager.createSymbolicLink(at: symlinkedTranscript, withDestinationURL: outsideFile)

        // Neither absence below may be an absent file: both symlinks resolve to something real and readable.
        XCTAssertNotNil(try? Data(contentsOf: symlinkedSlug.appendingPathComponent("\(behindDirectory.sessionID).jsonl")),
                        "the symlinked slug resolves to a directory holding a readable transcript")
        XCTAssertNotNil(try? Data(contentsOf: symlinkedTranscript), "the symlinked transcript resolves to a readable file")

        let notices = RecordingTimelineDiagnostics()
        let snapshot = try await makeIndex(temp, diagnostics: notices).build()

        XCTAssertEqual(Set(snapshot.entries.keys), [visible.sessionID],
                       "only the transcript under a real slug is indexed; the two behind symlinks are not")
        XCTAssertTrue(notices.notices.contains {
            if case .indexBuilt(let files, let skipped, _) = $0 { return files == 1 && skipped == 1 } else { return false }
        }, "one file read and one symlinked slug counted: \(notices.notices)")
    }

    // MARK: - The two title fallbacks no fixture reaches

    /// Both terminal branches of `getLogDisplayTitle` are pure functions of five optional strings and an id, so this
    /// needs no fixture, no config home and no file — only invented identifiers.
    func testTitleFallsBackToAutonomousSessionAndThenToTheSessionId() throws {
        let id = try XCTUnwrap(SessionID("3f2a91c4-77bd-4e0a-9c51-6b0e2d8a4f13"))

        // A first prompt that opens with `<tick>` is the engine's mark of a session no user prompted.
        let autonomous = TitlePrecedence.title(agentName: nil, customTitle: nil, aiTitle: nil, summary: nil,
                                               firstPrompt: "<tick>\nwhatever the tick carried</tick>", sessionID: id)
        XCTAssertEqual(autonomous.0, TitlePrecedence.autonomousSession)
        XCTAssertEqual(autonomous.1, .fallback)

        // Nothing at all: eight characters of the id, lowercased as `SessionID.description` gives them.
        let anonymous = TitlePrecedence.title(agentName: nil, customTitle: nil, aiTitle: nil, summary: nil,
                                              firstPrompt: nil, sessionID: id)
        XCTAssertEqual(anonymous.0, "3f2a91c4")
        XCTAssertEqual(anonymous.1, .fallback)
        XCTAssertEqual(anonymous.0.count, 8)

        // A present-but-empty source falls through exactly as JavaScript's `||` makes it, and so does a first prompt
        // that is nothing but an XML-ish block.
        let empty = TitlePrecedence.title(agentName: "", customTitle: "", aiTitle: "", summary: "",
                                          firstPrompt: "<note>ignored</note>", sessionID: id)
        XCTAssertEqual(empty.0, "3f2a91c4")
        XCTAssertEqual(empty.1, .fallback)
    }

    // MARK: - Titles

    func testTitlePrecedenceOnTheCorpus() async throws {
        let tree = try corpusTree()
        let index = makeIndex(tree.temp)
        let snapshot = try await index.build()

        var sourcesSeen: Set<TitleSource> = []
        for entry in snapshot.entries.values {
            let expected = expectedTitle(from: try fullParse(entry.path), sessionID: entry.sessionID)
            XCTAssertEqual(entry.title, expected.title, "title for \(entry.slug)")
            XCTAssertEqual(entry.titleSource, expected.source, "title source for \(entry.slug)")
            sourcesSeen.insert(entry.titleSource)
        }
        XCTAssertEqual(sourcesSeen, [.aiTitle, .firstPrompt],
                       "the corpus should win titles by aiTitle and by firstPrompt and by nothing else")
    }

    // MARK: - The relocated cwd

    func testRelocatedCwdOverridesTheRecordedOne() async throws {
        let tree = try corpusTree()
        let index = makeIndex(tree.temp)
        _ = try await index.build()

        let relocation = try XCTUnwrap(tree.fixtures["session-mirror-relocation"])
        let found = await index.entry(relocation.sessionID)
        let entry = try XCTUnwrap(found)
        let objects = try fullParse(entry.path).objects
        let relocated = try XCTUnwrap(objects.last { $0["type"]?.stringValue == "relocated" }?["relocatedCwd"]?.stringValue)
        let recorded = try XCTUnwrap(objects.first { $0["cwd"]?.stringValue != nil }?["cwd"]?.stringValue)

        XCTAssertNotEqual(relocated, recorded, "the fixture must actually relocate, or this test proves nothing")
        XCTAssertEqual(entry.cwd, relocated)
        XCTAssertNotEqual(entry.cwd, recorded)
    }

    // MARK: - Incremental update

    func testUpdateReReadsOnlyChangedFiles() async throws {
        let tree = try corpusTree()
        let reader = CountingReader()
        let index = makeIndex(tree.temp, reader: reader)
        _ = try await index.build()
        XCTAssertEqual(reader.reads.count, 17, "the cold build reads every main file once")

        // A changed file among two unchanged ones: one read, of that URL.
        reader.forget()
        let touched = try XCTUnwrap(tree.mains["control-shapes"])
        _ = try tree.temp.touch(touched)
        let untouchedA = try XCTUnwrap(tree.mains["permission-allow"])
        let untouchedB = try XCTUnwrap(tree.mains["ask-user-question"])
        let changedDelta = await index.update(changed: [untouchedA, touched, untouchedB])
        XCTAssertEqual(reader.reads, [touched], "only the changed file may be re-read, and it must be that one")
        XCTAssertEqual(changedDelta.updated, [try XCTUnwrap(tree.fixtures["control-shapes"]).sessionID])
        XCTAssertEqual(changedDelta.added, [])
        XCTAssertEqual(changedDelta.removed, [])

        // A vanished file: removed, and nothing read.
        reader.forget()
        let doomed = try XCTUnwrap(tree.mains["notification-hook"])
        let doomedID = try XCTUnwrap(tree.fixtures["notification-hook"]).sessionID
        try tree.temp.remove(doomed)
        let removedDelta = await index.update(changed: [doomed])
        XCTAssertEqual(reader.reads, [])
        XCTAssertEqual(removedDelta.removed, [doomedID])
        XCTAssertEqual(removedDelta.added, [])
        let goneEntry = await index.entry(doomedID)
        XCTAssertNil(goneEntry)

        // A file that appeared under an invented session id: added, read once.
        reader.forget()
        let inventedID = try XCTUnwrap(SessionID(UUID().uuidString))
        let appeared = canonical(tree.temp.projects.appendingPathComponent("control-shapes", isDirectory: true)
            .appendingPathComponent("\(inventedID).jsonl"))
        try Data(contentsOf: touched).write(to: appeared)
        let addedDelta = await index.update(changed: [appeared])
        XCTAssertEqual(reader.reads, [appeared])
        XCTAssertEqual(addedDelta.added, [inventedID])
        XCTAssertEqual(addedDelta.updated, [])
        XCTAssertEqual(addedDelta.removed, [])
    }

    /// The record appended is the file's own last `last-prompt`, edited: `leafUuid` nulled and `explicit` set. Nothing
    /// here invents a recording — it mutates a recorded record, because no fixture witnesses a cleared prompt.
    func testClearedToEmptyIsReadFromTheTail_mutation() async throws {
        let tree = try corpusTree()
        let index = makeIndex(tree.temp)
        _ = try await index.build()

        let fixture = try XCTUnwrap(tree.fixtures["control-shapes"])
        let beforeEntry = await index.entry(fixture.sessionID)
        let before = try XCTUnwrap(beforeEntry)
        XCTAssertFalse(before.clearedToEmpty)

        let url = try XCTUnwrap(tree.mains["control-shapes"])
        var record = try XCTUnwrap(try fullParse(url).objects.last { $0["type"]?.stringValue == "last-prompt" })
        record["leafUuid"] = .null
        record["explicit"] = .bool(true)
        var line = try JSONValue.object(record).canonicalData()
        line.append(UInt8(ascii: "\n"))
        try tree.temp.appendRaw(line, to: url)

        let delta = await index.update(changed: [url])
        XCTAssertEqual(delta.updated, [fixture.sessionID])
        let afterEntry = await index.entry(fixture.sessionID)
        let after = try XCTUnwrap(afterEntry)
        XCTAssertTrue(after.clearedToEmpty)
    }

    // MARK: - The storage seam

    func testSnapshotRoundTripsThroughStorage() async throws {
        let tree = try corpusTree()
        let storage = InMemoryIndexStorage()
        let first = makeIndex(tree.temp, storage: storage)
        let built = try await first.build()
        XCTAssertEqual(built.schemaVersion, 1)
        try await first.persist()

        let second = makeIndex(tree.temp, storage: storage)
        let emptyBefore = await second.snapshot
        XCTAssertTrue(emptyBefore.entries.isEmpty)
        let loaded = try await second.loadPersisted()
        XCTAssertEqual(loaded, built)
        let adopted = await second.snapshot
        XCTAssertEqual(adopted, built)
    }

    // MARK: - No drop rule

    func testNoDropRuleIsApplied() async throws {
        let tree = try corpusTree()
        let index = makeIndex(tree.temp)
        let snapshot = try await index.build()

        let synthetic = Set(try Self.syntheticNames.map { try XCTUnwrap(tree.fixtures[$0]).sessionID })
        let recorded = Set(snapshot.entries.keys).subtracting(synthetic)
        let sdkCLI = Set(snapshot.entries.values.filter { $0.entrypoint == "sdk-cli" }.map(\.sessionID))
        XCTAssertEqual(sdkCLI, recorded, "every recorded session is entrypoint sdk-cli and every one of them is listed")
        XCTAssertEqual(sdkCLI.count, 13)
        for id in synthetic {
            let entry = try XCTUnwrap(snapshot.entries[id], "a synthetic session is listed too")
            XCTAssertNil(entry.entrypoint, "the synthetic fixtures carry no entrypoint line")
        }
        XCTAssertTrue(snapshot.entries.values.allSatisfy { !$0.isSidechain })
        XCTAssertTrue(snapshot.entries.values.allSatisfy { $0.continuedIn == nil })
        XCTAssertTrue(snapshot.entries.values.allSatisfy { $0.turnCount == nil })
    }

    // MARK: - Two files, one id

    func testALaterSnapshotOfASessionUpdatesItsEntry() async throws {
        let temp = try TempTree()
        let plain = try FixtureCorpus.named("plain-two-turn")
        let resume = try FixtureCorpus.named("resume-no-replay")
        XCTAssertEqual(plain.sessionID, resume.sessionID, "the two fixtures are two snapshots of one session")

        let main = canonical(try temp.add(plain, slug: "plain-two-turn"))
        let index = makeIndex(temp)
        let built = try await index.build()
        XCTAssertEqual(built.entries.count, 1)
        let before = try XCTUnwrap(built.entries[plain.sessionID])

        let later = try Data(contentsOf: resume.transcriptRoot
            .appendingPathComponent("_slug_", isDirectory: true)
            .appendingPathComponent("\(resume.sessionID).jsonl"))
        try later.write(to: main)

        let delta = await index.update(changed: [main])
        XCTAssertEqual(delta.updated, [plain.sessionID])
        XCTAssertEqual(delta.added, [])
        XCTAssertEqual(delta.removed, [])
        let afterEntry = await index.entry(plain.sessionID)
        let after = try XCTUnwrap(afterEntry)
        XCTAssertEqual(after.size, Int64(later.count))
        XCTAssertGreaterThan(after.size, before.size)
    }

    func testRelocationToANewSlugUpdatesThePathNeverRemovesAndAdds() async throws {
        try await relocationCase(named: { old, new in [old, new] })
        try await relocationCase(named: { old, new in [new, old] })
    }

    private func relocationCase(named order: (URL, URL) -> [URL]) async throws {
        let temp = try TempTree()
        let fixture = try FixtureCorpus.named("session-mirror-relocation")
        let old = canonical(try temp.add(fixture, slug: "old-slug"))
        let index = makeIndex(temp)
        let built = try await index.build()
        XCTAssertEqual(built.entries[fixture.sessionID]?.path, old)

        try temp.relocate(session: fixture.sessionID, from: "old-slug", to: "new-slug")
        let new = canonical(temp.projects.appendingPathComponent("new-slug", isDirectory: true)
            .appendingPathComponent("\(fixture.sessionID).jsonl"))

        let delta = await index.update(changed: order(old, new))
        XCTAssertEqual(delta.updated, [fixture.sessionID], "order \(order(old, new).map(\.lastPathComponent))")
        XCTAssertEqual(delta.removed, [])
        XCTAssertEqual(delta.added, [])
        let relocated = await index.entry(fixture.sessionID)
        let entry = try XCTUnwrap(relocated)
        XCTAssertEqual(entry.path, new)
        XCTAssertEqual(entry.slug, "new-slug")
    }

    func testWhenTwoFilesCarryOneIdTheLaterMtimeWins() async throws {
        try await twoFileCase(named: { old, new in [old, new] })
        try await twoFileCase(named: { old, new in [new, old] })
    }

    private func twoFileCase(named order: (URL, URL) -> [URL]) async throws {
        let temp = try TempTree()
        let fixture = try FixtureCorpus.named("session-mirror-relocation")
        let old = canonical(try temp.add(fixture, slug: "old-slug"))
        let new = canonical(try temp.add(fixture, slug: "new-slug"))
        try temp.setModificationDate(old, Self.baseDate)
        try temp.setModificationDate(new, Self.baseDate.addingTimeInterval(-10))

        let index = makeIndex(temp)
        let built = try await index.build()
        XCTAssertEqual(built.entries.count, 1, "two files, one id, one entry")
        XCTAssertEqual(built.entries[fixture.sessionID]?.path, old, "the later mtime is the old slug's, so far")

        try temp.setModificationDate(new, Self.baseDate.addingTimeInterval(10))
        let delta = await index.update(changed: order(old, new))
        XCTAssertEqual(delta.updated, [fixture.sessionID], "order \(order(old, new).map { $0.deletingLastPathComponent().lastPathComponent })")
        XCTAssertEqual(delta.added, [])
        XCTAssertEqual(delta.removed, [])
        let winner = await index.entry(fixture.sessionID)
        let entry = try XCTUnwrap(winner)
        XCTAssertEqual(entry.path, new)
        XCTAssertEqual(entry.slug, "new-slug")
    }

    func testDeletingTheWinnerAloneFallsBackToTheSurvivingAlias() async throws {
        let temp = try TempTree()
        let fixture = try FixtureCorpus.named("session-mirror-relocation")
        let old = canonical(try temp.add(fixture, slug: "old-slug"))
        let new = canonical(try temp.add(fixture, slug: "new-slug"))
        try temp.setModificationDate(old, Self.baseDate)
        try temp.setModificationDate(new, Self.baseDate.addingTimeInterval(10))

        let index = makeIndex(temp)
        let built = try await index.build()
        XCTAssertEqual(built.entries[fixture.sessionID]?.path, new)

        try temp.remove(new)
        let first = await index.update(changed: [new])
        XCTAssertEqual(first.updated, [fixture.sessionID])
        XCTAssertEqual(first.removed, [])
        XCTAssertEqual(first.added, [])
        let survivorEntry = await index.entry(fixture.sessionID)
        let survivor = try XCTUnwrap(survivorEntry)
        XCTAssertEqual(survivor.path, old, "the alias only the build saw keeps the entry alive")
        XCTAssertEqual(survivor.slug, "old-slug")

        try temp.remove(old)
        let second = await index.update(changed: [old])
        XCTAssertEqual(second.removed, [fixture.sessionID])
        XCTAssertEqual(second.updated, [])
        XCTAssertEqual(second.added, [])
        let gone = await index.entry(fixture.sessionID)
        XCTAssertNil(gone)
    }

    // MARK: - A reader that counts, and which URLs it was asked for

    /// `@unchecked Sendable` is sound because the one mutable field is `urls` and every read and write of it happens
    /// between `lock.lock()` and `lock.unlock()` of this instance's private `NSLock`, which is the serialising mechanism.
    private final class CountingReader: HeadTailReading, @unchecked Sendable {
        private let inner = HeadTailReader()
        private let lock = NSLock()
        private var urls: [URL] = []

        var reads: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        func forget() { lock.lock(); defer { lock.unlock() }; urls = [] }

        func read(_ url: URL) throws -> HeadTail? {
            lock.lock(); urls.append(url); lock.unlock()
            return try inner.read(url)
        }
    }

    // MARK: - An independent full parse, and an independent precedence walk

    private struct Parsed {
        var objects: [[String: JSONValue]] = []
        var agentName: String?
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String = ""
    }

    /// Every line of the whole file parsed as JSON — not the head-and-tail substrings the index reads, and not a second
    /// call into `TitlePrecedence`. The last top-level string value wins for each title field, and the first prompt is
    /// walked out of the parsed records by this file's own implementation.
    private func fullParse(_ url: URL) throws -> Parsed {
        var parsed = Parsed()
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  let object = value.objectValue else { continue }
            parsed.objects.append(object)
            if let v = object["agentName"]?.stringValue { parsed.agentName = v }
            if let v = object["customTitle"]?.stringValue { parsed.customTitle = v }
            if let v = object["aiTitle"]?.stringValue { parsed.aiTitle = v }
            if let v = object["summary"]?.stringValue { parsed.summary = v }
        }
        parsed.firstPrompt = independentFirstPrompt(parsed.objects)
        return parsed
    }

    private func independentFirstPrompt(_ objects: [[String: JSONValue]]) -> String {
        var commandFallback = ""
        for object in objects {
            guard object["type"]?.stringValue == "user" else { continue }
            if object["isMeta"]?.boolValue == true || object["isCompactSummary"]?.boolValue == true { continue }
            guard let message = object["message"]?.objectValue, let content = message["content"] else { continue }
            var texts: [String] = []
            switch content {
            case .string(let text): texts = [text]
            case .array(let blocks):
                var toolResult = false
                for block in blocks {
                    guard let fields = block.objectValue else { continue }
                    if fields["type"]?.stringValue == "tool_result" { toolResult = true }
                    if fields["type"]?.stringValue == "text", let text = fields["text"]?.stringValue { texts.append(text) }
                }
                if toolResult { continue }
            default: continue
            }
            for raw in texts {
                var text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                if let name = body(of: "command-name", in: text) {
                    if commandFallback.isEmpty { commandFallback = name }
                    continue
                }
                if let command = body(of: "bash-input", in: text) {
                    return "! " + command.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if opensWithTag(text) { continue }
                if text.utf16.count > 200 {
                    text = String(decoding: Array(text.utf16)[0..<200], as: UTF16.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
                }
                return text
            }
        }
        return commandFallback
    }

    /// The precedence walk, written here rather than borrowed: agentName, customTitle, aiTitle, summary, the stripped
    /// first prompt, `Autonomous session` when that prompt opened with `<tick>`, and finally eight characters of the id.
    private func expectedTitle(from parsed: Parsed, sessionID: SessionID) -> (title: String, source: TitleSource) {
        let tick = parsed.firstPrompt.hasPrefix("<tick>")
        let strippedPrompt = stripBlocks(parsed.firstPrompt)

        var chosen: String
        var source: TitleSource
        if let v = parsed.agentName, !v.isEmpty { chosen = v; source = .agentName }
        else if let v = parsed.customTitle, !v.isEmpty { chosen = v; source = .customTitle }
        else if let v = parsed.aiTitle, !v.isEmpty { chosen = v; source = .aiTitle }
        else if let v = parsed.summary, !v.isEmpty { chosen = v; source = .summary }
        else if !strippedPrompt.isEmpty, !tick { chosen = strippedPrompt; source = .firstPrompt }
        else if tick { chosen = TitlePrecedence.autonomousSession; source = .fallback }
        else { chosen = String(sessionID.description.prefix(8)); source = .fallback }

        let display = stripBlocks(chosen)
        return (display.isEmpty ? chosen.trimmingCharacters(in: .whitespacesAndNewlines) : display, source)
    }

    /// `<tag …>…</tag>` blocks removed, by scanning rather than by a regular expression.
    private func stripBlocks(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            guard let (name, bodyStart) = tagName(in: rest, from: open) else {
                out += rest[..<rest.index(after: open)]
                rest = rest[rest.index(after: open)...]
                continue
            }
            guard let close = rest.range(of: "</\(name)>", options: .literal, range: bodyStart..<rest.endIndex) else {
                out += rest[..<rest.index(after: open)]
                rest = rest[rest.index(after: open)...]
                continue
            }
            out += rest[..<open]
            var after = close.upperBound
            if after < rest.endIndex, rest[after] == "\n" { after = rest.index(after: after) }
            rest = rest[after...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name of an opening tag starting at `open`, and the index just past its `>`; nil when this is not one.
    private func tagName(in text: Substring, from open: Substring.Index) -> (String, Substring.Index)? {
        var i = text.index(after: open)
        guard i < text.endIndex, let first = text[i].asciiValue, first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") else { return nil }
        var name = String(text[i])
        i = text.index(after: i)
        while i < text.endIndex, let c = text[i].asciiValue,
              (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-") {
            name.append(text[i]); i = text.index(after: i)
        }
        guard i < text.endIndex else { return nil }
        if text[i] == ">" { return (name, text.index(after: i)) }
        guard text[i].isWhitespace, let end = text[i...].firstIndex(of: ">") else { return nil }
        return (name, text.index(after: end))
    }

    private func opensWithTag(_ text: String) -> Bool {
        if text.hasPrefix("[Request interrupted by user"), text.contains("]") { return true }
        let trimmed = Substring(text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard let open = trimmed.firstIndex(of: "<"), open == trimmed.startIndex else { return false }
        return tagName(in: trimmed, from: open) != nil
    }

    private func body(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>", options: .literal),
              let close = text.range(of: "</\(tag)>", options: .literal, range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
