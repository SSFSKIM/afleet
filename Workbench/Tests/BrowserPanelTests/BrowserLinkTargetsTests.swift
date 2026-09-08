// C7.6 milestone 5: the two `LinkTarget`s the Browser registers, and the `.pullRequest` route.
//
// The rulings this file asserts (ledger, *Architect's rulings at the gate*, 2026-09-09): Q1 —
// `.currentPanel` opens in the Browser tab and `.newWindow` is the *system* browser, through the
// injected opener; Q2 — `.pullRequest(Int)` resolves by running `gh pr view <n> --json url` in the
// repository root, and every way that can fail is a panel-local error row rather than an exception
// reaching the channel (§10); Q3 — the channel is the host's selected one, supplied as a provider.
//
// Every URL here is invented under `example.invalid` or `.test` and every `gh` document is
// authored, never recorded (§6.3, §11). Nothing reaches a network, a repository or a browser: the
// tool runner is a stub and the external opener is injected.
import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
import LinkRouting
import SourceControlCore
@testable import BrowserPanel

@MainActor
final class BrowserLinkTargetsTests: XCTestCase {

    // MARK: - What the tests are built from

    /// Where the Browser was asked to be shown, in order — the injected `selectBrowserTab`.
    private final class SelectionLog {
        private(set) var count = 0
        func selected() { count += 1 }
    }

    /// A model over an in-memory store, with every seam injected.
    private func makeModel(store backing: InMemoryScopedStore = InMemoryScopedStore()) -> BrowserModel {
        BrowserModel(store: BrowserTabStore(store: backing, sleep: ManualSleeper().sleep),
                     factory: BrowserWebViewFactory(),
                     openExternally: { _ in
                         XCTFail("the model's own external opener must not be reached by a link target")
                     })
    }

    /// The whole assembly: the model, the targets, a real `LinkRouter` they are registered on, and
    /// the two sinks the assertions read.
    ///
    /// The router is the real one and not a stand-in, because two of the claims below are about the
    /// registry — the link arriving *intact* through resolution, and W5's fallback not firing.
    private func makeRouter(channel: ChannelContext?,
                            store backing: InMemoryScopedStore = InMemoryScopedStore(),
                            runner: any ToolRunning = StubToolRunner { _, _ in
                                XCTFail("no tool was expected to run")
                                return StubToolRunner.exited(0)
                            })
        async -> (model: BrowserModel, router: LinkRouter, opened: URLSink,
                  fallback: URLSink, selection: SelectionLog) {
        let model = makeModel(store: backing)
        let opened = URLSink()
        let fallback = URLSink()
        let selection = SelectionLog()
        let router = LinkRouter(externalOpener: { fallback.opened($0) }, diagnostic: { _ in })
        let resolver = PullRequestURLResolver(runner: runner, channel: { channel })
        for target in BrowserLinkTargets.make(model: model,
                                              pullRequests: resolver,
                                              selectBrowserTab: { selection.selected() },
                                              openExternally: { opened.opened($0) }) {
            await router.register(target)
        }
        return (model, router, opened, fallback, selection)
    }

    // MARK: - Q1: the `.url` target

    /// `.currentPanel` opens the URL in the Browser tab, and the host is asked to show that tab.
    ///
    /// The link is compared whole rather than by case: what the target navigates to is the URL that
    /// was opened, not merely *a* URL. W5's fallback is asserted silent in the same breath, because
    /// a target that failed to register would otherwise look identical from the panel's side —
    /// the fallback would open the page in the system browser and the test would only see an
    /// unnavigated panel.
    func testAURLAtCurrentPanelNavigatesTheBrowserTabAndAsksForIt() async {
        let rig = await makeRouter(channel: Values.channel())

        await rig.router.open(Values.pageLink, from: .currentPanel)

        guard case .url(let expected) = Values.pageLink else { return XCTFail("the fixture is not a .url") }
        XCTAssertEqual(rig.model.selected?.url, expected,
                       "the panel is on \(String(describing: rig.model.selected?.url))")
        XCTAssertEqual(rig.selection.count, 1,
                       "the host was asked for the Browser tab \(rig.selection.count) times, not once")
        XCTAssertEqual(rig.opened.urls, [], "a .currentPanel link reached the system opener")
        XCTAssertEqual(rig.fallback.urls, [], "W5's fallback fired for a link the Browser claimed")
    }

    /// `.newWindow` is the system browser and **not** the panel (Q1, as ruled).
    ///
    /// The panel is asserted untouched — no tab, no selection request — because a target that did
    /// both would satisfy an assertion on the opener alone while showing the user two pages.
    func testAURLAtNewWindowReachesTheInjectedOpenerAndLeavesThePanelAlone() async {
        let rig = await makeRouter(channel: Values.channel())

        await rig.router.open(Values.pageLink, from: .newWindow)

        guard case .url(let expected) = Values.pageLink else { return XCTFail("the fixture is not a .url") }
        XCTAssertEqual(rig.opened.urls, [expected],
                       "the system opener received \(rig.opened.urls)")
        XCTAssertTrue(rig.model.tabs.isEmpty, "the panel opened \(rig.model.tabs.count) tabs as well")
        XCTAssertEqual(rig.selection.count, 0, "the host was asked to show a tab it did not need")
        XCTAssertEqual(rig.fallback.urls, [], "W5's fallback fired for a link the Browser claimed")
    }

    /// W5's fallback fires for a `.url` **only** when the Browser has not claimed it.
    ///
    /// The control half is what makes the assertion above able to fail: without it, a router whose
    /// fallback never fires at all would pass every "the fallback stayed silent" line in this file.
    func testTheFallbackFiresOnlyWithoutTheBrowserTarget() async {
        let bare = URLSink()
        let empty = LinkRouter(externalOpener: { bare.opened($0) }, diagnostic: { _ in })

        await empty.open(Values.pageLink, from: .currentPanel)

        guard case .url(let expected) = Values.pageLink else { return XCTFail("the fixture is not a .url") }
        XCTAssertEqual(bare.urls, [expected],
                       "an unclaimed .url did not reach the router's external opener")

        let rig = await makeRouter(channel: Values.channel())
        await rig.router.open(Values.pageLink, from: .currentPanel)
        XCTAssertEqual(rig.fallback.urls, [],
                       "the same link reached the fallback with the Browser target registered")
    }

    /// The Browser declines the pop-out on both of its targets (X7's amendment, ruled at the gate).
    func testBothTargetsDeclineThePopOut() {
        let model = makeModel()
        let targets = BrowserLinkTargets.make(model: model,
                                              pullRequests: PullRequestURLResolver(runner: StubToolRunner { _, _ in
                                                  StubToolRunner.exited(0)
                                              }, channel: { nil }),
                                              selectBrowserTab: {},
                                              openExternally: { _ in })
        XCTAssertEqual(targets.count, 2, "the Browser registered \(targets.count) targets, not 2")
        XCTAssertTrue(targets.allSatisfy { $0.tab == .browser },
                      "a target was registered for a tab that is not the Browser")
        XCTAssertTrue(targets.allSatisfy { !$0.popsOutForNewWindow },
                      "a Browser target still asks the host to pop its tab out")
        XCTAssertTrue(targets.contains { $0.handles(Values.pageLink) },
                      "no target handles a .url link")
        XCTAssertTrue(targets.contains { $0.handles(.pullRequest(Values.pullRequestNumber)) },
                      "no target handles a .pullRequest link")
    }

    /// **A routed link does not race the restore** (A1).
    ///
    /// The panel is being drawn for the first time — its restore is in flight, holding on the
    /// store's read — and a `.url` arrives in that window. Both orders lose something if the two
    /// are not ordered: an `open` that runs first is thrown away when the restore replaces the tab
    /// set, and a restore that lands first over an `open` publishes a set the store never saw.
    /// The clicked page is the one on screen, and the saved tabs are still there.
    func testALinkDeliveredDuringTheRestoreKeepsTheSavedTabsAndLandsOnTheClickedPage() async throws {
        let backing = InMemoryScopedStore()
        let first = URL(string: "https://saved-one.example.invalid/")!
        let second = URL(string: "https://saved-two.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: first, title: "One"),
                                                             PersistedTab(url: second, title: "Two")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        await backing.holdReads()
        let rig = await makeRouter(channel: Values.channel(), store: backing)

        // The panel is drawn: `BrowserPanelView`'s own `.task { await model.restore() }`.
        let render = Task { await rig.model.restore() }
        let reading = expectation(description: "the restore reached the store")
        await backing.expectReadArrival(reading)
        await fulfillment(of: [reading], timeout: 5)

        // The click, while the read is still held open.
        let delivery = Task { await rig.router.open(Values.pageLink, from: .currentPanel) }
        for _ in 0..<50 { await Task.yield() }
        await backing.releaseReads()
        await render.value
        await delivery.value

        guard case .url(let clicked) = Values.pageLink else { return XCTFail("the fixture is not a .url") }
        XCTAssertEqual(rig.model.tabs.count, 2, "the saved tab set did not survive the click")
        XCTAssertEqual(rig.model.tabs.last?.url, second, "the saved set came back changed")
        XCTAssertEqual(rig.model.selected?.url, clicked,
                       "the panel is on \(String(describing: rig.model.selected?.url)), not the page that was clicked")
    }

    // MARK: - Q2: the `.pullRequest` route

    /// The resolved page is what `gh pr view <n> --json url` printed, and the command is exactly
    /// that: a read, in the repository root, with no flag that could open a browser or prompt.
    func testAPullRequestResolvesThroughGhAndNavigatesThePanel() async {
        let runner = StubToolRunner { tool, arguments in
            switch (tool, arguments.first) {
            case (.git, "rev-parse"): return StubToolRunner.printed(Values.repositoryRoot + "\n")
            case (.gh, "pr"): return StubToolRunner.printed(Values.pullRequestDocument)
            default:
                XCTFail("an unexpected command ran: \(tool.rawValue) \(arguments)")
                return StubToolRunner.exited(1)
            }
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertEqual(rig.model.selected?.url, Values.pullRequestPage,
                       "the panel is on \(String(describing: rig.model.selected?.url))")
        XCTAssertNil(rig.model.linkError, "a resolved pull request left an error row behind")
        XCTAssertEqual(runner.calls.map(\.arguments),
                       [["rev-parse", "--show-toplevel"], ["pr", "view", "7", "--json", "url"]],
                       "the commands run were \(runner.calls.map(\.arguments))")
        // Compared as a *directory* path: `GitCommands.repositoryRoot` builds the URL with
        // `directoryHint: .isDirectory`, so the root it hands on carries a trailing separator.
        XCTAssertEqual(runner.calls.last?.cwd.path(percentEncoded: false),
                       Values.repositoryRoot + "/",
                       "gh ran in \(String(describing: runner.calls.last?.cwd.path(percentEncoded: false)))")
    }

    /// The same route at `.newWindow` hands the resolved page to the system browser.
    func testAPullRequestAtNewWindowReachesTheInjectedOpener() async {
        let runner = StubToolRunner { tool, _ in
            tool == .git ? StubToolRunner.printed(Values.repositoryRoot + "\n")
                         : StubToolRunner.printed(Values.pullRequestDocument)
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .newWindow)

        XCTAssertEqual(rig.opened.urls, [Values.pullRequestPage],
                       "the system opener received \(rig.opened.urls)")
        XCTAssertTrue(rig.model.tabs.isEmpty, "the panel opened \(rig.model.tabs.count) tabs as well")
    }

    /// `gh` absent is a panel row and **not** an exception: §10 says a tool failure is panel-local
    /// and never reaches the channel. The `await` below would rethrow anything the handler threw,
    /// so "throws nothing" is asserted by this test completing at all.
    func testAMissingGhBinaryBecomesAPanelErrorRow() async {
        let runner = StubToolRunner { tool, _ in
            guard tool == .git else { throw ToolError.binaryNotFound(tool: .gh) }
            return StubToolRunner.printed(Values.repositoryRoot + "\n")
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertNotNil(rig.model.linkError, "a missing gh left no error row")
        XCTAssertTrue(rig.model.tabs.isEmpty, "the panel navigated somewhere for a lookup that failed")
        XCTAssertEqual(rig.opened.urls, [], "a failed lookup reached the system opener")
    }

    /// A logged-out `gh` exits non-zero and says so; the row carries the `gh auth login` hint, and
    /// **nothing prompts** — the runner is asked for one read and no login verb is ever run.
    func testALoggedOutGhCarriesTheAuthLoginHint() async {
        let runner = StubToolRunner { tool, _ in
            guard tool == .gh else { return StubToolRunner.printed(Values.repositoryRoot + "\n") }
            return ToolOutput(stdout: Data(),
                              stderr: Data("gh: To get started with GitHub CLI, please run: gh auth login\n".utf8),
                              exitCode: 1, timedOut: false)
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        let hint = rig.model.linkError?.hint
        XCTAssertNotNil(hint, "a logged-out gh left no hint: \(String(describing: rig.model.linkError))")
        XCTAssertTrue(hint?.contains("gh auth login") == true,
                      "the hint was \(String(describing: hint))")
        XCTAssertEqual(runner.calls.filter { $0.tool == .gh }.map(\.arguments),
                       [["pr", "view", "7", "--json", "url"]],
                       "gh was asked to run \(runner.calls.filter { $0.tool == .gh }.map(\.arguments))")
    }

    /// A `gh` that exits non-zero for any other reason — a number that is not a pull request — is a
    /// row **without** the auth hint. A resolver that hinted at login for every failure would send
    /// the user to re-authenticate over a typo.
    func testANumberThatIsNotAPullRequestIsARowWithoutTheAuthHint() async {
        let runner = StubToolRunner { tool, _ in
            guard tool == .gh else { return StubToolRunner.printed(Values.repositoryRoot + "\n") }
            return ToolOutput(stdout: Data(),
                              stderr: Data("no pull requests found for the given number\n".utf8),
                              exitCode: 1, timedOut: false)
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertNil(rig.model.linkError?.hint,
                     "a failure that is not about authentication carried \(String(describing: rig.model.linkError?.hint))")
        // The row names the exit status, which is what says the failure was *read* rather than
        // fallen into: a resolver that ignored the exit code lands on the undecodable empty
        // document instead and produces a different row with an equally empty hint.
        XCTAssertTrue(rig.model.linkError?.message.contains("exit 1") == true,
                      "the row was \(String(describing: rig.model.linkError?.message))")
    }

    /// **What `gh` prints is not authority to launch anything** (A4).
    ///
    /// The API endpoint is configurable, the `gh` that runs is whatever the session's PATH holds,
    /// and `--json url` is one field of somebody's response. Unvalidated, a custom scheme or a
    /// `file:` gets `NSWorkspace` from a click on a pull-request number at `.newWindow`, and the
    /// URL bar's authority in the panel at `.currentPanel`. Only an absolute `http`/`https` URL
    /// with a host is a page; everything else is a panel-local row.
    func testAPullRequestURLThatIsNotAnAbsoluteWebURLIsARowAtEitherDestination() async {
        let answers = [#"{"url":"x-launch://run/anything"}"#,
                       #"{"url":"file:///invented/secret.txt"}"#,
                       #"{"url":"/o/r/pull/7"}"#,
                       #"{"url":"https:///pull/7"}"#]
        for answer in answers {
            for destination in [LinkDestination.currentPanel, .newWindow] {
                let runner = StubToolRunner { tool, _ in
                    tool == .git ? StubToolRunner.printed(Values.repositoryRoot + "\n")
                                 : StubToolRunner.printed(answer)
                }
                let rig = await makeRouter(channel: Values.channel(), runner: runner)

                await rig.router.open(.pullRequest(Values.pullRequestNumber), from: destination)

                XCTAssertEqual(rig.opened.urls, [],
                               "\(answer) at \(destination) reached the system opener")
                XCTAssertTrue(rig.model.tabs.isEmpty,
                              "\(answer) at \(destination) navigated the panel")
                XCTAssertNotNil(rig.model.linkError,
                                "\(answer) at \(destination) left no error row")
            }
        }
    }

    /// The control half: an enterprise host is an ordinary answer and still resolves. A check that
    /// pinned the hostname rather than the shape would break every self-hosted GitHub.
    func testAnEnterpriseHostStillResolves() async {
        let page = "https://git.enterprise.invalid/o/r/pull/7"
        let runner = StubToolRunner { tool, _ in
            tool == .git ? StubToolRunner.printed(Values.repositoryRoot + "\n")
                         : StubToolRunner.printed("{\"url\":\"\(page)\"}")
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertEqual(rig.model.selected?.url, URL(string: page))
        XCTAssertNil(rig.model.linkError, "an enterprise host was refused")
    }

    /// A directory in no repository is the panel's row, not a guess at a URL.
    func testADirectoryOutsideARepositoryIsAnErrorRow() async {
        let runner = StubToolRunner { tool, _ in
            guard tool == .git else {
                XCTFail("gh ran outside a repository")
                return StubToolRunner.exited(1)
            }
            return ToolOutput(stdout: Data(),
                              stderr: Data("fatal: not a git repository\n".utf8),
                              exitCode: 128, timedOut: false)
        }
        let rig = await makeRouter(channel: Values.channel(), runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertNotNil(rig.model.linkError, "a directory in no repository left no error row")
        XCTAssertTrue(rig.model.tabs.isEmpty, "the panel navigated somewhere for a lookup that failed")
    }

    /// Q3: with no channel selected there is no repository to ask, so the row says so and **no
    /// command runs at all**. A resolver that fell back to any other directory would be answering
    /// about a repository the user is not looking at.
    func testNoChannelIsAnErrorRowRatherThanAGuess() async {
        let runner = StubToolRunner { tool, arguments in
            XCTFail("a command ran with no channel: \(tool.rawValue) \(arguments)")
            return StubToolRunner.exited(1)
        }
        let rig = await makeRouter(channel: nil, runner: runner)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)

        XCTAssertNotNil(rig.model.linkError, "a link with no channel left no error row")
        XCTAssertEqual(runner.calls.count, 0, "\(runner.calls.count) commands ran with no channel")
        XCTAssertTrue(rig.model.tabs.isEmpty, "the panel navigated somewhere with no channel")
    }

    /// The error row is cleared by the next navigation the panel accepts, like every other notice.
    func testTheNextAcceptedNavigationClearsTheErrorRow() async {
        let rig = await makeRouter(channel: nil)

        await rig.router.open(.pullRequest(Values.pullRequestNumber), from: .currentPanel)
        XCTAssertNotNil(rig.model.linkError, "the precondition did not hold: no error row was set")

        await rig.router.open(Values.pageLink, from: .currentPanel)
        XCTAssertNil(rig.model.linkError, "the error row survived a navigation the panel accepted")
    }

    // MARK: - Values

}

/// The invented values this file is written against, at file scope rather than on the test case:
/// the case is `@MainActor`, and the stub runner answers from a `@Sendable` closure that cannot
/// read main-actor state.
enum Values {
    static let pullRequestNumber = 7
    static let pullRequestPage = URL(string: "https://example.invalid/o/r/pull/7")!
    static let pageLink = WorkspaceLink.url(URL(string: "https://example.invalid/page-1")!)
    static let repositoryRoot = "/invented/workspace/a"

    /// The one `gh` document this file decodes: the single field `--json url` asks for, with an
    /// invented owner, repository and number - never a recorded account (S6.3, S11).
    static let pullRequestDocument = #"{"url":"https://example.invalid/o/r/pull/7"}"#

    /// A context for an invented channel, whose cwd is the root the stub runner answers for.
    @MainActor
    static func channel() -> ChannelContext { makeChannelContext(mark: "a") }
}

// MARK: - The doubles

/// A `[URL]` box the injected openers write to. `@unchecked Sendable` with a lock rather than an
/// actor, because an opener is a non-async closure and cannot hop.
final class URLSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
    func opened(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
}

/// A `ToolRunning` that answers from a closure and records what it was asked to run.
///
/// It is what makes the whole `.pullRequest` route testable without `git`, without `gh`, without a
/// repository and without a network — and what makes "no login is ever prompted" assertable, since
/// the recorded argument vectors are the whole of what the panel would have run.
final class StubToolRunner: ToolRunning, @unchecked Sendable {

    struct Call: Sendable, Equatable {
        let tool: Tool
        let arguments: [String]
        let cwd: URL
    }

    private let lock = NSLock()
    private var stored: [Call] = []
    private let respond: @Sendable (Tool, [String]) throws -> ToolOutput

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return stored }

    init(respond: @escaping @Sendable (Tool, [String]) throws -> ToolOutput) {
        self.respond = respond
    }

    static func printed(_ text: String) -> ToolOutput {
        ToolOutput(stdout: Data(text.utf8), stderr: Data(), exitCode: 0, timedOut: false)
    }

    static func exited(_ code: Int32) -> ToolOutput {
        ToolOutput(stdout: Data(), stderr: Data(), exitCode: code, timedOut: false)
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        record(Call(tool: tool, arguments: arguments, cwd: cwd))
        return try respond(tool, arguments)
    }

    /// The locked half, kept out of the `async` member: `NSLock` is unavailable from an
    /// asynchronous context, and a stub is not the place to invent a lock discipline (the shape
    /// `StubRecentURLFeed` already records).
    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        stored.append(call)
    }
}
