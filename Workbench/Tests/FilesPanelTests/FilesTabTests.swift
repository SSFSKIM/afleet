import Foundation
import XCTest
import AppKit
import CoreGraphics
@testable import FilesPanel
import AfleetCore
import EditorCore
import FleetKit
import LinkRouting
import PanelHostAPI
import SourceControlCore

/// Spec Design §1, §4 and §10; the rendered halves of G1 and G2, as far as a headless run reaches.
///
/// Everything below is asserted through `FilesPanelReadout` — the same device C5's
/// `PlaceholderReadout` is — because `FilesPanelView` reads that value and formats nothing else.
/// A rendered `Text` is not an assertion; a readout is, and what a test asserts here is what the
/// panel draws.
///
/// §6.3 and §11: every assertion names a file's own invented **name**, a count or a case, never a
/// path and never a buffer. TCC: every tree is built under the process's temporary directory and
/// no test reads a path it did not create.
@MainActor
final class FilesTabTests: XCTestCase {

    private var tree: ScratchTree!

    override func setUp() async throws {
        tree = try ScratchTree()
    }

    override func tearDown() async throws {
        tree?.remove()
        tree = nil
    }

    // MARK: - 1. the tab itself (Design §10)

    func testTheTabCarriesTheFilesIdAndThatIdsOwnTitleAndSymbol() throws {
        let tab = FilesTab()

        XCTAssertEqual(tab.id, .files)
        XCTAssertEqual(tab.title, PanelTabID.files.defaultTitle,
                       "the title is the id's own, not a second spelling of it")
        XCTAssertEqual(tab.systemImage, PanelTabID.files.defaultSystemImage)
    }

    func testTheTabIsAvailableForEveryChannel() throws {
        let tab = FilesTab()
        let one = try makeContext(store: try makeStore())
        let other = try makeContext(store: try makeStore(), cwd: try tree.directory("second"))

        XCTAssertTrue(tab.isAvailable(in: one))
        XCTAssertTrue(tab.isAvailable(in: other), "a tab that can render a context can render any")
    }

    func testMakeSessionBuildsAFilesPanelSessionForThatChannelsDirectory() throws {
        let tab = FilesTab()
        let cwd = try tree.directory("workspace")
        let context = try makeContext(store: try makeStore(), cwd: cwd)

        let session = tab.makeSession(for: context)

        let files = try XCTUnwrap(session as? FilesPanelSession)
        XCTAssertEqual(files.tree.root, cwd, "the tree is rooted at the channel's own directory")
        XCTAssertEqual(FilesPanelReadout(session: files).openFileCount, 0)
    }

    func testEachChannelGetsItsOwnSession() throws {
        let tab = FilesTab()
        let one = try makeContext(store: try makeStore())
        let other = try makeContext(store: try makeStore(), cwd: try tree.directory("second"))

        let first = tab.makeSession(for: one) as? FilesPanelSession
        let second = tab.makeSession(for: other) as? FilesPanelSession

        XCTAssertFalse(first === second, "the host retains one session per (tab, channel)")
    }

    /// `makeSession` is where §9's "when the session is created" lands: the tab is the one caller
    /// that knows a session has just been built, and `activate()` is `async` while `makeSession`
    /// is not. A tab that left this to the view would register a second pair of targets on every
    /// remount.
    func testMakeSessionActivatesTheSessionSoItsTwoLinkTargetsRegisterOnce() async throws {
        let tab = FilesTab()
        let links = CountingLinks()
        let context = try makeContext(store: try makeStore(), links: links)

        _ = tab.makeSession(for: context)

        try await waitUntil("the two link targets to register") { links.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(links.count, 2, "two targets, registered once")
    }

    /// Design §9 registered a pair per **session**, and every pair carries the same tab at the
    /// same specificity: `LinkRouter.mostSpecific` compares specificity and canonical tab order and
    /// nothing else, so it cannot tell one channel's target from another's. The mitigation inside
    /// this leaf's fence is one registration for the tab (Parent revision 4, tracker 240).
    func testTheTabRegistersOneLinkPairHoweverManyChannelsItBuildsSessionsFor() async throws {
        let tab = FilesTab()
        let links = CountingLinks()

        _ = tab.makeSession(for: try makeContext(store: try makeStore(), links: links))
        _ = tab.makeSession(for: try makeContext(store: try makeStore(),
                                                 cwd: try tree.directory("second"), links: links))
        _ = tab.makeSession(for: try makeContext(store: try makeStore(),
                                                 cwd: try tree.directory("third"), links: links))

        try await waitUntil("the two link targets to register") { links.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(links.count, 2, "the registration grew with the number of channels")
    }

    /// The same fact seen from the real router, which is what a host would ask.
    func testTheRoutersTargetCountDoesNotGrowWithTheNumberOfChannels() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let tab = FilesTab()

        for name in ["one", "two", "three", "four"] {
            _ = tab.makeSession(for: try makeContext(store: try makeStore(),
                                                     cwd: try tree.directory(name),
                                                     links: capability))
        }

        try await waitUntilCount(2, in: router)
        try await Task.sleep(for: .milliseconds(100))
        let count = await router.targetCount
        XCTAssertEqual(count, 2, "two targets for the tab, whatever the channel count")
    }

    /// And the routing itself: the delivery reaches the session for the channel the panel is
    /// presenting, rather than whichever channel happened to register first.
    func testALinkOpensInTheChannelThePanelIsPresenting() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let tab = FilesTab()
        let offscreen = try makeContext(store: try makeStore(),
                                        cwd: try tree.directory("offscreen"), links: capability)
        let onscreen = try makeContext(store: try makeStore(),
                                       cwd: try tree.directory("onscreen"), links: capability)
        // The on-screen channel's session is built *first*, so neither registration order nor
        // creation order can be what makes this pass: only the presentation can.
        let shown = try XCTUnwrap(tab.makeSession(for: onscreen) as? FilesPanelSession)
        let hidden = try XCTUnwrap(tab.makeSession(for: offscreen) as? FilesPanelSession)
        let file = try tree.file("onscreen/routed.swift", "let routed = true\n")
        // The host draws the channel it is on, which is what makes that session the presented one.
        _ = tab.makeView(session: shown, context: onscreen)
        try await waitUntilCount(2, in: router)

        await router.open(.file(file, line: 3), from: .currentPanel)

        XCTAssertEqual(shown.openFiles.count, 1, "the link did not reach the panel on screen")
        XCTAssertEqual(hidden.openFiles.count, 0,
                       "the link opened in a channel the user was not looking at")
    }

    /// And with a host, the resolution is the host's: the delivery reaches the session the host
    /// names for the channel it is showing, whatever the render path drew last. A pop-out draws a
    /// channel of its own and a channel switch under another tab draws no Files view at all, so
    /// "the session rendered last" is not the channel a `.currentPanel` link belongs to.
    func testAHostedLinkOpensInTheChannelTheHostIsShowingRatherThanTheOneDrawnLast() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let host = StubFilesTabHost()
        let tab = FilesTab(host: host)
        let drawnContext = try makeContext(store: try makeStore(),
                                           cwd: try tree.directory("drawn"), links: capability)
        let drawn = try XCTUnwrap(tab.makeSession(for: drawnContext) as? FilesPanelSession)
        let showing = try XCTUnwrap(tab.makeSession(for: try makeContext(
            store: try makeStore(), cwd: try tree.directory("showing"), links: capability))
            as? FilesPanelSession)
        // The last thing rendered is one channel; the host is on the other.
        _ = tab.makeView(session: drawn, context: drawnContext)
        host.showing = showing
        let file = try tree.file("showing/routed.swift", "let routed = true\n")
        try await waitUntilCount(2, in: router)

        await router.open(.file(file, line: 3), from: .currentPanel)

        XCTAssertEqual(showing.openFiles.count, 1, "the link did not reach the host's channel")
        XCTAssertEqual(drawn.openFiles.count, 0, "the link followed the last render")
    }

    /// A `.newWindow` delivery belongs to the channel its window was popped out **for**, which the
    /// host knows and the render path does not. The pop-out is prepared from the channel the action
    /// came from, routing suspends twice between that preparation and the handler, and the window
    /// is free to move to another channel in between — so a resolution that ignores the destination
    /// writes the file into the channel the window is on now while the new window renders the other.
    func testANewWindowDeliveryOpensInTheChannelItsWindowWasPoppedOutFor() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let host = StubFilesTabHost()
        let tab = FilesTab(host: host)
        let poppedOut = try XCTUnwrap(tab.makeSession(for: try makeContext(
            store: try makeStore(), cwd: try tree.directory("popped"), links: capability))
            as? FilesPanelSession)
        let showing = try XCTUnwrap(tab.makeSession(for: try makeContext(
            store: try makeStore(), cwd: try tree.directory("showing"), links: capability))
            as? FilesPanelSession)
        host.showing = showing
        host.poppedOut = poppedOut
        let file = try tree.file("popped/routed.swift", "let routed = true\n")
        try await waitUntilCount(2, in: router)

        await router.open(.file(file, line: nil), from: .newWindow)

        XCTAssertEqual(poppedOut.openFiles.count, 1,
                       "the link did not reach the channel its own window was popped out for")
        XCTAssertEqual(showing.openFiles.count, 0,
                       "the link followed the channel the window happens to be on now")
    }

    /// With a host, the host's answer is the whole answer. Nil means this delivery has no channel
    /// at all, and the session the render path drew last is *some other* channel's — a pop-out's,
    /// or the last one Files was drawn for — so opening in it writes a file the link never named.
    /// The render anchor is the answer only for a tab built with no host.
    func testAHostedDeliveryTheHostResolvesNothingForOpensNothing() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let host = StubFilesTabHost()
        let tab = FilesTab(host: host)
        let drawnContext = try makeContext(store: try makeStore(),
                                           cwd: try tree.directory("drawn"), links: capability)
        let drawn = try XCTUnwrap(tab.makeSession(for: drawnContext) as? FilesPanelSession)
        _ = tab.makeView(session: drawn, context: drawnContext)
        host.showing = nil
        let file = try tree.file("drawn/routed.swift", "let routed = true\n")
        try await waitUntilCount(2, in: router)

        await router.open(.file(file, line: nil), from: .currentPanel)

        XCTAssertEqual(drawn.openFiles.count, 0,
                       "a hosted delivery fell back to the session the render path drew")
        XCTAssertEqual(host.selections, 0,
                       "the panel was brought forward for a delivery that opened nothing")
    }

    /// A `.currentPanel` delivery brings Files forward; a `.newWindow` one does not, because the
    /// host has already popped a window out for it and the main panel's selection is not its
    /// business.
    func testACurrentPanelDeliverySelectsFilesAndANewWindowOneDoesNot() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = RouterCapability(router: router)
        let host = StubFilesTabHost()
        let tab = FilesTab(host: host)
        let context = try makeContext(store: try makeStore(), links: capability)
        host.showing = try XCTUnwrap(tab.makeSession(for: context) as? FilesPanelSession)
        let file = try tree.file("workspace/routed.swift", "let routed = true\n")
        try await waitUntilCount(2, in: router)

        await router.open(.file(file, line: nil), from: .currentPanel)
        XCTAssertEqual(host.selections, 1, "the panel was left behind whichever tab was up")

        await router.open(.file(file, line: nil), from: .newWindow)
        XCTAssertEqual(host.selections, 1,
                       "a link that asked for its own window moved the main panel's selection")
    }

    /// The registration the app does: the targets exist before any session does, because the host
    /// builds one lazily for rendering and a link may arrive before the first visit.
    func testTheTabRegistersItsTargetsWithNoSessionBuiltAtAll() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let host = StubFilesTabHost()
        let tab = FilesTab(host: host)

        await tab.registerLinkTargets(through: RouterCapability(router: router))

        let count = await router.targetCount
        XCTAssertEqual(count, 2, "the pair is not registered until something renders")

        // And a delivery arriving now still reaches the host's channel, which is what the
        // registration is for.
        let context = try makeContext(store: try makeStore())
        host.showing = try XCTUnwrap(tab.makeSession(for: context) as? FilesPanelSession)
        let file = try tree.file("workspace/routed.swift", "let routed = true\n")
        await router.open(.file(file, line: nil), from: .currentPanel)
        XCTAssertEqual(host.showing?.openFiles.count, 1)
        let after = await router.targetCount
        XCTAssertEqual(after, 2, "building a session registered a second pair")
    }

    /// The weak half survives the move: a released session leaves the tab's targets claiming
    /// nothing, and the router takes W5's fallback rather than delivering into nothing.
    func testATargetWhoseSessionWasReleasedIsInertAndTheOpenFallsBack() async throws {
        let file = try tree.file("routed.swift", "let routed = true\n")
        let fell = Fallbacks()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { fell.record($0) })

        try await registerThenRelease(router: router)

        await router.open(.file(file, line: 7), from: .currentPanel)

        XCTAssertEqual(fell.count, 1, "the open took W5's fallback")
        let count = await router.targetCount
        XCTAssertEqual(count, 2, "the registrations outlive the session; only their claim does not")
    }

    /// Builds a tab and a session, registers, and lets both go. Separate so nothing in the test's
    /// own frame keeps either alive.
    private func registerThenRelease(router: LinkRouter) async throws {
        let tab = FilesTab()
        _ = tab.makeSession(for: try makeContext(store: try makeStore(),
                                                 links: RouterCapability(router: router)))
        try await waitUntilCount(2, in: router)
    }

    /// Polls the router's target count under a bounded wait. A count, never a target (§11).
    private func waitUntilCount(_ expected: Int, in router: LinkRouter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await router.targetCount == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(expected) registered targets")
    }

    // MARK: - 2. the readout over a session driven through its own API

    func testAnEmptyPanelDrawsNothingAndSaysNothing() throws {
        let session = try makeSession()

        let readout = FilesPanelReadout(session: session)

        XCTAssertNil(readout.selectedName)
        XCTAssertEqual(readout.viewer, .nothing)
        XCTAssertEqual(readout.openFileCount, 0)
        XCTAssertFalse(readout.showsConflictBanner)
        XCTAssertFalse(readout.isFilterActive)
        XCTAssertNil(readout.issue)
        XCTAssertNil(readout.notice, "the panel-local area is empty until something goes wrong")
    }

    func testAnOpenedSourceFileDrawsTheEditorUnderItsOwnName() async throws {
        let file = try tree.file("workspace/notes.swift", "let a = 1\n")
        let session = try makeSession()

        await session.openFile(at: file, line: nil)

        let readout = FilesPanelReadout(session: session)
        XCTAssertEqual(readout.selectedName, "notes.swift", "the name, never the path")
        XCTAssertEqual(readout.viewer, .editor)
        XCTAssertEqual(readout.openFileCount, 1)
        XCTAssertFalse(readout.isDirty)
    }

    func testAMarkdownFileDrawsItsNativeViewerUntilTheSourceToggle() async throws {
        let file = try tree.file("workspace/notes.md", "# a heading\n")
        let session = try makeSession()

        await session.openFile(at: file, line: nil)
        XCTAssertEqual(FilesPanelReadout(session: session).viewer, .markdown,
                       "markdown is rendered by default (Design §4)")

        await session.setRendersMarkdown(false, for: file)
        XCTAssertEqual(FilesPanelReadout(session: session).viewer, .editor,
                       "the toggle opens the same file's source in Monaco")
    }

    func testADirtyBufferIsMarkedInTheHeader() async throws {
        let file = try tree.file("workspace/notes.swift", "let a = 1\n")
        let surface = RecordingSurface()
        let session = try makeSession(surface: surface)

        await session.openFile(at: file, line: nil)
        surface.deliver(.dirty(path: file.path(percentEncoded: false), isDirty: true))

        XCTAssertTrue(FilesPanelReadout(session: session).isDirty)
    }

    /// The banner is raised the way a user raises it: the buffer is dirty, another writer has the
    /// file, and the save is refused into the conflict rather than overwriting it (Design §8).
    func testAConflictRaisesTheBanner() async throws {
        let file = try tree.file("workspace/notes.swift", "one\n")
        let surface = RecordingSurface()
        let session = try makeSession(surface: surface)
        await session.openFile(at: file, line: nil)
        let path = file.path(percentEncoded: false)
        surface.deliver(.dirty(path: path, isDirty: true))

        try "another writer\n".write(to: file, atomically: true, encoding: .utf8)
        session.save()
        surface.deliver(.saveRequested(path: path, text: "mine\n"))

        let readout = FilesPanelReadout(session: session)
        XCTAssertTrue(readout.showsConflictBanner, "the panel offers Reload and Keep mine")

        session.keepMine(file)
        XCTAssertFalse(FilesPanelReadout(session: session).showsConflictBanner,
                       "Keep mine takes the banner down")
    }

    func testADiffOnScreenDrawsTheDiffViewerRatherThanTheSelectedFile() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["sample.swift": "let a = 1\n"])
        try repository.write("sample.swift", "let a = 2\n")
        let session = try makeSession(environment: repository.environment)

        await session.showDiff(DiffRef(repository: repository.root, path: "sample.swift",
                                       base: .workingTreeAgainstHEAD))

        let readout = FilesPanelReadout(session: session)
        XCTAssertEqual(readout.viewer, .diff)
        XCTAssertNil(readout.issue, "a resolved pair is not a panel-local state")
    }

    func testAPathThatCannotBeReadDrawsThePanelLocalNoticeAndNoViewer() async throws {
        let session = try makeSession()

        await session.openFile(at: tree.root.appending(path: "workspace/absent.swift"), line: nil)

        let readout = FilesPanelReadout(session: session)
        XCTAssertEqual(readout.issue, .unreadableFile)
        XCTAssertNotNil(readout.notice, "the panel draws its own errors and never the channel's")
        XCTAssertEqual(readout.viewer, .nothing)
        XCTAssertEqual(readout.openFileCount, 0)
    }

    func testADiffWithNoTextSideDrawsThePanelLocalNoticeRatherThanTheDiffViewer() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["sample.swift": "let a = 1\n"])
        let session = try makeSession(environment: repository.environment)

        await session.showDiff(DiffRef(repository: repository.root, path: "sample.swift",
                                       base: .workingTreeAgainstHEAD))

        let readout = FilesPanelReadout(session: session)
        XCTAssertEqual(readout.issue, .noTextDiff(.pathUnchangedByBase))
        XCTAssertNotNil(readout.notice)
        XCTAssertEqual(readout.viewer, .nothing)
    }

    /// The header's *Close*: the count falls and the panel falls back to whatever is left.
    func testClosingTheSelectedFileLeavesTheOtherOpenFileOnScreen() async throws {
        let first = try tree.file("workspace/one.swift", "let a = 1\n")
        let second = try tree.file("workspace/two.swift", "let b = 2\n")
        let session = try makeSession()
        await session.openFile(at: first, line: nil)
        await session.openFile(at: second, line: nil)
        XCTAssertEqual(FilesPanelReadout(session: session).openFileCount, 2)

        await session.close(second)

        let readout = FilesPanelReadout(session: session)
        XCTAssertEqual(readout.openFileCount, 1)
        XCTAssertEqual(readout.selectedName, "one.swift")
        XCTAssertEqual(readout.viewer, .editor)
    }

    func testAFilterOverTheTreeIsReportedAsActive() throws {
        let session = try makeSession()

        XCTAssertFalse(FilesPanelReadout(session: session).isFilterActive)
        session.tree.filter = "no"
        XCTAssertTrue(FilesPanelReadout(session: session).isFilterActive)
    }

    // MARK: - 3. the viewer the item-25 corpus draws (Design §4, G2's rendered half)

    func testTheItem25CorpusDrawsItsOwnViewer() async throws {
        let corpus: [(name: String, bytes: Data, viewer: FilesPanelReadout.Viewer)] = [
            ("notes.md", Data("# a heading\n".utf8), .markdown),
            ("pixel.png", Self.pngBytes(), .image),
            ("page.pdf", Self.singlePagePDFBytes(), .pdf),
            ("clip.mp4", Self.mp4ContainerBytes(), .media),
            ("tone.wav", Self.wavBytes(), .media),
            ("sample.swift", Data("struct Sample {}\n".utf8), .editor),
            ("LICENCE", Data("Permission is granted.\n".utf8), .editor),
            ("blob", Data([0x00, 0x01, 0x02, 0x00, 0x7f]), .unsupported),
            ("card.rtf", Data("{\\rtf1\\ansi hello}".utf8), .quickLook),
            // The veto: bytes that contradict the name are `.binary`, and a panel-local surface
            // draws them rather than an `NSImage` that would fail inside a view (Design §4).
            ("claimed.png", Data("this is not a PNG at all\n".utf8), .unsupported),
        ]
        let session = try makeSession()

        for item in corpus {
            let url = try tree.file("corpus/\(item.name)")
            try item.bytes.write(to: url)
            await session.openFile(at: url, line: nil)
            XCTAssertEqual(FilesPanelReadout(session: session).viewer, item.viewer,
                           "\(item.name) names its own viewer")
            XCTAssertEqual(FilesPanelReadout(session: session).selectedName, item.name)
        }
        XCTAssertEqual(FilesPanelReadout(session: session).openFileCount, corpus.count,
                       "every file of the corpus is open at once")
    }

    // MARK: - the corpus, encoded rather than typed out

    /// A genuine 1×1 PNG, encoded by the system.
    private static func pngBytes() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 4, bitsPerPixel: 32)!
        rep.setColor(.white, atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])!
    }

    /// A genuine single-page PDF, drawn by Core Graphics.
    private static func singlePagePDFBytes() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// An `ftyp` box: the first box of every ISO base media container.
    private static func mp4ContainerBytes() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(contentsOf: Array("ftypisom".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        data.append(contentsOf: Array("isomiso2".utf8))
        data.append(Data(repeating: 0, count: 16))
        return data
    }

    /// A valid RIFF/WAVE header over a few samples of silence.
    private static func wavBytes() -> Data {
        let samples = Data(repeating: 0, count: 64)
        var data = Data(Array("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples.count).littleEndian) { Array($0) })
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(44100).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(88200).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(samples.count).littleEndian) { Array($0) })
        data.append(samples)
        return data
    }

    // MARK: - the harness

    private func makeSession(surface: (any EditorSurface)? = nil,
                             environment: [String: String] = [:],
                             links: any LinkRouterCapability = UnusedLinks()) throws
        -> FilesPanelSession {
        let context = try makeContext(store: try makeStore(), environment: environment, links: links)
        return FilesPanelSession(context: context, surface: surface,
                                 coalescingInterval: .milliseconds(10),
                                 watchCoalescingDelay: .milliseconds(20),
                                 watchPollInterval: .milliseconds(50))
    }

    private func makeContext(store: any ScopedStore, cwd: URL? = nil,
                             environment: [String: String] = [:],
                             links: any LinkRouterCapability = UnusedLinks()) throws
        -> ChannelContext {
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

    private func makeStore() throws -> some ScopedStore {
        let base = tree.root.appending(path: "state-\(UUID().uuidString)")
        return TabScoped(store: try FileStateStore(baseDirectory: base, configHomes: []))
    }

    private struct TabScoped: ScopedStore {
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

/// The app, as far as a delivered link can see it: the channel the window is showing, and the
/// selection. A count and a session, never a channel key (§11).
@MainActor
final class StubFilesTabHost: FilesTabHost {
    /// The channel the window is showing, and the channel a `.newWindow` delivery's window was
    /// popped out for. Two, because the destination is what chooses between them.
    var showing: FilesPanelSession?
    var poppedOut: FilesPanelSession?
    private(set) var selections = 0

    func filesSession(for destination: LinkDestination) -> FilesPanelSession? {
        destination == .newWindow ? poppedOut : showing
    }
    func selectFilesTab() { selections += 1 }
}

/// Counts registrations and nothing else: the count is the whole assertion (§11).
final class CountingLinks: LinkRouterCapability, @unchecked Sendable {
    private let lock = NSLock()
    private var registered = 0
    var count: Int { lock.withLock { registered } }
    func register(_ target: LinkTarget) async { lock.withLock { registered += 1 } }
    func unregister(tab: PanelTabID) async { lock.withLock { registered = 0 } }
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}
