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
        let tab = FilesTab()
        await tab.registerLinkTargets(through: RouterCapability(router: router),
                                      presenting: harness.session)

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
        let tab = FilesTab()
        await tab.registerLinkTargets(through: RouterCapability(router: router),
                                      presenting: harness.session)

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
        let tab = FilesTab()
        await tab.registerLinkTargets(through: RouterCapability(router: router),
                                      presenting: harness.session)
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

    /// T7 found the gap this closes: `isShowingDiff` was cleared only by opening or selecting an
    /// editor-backed file, so a user in a diff had no way back to the file they came from, and
    /// the bridge refuses `save` for as long as the diff is up (§7).
    func testDismissingTheDiffReturnsToTheSelectedFilesEditorAndClearsTheRefusal() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.openFile(at: repository.root.appending(path: "notes.swift"), line: nil)
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)
        harness.session.save()
        harness.surface.deliver(.error(message: "save while a diff is on screen: the diff is read-only"))
        XCTAssertEqual(harness.session.issue, .saveRefusedWhileDiffShown)
        harness.surface.reset()

        await harness.session.dismissDiff()

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.swift", language: "swift", text: "working\n", line: nil)],
                       "leaving the diff did not put the selected file back on the editor")
        XCTAssertFalse(harness.session.isShowingDiff, "the diff is still the surface on screen")
        XCTAssertNil(harness.session.issue, "the refusal outlived the diff that caused it")
        XCTAssertEqual(FilesPanelReadout(session: harness.session).viewer, .editor)
    }

    /// The other branch: a diff opened with nothing else open leaves the empty state, not a
    /// diff nobody can dismiss into a file that is not there.
    func testDismissingADiffWithNoOpenFileLeavesTheEmptyStateAndSendsNothing() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)
        harness.surface.reset()

        await harness.session.dismissDiff()

        XCTAssertTrue(harness.surface.commands.isEmpty, "the empty state sent a command")
        XCTAssertFalse(harness.session.isShowingDiff)
        XCTAssertEqual(FilesPanelReadout(session: harness.session).viewer, .nothing)
        XCTAssertEqual(harness.session.openFiles.count, 0)
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

    /// `teardown()` flushes the store, and nothing calls it: X7's host releases a session by
    /// setting its slot to nil under LRU pressure, on `unregister`, and when a channel leaves the
    /// index. The cursor G4 promises to persist was therefore lost exactly when a channel was
    /// evicted — the ordinary case for the sixteenth channel. The coalescing interval here is long
    /// enough that no drain can land the document: only the release can.
    func testTheDocumentTheStoreIsStillCoalescingLandsWhenTheSessionIsReleased() async throws {
        let file = try tree.file("evicted.swift", "kept\n")
        let store = try makeStore()
        let context = try makeContext(store: store)

        let key = try await openThenRelease(file, context: context)

        var landed: FilesPanelState?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, landed == nil {
            landed = try await store.read(FilesPanelState.self, key: key)
            if landed == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let document = try XCTUnwrap(landed, "no document was written after the session was released")
        XCTAssertEqual(document.openFiles.count, 1)
        XCTAssertEqual(document.openFiles.first?.line, 9, "the cursor the panel last heard")
        XCTAssertEqual(document.selectedPath, file.path(percentEncoded: false))
    }

    /// Opens a file, moves the cursor and lets the session go without a `teardown()` — the host
    /// evicting a channel. Separate so nothing in the test's own frame keeps it alive; the store's
    /// key is all that comes back.
    private func openThenRelease(_ file: URL, context: ChannelContext) async throws -> String {
        let harness = try makeHarness(context: context, coalescingInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.cursor(line: 9, column: 5))
        return harness.session.storeKey
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

    // MARK: - 11a. a save preserves the file's mode

    /// The write is a sibling temporary and a `rename`, and a rename replaces the inode: without
    /// carrying the destination's mode onto the temporary first, every save re-modes the file to
    /// whatever the process umask gives a fresh file. An executable script saved from the panel
    /// would stop being executable, and a file the user restricted would be opened up again.
    /// Only the mode is asserted — never the path (§6.3, §11).

    func testASaveOverAnExecutableFileLeavesItExecutable() async throws {
        try await assertASavePreservesTheMode(0o755)
    }

    func testASaveOverAFileTheUserRestrictedLeavesItRestricted() async throws {
        try await assertASavePreservesTheMode(0o600)
    }

    private func assertASavePreservesTheMode(_ mode: mode_t,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) async throws {
        let target = try tree.file("moded.swift", "original\n")
        let path = target.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                              ofItemAtPath: path)
        let harness = try makeHarness()
        await harness.session.openFile(at: target, line: nil)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: path, text: "edited\n"))

        XCTAssertNil(harness.session.issue, "the save did not land", file: file, line: line)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "edited\n",
                       "the bytes did not land", file: file, line: line)
        XCTAssertEqual(Self.permissions(of: target), mode,
                       "the save replaced the file's mode", file: file, line: line)
    }

    /// The file's permission bits, which is the whole of what these two cases assert.
    private static func permissions(of url: URL) -> mode_t? {
        var status = stat()
        guard stat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return status.st_mode & 0o7777
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

    // MARK: - 12. where a save may not land (CLAUDE.md rule 1, root spec X9)

    /// A settings file reached through a `.file` link reads like any other file, and *Save* would
    /// replace it. Reading stays allowed; the write is refused with a panel-local state that names
    /// the reason and no path.
    func testASaveIntoTheChannelsConfigHomeIsRefusedAndTheFileIsUntouched() async throws {
        let store = try makeStore()
        let context = try makeContext(store: store)
        let settings = context.key.configHome.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: context.key.configHome,
                                                withIntermediateDirectories: true)
        try "{\"model\":\"opus\"}\n".write(to: settings, atomically: true, encoding: .utf8)
        let harness = try makeHarness(context: context)

        await harness.session.openFile(at: settings, line: nil)
        XCTAssertEqual(harness.session.openFiles.count, 1, "reading inside a config home is allowed")
        XCTAssertNil(harness.session.issue)

        harness.surface.deliver(.dirty(path: settings.path(percentEncoded: false), isDirty: true))
        harness.session.save()
        harness.surface.deliver(.saveRequested(path: settings.path(percentEncoded: false),
                                               text: "{\"model\":\"replaced\"}\n"))

        XCTAssertEqual(harness.session.issue, .saveRefusedIntoConfigHome)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\"model\":\"opus\"}\n",
                       "the engine's own file was replaced")
        XCTAssertEqual(harness.session.selected?.isDirty, true, "nothing was saved")
    }

    /// A link *inside* the scratch tree pointing at a file inside a config home is the same write:
    /// the guard compares resolved paths, so the link's own spelling does not get past it.
    func testASaveThroughALinkIntoTheConfigHomeIsRefusedToo() async throws {
        let store = try makeStore()
        let context = try makeContext(store: store)
        let settings = context.key.configHome.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: context.key.configHome,
                                                withIntermediateDirectories: true)
        try "original\n".write(to: settings, atomically: true, encoding: .utf8)
        try tree.symlink("elsewhere/link.json", to: settings.path(percentEncoded: false))
        let link = tree.root.appending(path: "elsewhere/link.json")
        let harness = try makeHarness(context: context)

        await harness.session.openFile(at: link, line: nil)
        harness.session.save()
        harness.surface.deliver(.saveRequested(path: link.path(percentEncoded: false),
                                               text: "replaced\n"))

        XCTAssertEqual(harness.session.issue, .saveRefusedIntoConfigHome)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "original\n")
    }

    /// The set of homes, as a count and as membership decisions — never as a path.
    func testTheProtectedHomesCoverTheChannelBothEnvironmentsAndTheDefault() throws {
        let channel = tree.root.appending(path: "channel-home")
        let fromChannelEnvironment = tree.root.appending(path: "env-home")
        let fromProcess = tree.root.appending(path: "process-home")
        let home = tree.root.appending(path: "pretend-home")
        let homes = FilesPanelSession.protectedConfigHomes(
            channel: channel,
            variables: ["CLAUDE_CONFIG_DIR": fromChannelEnvironment.path(percentEncoded: false)],
            processVariables: ["CLAUDE_CONFIG_DIR": fromProcess.path(percentEncoded: false)],
            home: home)

        XCTAssertEqual(homes.count, 4, "one home per source")
        for inside in [channel.appending(path: "settings.json"),
                       fromChannelEnvironment.appending(path: "deep/agent.md"),
                       fromProcess.appending(path: "settings.json"),
                       home.appending(path: ".claude/settings.json"),
                       channel] {
            XCTAssertTrue(FilesPanelSession.isInside(homes, inside),
                          "a destination inside a config home was allowed")
        }
        for outside in [tree.root.appending(path: "channel-home-next-door/settings.json"),
                        tree.root.appending(path: "workspace/settings.json"),
                        home.appending(path: "notes.md")] {
            XCTAssertFalse(FilesPanelSession.isInside(homes, outside),
                           "an ordinary destination was refused")
        }
    }

    // MARK: - 13. the save writes through a link, not over it

    func testASaveThroughASymlinkReplacesTheTargetAndLeavesTheLinkALink() async throws {
        let target = try tree.file("real/target.swift", "original\n")
        try tree.symlink("link.swift", to: target.path(percentEncoded: false))
        let link = tree.root.appending(path: "link.swift")
        let harness = try makeHarness()
        await harness.session.openFile(at: link, line: nil)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: link.path(percentEncoded: false),
                                               text: "edited\n"))

        XCTAssertNil(harness.session.issue)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "edited\n",
                       "the link's target did not receive the write")
        var status = stat()
        XCTAssertEqual(lstat(link.path(percentEncoded: false), &status), 0)
        XCTAssertTrue((status.st_mode & S_IFMT) == S_IFLNK, "the save replaced the link itself")
    }

    // MARK: - 14. the dirty baseline after a save

    /// `readBuffer` deliberately leaves the editor's dirty flag set, and `dirty` is reported on a
    /// transition: without the host clearing the baseline the next edit reports nothing, *Save*
    /// stays disabled and a refresh discards edits nobody was told about.
    func testASuccessfulSaveClearsTheEditorsBaselineWithTheBytesItWrote() async throws {
        let file = try tree.file("baseline.swift", "one\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        harness.surface.reset()

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "two\n"))

        XCTAssertEqual(harness.surface.shapes, [.save, .setText(text: "two\n")],
                       "the write did not clear the editor's baseline")
    }

    /// A failed write leaves the buffer alone: the baseline it would clear describes bytes that
    /// are not on disk.
    func testAFailedSaveClearsNothing() async throws {
        let directory = try tree.directory("sealed-baseline")
        let file = try tree.file("sealed-baseline/notes.swift", "original\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path(percentEncoded: false))
        }
        harness.surface.reset()

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "no\n"))

        XCTAssertEqual(harness.surface.shapes, [.save])
    }

    // MARK: - 15. the loaded baseline is retired by a save

    /// After saving B the buffer's bytes are B, so **both** baselines are B. Leaving `lastLoaded`
    /// on A is what makes an external writer restoring A invisible to §8's rule 2 and to the save
    /// preflight. Asserted as the two digests, which name no path and print no buffer.
    ///
    /// The end-to-end version — a watcher refresh after such a restore — is §25 below, drivable
    /// now that `FileSnapshot` reads through `stat(2)` rather than through a long-lived `URL`'s
    /// cached resource values.
    func testASaveRetiresTheLoadedBaselineAlongWithTheWrittenOne() async throws {
        let file = try tree.file("retired.swift", "loaded\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        let opened = try XCTUnwrap(harness.session.selected?.lastLoaded)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "saved\n"))

        let saved = try XCTUnwrap(harness.session.selected)
        let written = FileSnapshot.predicted(contents: Data("saved\n".utf8))
        XCTAssertNotEqual(opened.digest, written.digest, "the two baselines are distinguishable")
        XCTAssertEqual(saved.lastWritten?.digest, written.digest)
        XCTAssertEqual(saved.lastLoaded?.digest, written.digest,
                       "the buffer's loaded baseline is still the bytes the file was opened from")
    }

    /// The same rule on the save side: the preflight accepts only what the buffer's bytes are now.
    func testASaveOverAFileRestoredToTheLoadedBytesIsRefusedAndRaisesTheConflict() async throws {
        let file = try tree.file("restored.swift", "loaded\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "saved\n"))
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        try "loaded\n".write(to: file, atomically: true, encoding: .utf8)
        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "mine\n"))

        XCTAssertEqual(harness.session.selected?.hasConflict, true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "loaded\n",
                       "the other writer's bytes were overwritten")
    }

    // MARK: - 16. a destination that vanished

    func testASaveOverADestinationThatVanishedIsAConflictAndRecreatesNothing() async throws {
        let file = try tree.file("vanished.swift", "original\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        try FileManager.default.removeItem(at: file)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "mine\n"))

        XCTAssertEqual(harness.session.selected?.hasConflict, true)
        XCTAssertEqual(harness.session.selected?.isDirty, true, "nothing was saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
                       "a deleted destination was recreated behind the user")
    }

    /// *Keep mine* is the user resolving exactly that conflict, and it does write the file back.
    func testKeepMineOverADestinationThatVanishedWritesIt() async throws {
        let file = try tree.file("vanished-kept.swift", "original\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .seconds(30))
        await harness.session.openFile(at: file, line: nil)
        try FileManager.default.removeItem(at: file)
        harness.session.keepMine(file)

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false), text: "mine\n"))

        XCTAssertNil(harness.session.issue)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine\n")
    }

    // MARK: - 17. the temporary, and the window before the rename

    /// The temporary carries the destination's mode **before** a byte reaches it: a 0600 file
    /// written into a 0644 temporary is published to anyone who can traverse the directory, and
    /// the later `chmod` cannot take that back. The check runs while the temporary still holds the
    /// content, which is exactly where the exposure would be.
    func testTheTemporaryCarriesTheDestinationsModeBeforeAnyContentReachesIt() throws {
        let directory = try tree.directory("staging")
        let destination = directory.appending(path: "restricted.swift")
        try "original\n".write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                              ofItemAtPath: destination.path(percentEncoded: false))
        var temporaryMode: mode_t?
        var temporarySize: Int?

        try FilesPanelSession.atomicallyWrite(Data("edited\n".utf8), to: destination) { _ in
            let temporary = Self.onlyTemporary(in: directory)
            temporaryMode = temporary.flatMap(Self.permissions(of:))
            temporarySize = temporary.flatMap { try? Data(contentsOf: $0).count }
            return true
        }

        XCTAssertEqual(temporarySize, 7, "the check did not run while the temporary held the bytes")
        XCTAssertEqual(temporaryMode, 0o600, "the content was exposed before the mode was carried")
        XCTAssertEqual(Self.permissions(of: destination), 0o600)
    }

    /// The content check happens before the temporary is written; another writer landing in that
    /// window would otherwise be overwritten unconditionally. The rename is refused instead.
    func testAWriteWhoseDestinationChangedBeforeTheRenameIsRefusedAndLeavesNoTemporary() throws {
        let directory = try tree.directory("contended-staging")
        let destination = directory.appending(path: "contended.swift")
        try "original\n".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FilesPanelSession.atomicallyWrite(Data("mine\n".utf8),
                                                                  to: destination) { _ in false })

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original\n",
                       "a refused write still landed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)).count, 1,
                       "the refused write left its temporary behind")
    }

    /// The only `.afleet-save-` entry in `directory`, which is what the checks above look at.
    private static func onlyTemporary(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))) ?? []
        guard let name = names.first(where: { $0.hasPrefix(".afleet-save-") }), names.count == 2
        else { return nil }
        return directory.appending(path: name)
    }

    // MARK: - 18. the tree's toggles are part of the document

    /// A toggle records the document like every other change, so an eviction — which releases the
    /// session with no `teardown()` — cannot lose it. `teardown()` is deliberately not called: it
    /// would record the state itself and prove nothing about the toggle.
    func testATreeToggleIsRecordedWithoutATeardown() async throws {
        let store = try makeStore()
        let context = try makeContext(store: store)
        let harness = try makeHarness(context: context)

        await harness.session.setShowsHiddenFiles(true)
        await harness.session.setShowsGitIgnored(true)

        var landed: FilesPanelState?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, landed == nil {
            landed = try await store.read(FilesPanelState.self, key: harness.session.storeKey)
            if landed == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let document = try XCTUnwrap(landed, "a toggle recorded no document")
        XCTAssertTrue(document.showsHiddenFiles, "the hidden-files toggle was not recorded")
        XCTAssertTrue(document.showsGitIgnored, "the gitignore toggle was not recorded")
    }

    /// The other half: what was recorded is what a later session comes back with.
    func testTheTreesTogglesAreRestored() async throws {
        let store = try makeStore()
        let context = try makeContext(store: store)
        let first = try makeHarness(context: context)

        await first.session.setShowsHiddenFiles(true)
        await first.session.setShowsGitIgnored(true)
        await first.session.teardown()

        let second = try makeHarness(context: context)
        await second.session.restore()

        XCTAssertTrue(second.session.tree.showsHiddenFiles)
        XCTAssertFalse(second.session.tree.hidesIgnoredFiles)
    }

    // MARK: - 19. the buffer belongs to the session, not to the surface it is on

    /// The panel's only way to obtain the buffer is `save` → `saveRequested`, so a presentation
    /// that replaces the buffer has to ask for it first — with the intent to *stash* rather than
    /// to write. Without that, switching files discards whatever the user typed: `open` replaces
    /// the model with the session's cached text and the bridge reports the buffer clean.
    func testSwitchingToAnotherFileAndBackKeepsWhatTheUserTyped() async throws {
        let first = try tree.file("first.swift", "one\n")
        let second = try tree.file("second.swift", "two\n")
        let harness = try makeHarness()
        harness.surface.answersSave = true
        await harness.session.openFile(at: first, line: nil)

        harness.surface.type("edited one\n")
        harness.surface.deliver(.dirty(path: first.path(percentEncoded: false), isDirty: true))
        await harness.session.openFile(at: second, line: nil)
        harness.surface.reset()

        await harness.session.select(first)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "first.swift", language: "swift", text: "edited one\n",
                              line: nil)],
                       "the file came back as it was on disk, not as the user left it")
        XCTAssertEqual(harness.session.selected?.isDirty, true, "the unsaved marker was dropped")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one\n",
                       "a stash wrote the file")
    }

    /// The same rule across the markdown toggle, which moves one file between two surfaces.
    func testTheMarkdownSourceToggleKeepsWhatTheUserTyped() async throws {
        let file = try tree.file("notes.md", "# heading\n")
        let harness = try makeHarness()
        harness.surface.answersSave = true
        await harness.session.openFile(at: file, line: nil)
        await harness.session.setRendersMarkdown(false, for: file)

        harness.surface.type("# edited\n")
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        await harness.session.setRendersMarkdown(true, for: file)
        harness.surface.reset()

        await harness.session.setRendersMarkdown(false, for: file)

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.md", language: "markdown", text: "# edited\n",
                              line: nil)])
        XCTAssertEqual(FilesPanelReadout(session: harness.session).isDirty, true)
    }

    /// And across a diff, which is the case with no way back: the diff editor is read-only and the
    /// bridge refuses `save` while it is up, so the buffer has to be stashed before it goes on.
    func testDismissingADiffPutsBackWhatTheUserTypedRatherThanWhatIsOnDisk() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        harness.surface.answersSave = true
        let file = repository.root.appending(path: "notes.swift")
        await harness.session.openFile(at: file, line: nil)

        harness.surface.type("half-finished\n")
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)
        harness.surface.reset()

        await harness.session.dismissDiff()

        XCTAssertEqual(harness.surface.shapes,
                       [.open(name: "notes.swift", language: "swift", text: "half-finished\n",
                              line: nil)])
        XCTAssertEqual(harness.session.selected?.isDirty, true)
    }

    // MARK: - 20. two windows, one session (Design §1)

    /// X7's host hands the same session to the main window and to a popped-out one, and each
    /// builds its own editor. Both are driven, so both show the same file; `save` is not
    /// broadcast, because each window has its own buffer and only the one the user is in may
    /// answer for the file.
    func testBothWindowsAreDrivenAndTheSaveWritesTheWindowTheUserIsIn() async throws {
        let file = try tree.file("shared.swift", "one\n")
        let harness = try makeHarness()
        let poppedOut = RecordingSurface()
        harness.session.attach(poppedOut)
        harness.surface.answersSave = true
        poppedOut.answersSave = true

        await harness.session.openFile(at: file, line: nil)
        XCTAssertEqual(poppedOut.shapes, harness.surface.shapes,
                       "the two windows were not shown the same file")

        // The user is typing in the main window, which is what reports the dirty buffer.
        harness.surface.type("from the window the user is in\n")
        poppedOut.type("from the other window\n")
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        harness.session.save()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "from the window the user is in\n",
                       "the save wrote the buffer of a window the user was not in")
    }

    /// A window that closed must be let go: nothing here may keep a dead web view alive, and a
    /// detached editor stops answering for the session's buffer.
    func testADetachedSurfaceIsDroppedAndStopsBeingDriven() async throws {
        let file = try tree.file("dropped.swift", "one\n")
        let harness = try makeHarness()
        let closing = RecordingSurface()
        harness.session.attach(closing)
        XCTAssertEqual(harness.session.attachedSurfaceCount, 2)
        closing.reset()

        harness.session.detach(closing)
        await harness.session.openFile(at: file, line: nil)

        XCTAssertEqual(harness.session.attachedSurfaceCount, 1)
        XCTAssertTrue(closing.commands.isEmpty, "a detached editor was still being driven")
    }

    /// The weak half: a surface nobody detached, released with its window, leaves no entry behind.
    func testASurfaceReleasedWithItsWindowIsNotHeldBySession() async throws {
        let file = try tree.file("released.swift", "one\n")
        let harness = try makeHarness()
        attachAndRelease(harness.session)

        await harness.session.openFile(at: file, line: nil)

        XCTAssertEqual(harness.session.attachedSurfaceCount, 1,
                       "the session is holding an editor whose window is gone")
    }

    /// Attaches a surface and lets it go inside this frame, so the test's own stack does not keep
    /// it alive.
    private func attachAndRelease(_ session: FilesPanelSession) {
        session.attach(RecordingSurface())
    }

    /// SwiftUI may rebuild the panel's subtree while the host keeps the session: `makeNSView`
    /// builds a fresh editor and attaches it to a queue that was drained on the first attachment.
    /// An editor that was told nothing draws a blank page, so attaching brings it up to date.
    func testASurfaceAttachedAfterAPresentationIsBroughtUpToDate() async throws {
        let file = try tree.file("remounted.swift", "one\n")
        let harness = try makeHarness()
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.cursor(line: 6, column: 3))

        harness.session.detach(harness.surface)
        let remounted = RecordingSurface()
        harness.session.attach(remounted)

        XCTAssertEqual(remounted.shapes,
                       [.open(name: "remounted.swift", language: "swift", text: "one\n", line: nil),
                        .gotoLine(line: 6, column: 3)],
                       "a remounted editor was left blank")
    }

    /// The same rule under a diff, which is a presentation nothing on disk describes: one of its
    /// two sides is a repository object, so a remounted editor can only be shown the pair again.
    func testASurfaceAttachedUnderADiffIsShownThatDiff() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)

        harness.session.detach(harness.surface)
        let remounted = RecordingSurface()
        harness.session.attach(remounted)

        XCTAssertEqual(remounted.shapes,
                       [.showDiff(path: "notes.swift", original: "committed\n",
                                  modified: "working\n", language: "swift")],
                       "a remount under a diff drew an empty editor")
    }

    // MARK: - 21. leaving the diff (Design §4, §5)

    /// The readout prioritises `isShowingDiff`, so clearing it *after* the native-viewer return
    /// left the diff drawn over the file that had just been opened.
    func testAFileWithANativeViewerOpenedOutOfADiffLeavesTheDiffBehind() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        try repository.write("readme.md", "# heading\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)
        XCTAssertTrue(harness.session.isShowingDiff)

        await harness.session.openFile(at: repository.root.appending(path: "readme.md"), line: nil)

        XCTAssertFalse(harness.session.isShowingDiff)
        XCTAssertEqual(FilesPanelReadout(session: harness.session).viewer, .markdown)
    }

    /// The other half of the same move: the panel left the diff, but *Monaco* did not, and the
    /// bridge refuses `save` for as long as its diff pane is up. `gotoLine` is the command in W4's
    /// closed vocabulary that shows the editor pane and changes no text.
    func testAMarkdownFileOpenedOutOfADiffTakesMonacoOutOfItsDiffPane() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        try repository.write("readme.md", "# heading\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)
        await harness.session.openFile(at: repository.root.appending(path: "notes.swift"), line: nil)
        harness.surface.deliver(.cursor(line: 5, column: 2))
        await harness.session.open(.diff(DiffRef(repository: repository.root, path: "notes.swift",
                                                 base: .workingTreeAgainstHEAD)),
                                   from: .currentPanel)
        harness.surface.reset()

        await harness.session.openFile(at: repository.root.appending(path: "readme.md"), line: nil)

        XCTAssertEqual(harness.surface.shapes, [.gotoLine(line: 5, column: 2)],
                       "Monaco was left in its diff pane behind a rendered file")
    }

    // MARK: - 22. a restore that finds the panel busy

    /// `restore()` suspends on the store and on every watcher it arms, and `activate()` starts it
    /// in a task. A link delivered inside one of those suspensions has already opened the file the
    /// user asked for, and the restore must not append over it or select away from it.
    func testALinkDeliveredWhileTheRestoreIsSuspendedIsNotOverwritten() async throws {
        let recorded = try tree.file("recorded.swift", "recorded\n")
        let linked = try tree.file("linked.swift", "linked\n")
        let store = try makeStore()
        let context = try makeContext(store: store)
        let first = try makeHarness(context: context)
        await first.session.openFile(at: recorded, line: nil)
        await first.session.teardown()

        let second = try makeHarness(context: context)
        let restoring = Task { await second.session.restore() }
        // One turn is all it takes to put the restore inside its first suspension — the store's
        // load — which is where the link below arrives.
        await Task.yield()
        await second.session.openFile(at: linked, line: nil)
        await restoring.value

        XCTAssertEqual(second.session.openFiles.count, 1,
                       "the restore appended over a file the user was already looking at")
        XCTAssertEqual(second.session.selected?.name, "linked.swift",
                       "the restore selected away from the link that arrived")
    }

    // MARK: - 23. a diff that was superseded while it resolved

    /// `showDiff` runs several `git` commands, and the panel does not stand still while they do.
    func testADiffSupersededByAFileTheUserOpenedIsNotApplied() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.swift": "committed\n"])
        try repository.write("notes.swift", "working\n")
        try repository.write("other.swift", "other\n")
        let harness = try makeHarness(cwd: repository.root, environment: repository.environment)

        let diffing = Task {
            await harness.session.showDiff(DiffRef(repository: repository.root,
                                                   path: "notes.swift",
                                                   base: .workingTreeAgainstHEAD))
        }
        await harness.session.openFile(at: repository.root.appending(path: "other.swift"), line: nil)
        await diffing.value

        XCTAssertFalse(harness.session.isShowingDiff,
                       "a diff resolved after the user opened a file replaced it")
        XCTAssertEqual(FilesPanelReadout(session: harness.session).viewer, .editor)
        XCTAssertEqual(harness.session.selected?.name, "other.swift")
    }

    // MARK: - 24. a file above the cap (Design §4)

    /// Above the cap the file is not read at all — `FileSnapshot.read` refuses it too — but Design
    /// §4 says it still opens: it draws its size and offers *Reveal in Finder*. `.unreadableFile`
    /// is for the file that genuinely could not be read.
    func testAFileAboveTheCapOpensIntoTheUnsupportedViewerRatherThanAnError() async throws {
        let file = try tree.file("enormous.bin", "")
        let handle = try FileHandle(forWritingTo: file)
        // Sparse: the size is what the cap is about, and no test needs the bytes on disk.
        try handle.truncate(atOffset: UInt64(FileKind.maximumReadableBytes + 1))
        try handle.close()
        let harness = try makeHarness()

        await harness.session.openFile(at: file, line: nil)

        XCTAssertNil(harness.session.issue, "a file above the cap was refused rather than drawn")
        XCTAssertEqual(harness.session.openFiles.count, 1)
        XCTAssertEqual(FilesPanelReadout(session: harness.session).viewer, .unsupported)
        XCTAssertTrue(harness.surface.commands.isEmpty, "nothing above the cap reaches the editor")
    }

    /// The other side of the same branch: a path that is not a readable regular file is still the
    /// panel-local error it always was.
    func testAPathThatIsNotAFileIsStillTheUnreadableState() async throws {
        let missing = tree.root.appending(path: "not-there.swift")
        let harness = try makeHarness()

        await harness.session.openFile(at: missing, line: nil)

        XCTAssertEqual(harness.session.issue, .unreadableFile)
        XCTAssertEqual(harness.session.openFiles.count, 0)
    }

    // MARK: - 25. an external writer that puts the previous contents back

    /// After saving B both baselines are B, so a writer restoring A is a change and not this
    /// save's own echo. The end-to-end half of the rule §15 asserts as two digests: it is drivable
    /// now that `FileSnapshot` reads through `stat(2)` rather than through a long-lived `URL`'s
    /// cached resource values.
    func testAnExternalWriterRestoringTheLoadedBytesAfterASaveIsSeenAsAChange() async throws {
        let file = try tree.file("restored-end-to-end.swift", "alpha\n")
        let harness = try makeHarness(watchMode: .poll, pollInterval: .milliseconds(50))
        await harness.session.openFile(at: file, line: nil)
        harness.surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        harness.session.save()
        harness.surface.deliver(.saveRequested(path: file.path(percentEncoded: false),
                                               text: "beta and then some\n"))
        XCTAssertEqual(harness.session.selected?.isDirty, false)
        harness.surface.reset()

        try "alpha\n".write(to: file, atomically: true, encoding: .utf8)

        try await waitUntil("the restore reaches the buffer") { !harness.surface.commands.isEmpty }
        XCTAssertEqual(harness.surface.shapes.first,
                       .open(name: "restored-end-to-end.swift", language: "swift",
                             text: "alpha\n", line: nil),
                       "the writer's restore was swallowed as the save's own echo")
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
                             pollInterval: Duration = .milliseconds(50),
                             coalescingInterval: Duration = .milliseconds(10)) throws -> Harness {
        let surface = RecordingSurface()
        let resolved = try context ?? makeContext(store: try makeStore(), cwd: cwd,
                                                  environment: environment, links: links)
        let session = FilesPanelSession(context: resolved, surface: surface,
                                        coalescingInterval: coalescingInterval,
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

    /// Whether this surface answers `save` out of the buffer below, as the bridge's `readBuffer`
    /// answers it out of its model. **Off by default**: most tests synthesise the reply by hand,
    /// and two answers to one `save` would be two writes.
    var answersSave = false
    /// What the buffer holds: the text of the last `open` or `setText`, and whatever `type(_:)`
    /// has put there since — which is the user having typed.
    private(set) var buffer: String?
    /// The path the buffer belongs to, taken from the last `open`, exactly as the bridge reads it
    /// back out of the model's URI.
    private(set) var bufferPath: String?

    func send(_ command: EditorCommand) {
        commands.append(command)
        switch command {
        case let .open(path, _, text, _):
            bufferPath = path
            buffer = text
        case .setText(let text):
            buffer = text
        case .save where answersSave:
            guard let bufferPath, let buffer else { return }
            deliver(.saveRequested(path: bufferPath, text: buffer))
        default:
            break
        }
    }

    /// The user typing into this window's buffer.
    func type(_ text: String) { buffer = text }

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
