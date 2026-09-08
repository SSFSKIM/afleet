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
                           sleeper: ManualSleeper = ManualSleeper())
        -> (BrowserModel, InMemoryScopedStore, ManualSleeper) {
        let tabStore = BrowserTabStore(store: backing, sleep: sleeper.sleep)
        let model = BrowserModel(store: tabStore,
                                 factory: BrowserWebViewFactory(),
                                 openExternally: { _ in
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
