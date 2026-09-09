// C7.7 spec Design §2, §9, §11; gate G2.3 (a pull request opens in the Browser) and G4's readout
// inventory.
//
// §6.3 and §11: every assertion names a number, a case or a count — never a byte `gh` printed and
// never a real account.
import Foundation
import XCTest
import AfleetCore
import FleetKit
import LinkRouting
import PanelHostAPI
import SourceControlCore
@testable import SourceControlPanel

@MainActor
final class GitHubTabTests: XCTestCase {

    private var tree: ScratchTree!

    override func setUp() async throws {
        tree = try ScratchTree()
    }

    override func tearDown() async throws {
        tree?.remove()
        tree = nil
    }

    // MARK: - 1. the tab itself (Design §2, §11)

    func testTheTabCarriesTheGitHubIdAndThatIdsOwnTitleAndSymbol() throws {
        let tab = GitHubTab()

        XCTAssertEqual(tab.id, .github)
        XCTAssertEqual(tab.title, PanelTabID.github.defaultTitle)
        XCTAssertEqual(tab.systemImage, PanelTabID.github.defaultSystemImage)
    }

    /// The same reason the Source Control tab is unconditional: availability is what X7's Cmd+1…7
    /// indexes over, and a channel in no repository gets this tab's own empty state (Design §11).
    func testTheTabIsAvailableForARepositoryAndForAChannelInNone() async throws {
        let tab = GitHubTab()
        let repository = try await GitRepository(tree)
        try await repository.commit("one", files: ["a.txt": "a\n"])

        XCTAssertTrue(tab.isAvailable(in: try makeContext(cwd: repository.root,
                                                          environment: repository.environment)))
        XCTAssertTrue(tab.isAvailable(in: try makeContext(cwd: try tree.directory("none"))),
                      "a channel in no repository lost the tab instead of getting the empty state")
    }

    // MARK: - 2. sessions and views (Design §2, §11)

    /// Bound to the channel: the read runs `git` in the channel's own directory and with the
    /// channel's own environment, which is what `.notARepository` here reports. Nothing reaches
    /// `gh` — a directory with no repository has no GitHub repository to ask about (Design §8).
    func testMakeSessionBuildsAGitHubModelBoundToTheChannelsDirectory() async throws {
        let tab = GitHubTab()
        let repository = try await GitRepository(tree)
        var environment = repository.environment
        environment["HOME"] = try tree.directory("home").path(percentEncoded: false)
        let context = try makeContext(cwd: try tree.directory("outside-any-repository"),
                                      environment: environment)

        let session = tab.makeSession(for: context)

        let model = try XCTUnwrap(session as? GitHubModel)
        try await waitUntil("the session to read the channel's own directory") {
            model.failure != nil
        }
        XCTAssertEqual(model.failure, .notARepository)
    }

    func testEachChannelGetsItsOwnSession() throws {
        let tab = GitHubTab()
        let first = tab.makeSession(for: try makeContext(cwd: try tree.directory("one"))) as? GitHubModel
        let second = tab.makeSession(for: try makeContext(cwd: try tree.directory("two"))) as? GitHubModel

        XCTAssertFalse(first === second, "the host retains one session per (tab, channel)")
    }

    func testMakeViewTakesItsSurfaceAndDescribesTheSameViewForBoth() throws {
        let tab = GitHubTab()
        let context = try makeContext(cwd: try tree.directory("drawn"))
        let session = tab.makeSession(for: context)

        let inPanel = tab.panelView(session: session, surface: .panel)
        let poppedOut = tab.panelView(session: session,
                                      surface: .poppedOutWindow(tab: .github,
                                                                channel: context.key))

        XCTAssertNotNil(inPanel)
        XCTAssertTrue(inPanel?.session === poppedOut?.session,
                      "the two surfaces were given different views of one session")
    }

    func testMakeViewOfSomeOtherTabsSessionDescribesNothing() throws {
        let tab = GitHubTab()
        let context = try makeContext(cwd: try tree.directory("other"))

        XCTAssertNil(tab.panelView(session: SourceControlModel(cwd: tree.root,
                                                              environment: context.environment,
                                                              watchesForChanges: false),
                                   surface: .panel))
    }

    // MARK: - 4. opening a pull request (Design §9, G2.3)

    /// It emits `.pullRequest(number)` and nothing else: no URL is built here, no remote is
    /// parsed, and C7.6's resolver is the only thing that turns a number into a page.
    func testOpeningAPullRequestEmitsExactlyThatLinkThroughARealRouter() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let received = ReceivedLinks()
        await router.register(recordingPullRequestTarget(into: received))
        let context = try makeContext(cwd: try tree.directory("channel"),
                                      links: TabRouterCapability(router: router))
        let session = GitHubModel(context: context)

        await session.open(pullRequest: 41, from: .currentPanel)

        XCTAssertEqual(received.links.count, 1, "the emission did not reach the registry")
        XCTAssertEqual(received.links.first?.link, .pullRequest(41),
                       "the link that left this leaf was not the number the row carried")
        XCTAssertEqual(received.links.first?.destination, .currentPanel)
    }

    func testACmdClickedPullRequestCarriesItsOwnDestination() async throws {
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let received = ReceivedLinks()
        await router.register(recordingPullRequestTarget(into: received))
        let context = try makeContext(cwd: try tree.directory("channel"),
                                      links: TabRouterCapability(router: router))

        await GitHubModel(context: context).open(pullRequest: 7, from: .newWindow)

        XCTAssertEqual(received.links.first?.link, .pullRequest(7))
        XCTAssertEqual(received.links.first?.destination, .newWindow)
    }

    /// **This leaf registers no `.pullRequest` target of its own** (Design §9). Asserted by the tab
    /// of every registration the two tabs make, and by the router's count.
    func testThisLeafRegistersNoPullRequestTargetOfItsOwn() async throws {
        let recorder = TabRecordingLinks()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let capability = TabRouterCapability(router: router)
        let before = await router.targetCount

        let github = GitHubTab()
        _ = github.makeSession(for: try makeContext(cwd: try tree.directory("gh-one"),
                                                    links: recorder))
        _ = github.makeSession(for: try makeContext(cwd: try tree.directory("gh-two"),
                                                    links: capability))
        // Two tabs, because one registers once and only once: the recorder answers "for which tab
        // is anything registered at all", the router answers "how many".
        let sourceControl = SourceControlTab()
        await sourceControl.registerLinkTargets(through: recorder)
        await SourceControlTab().registerLinkTargets(through: capability)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.registrations, [.sourceControl],
                       "a registration was made for a tab this leaf does not claim links for")
        let after = await router.targetCount
        XCTAssertEqual(after, before + 1, "the GitHub tab registered a target of its own")
        // And the one target this leaf does register claims no pull request.
        for target in sourceControl.linkTargets() {
            XCTAssertFalse(target.handles(.pullRequest(41)))
        }
    }

    // MARK: - 5. G4's inventory: every action this tab's surfaces offer

    func testTheReadoutsActionInventoryHoldsNoStagingCommitOrBranchAction() throws {
        XCTAssertEqual(Set(GitHubReadout.Action.allCases),
                       [.refresh, .scopeToBranch, .scopeToAllOpen, .selectPullRequest,
                        .openPullRequest],
                       "this tab offers an action outside the reader's inventory")
    }

    // MARK: - helpers

    /// A target that claims `.pullRequest` and records what it was given — C7.6's Browser, as far
    /// as this leaf can see it.
    private func recordingPullRequestTarget(into received: ReceivedLinks) -> LinkTarget {
        LinkTarget(tab: .browser, specificity: 10,
                   handles: { link in
                       if case .pullRequest = link { return true }
                       return false
                   },
                   open: { link, destination in received.record(link, destination) })
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func makeContext(cwd: URL, environment: [String: String] = ["PATH": ""],
                             links: any LinkRouterCapability = TabUnusedLinks()) throws
        -> ChannelContext {
        let session = SessionID()
        return ChannelContext(
            key: ChannelKey(configHome: tree.root.appending(path: "config-home-\(session)"),
                            session: session),
            session: session,
            cwd: cwd,
            environment: ResolvedEnvironment(variables: environment, shell: "/bin/zsh",
                                             capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                                             mode: .processFallback),
            store: TabUnusedStore(),
            links: links,
            recentURLs: TabUnusedFeed(),
            reportPaneExit: { _ in })
    }
}

/// What a registered target was handed. A link and a destination, both of this test's own making.
final class ReceivedLinks: @unchecked Sendable {
    struct Delivered: Sendable {
        let link: WorkspaceLink
        let destination: LinkDestination
    }

    private let lock = NSLock()
    private var delivered: [Delivered] = []
    var links: [Delivered] { lock.withLock { delivered } }
    func record(_ link: WorkspaceLink, _ destination: LinkDestination) {
        lock.withLock { delivered.append(Delivered(link: link, destination: destination)) }
    }
}
