import Foundation
import XCTest
@testable import FilesPanel
import AfleetCore
import EditorCore
import FleetKit
import LinkRouting
import PanelHostAPI
import SourceControlCore

/// Spec Design §1, §7, §8 and §9; gates G1.1 through G1.5, G3 and G4's headless halves.
///
/// Every assertion is on the **command sequence** the session emits on the `EditorSurface` seam,
/// which is the observable behaviour C7.7 and the human both see: a target that opened the file
/// and dropped the line, or a resolver that produced the right texts and sent the wrong command,
/// fails here rather than at integration.
///
/// No assertion names a path or carries a buffer (§6.3, §11); every tree is built under the
/// process's temporary directory and no test reads a path it did not create (TCC).
@MainActor
final class FilesPanelSessionTests: XCTestCase {

    private var tree: ScratchTree!

    // `async` rather than `setUpWithError`: this case is main-actor isolated, and the throwing
    // synchronous overrides are not, so building the tree there is a main-actor property mutated
    // from a nonisolated context.
    override func setUp() async throws {
        tree = try ScratchTree()
    }

    override func tearDown() async throws {
        tree?.remove()
        tree = nil
    }

    // MARK: - 1. opening a file link

    func testAFileLinkWithALineEmitsExactlyOneOpenCarryingThatLine() async throws {
        let file = try tree.file("module/notes.swift", "let a = 1\nlet b = 2\n")
        let harness = try makeHarness()

        await harness.session.open(.file(file, line: 42), from: .currentPanel)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.swift", language: "swift",
                              text: "let a = 1\nlet b = 2\n", line: 42)],
                       "one command, and it is the open carrying the link's line")
        XCTAssertTrue(harness.surface.openedPaths == [file.path(percentEncoded: false)],
                      "the open names the file's own path")
    }

    func testAFileLinkWithNoLineEmitsAnOpenWithNoLine() async throws {
        let file = try tree.file("module/notes.swift", "let a = 1\n")
        let harness = try makeHarness()

        await harness.session.open(.file(file, line: nil), from: .currentPanel)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.swift", language: "swift", text: "let a = 1\n", line: nil)])
    }

    func testAMarkdownFileOpensInItsNativeViewerAndSendsNothingUntilTheSourceToggle() async throws {
        let file = try tree.file("notes.md", "# heading\n")
        let harness = try makeHarness()

        await harness.session.openFile(at: file, line: nil)
        XCTAssertTrue(harness.surface.commands.isEmpty, "markdown is rendered, not highlighted")

        await harness.session.setRendersMarkdown(false, for: file)
        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.md", language: "markdown", text: "# heading\n", line: nil)])
    }

    // MARK: - 2. routed through a real LinkRouter

    func testAFileLinkRoutedThroughTheRealRouterReachesTheSessionWithTheLineIntact() async throws {
        let file = try tree.file("routed.swift", "let routed = true\n")
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let harness = try makeHarness(links: RouterCapability(router: router))
        await harness.session.registerLinkTargets()

        await router.open(.file(file, line: 7), from: .currentPanel)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "routed.swift", language: "swift",
                              text: "let routed = true\n", line: 7)])
        XCTAssertTrue(harness.surface.openedPaths == [file.path(percentEncoded: false)],
                      "the link arrived intact")
        XCTAssertEqual(harness.session.lastOpenedDestination, .currentPanel)
    }

    func testAPoppedOutDestinationIsReceivedAndDoesTheSameOpen() async throws {
        let file = try tree.file("routed.swift", "let routed = true\n")
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let harness = try makeHarness(links: RouterCapability(router: router))
        await harness.session.registerLinkTargets()

        await router.open(.file(file, line: 7), from: .newWindow)

        // The host has already popped the tab out, and a popped-out window draws this same
        // session, so the handler does the same open. That it does not branch is §9's own note.
        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "routed.swift", language: "swift",
                              text: "let routed = true\n", line: 7)])
        XCTAssertEqual(harness.session.lastOpenedDestination, .newWindow)
    }

    func testATargetWhoseSessionWasReleasedIsInertAndTheOpenFallsBack() async throws {
        let file = try tree.file("routed.swift", "let routed = true\n")
        let fell = Fallbacks()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { fell.record($0) })

        // The session is built, registers, and is released — the host's LRU releasing a channel.
        try await withSessionReleased(router: router)

        await router.open(.file(file, line: 7), from: .currentPanel)

        XCTAssertEqual(fell.count, 1, "the open took W5's fallback")
        let count = await router.targetCount
        XCTAssertEqual(count, 2, "the registrations outlive the session; only their claim does not")
    }

    /// Builds a session, registers its targets and lets it go. Separate so nothing in the test's
    /// own frame keeps it alive.
    private func withSessionReleased(router: LinkRouter) async throws {
        let harness = try makeHarness(links: RouterCapability(router: router))
        await harness.session.registerLinkTargets()
    }

    // MARK: - 3. the save round trip

    func testASaveWritesTheBufferToThatPathAndLeavesTheOtherOpenFileUntouched() async throws {
        let first = try tree.file("first.swift", "original first\n")
        let second = try tree.file("second.swift", "original second\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: first, line: nil)
        await harness.session.openFile(at: second, line: nil)

        harness.session.save()
        XCTAssertEqual(harness.surface.shapes.last, .save)
        harness.surface.deliver(.saveRequested(path: second.path(percentEncoded: false),
                                               text: "edited second\n"))

        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "edited second\n")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original first\n",
                       "the other open file is untouched")
        XCTAssertNil(harness.session.issue)
    }

    func testASaveClearsTheDirtyFlagTheEditorReported() async throws {
        let file = try tree.file("dirty.swift", "one\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)

        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        XCTAssertEqual(harness.session.selected?.isDirty, true)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "two\n"))
        XCTAssertEqual(harness.session.selected?.isDirty, false)
    }

    // MARK: - 4. a save whose write fails

    func testASaveWhoseWriteFailsLeavesTheBufferDirtyAndRaisesThePanelLocalError() async throws {
        let directory = try tree.directory("sealed")
        let file = try tree.file("sealed/notes.swift", "original\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        // The write is a sibling temporary and a rename, so a directory nothing may create in is
        // the failure the panel has to survive.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path(percentEncoded: false))
        }

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false),
                                               text: "not written\n"))

        XCTAssertEqual(harness.session.issue, .saveFailed)
        XCTAssertEqual(harness.session.selected?.isDirty, true, "nothing was saved")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
    }

    // MARK: - 5. the refresh

    func testAFileRewrittenUnderACleanBufferRefreshesAndRestoresTheCursor() async throws {
        let file = try tree.file("watched.swift", "first\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.cursor(line: 12, column: 4))
        harness.surface.reset()

        try "second\n".write(to: file, atomically: true, encoding: .utf8)

        try await waitUntil("the refresh arrives") { harness.surface.commands.count >= 2 }
        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "watched.swift", language: "swift", text: "second\n", line: nil),
                        .gotoLine(line: 12, column: 4)],
                       "open with the new text, then the cursor, in that order")
    }

    // MARK: - 6. the conflict, Reload and Keep mine

    func testAFileRewrittenUnderADirtyBufferRaisesTheConflictAndRefreshesNothing() async throws {
        let file = try tree.file("watched.swift", "first\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        harness.surface.reset()

        try "from the agent\n".write(to: file, atomically: true, encoding: .utf8)

        try await waitUntil("the conflict is raised") { harness.session.selected?.hasConflict == true }
        XCTAssertTrue(harness.surface.commands.isEmpty, "a dirty buffer is not replaced")
    }

    func testReloadRefreshesAndClearsTheConflict() async throws {
        let file = try tree.file("watched.swift", "first\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        harness.surface.deliver(.cursor(line: 3, column: 2))
        try "from the agent\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil("the conflict is raised") { harness.session.selected?.hasConflict == true }
        harness.surface.reset()

        await harness.session.reload(file)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "watched.swift", language: "swift",
                              text: "from the agent\n", line: nil),
                        .gotoLine(line: 3, column: 2)])
        XCTAssertEqual(harness.session.selected?.hasConflict, false)
        XCTAssertEqual(harness.session.selected?.isDirty, false)
    }

    func testKeepMineClearsTheBannerAndMakesTheNextSaveAnOverwrite() async throws {
        let file = try tree.file("watched.swift", "first\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        try "from the agent\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil("the conflict is raised") { harness.session.selected?.hasConflict == true }

        harness.session.keepMine(file)
        XCTAssertEqual(harness.session.selected?.hasConflict, false, "the banner is cleared")

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "mine\n"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine\n",
                       "the next save overwrites rather than refusing")
    }

    // MARK: - 7. the save echo

    func testTheSessionsOwnSaveProducesNoRefreshAndNoConflictWhileTheWatcherIsStillLive()
        async throws {
        let file = try tree.file("watched.swift", "first\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        harness.surface.reset()

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false),
                                               text: "the panel's own bytes\n"))
        harness.surface.reset()

        // The control: another writer's bytes after the save do produce a refresh, which is what
        // proves the watcher was live through the whole of the assertion above. Without the
        // `lastWritten` rule in `WatchPolicy` the save's own echo would already have produced one.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(harness.surface.commands.isEmpty, "a save's own echo is not a refresh")
        XCTAssertEqual(harness.session.selected?.hasConflict, false)

        try "another writer\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitUntil("the watcher is still live") { harness.surface.commands.count >= 2 }
    }

    // MARK: - 8. a save with the file changed underneath

    func testASaveOverAFileAnotherWriterChangedIsRefusedAndRaisesTheConflict() async throws {
        let file = try tree.file("contended.swift", "first\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        // The watcher is deliberately slow here: a watcher event that has not been delivered yet
        // is not the same as a file that has not changed, which is what the save-side re-read is
        // for (§8).
        try "the other writer\n".write(to: file, atomically: true, encoding: .utf8)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "mine\n"))

        XCTAssertEqual(harness.session.selected?.hasConflict, true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "the other writer\n",
                       "the other writer's bytes are still on disk")
        XCTAssertEqual(harness.session.selected?.isDirty, true)
    }

    // MARK: - 9. the diff link

    func testADiffLinkShowsThePairTheResolverProduced() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)

        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)

        XCTAssertEqual(harness.surface.shapes,
                       [.showDiff(path: "notes.swift", original: "committed\n",
                                  modified: "working\n", language: "swift")])
        XCTAssertTrue(harness.session.isShowingDiff)
    }

    func testAPathTheBaseDidNotTouchIsAPanelLocalStateAndNotADiff() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)

        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)

        XCTAssertTrue(harness.surface.commands.isEmpty)
        XCTAssertEqual(harness.session.issue, .noTextDiff(.pathUnchangedByBase))
    }

    func testASaveRefusedWhileADiffIsOnScreenIsAPanelLocalState() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)

        harness.session.save()
        // The bridge refuses `save` while the diff is up and answers with `error`; the recorder is
        // not Monaco, so the refusal is synthesised here in the bridge's own words.
        harness.surface.deliver(.error(message: "save while a diff is on screen: the diff is read-only"))

        XCTAssertEqual(harness.session.issue, .saveRefusedWhileDiffShown)
    }

    // MARK: - 10. persistence

    func testASecondSessionOverTheSameStoreRestoresTheOpenFilesTheSelectionAndTheCursor()
        async throws {
        let kept = try tree.file("kept.swift", "kept\n")
        let dropped = try tree.file("dropped.swift", "dropped\n")
        let store = try makeStore()
        let context = try makeContext(store: store)

        let first = try makeHarness(context: context)
        await first.session.openFile(at: dropped, line: nil)
        await first.session.openFile(at: kept, line: 3)
        first.surface.deliver(.cursor(line: 9, column: 5))
        await first.session.teardown()

        // The recorded file that is no longer on disk is dropped from the restore, not opened as
        // an error.
        try FileManager.default.removeItem(at: dropped)

        let second = try makeHarness(context: context)
        await second.session.restore()

        XCTAssertEqual(second.session.openFiles.count, 1)
        XCTAssertEqual(second.session.selected?.name, kept.lastPathComponent)
        XCTAssertEqual(second.surface.shapes,
                       [.open(name: "kept.swift", language: "swift", text: "kept\n", line: 9)],
                       "the selected file is reopened at its stored line")
        XCTAssertNil(second.session.issue)
    }

    func testTwoChannelsWriteTwoKeysAndNeitherReadsTheOthers() async throws {
        let file = try tree.file("kept.swift", "kept\n")
        let store = try makeStore()
        let oneContext = try makeContext(store: store)
        let one = try makeHarness(context: oneContext)
        let other = try makeHarness(context: try makeContext(store: store))
        XCTAssertNotEqual(one.session.storeKey, other.session.storeKey)

        await one.session.openFile(at: file, line: nil)
        await one.session.teardown()
        await other.session.restore()
        // The control: the same document does restore for the channel that wrote it, so "nothing
        // restored" below is the key being separate and not the write never landing.
        let again = try makeHarness(context: oneContext)
        await again.session.restore()

        XCTAssertEqual(again.session.openFiles.count, 1, "the channel that wrote it restores it")
        XCTAssertEqual(other.session.openFiles.count, 0, "a channel restores only its own document")
    }

    func testADocumentFromAFutureSchemaIsRefusedIntoTheEmptyState() async throws {
        let store = try makeStore()
        let context = try makeContext(store: store)
        let harness = try makeHarness(context: context)
        struct FutureDocument: Codable { let schemaVersion: Int; let openFiles: [String] }
        try await store.write(FutureDocument(schemaVersion: FilesPanelState.currentSchemaVersion + 1,
                                             openFiles: []),
                              key: harness.session.storeKey)

        await harness.session.restore()

        XCTAssertEqual(harness.session.openFiles.count, 0)
        XCTAssertNil(harness.session.selectedPath)
    }

    // MARK: - 11. the theme

    func testTheSessionSendsNoThemeOfItsOwnAndTheToggleSendsExactlyOne() async throws {
        let file = try tree.file("themed.swift", "let a = 1\n")
        let harness = try makeHarness()

        await harness.session.openFile(at: file, line: 4)
        XCTAssertEqual(harness.surface.shapes.filter(\.isSetTheme).count, 0,
                       "C7.2's view follows the system until a host sets one")

        harness.session.setTheme(name: "vs-dark")
        XCTAssertEqual(harness.surface.shapes.filter(\.isSetTheme).count, 1)
        XCTAssertEqual(harness.surface.shapes.last, .setTheme(name: "vs-dark"))
    }

    // MARK: - Harness

    /// A session and the recorder it drives, held together so a test cannot let the session go by
    /// accident.
    private struct Harness {
        let session: FilesPanelSession
        let surface: RecordingSurface
    }

    private func makeHarness(context: ChannelContext? = nil,
                             cwd: URL? = nil,
                             environment: [String: String] = [:],
                             links: any LinkRouterCapability = UnusedLinks(),
                             watchMode: FileWatch.Mode = .vnode,
                             pollInterval: Duration = .milliseconds(50)) throws -> Harness {
        let surface = RecordingSurface()
        let resolved = try context ?? makeContext(store: try makeStore(), cwd: cwd,
                                                  environment: environment, links: links)
        let session = FilesPanelSession(context: resolved, surface: surface,
                                        coalescingInterval: .milliseconds(10),
                                        watchMode: watchMode,
                                        watchCoalescingDelay: .milliseconds(20),
                                        watchPollInterval: pollInterval)
        return Harness(session: session, surface: surface)
    }

    private func makeContext(store: any ScopedStore, cwd: URL? = nil,
                             environment: [String: String] = [:],
                             links: any LinkRouterCapability = UnusedLinks()) throws -> ChannelContext {
        let session = SessionID()
        let home = tree.root.appending(path: "config-home-\(session.description)")
        return ChannelContext(
            key: ChannelKey(configHome: home, session: session),
            session: session,
            cwd: try cwd ?? tree.directory("workspace"),
            environment: ResolvedEnvironment(variables: environment.isEmpty
                                                ? ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
                                                : environment,
                                             shell: "/bin/zsh", capturedAt: Date(),
                                             mode: .processFallback),
            store: store,
            links: links,
            recentURLs: StubFeed(),
            reportPaneExit: { _ in })
    }

    /// The real `FileStateStore`, wrapped exactly as `WorkbenchScopedStore` wraps it in the app.
    private func makeStore() throws -> some ScopedStore {
        let base = tree.root.appending(path: "state-\(UUID().uuidString)")
        return WorkbenchScoped(store: try FileStateStore(baseDirectory: base, configHomes: []))
    }

    private struct WorkbenchScoped: ScopedStore {
        let store: any StateStore
        func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
            try await store.read(type, namespace: .workbench, key: key)
        }
        func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
            try await store.write(value, namespace: .workbench, key: key)
        }
        func remove(key: String) async throws { try await store.remove(namespace: .workbench, key: key) }
        func keys() async throws -> [String] { try await store.keys(in: .workbench) }
    }

    /// Polls a main-actor condition under a bounded wait, so a slow machine fails as a timeout
    /// naming the condition rather than as a mystery.
    private func waitUntil(_ what: String, within: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for: \(what)")
    }
}

/// The `EditorSurface` every assertion is made against: it records the command sequence and lets
/// a test deliver the events Monaco would have posted.
@MainActor
final class RecordingSurface: EditorSurface {
    private(set) var commands: [EditorCommand] = []
    var onEvent: (@MainActor @Sendable (EditorEvent) -> Void)?

    func send(_ command: EditorCommand) { commands.append(command) }
    func reset() { commands = [] }
    func deliver(_ event: EditorEvent) { onEvent?(event) }

    /// The recorded sequence reduced to what an assertion may print.
    ///
    /// §6.3 and §11: a failed `XCTAssertEqual` prints both values, and an `EditorCommand` carries
    /// an absolute path. The shape keeps everything the gates are about — the command, its order,
    /// the language, the text, the line — and replaces the path with the file's own name, which
    /// the test invented. The path itself is asserted separately, by a comparison that prints
    /// nothing.
    var shapes: [CommandShape] { commands.map(CommandShape.init) }

    /// Every path an `open` named, in order.
    var openedPaths: [String] {
        commands.compactMap { command in
            guard case .open(let path, _, _, _) = command else { return nil }
            return path
        }
    }
}

/// One recorded command, with the absolute path replaced by the file's name.
enum CommandShape: Equatable {
    case open(name: String, language: String, text: String, line: Int?)
    case setText(text: String)
    case gotoLine(line: Int, column: Int?)
    case setTheme(name: String)
    /// A diff's path is repository-relative and invented by the test, so it stays whole.
    case showDiff(path: String, original: String, modified: String, language: String)
    case save

    init(_ command: EditorCommand) {
        switch command {
        case let .open(path, language, text, line):
            self = .open(name: URL(filePath: path).lastPathComponent, language: language,
                         text: text, line: line)
        case let .setText(text): self = .setText(text: text)
        case let .gotoLine(line, column): self = .gotoLine(line: line, column: column)
        case let .setTheme(name): self = .setTheme(name: name)
        case let .showDiff(path, original, modified, language):
            self = .showDiff(path: path, original: original, modified: modified, language: language)
        case .save: self = .save
        }
    }

    var isSetTheme: Bool {
        if case .setTheme = self { return true }
        return false
    }
}

/// Counts the router's fallbacks. The message names the kind and nothing of the link, so the
/// count is the whole assertion (§11).
final class Fallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0
    func record(_ message: String) { lock.withLock { recorded += 1 } }
    var count: Int { lock.withLock { recorded } }
}

/// A `LinkRouterCapability` over a real `LinkRouter`, which is what the app's `HostLinkRouter` is.
/// No `prepare`: the pop-out is the host's, and §9's point is that the handler does not branch on
/// the destination either way.
struct RouterCapability: LinkRouterCapability {
    let router: LinkRouter
    func register(_ target: LinkTarget) async { await router.register(target) }
    func unregister(tab: PanelTabID) async { await router.unregister(tab: tab) }
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        await router.open(link, from: destination)
    }
}

/// The capability for the tests that route nothing.
struct UnusedLinks: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

struct StubFeed: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}
