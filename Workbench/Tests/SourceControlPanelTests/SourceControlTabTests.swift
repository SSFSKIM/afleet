// C7.7 spec Design §2, §7, §11; gates G1, G3's `.commit` half and G4's readout inventory.
//
// §6.3 and §11: every assertion names a count, a case or a hash the test itself invented — never a
// path, never a byte a tool printed. Every repository is built under the process's temporary
// directory by the fixtures, and no test reads one it did not create.
import Foundation
import XCTest
import AfleetCore
import FleetKit
import LinkRouting
import PanelHostAPI
import SourceControlCore
@testable import SourceControlPanel

@MainActor
final class SourceControlTabTests: XCTestCase {

    private var tree: ScratchTree!

    override func setUp() async throws {
        tree = try ScratchTree()
    }

    override func tearDown() async throws {
        tree?.remove()
        tree = nil
    }

    // MARK: - 1. the tab itself (Design §2, §11)

    func testTheTabCarriesTheSourceControlIdAndThatIdsOwnTitleAndSymbol() throws {
        let tab = SourceControlTab()

        XCTAssertEqual(tab.id, .sourceControl)
        XCTAssertEqual(tab.title, PanelTabID.sourceControl.defaultTitle,
                       "the title is the id's own, not a second spelling of it")
        XCTAssertEqual(tab.systemImage, PanelTabID.sourceControl.defaultSystemImage)
    }

    /// Availability is what X7's Cmd+1…7 indexes over, so a tab that came and went as the user
    /// moved between channels would renumber the shortcuts under them. A channel in no repository
    /// gets the empty state instead (Design §11).
    func testTheTabIsAvailableForARepositoryAndForAChannelInNone() async throws {
        let tab = SourceControlTab()
        let repository = try await GitRepository(tree)
        try await repository.commit("one", files: ["a.txt": "a\n"])
        let inRepository = try makeContext(cwd: repository.root,
                                           environment: repository.environment)
        let outsideAny = try makeContext(cwd: try tree.directory("no-repository"))

        XCTAssertTrue(tab.isAvailable(in: inRepository))
        XCTAssertTrue(tab.isAvailable(in: outsideAny),
                      "a channel in no repository lost the tab instead of getting the empty state")
    }

    // MARK: - 2. sessions and views (Design §2, §11)

    func testMakeSessionBuildsASourceControlModelBoundToTheChannelsDirectory() async throws {
        let tab = SourceControlTab()
        let repository = try await GitRepository(tree)
        try await repository.commit("one", files: ["a.txt": "a\n"])
        let context = try makeContext(cwd: repository.root, environment: repository.environment)

        let session = tab.makeSession(for: context)

        let model = try XCTUnwrap(session as? SourceControlModel)
        try await waitUntil("the session to read the channel's own repository") {
            model.state.root != nil
        }
        XCTAssertEqual(model.state.root.map(Self.directoryPath), Self.directoryPath(repository.root),
                       "the session read some directory other than the channel's")
    }

    func testEachChannelGetsItsOwnSession() throws {
        let tab = SourceControlTab()
        let one = try makeContext(cwd: try tree.directory("one"), environment: pathlessEnvironment())
        let other = try makeContext(cwd: try tree.directory("two"),
                                    environment: pathlessEnvironment())

        let first = tab.makeSession(for: one) as? SourceControlModel
        let second = tab.makeSession(for: other) as? SourceControlModel

        XCTAssertFalse(first === second, "the host retains one session per (tab, channel)")
    }

    /// This tab describes a view rather than owning an `NSView`, so the same description is right
    /// in the main column and in a popped-out window — and the parameter is taken and named,
    /// because X7 gives it no default (Design §11).
    func testMakeViewTakesItsSurfaceAndDescribesTheSameViewForBoth() throws {
        let tab = SourceControlTab()
        let context = try makeContext(cwd: try tree.directory("drawn"),
                                      environment: pathlessEnvironment())
        let session = tab.makeSession(for: context)

        let inPanel = tab.panelView(session: session, surface: .panel)
        let poppedOut = tab.panelView(
            session: session,
            surface: .poppedOutWindow(tab: .sourceControl, channel: context.key))

        XCTAssertNotNil(inPanel)
        XCTAssertTrue(inPanel?.session === poppedOut?.session,
                      "the two surfaces were given different views of one session")
    }

    func testMakeViewOfSomeOtherTabsSessionDescribesNothing() throws {
        let tab = SourceControlTab()
        let context = try makeContext(cwd: try tree.directory("other"),
                                      environment: pathlessEnvironment())

        XCTAssertNil(tab.panelView(session: GitHubModel(context: context), surface: .panel))
    }

    // MARK: - 3. the `.commit` target, through a real router (Design §7)

    func testTheTabRegistersOneCommitTargetAtSpecificity100WithThePopOutDefault() throws {
        let targets = SourceControlTab().linkTargets()

        XCTAssertEqual(targets.count, 1, "this leaf registers one target and only one")
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(target.tab, .sourceControl)
        XCTAssertEqual(target.specificity, 100)
        XCTAssertTrue(target.popsOutForNewWindow,
                      "the Browser's declination is about leaving the app, which nothing here does")
    }

    /// The claim is `.commit` and nothing else: `.diff` and `.pullRequest` are **emitted** by this
    /// leaf and claimed by other panels (Design §6, §9).
    func testTheTargetClaimsCommitLinksAndNoOtherKind() throws {
        let tab = SourceControlTab()
        let session = SourceControlModel(cwd: tree.root, environment: pathlessEnvironment(),
                                         watchesForChanges: false)
        tab.present(session)
        let target = try XCTUnwrap(tab.linkTargets().first)

        XCTAssertTrue(target.handles(.commit(Self.hash)))
        XCTAssertFalse(target.handles(.pullRequest(41)))
        XCTAssertFalse(target.handles(.file(tree.root, line: nil)))
        XCTAssertFalse(target.handles(.diff(DiffRef(repository: tree.root, path: "a.txt",
                                                   base: .workingTreeAgainstHEAD))))
        XCTAssertFalse(target.handles(.url(URL(string: "https://example.invalid")!)))
    }

    /// A delivery reaches the session the **host** resolves for the delivery's destination, with
    /// the link intact: the hash the panel answers about is the one the link carried.
    func testACommitLinkReachesTheSessionTheHostResolvesForTheCurrentPanel() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let host = StubSourceControlTabHost()
        let tab = SourceControlTab(host: host)
        host.showing = makeModel()
        host.poppedOut = makeModel()
        await tab.registerLinkTargets(through: TabRouterCapability(router: router))

        await router.open(.commit(Self.hash), from: .currentPanel)

        XCTAssertEqual(host.showing?.deliveryNotice, .noRepository(hash: Self.hash),
                       "the link did not reach the channel the host is showing, hash intact")
        XCTAssertNil(host.poppedOut?.deliveryNotice)
        XCTAssertEqual(host.selections, 1, "the panel was left behind whichever tab was up")
    }

    /// `.newWindow` belongs to the channel the host popped the tab out **for**, and it does not
    /// move the main panel's selection.
    func testANewWindowDeliveryReachesTheChannelItsWindowWasPoppedOutFor() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let host = StubSourceControlTabHost()
        let tab = SourceControlTab(host: host)
        host.showing = makeModel()
        host.poppedOut = makeModel()
        await tab.registerLinkTargets(through: TabRouterCapability(router: router))

        await router.open(.commit(Self.hash), from: .newWindow)

        XCTAssertEqual(host.poppedOut?.deliveryNotice, .noRepository(hash: Self.hash),
                       "the link followed the channel the window happens to be on now")
        XCTAssertNil(host.showing?.deliveryNotice)
        XCTAssertEqual(host.selections, 0,
                       "a link that asked for its own window moved the main panel's selection")
    }

    /// A tab built with no host falls back to the anchored session — the seam this package's own
    /// tests drive, and the only case the anchor answers.
    func testWithNoHostTheAnchoredSessionAnswers() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let tab = SourceControlTab()
        let session = makeModel()
        await tab.registerLinkTargets(through: TabRouterCapability(router: router),
                                      presenting: session)

        await router.open(.commit(Self.hash), from: .currentPanel)

        XCTAssertEqual(session.deliveryNotice, .noRepository(hash: Self.hash))
    }

    /// With a host, the host's answer is the whole answer: nil means this delivery has no channel
    /// to land in, and the anchored session is a *different* channel's.
    func testAHostedDeliveryTheHostResolvesNothingForOpensNothing() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let host = StubSourceControlTabHost()
        let tab = SourceControlTab(host: host)
        let anchored = makeModel()
        await tab.registerLinkTargets(through: TabRouterCapability(router: router),
                                      presenting: anchored)
        host.showing = nil

        await router.open(.commit(Self.hash), from: .currentPanel)

        XCTAssertNil(anchored.deliveryNotice,
                     "a hosted delivery fell back to the session the render path drew")
        XCTAssertEqual(host.selections, 0,
                       "the panel was brought forward for a delivery that opened nothing")
    }

    /// `LinkRouterCapability` has no per-registration withdrawal, so a released session — or a
    /// released host — leaves an **inert** target and the router takes W5's fallback.
    func testATargetWhoseSessionAndHostWereReleasedIsInertAndTheOpenFallsBack() async throws {
        let fell = Fallbacks()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { fell.record($0) })

        try await registerThenRelease(router: router)

        await router.open(.commit(Self.hash), from: .currentPanel)

        XCTAssertEqual(fell.count, 1, "the open took W5's fallback")
        let count = await router.targetCount
        XCTAssertEqual(count, 1, "the registration outlives the session; only its claim does not")
    }

    /// The discriminating test of this task. Design §7 registered a target per **session**, and
    /// every one of them would carry the same tab at the same specificity: `mostSpecific` compares
    /// specificity and canonical tab order and never channel identity (tracker 240).
    func testASecondMakeSessionDoesNotRegisterASecondTarget() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = TabRouterCapability(router: router)
        let before = await router.targetCount
        let tab = SourceControlTab()

        for name in ["one", "two", "three", "four"] {
            _ = tab.makeSession(for: try makeContext(cwd: try tree.directory(name),
                                                     environment: pathlessEnvironment(),
                                                     links: capability))
        }

        try await waitUntilCount(before + 1, in: router)
        try await Task.sleep(for: .milliseconds(100))
        let after = await router.targetCount
        XCTAssertEqual(after, before + 1,
                       "the registration grew with the number of channels")
    }

    /// The registration the app (T8) does: the target exists before any session does, because the
    /// host builds one lazily for rendering and a link may arrive before the first visit.
    func testTheAppsRegistrationHappensOnceAndASessionBuiltAfterwardsAddsNothing() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = TabRouterCapability(router: router)
        let before = await router.targetCount
        let host = StubSourceControlTabHost()
        let tab = SourceControlTab(host: host)

        await tab.registerLinkTargets(through: capability)
        let afterRegistration = await router.targetCount
        XCTAssertEqual(afterRegistration, before + 1,
                       "the target is not registered until something renders")

        host.showing = try XCTUnwrap(tab.makeSession(
            for: try makeContext(cwd: try tree.directory("late"),
                                 environment: pathlessEnvironment(), links: capability))
            as? SourceControlModel)
        try await Task.sleep(for: .milliseconds(100))
        let afterSession = await router.targetCount
        XCTAssertEqual(afterSession, before + 1, "building a session registered a second target")

        await router.open(.commit(Self.hash), from: .currentPanel)
        // `pathlessEnvironment()` leaves `git` unresolvable, so this channel's repository could not
        // be **read**; it is not a folder in no repository, and §5/§7 as amended at T5's review
        // keep the two apart — a row that says "not a repository" over a `git` that failed sends
        // the user to look at a repository that is fine.
        XCTAssertEqual(host.showing?.deliveryNotice, .notReadable(hash: Self.hash, tool: .git))
    }

    // MARK: - 5. G4's inventory: every action this tab's surfaces offer

    /// §9.2 is binding and this panel is a reader, so the assertion is on the **universe** of
    /// actions and not on a sample: an action added to a view and not to the readout fails the
    /// readout test it was added to, and one added to both fails this.
    func testTheReadoutsActionInventoryHoldsNoStagingCommitOrBranchAction() throws {
        XCTAssertEqual(Set(SourceControlReadout.Action.allCases),
                       [.refresh, .selectCommit, .selectWorkingTree, .selectParentCommit,
                        .openFileDiff],
                       "this tab offers an action outside the reader's inventory")
    }

    // MARK: - helpers

    /// A directory's path without its trailing separator, so that a root `git` printed and one the
    /// fixture created compare as the directory they both name.
    private nonisolated static func directoryPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Invented, never a hash from any repository the author has (§11).
    private static let hash = "4f1c9a7bd3e05628a1c47bb90f2d6e8137ac54d2"

    /// A model over a directory in no repository and with nothing on `PATH`, so a delivery is
    /// answered by `.noRepository` — which is the whole of what these tests read: the link arrived,
    /// with its hash intact.
    private func makeModel() -> SourceControlModel {
        SourceControlModel(cwd: tree.root, environment: pathlessEnvironment(),
                           watchesForChanges: false)
    }

    /// Builds a tab and its session, registers, and lets both go. Separate so nothing in the
    /// test's own frame keeps either alive.
    private func registerThenRelease(router: LinkRouter) async throws {
        let host = StubSourceControlTabHost()
        let tab = SourceControlTab(host: host)
        host.showing = makeModel()
        await tab.registerLinkTargets(through: TabRouterCapability(router: router))
    }

    /// Polls the router's target count under a bounded wait. A count, never a target (§11).
    private func waitUntilCount(_ expected: Int, in router: LinkRouter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await router.targetCount == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let count = await router.targetCount
        XCTFail("timed out waiting for \(expected) registered targets, and there were \(count)")
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// An environment with an empty `PATH`, so a session built by `makeSession` resolves no binary
    /// and starts no process: these tests are about registration and identity, not about `git`.
    private func pathlessEnvironment() -> ResolvedEnvironment {
        ResolvedEnvironment(variables: ["PATH": ""], shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback)
    }

    private func makeContext(cwd: URL, environment: [String: String] = ["PATH": ""],
                             links: any LinkRouterCapability = TabUnusedLinks()) throws
        -> ChannelContext {
        try makeContext(cwd: cwd,
                        environment: ResolvedEnvironment(
                            variables: environment, shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback),
                        links: links)
    }

    private func makeContext(cwd: URL, environment: ResolvedEnvironment,
                             links: any LinkRouterCapability = TabUnusedLinks()) throws
        -> ChannelContext {
        let session = SessionID()
        return ChannelContext(
            key: ChannelKey(configHome: tree.root.appending(path: "config-home-\(session)"),
                            session: session),
            session: session,
            cwd: cwd,
            environment: environment,
            store: TabUnusedStore(),
            links: links,
            recentURLs: TabUnusedFeed(),
            reportPaneExit: { _ in })
    }
}

/// The app, as far as a delivered link can see it: the channel the window is showing, the channel
/// a `.newWindow` delivery's window was popped out for, and the selection. A count and a session,
/// never a channel key (§11).
@MainActor
final class StubSourceControlTabHost: SourceControlTabHost {
    var showing: SourceControlModel?
    var poppedOut: SourceControlModel?
    private(set) var selections = 0

    func sourceControlSession(for destination: LinkDestination) -> SourceControlModel? {
        destination == .newWindow ? poppedOut : showing
    }
    func selectSourceControlTab() { selections += 1 }
}

/// The real `LinkRouter` behind the capability a `ChannelContext` carries. The host is what
/// conforms in the app; a test needs only the registry half.
struct TabRouterCapability: LinkRouterCapability {
    let router: LinkRouter
    func register(_ target: LinkTarget) async { await router.register(target) }
    func unregister(tab: PanelTabID) async { await router.unregister(tab: tab) }
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        await router.open(link, from: destination)
    }
}

/// Records the tab of every registration and nothing else — the whole of what §11 allows and the
/// whole of what "this leaf registers no `.pullRequest` target" needs.
final class TabRecordingLinks: LinkRouterCapability, @unchecked Sendable {
    private let lock = NSLock()
    private var tabs: [PanelTabID] = []
    var registrations: [PanelTabID] { lock.withLock { tabs } }
    func register(_ target: LinkTarget) async { lock.withLock { tabs.append(target.tab) } }
    func unregister(tab: PanelTabID) async { lock.withLock { tabs.removeAll { $0 == tab } } }
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

/// Counts the router's fallback diagnostics. The message is the router's own and names a kind,
/// never a link (§11).
final class Fallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var count: Int { lock.withLock { messages.count } }
    func record(_ message: String) { lock.withLock { messages.append(message) } }
}

/// The capability for tests that route nothing.
struct TabUnusedLinks: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

/// This leaf writes no store document (Design §10), so the store a context carries is never read.
struct TabUnusedStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

struct TabUnusedFeed: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}
