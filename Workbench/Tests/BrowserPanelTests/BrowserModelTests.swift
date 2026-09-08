import Foundation
import WebKit
import XCTest
import PanelHostAPI
@testable import BrowserPanel

/// C7.6 milestone 4: the shared model, and the structural claim item 39 rests on.
///
/// Two things are asserted here that no other file can assert. The first is Q5 and Q20 together:
/// the tab set and its web views belong to the **tab**, not to a per-channel session, so switching
/// channels cannot produce a second web view — not because a test happened not to see one, but
/// because there is one place a web view can be created and a session is not it. The second is
/// Q7's lazy restore, counted at the loopback server: a three-tab document issues exactly one
/// request.
///
/// Every URL is loopback or invented (§11). No test reaches the network and none launches a
/// browser: the external opener is injected everywhere.
@MainActor
final class BrowserModelTests: XCTestCase {

    // MARK: What the tests are built from

    private static func page(_ title: String) -> String {
        "<html><head><title>\(title)</title></head><body><h1>\(title)</h1></body></html>"
    }

    private func startServer() async throws -> LoopbackHTTPServer {
        let running = try LoopbackHTTPServer(pages: [
            "/one": Self.page("First page"),
            "/two": Self.page("Second page"),
            "/three": Self.page("Third page"),
        ])
        try await running.start()
        return running
    }

    /// A model over an in-memory store, with every seam injected.
    private func makeModel(store backing: InMemoryScopedStore = InMemoryScopedStore(),
                           sleeper: ManualSleeper = ManualSleeper(),
                           openExternally: (@Sendable (URL) -> Void)? = nil)
        -> (BrowserModel, InMemoryScopedStore, ManualSleeper) {
        let tabStore = BrowserTabStore(store: backing, sleep: sleeper.sleep)
        let model = BrowserModel(store: tabStore,
                                 factory: BrowserWebViewFactory(),
                                 openExternally: openExternally ?? { _ in
                                     XCTFail("no test in this file may reach the system opener")
                                 })
        return (model, backing, sleeper)
    }

    /// Waits for the model's next settled navigation, whichever tab it belongs to.
    private func settling(_ model: BrowserModel,
                          _ description: String,
                          _ body: @MainActor () -> Void) async {
        let settled = expectation(description: description)
        settled.assertForOverFulfill = false
        model.didSettleNavigation = { _ in settled.fulfill() }
        defer { model.didSettleNavigation = nil }
        body()
        await fulfillment(of: [settled], timeout: Self.webDeadline)
    }

    // MARK: Q5, Q20 and root item 39 — one tab set, whatever the channel

    /// The structural half of item 39. Two contexts for two *different* channels are handed to the
    /// same `BrowserTab`; each gets its own session, and both render the one model — the same tab
    /// list and the same `WKWebView` instance, not an equal one.
    func testTwoChannelsShareOneModelAndOneWebViewInstance() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, _, _) = makeModel()
        let tab = BrowserTab(model: model)

        let channelA = makeChannelContext(mark: "a")
        let channelB = makeChannelContext(mark: "b")
        XCTAssertNotEqual(channelA.key, channelB.key, "the two contexts must be different channels")

        let sessionA = tab.makeSession(for: channelA)
        await settling(model, "the first page loads") {
            model.openNewTab(url: server.url("/one"))
        }
        let webViewUnderA = try XCTUnwrap(model.selected?.web?.webView)
        XCTAssertEqual(model.tabs.count, 1)

        // The channel switch: the host asks for the other channel's session and renders again.
        let sessionB = tab.makeSession(for: channelB)
        XCTAssertFalse(sessionA === sessionB, "a session is per (tab, channel); these two are one object")

        XCTAssertEqual(model.tabs.count, 1, "a channel switch produced a second tab")
        XCTAssertIdentical(model.selected?.web?.webView, webViewUnderA,
                           "a channel switch produced a second web view")
        XCTAssertIdentical(tab.model, model, "the tab handed a channel a model of its own")
    }

    /// Q20 as a pinned member set, for the reason `ProtocolShapeTests` pins `ChannelContext`'s: a
    /// session that acquired a web view or a tab set would leave every other test green, and item
    /// 39 would go back to being lucky rather than structural.
    func testTheSessionHoldsOnlyPerChannelState() {
        let session = BrowserTabSession(recentURLs: StubRecentURLFeed(seeded: []))
        let labels = Set(Mirror(reflecting: session).children.compactMap(\.label))
            .subtracting(["_$observationRegistrar"])
        XCTAssertEqual(labels, ["recentURLs", "_isPresented", "_query", "_entries", "watcher"],
                       "BrowserTabSession's member set changed; Q20 says it holds no web view and "
                       + "no tab set")
    }

    // MARK: The empty state

    func testClosingTheLastTabLeavesTheDefinedEmptyState() async throws {
        let (model, backing, _) = makeModel()
        model.openNewTab(url: nil)
        let only = try XCTUnwrap(model.tabs.first)
        await writeAttempts(backing, reach: 1)

        model.close(only.id)

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.isEmpty, "the panel's empty state is not reported")
        await writeAttempts(backing, reach: 2)
        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs, [], "closing the last tab did not persist an empty set")
    }

    func testClosingANonSelectedTabKeepsTheSelection() async throws {
        let (model, _, _) = makeModel()
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        let first = try XCTUnwrap(model.tabs.first)
        model.openNewTab(url: URL(string: "https://two.example.invalid/")!)
        let second = try XCTUnwrap(model.tabs.last)
        XCTAssertEqual(model.selected?.id, second.id)

        model.close(first.id)

        XCTAssertEqual(model.tabs.map(\.id), [second.id])
        XCTAssertEqual(model.selected?.id, second.id, "closing another tab moved the selection")
    }

    func testClosingTheSelectedTabSelectsANeighbour() throws {
        let (model, _, _) = makeModel()
        for name in ["one", "two", "three"] {
            model.openNewTab(url: URL(string: "https://\(name).example.invalid/")!)
        }
        let middle = try XCTUnwrap(model.tabs.dropFirst().first)
        model.select(middle.id)

        model.close(middle.id)

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selected?.id, model.tabs.last?.id,
                       "the tab that took the closed one's position should be selected")
    }

    // MARK: Reordering

    func testReorderingMovesATabAndKeepsTheSelection() throws {
        let (model, _, _) = makeModel()
        for name in ["one", "two", "three"] {
            model.openNewTab(url: URL(string: "https://\(name).example.invalid/")!)
        }
        let ids = model.tabs.map(\.id)
        model.select(ids[0])

        model.move(from: 0, to: 2)

        XCTAssertEqual(model.tabs.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(model.selected?.id, ids[0], "reordering changed which tab is selected")
    }

    // MARK: Q7 — a restore loads only the selected tab

    func testRestoringAThreeTabDocumentLoadsOnlyTheSelectedTab() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let backing = InMemoryScopedStore()
        let document = BrowserTabSetDocument(
            tabs: [PersistedTab(url: server.url("/one"), title: "First page"),
                   PersistedTab(url: server.url("/two"), title: "Second page"),
                   PersistedTab(url: server.url("/three"), title: "Third page")],
            selectedIndex: 1)
        try await backing.write(document, key: BrowserTabStore.storeKey)
        let (model, _, _) = makeModel(store: backing)

        let settled = expectation(description: "the selected tab finishes loading")
        settled.assertForOverFulfill = false
        model.didSettleNavigation = { _ in settled.fulfill() }
        await model.restore()
        await fulfillment(of: [settled], timeout: Self.webDeadline)
        model.didSettleNavigation = nil

        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(model.selected?.id, model.tabs[1].id)
        XCTAssertEqual(server.requests, ["/two"],
                       "a restore is expected to load the selected tab and nothing else")
        XCTAssertNil(model.tabs[0].web, "an unselected tab has no web view until it is first selected")
        XCTAssertEqual(model.tabs[0].displayTitle, "First page",
                       "an unloaded tab carries its persisted title")
    }

    func testSelectingARestoredTabLoadsItThenAndNotBefore() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let backing = InMemoryScopedStore()
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: server.url("/one"), title: "First page"),
                                                             PersistedTab(url: server.url("/two"), title: "Second page")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        let (model, _, _) = makeModel(store: backing)

        await settling(model, "the selected tab loads") { Task { await model.restore() } }
        XCTAssertEqual(server.requests, ["/one"])

        let second = model.tabs[1].id
        await settling(model, "the second tab loads when it is first selected") { model.select(second) }

        XCTAssertEqual(server.requests, ["/one", "/two"])
    }

    func testRestoreRunsOnceHoweverManyChannelsAsk() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let backing = InMemoryScopedStore()
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: server.url("/one"), title: "First page")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        let (model, _, _) = makeModel(store: backing)

        await settling(model, "the restore loads its one tab") { Task { await model.restore() } }
        let tab = try XCTUnwrap(model.tabs.first)
        let web = try XCTUnwrap(tab.web)

        await model.restore()

        // Identity, not counts. A second restore rebuilds the set from the document, so the tab
        // list is the same *length* either way and only the objects differ — and the reload it
        // would issue is asynchronous, so a request count read here would still be one.
        XCTAssertIdentical(model.tabs.first, tab, "a second restore rebuilt the tab set")
        XCTAssertIdentical(model.tabs.first?.web, web, "a second restore built a second web view")
    }

    // MARK: Q6 — when a write happens

    /// M1 owns the coalescer; this asserts that the *model* uses it the way Q6 says — a tab opened
    /// is a structural change and writes at once, and the URL and title a navigation settles with
    /// go through the window.
    func testOpeningATabWritesAtOnceAndATitleChangeCoalesces() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let backing = InMemoryScopedStore()
        let sleeper = ManualSleeper()
        let (model, _, _) = makeModel(store: backing, sleeper: sleeper)

        await settling(model, "the first page loads") { model.openNewTab(url: server.url("/one")) }
        await writeAttempts(backing, reach: 1)
        var writes = await backing.attemptedWrites
        XCTAssertEqual(writes, 1, "opening a tab did not write immediately")

        // The settle above committed an edit, which opened the window.
        await sleepBegins(sleeper)
        let durations = await sleeper.requestedDurations
        XCTAssertEqual(durations, [BrowserTabStore.coalescingWindow])

        // The title, not the settle: `didFinish` lands before the page's title reaches the web
        // view, so waiting on the settle here would assert against the previous page's title.
        let tab = try XCTUnwrap(model.tabs.first)
        let retitled = observed(tab, "the second page's title reaches the tab") {
            $0.title == "Second page" && $0.url == server.url("/two")
        }
        model.open(server.url("/two"), in: .currentTab)
        await fulfillment(of: [retitled], timeout: Self.webDeadline)
        await model.persistenceSettled()

        writes = await backing.attemptedWrites
        XCTAssertEqual(writes, 1, "an edit inside the window wrote on its own")

        await sleeper.advance()
        await writeAttempts(backing, reach: 2)

        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.count, 1)
        XCTAssertEqual(document?.tabs.first?.url, server.url("/two"))
        XCTAssertEqual(document?.tabs.first?.title, "Second page",
                       "the coalesced write should carry the last title, not the first")
    }

    /// A tab the user has opened but not navigated has no page to restore, so it is not in the
    /// document — and the selection still has to point at something (D34).
    func testABlankTabIsNotPersistedAndTheSelectionStillLands() async throws {
        let (model, backing, _) = makeModel()
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        model.openNewTab(url: nil)
        await writeAttempts(backing, reach: 2)

        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.count, 1, "a blank tab has no page and is not persisted")
        XCTAssertEqual(document?.selectedIndex, 0,
                       "the selection was on the blank tab and has to land on a persisted one")
    }

    // MARK: Q9 — the URL bar's entry path

    func testTheURLBarNormalisesBeforeItNavigates() async throws {
        let (model, _, _) = makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("  example.invalid/docs  ")

        XCTAssertEqual(model.selected?.url, URL(string: "https://example.invalid/docs")!)
        XCTAssertNil(model.urlBarMessage)
    }

    func testTheURLBarReportsAStringThatIsNotAURLAndNavigatesNowhere() {
        let (model, _, _) = makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("not a url at all")

        XCTAssertNil(model.selected?.url, "a string that is not a URL must not navigate")
        XCTAssertNotNil(model.urlBarMessage, "a rejected entry has to say so; a silent bar looks broken")
    }

    func testAnEmptyURLBarSubmissionDoesNothing() {
        let (model, _, _) = makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("   ")

        XCTAssertNil(model.selected?.url)
        XCTAssertNil(model.urlBarMessage, "an empty bar is not an error")
    }

    /// Q9's row 6 is the panel's, not the policy's, but a refused *scheme* is the policy's and the
    /// panel has to show it (D29's `isDiagnosticOnly == false`).
    func testARefusedSchemeTypedIntoTheBarIsReportedAndLoadsNothing() {
        let (model, _, _) = makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("javascript:alert(1)")

        XCTAssertNotNil(model.notice, "a refusal the user is owed an answer about was not shown")
        XCTAssertNil(model.selected?.web?.webView.url)
    }

    func testAURLBarEntryWithNoTabOpenOpensOne() {
        let (model, _, _) = makeModel()
        XCTAssertTrue(model.tabs.isEmpty)

        model.submitURLBar("example.invalid")

        XCTAssertEqual(model.tabs.count, 1, "typing into the bar with no tab open should open one")
        XCTAssertEqual(model.selected?.url, URL(string: "https://example.invalid")!)
    }

    // MARK: What may be remembered (D48)

    /// A destination the policy hands to the system rather than loading is **not** the tab's URL
    /// and never reaches the document.
    ///
    /// This is the security half of D38 rather than a tidiness one: everything a tab remembers is
    /// dispatched again at restore through `activate`, with the URL bar's authority — the strongest
    /// authority in this design — so a persisted `mailto:` would launch an application at startup.
    func testAnExternallyOpenedDestinationIsNeitherTheTabsURLNorPersisted() async throws {
        let opened = URLSink()
        let (model, backing, _) = makeModel(openExternally: { opened.opened($0) })
        let mail = URL(string: "mailto:someone@example.invalid")!

        model.openNewTab(url: mail)
        await model.flush()

        XCTAssertEqual(opened.urls, [mail], "the URL bar's own destination did not reach the opener")
        XCTAssertNil(model.selected?.url, "a destination the panel never loaded became the tab's URL")
        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.count, 0, "an externally-opened destination was persisted")
    }

    /// The same for a destination the policy refuses outright, arriving in the current tab.
    ///
    /// Asserted with no `await` in the body on purpose: the tab is following a real navigation, and
    /// a suspension here would let the chrome write the page's own URL back over whatever `open`
    /// left behind — which is a correction, not the rule under test.
    func testARefusedDestinationIsNotWhatTheDocumentWouldRemember() {
        let (model, _, _) = makeModel()
        let page = URL(string: "https://one.example.invalid/")!
        model.openNewTab(url: page)

        model.open(URL(string: "file:///invented/secret.txt")!, in: .currentTab)

        XCTAssertEqual(model.selected?.url, page, "a refused destination replaced the tab's URL")
        XCTAssertEqual(model.snapshot().tabs.map(\.url), [page], "a refused destination would be persisted")
        XCTAssertNotNil(model.notice, "a refusal the user is owed an answer about was not shown")
    }

    /// And a document that already holds one — written by hand, or by a build before this rule —
    /// cannot launch anything on the way back in.
    func testARestoredDestinationThePanelWillNotLoadNeverReachesTheExternalOpener() async throws {
        let backing = InMemoryScopedStore()
        try await backing.write(
            BrowserTabSetDocument(tabs: [PersistedTab(url: URL(string: "mailto:someone@example.invalid")!,
                                                      title: "Mail")],
                                  selectedIndex: 0),
            key: BrowserTabStore.storeKey)
        let opened = URLSink()
        let (model, _, _) = makeModel(store: backing, openExternally: { opened.opened($0) })

        await model.restore()

        XCTAssertEqual(opened.urls, [], "a restore handed a persisted destination to the system opener")
        XCTAssertEqual(model.tabs.count, 1, "the restored tab itself is still there")
        XCTAssertNil(model.tabs.first?.url, "the restored tab kept a destination the panel will not load")
    }

    // MARK: The store's trouble, as the panel sees it

    /// A coalesced write that fails half a second later reaches the panel's error row.
    ///
    /// `commitEdit` returns as soon as it has scheduled its window, so a model that sampled the
    /// store's row at the commit sampled it before the write — and the row the panel shows would
    /// say the last *structural* write's answer for ever.
    func testAFailedCoalescedWriteReachesThePanelsErrorRow() async throws {
        let (model, backing, sleeper) = makeModel()
        await model.restore()
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        await model.persistenceSettled()
        XCTAssertNil(model.storeError, "the precondition: the structural write succeeded")

        await backing.setFailsWrites(true)
        model.open(URL(string: "https://two.example.invalid/")!, in: .currentTab)
        await model.persistenceSettled()

        await sleeper.waitForSleep()
        await sleeper.advance()
        await model.flush()

        XCTAssertEqual(model.storeError, .writeFailed,
                       "the write that failed never reached the panel's error row")
        XCTAssertNotNil(model.storeErrorMessage, "and there is no line for the panel to show")
    }

    /// A document this build may never write over is a panel-local state with a line of its own
    /// (§10) — not an alert, and not silence behind ordinary editable tabs.
    func testADocumentFromANewerBuildIsAPanelStateWithALine() async throws {
        let backing = InMemoryScopedStore()
        await backing.seed(json: #"{"schemaVersion":2,"tabs":[],"selection":{"tabID":null}}"#,
                           key: BrowserTabStore.storeKey)
        let (model, _, _) = makeModel(store: backing)

        await model.restore()

        XCTAssertEqual(model.storeError, .documentFromANewerBuild(found: 2))
        XCTAssertNotNil(model.storeErrorMessage,
                        "the panel has nothing to say about tabs it can never save")
        for error: BrowserTabStoreError in [.documentFromANewerBuild(found: 2), .documentUnreadable, .writeFailed] {
            XCTAssertFalse(BrowserModel.copy(for: error).isEmpty, "\(error) has no line")
        }
    }

    // MARK: Q8 — Enter and Cmd-Enter

    func testEnterOpensInTheCurrentTabAndCommandEnterOpensANewOne() throws {
        let (model, _, _) = makeModel()
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        let first = try XCTUnwrap(model.tabs.first)

        XCTAssertEqual(BrowserModel.OpenDestination.quickOpenSubmission(commandHeld: false), .currentTab)
        XCTAssertEqual(BrowserModel.OpenDestination.quickOpenSubmission(commandHeld: true), .newTab)

        model.open(URL(string: "https://two.example.invalid/")!,
                   in: .quickOpenSubmission(commandHeld: false))
        XCTAssertEqual(model.tabs.count, 1, "Enter opened a tab instead of navigating the current one")
        XCTAssertEqual(model.selected?.id, first.id)
        XCTAssertEqual(model.selected?.url, URL(string: "https://two.example.invalid/")!)

        model.open(URL(string: "https://three.example.invalid/")!,
                   in: .quickOpenSubmission(commandHeld: true))
        XCTAssertEqual(model.tabs.count, 2, "Cmd-Enter navigated the current tab instead of opening one")
        XCTAssertNotEqual(model.selected?.id, first.id)
        XCTAssertEqual(model.selected?.url, URL(string: "https://three.example.invalid/")!)
    }

    // MARK: Q5's pop-out consequence

    /// An `NSView` has one superview, so the web views follow the pop-out and the surface they left
    /// draws a short state instead. The model carries which surface holds them; the view renders it.
    func testTheWebViewsFollowThePopOutAndComeBack() {
        let (model, _, _) = makeModel()
        XCTAssertEqual(model.attachedTo, .panel)
        XCTAssertTrue(model.rendersWebViews(on: .panel))
        XCTAssertFalse(model.rendersWebViews(on: .poppedOutWindow))

        model.attach(to: .poppedOutWindow)

        XCTAssertFalse(model.rendersWebViews(on: .panel),
                       "the panel cannot draw web views that moved to the pop-out")
        XCTAssertTrue(model.rendersWebViews(on: .poppedOutWindow))

        model.attach(to: .panel)

        XCTAssertTrue(model.rendersWebViews(on: .panel), "bringing them back did not")
    }

    // MARK: The stop control, and a load that ended without a page

    /// While a page is loading the round control is a stop control, and it has to stop.
    ///
    /// The server never answers `/slow`, so the navigation is still in flight when the control is
    /// used and cannot settle on its own. Two things are asserted, because either alone passes for
    /// the wrong reason: the load ends, and the page is **not requested again** — a reload would
    /// also end the first load, by starting a second.
    func testTheStopControlEndsTheLoadWithoutRequestingThePageAgain() async throws {
        let server = try LoopbackHTTPServer(pages: [:], stalls: ["/slow"])
        try await server.start()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        let asked = expectation(description: "the page is requested")
        server.expectRequest("/slow", asked)
        model.openNewTab(url: server.url("/slow"))
        await fulfillment(of: [asked], timeout: Self.webDeadline)
        XCTAssertEqual(model.chrome?.isLoading, true, "the page settled before it could be stopped")

        model.reloadOrStop()

        let stopped = observed(model.selected!.web!.chrome, "the load stops") { !$0.isLoading }
        await fulfillment(of: [stopped], timeout: Self.webDeadline)
        XCTAssertEqual(server.requestCount(for: "/slow"), 1,
                       "the stop control re-requested the page it was asked to abandon")
        // WebKit reports a stopped load as an error, and a user who stopped a load is not owed a
        // line telling them the page failed.
        XCTAssertNil(model.loadFailureMessage, "stopping a load was reported as a failed load")
    }

    /// The companion: the same control on a settled page **is** a reload.
    func testTheSameControlReloadsAPageThatIsNotLoading() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the page loads") { model.openNewTab(url: server.url("/one")) }
        XCTAssertEqual(server.requestCount(for: "/one"), 1)

        await settling(model, "the page loads again") { model.reloadOrStop() }

        XCTAssertEqual(server.requestCount(for: "/one"), 2,
                       "the control did not reload a page that had finished")
    }

    /// A connection that goes away is an ordinary failure, and the panel says so quietly (§10).
    ///
    /// The server accepts the request and closes without answering, which is what a server that
    /// went away looks like from inside WebKit. No test reaches a network to produce it.
    func testALoadThatFailsBecomesARowUnderTheURLBar() async throws {
        let server = try LoopbackHTTPServer(pages: [:], drops: ["/gone"])
        try await server.start()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the load fails") { model.openNewTab(url: server.url("/gone")) }

        XCTAssertNotNil(model.chrome?.failure, "a failed load left no failure on the chrome")
        XCTAssertNotNil(model.loadFailureMessage, "a failed load produced no line for the panel")
    }

    /// The page that loads after a failure clears the row, so a line never outlives what it is
    /// about.
    func testAPageThatLoadsAfterAFailureClearsTheRow() async throws {
        let server = try LoopbackHTTPServer(pages: ["/one": Self.page("First page")],
                                            drops: ["/gone"])
        try await server.start()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the load fails") { model.openNewTab(url: server.url("/gone")) }
        XCTAssertNotNil(model.loadFailureMessage)

        await settling(model, "the page loads") { model.open(server.url("/one"), in: .currentTab) }

        XCTAssertNil(model.loadFailureMessage, "the row outlived the load it was about")
    }

    /// A refusal this panel issued deliberately is **not** a failed load. WebKit reports the
    /// panel's own policy cancellations to the same delegate methods a dropped connection reaches,
    /// so a panel that took every error at face value would tell the user a page failed every time
    /// it declined one on purpose.
    func testAPolicyRefusalIsNotAFailedLoad() async throws {
        let refusing = """
            <html><head><title>Refused</title></head><body>
            <script>location.href = 'data:text/html;base64,PGgxPmhpPC9oMT4='</script>
            </body></html>
            """
        let server = try LoopbackHTTPServer(pages: ["/refused": refusing])
        try await server.start()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the page loads") { model.openNewTab(url: server.url("/refused")) }
        // The refusal happens after the load settles, so the wait is on the consequence it has: a
        // `data:` URL from page content is refused in the panel and says so (D29).
        let refused = observed(model, "the page's own navigation is refused") { $0.notice != nil }
        await fulfillment(of: [refused], timeout: Self.webDeadline)

        XCTAssertNil(model.chrome?.failure,
                     "a navigation the panel refused on purpose was reported as a failed load")
        XCTAssertNil(model.loadFailureMessage)
    }

    // MARK: Q5's pop-out, connected to the pop-out lifecycle (D52)

    /// The window takes the web views when it appears and gives them back when it goes away.
    ///
    /// "Exactly one" is asserted over every surface there is rather than over the two by name, so a
    /// third surface could not quietly draw a second browser.
    func testAPoppedOutWindowTakesTheWebViewsAndClosingHandsThemBack() {
        let (model, _, _) = makeModel()
        XCTAssertEqual(Self.surfacesRendering(model), [.panel])

        model.surfaceAppeared(.poppedOutWindow)

        XCTAssertEqual(Self.surfacesRendering(model), [.poppedOutWindow],
                       "the pop-out did not take the web views, or did not take them exclusively")

        model.surfaceDisappeared(.poppedOutWindow)

        XCTAssertEqual(Self.surfacesRendering(model), [.panel],
                       "closing the pop-out did not hand the web views back")
    }

    /// The main panel is on screen for as long as its window is, so it must not claim on
    /// appearance: a re-render of the column would otherwise take the pages out of a pop-out window
    /// that is still open.
    func testTheMainPanelAppearingDoesNotTakeTheWebViewsFromAWindow() {
        let (model, _, _) = makeModel()
        model.surfaceAppeared(.poppedOutWindow)

        model.surfaceAppeared(.panel)

        XCTAssertEqual(Self.surfacesRendering(model), [.poppedOutWindow],
                       "the panel took the web views back from a window that is still open")
    }

    /// A surface going away while it holds nothing changes nothing.
    func testASurfaceThatHoldsNothingHandsNothingBack() {
        let (model, _, _) = makeModel()
        model.surfaceAppeared(.poppedOutWindow)

        model.surfaceDisappeared(.panel)

        XCTAssertEqual(Self.surfacesRendering(model), [.poppedOutWindow])
    }

    /// The other half of D52: the surface is a real input to the view the tab makes. Without this
    /// both surfaces render the same one, and whichever `NSView` hierarchy asked last holds the
    /// web views while the other draws a placeholder that will never come true.
    func testTheViewTheTabMakesIsForTheSurfaceItWasAskedFor() {
        let (model, _, _) = makeModel()
        let tab = BrowserTab(model: model)
        let context = makeChannelContext(mark: "surface")
        let session = tab.makeSession(for: context)

        XCTAssertEqual(tab.panelView(session: session, surface: .panel)?.surface, .panel)
        XCTAssertEqual(tab.panelView(session: session, surface: .poppedOutWindow)?.surface,
                       .poppedOutWindow,
                       "the popped-out window was handed a view that claims to be the panel")
    }

    /// Every surface that would draw the web views right now.
    private static func surfacesRendering(_ model: BrowserModel) -> [PanelSurface] {
        PanelSurface.allCases.filter { model.rendersWebViews(on: $0) }
    }

    // MARK: Chrome delegation

    func testBackAndForwardFollowTheSelectedTab() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the first page loads") { model.openNewTab(url: server.url("/one")) }
        await settling(model, "the second page loads") { model.open(server.url("/two"), in: .currentTab) }
        XCTAssertTrue(model.chrome?.canGoBack == true)

        await settling(model, "the back navigation lands") { model.goBack() }

        XCTAssertEqual(model.chrome?.url, server.url("/one"))
        XCTAssertTrue(model.chrome?.canGoForward == true)
    }

    func testReloadReRequestsTheSelectedTabsPage() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, _, _) = makeModel()

        await settling(model, "the page loads") { model.openNewTab(url: server.url("/one")) }
        XCTAssertEqual(server.requestCount(for: "/one"), 1)

        await settling(model, "the reload lands") { model.reload() }

        XCTAssertEqual(server.requestCount(for: "/one"), 2)
    }

    /// Q11 through the model: a page that opens a window gets a panel tab, and the model is what
    /// the web tab's callback reaches. Nothing here may open an application window.
    func testAPageThatOpensAWindowGetsANewPanelTab() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let opener = try LoopbackHTTPServer(pages: [
            "/opens": """
                <html><head><title>Opener</title></head><body>
                <script>window.open('/two')</script></body></html>
                """,
            "/two": Self.page("Second page"),
        ])
        try await opener.start()
        defer { opener.stop() }
        let (model, _, _) = makeModel()

        let opened = observed(model, "a second tab appears") { $0.tabs.count == 2 }
        model.openNewTab(url: opener.url("/opens"))
        await fulfillment(of: [opened], timeout: Self.webDeadline)

        XCTAssertEqual(model.tabs.last?.url, opener.url("/two"))
    }
}
