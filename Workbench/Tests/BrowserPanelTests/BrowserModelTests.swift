import Foundation
import FleetKit
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
    ///
    /// It is **restored by default**, because that is the state the panel is in by the time a
    /// control can be used: every mutation joins the restoration (D57), so a model that had never
    /// read its document would defer whatever a test did to it. A test that drives the restoration
    /// itself — one that seeded a document, or that holds the read open — passes `restored: false`.
    private func makeModel(store backing: InMemoryScopedStore = InMemoryScopedStore(),
                           sleeper: ManualSleeper = ManualSleeper(),
                           restored: Bool = true,
                           openExternally: (@Sendable (URL) -> Void)? = nil) async
        -> (BrowserModel, InMemoryScopedStore, ManualSleeper) {
        let tabStore = BrowserTabStore(store: backing, sleep: sleeper.sleep)
        let model = BrowserModel(store: tabStore,
                                 factory: BrowserWebViewFactory(),
                                 openExternally: openExternally ?? { _ in
                                     XCTFail("no test in this file may reach the system opener")
                                 })
        if restored { await model.restore() }
        return (model, backing, sleeper)
    }

    /// A popped-out Browser window for an invented channel. `PanelHost.popOut` keys windows by
    /// (tab, channel), so this is what one window *is*.
    private static func window(_ mark: String) -> PanelSurface {
        .poppedOutWindow(tab: .browser, channel: ChannelKey(configHome: URL(filePath: "/invented/config-home"),
                                                            session: SessionID(uuid: UUID())))
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
        let (model, _, _) = await makeModel()
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
        XCTAssertEqual(labels, ["recentURLs", "_presentedOn", "_query", "_entries", "watcher"],
                       "BrowserTabSession's member set changed; Q20 says it holds no web view and "
                       + "no tab set")
    }

    // MARK: The empty state

    func testClosingTheLastTabLeavesTheDefinedEmptyState() async throws {
        let (model, backing, _) = await makeModel()
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
        let (model, _, _) = await makeModel()
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        let first = try XCTUnwrap(model.tabs.first)
        model.openNewTab(url: URL(string: "https://two.example.invalid/")!)
        let second = try XCTUnwrap(model.tabs.last)
        XCTAssertEqual(model.selected?.id, second.id)

        model.close(first.id)

        XCTAssertEqual(model.tabs.map(\.id), [second.id])
        XCTAssertEqual(model.selected?.id, second.id, "closing another tab moved the selection")
    }

    func testClosingTheSelectedTabSelectsANeighbour() async throws {
        let (model, _, _) = await makeModel()
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

    func testReorderingMovesATabAndKeepsTheSelection() async throws {
        let (model, _, _) = await makeModel()
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
        let (model, _, _) = await makeModel(store: backing, restored: false)

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
        let (model, _, _) = await makeModel(store: backing, restored: false)

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
        let (model, _, _) = await makeModel(store: backing, restored: false)

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
        let (model, _, _) = await makeModel(store: backing, sleeper: sleeper)

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
        let (model, backing, _) = await makeModel()
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
        let (model, _, _) = await makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("  example.invalid/docs  ")

        XCTAssertEqual(model.selected?.url, URL(string: "https://example.invalid/docs")!)
        XCTAssertNil(model.urlBarMessage)
    }

    func testTheURLBarReportsAStringThatIsNotAURLAndNavigatesNowhere() async {
        let (model, _, _) = await makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("not a url at all")

        XCTAssertNil(model.selected?.url, "a string that is not a URL must not navigate")
        XCTAssertNotNil(model.urlBarMessage, "a rejected entry has to say so; a silent bar looks broken")
    }

    func testAnEmptyURLBarSubmissionDoesNothing() async {
        let (model, _, _) = await makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("   ")

        XCTAssertNil(model.selected?.url)
        XCTAssertNil(model.urlBarMessage, "an empty bar is not an error")
    }

    /// Q9's row 6 is the panel's, not the policy's, but a refused *scheme* is the policy's and the
    /// panel has to show it (D29's `isDiagnosticOnly == false`).
    func testARefusedSchemeTypedIntoTheBarIsReportedAndLoadsNothing() async {
        let (model, _, _) = await makeModel()
        model.openNewTab(url: nil)

        model.submitURLBar("javascript:alert(1)")

        XCTAssertNotNil(model.notice, "a refusal the user is owed an answer about was not shown")
        XCTAssertNil(model.selected?.web?.webView.url)
    }

    func testAURLBarEntryWithNoTabOpenOpensOne() async {
        let (model, _, _) = await makeModel()
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
        let (model, backing, _) = await makeModel(openExternally: { opened.opened($0) })
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
    func testARefusedDestinationIsNotWhatTheDocumentWouldRemember() async {
        let (model, _, _) = await makeModel()
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
        let (model, _, _) = await makeModel(store: backing, restored: false, openExternally: { opened.opened($0) })

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
        let (model, backing, sleeper) = await makeModel()
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
        let (model, _, _) = await makeModel(store: backing, restored: false)

        await model.restore()

        XCTAssertEqual(model.storeError, .documentFromANewerBuild(found: 2))
        XCTAssertNotNil(model.storeErrorMessage,
                        "the panel has nothing to say about tabs it can never save")
        for error: BrowserTabStoreError in [.documentFromANewerBuild(found: 2), .documentUnreadable, .writeFailed] {
            XCTAssertFalse(BrowserModel.copy(for: error).isEmpty, "\(error) has no line")
        }
    }

    // MARK: Q8 — Enter and Cmd-Enter

    func testEnterOpensInTheCurrentTabAndCommandEnterOpensANewOne() async throws {
        let (model, _, _) = await makeModel()
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

    // MARK: The restoration gate (Q7, D49) — the user is as fast as a link

    /// A tab the user opens while the restoration is still reading is not thrown away by it.
    ///
    /// `openRouted` orders a *link* behind the read; the panel's own controls called straight into
    /// the set and enqueued a structural write, and `performRestore` then replaced `tabs` whole. So
    /// the tab went, and the incomplete snapshot the write carried could land on the saved
    /// document as well. Every mutation that can enqueue persistence joins the restoration.
    func testATabOpenedDuringARestoreSurvivesIt() async throws {
        let backing = InMemoryScopedStore()
        let saved = URL(string: "https://saved.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: saved, title: "Saved")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        await backing.holdReads()
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let restoring = Task { await model.restore() }
        let reading = expectation(description: "the restore reached the store")
        await backing.expectReadArrival(reading)
        await fulfillment(of: [reading], timeout: Self.webDeadline)

        // The `+` control, while the read is still held open.
        let opened = URL(string: "https://opened-during-the-restore.example.invalid/")!
        model.openNewTab(url: opened)

        await backing.releaseReads()
        await restoring.value
        await model.persistenceSettled()

        XCTAssertEqual(model.tabs.map(\.url), [saved, opened],
                       "the tab the user opened during the restore was replaced by the saved set")
        XCTAssertEqual(model.selected?.url, opened, "the panel is not on the tab the user opened")
        let document = try await backing.document(BrowserTabSetDocument.self,
                                                  key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.map(\.url), [saved, opened],
                       "an incomplete snapshot replaced the saved document")
    }

    /// The other ordering: the mutation is in front of the restoration rather than inside it. The
    /// restored set is installed *beneath* what is already there, so no ordering loses either one.
    func testATabOpenedBeforeARestoreIsNotReplacedByIt() async throws {
        let backing = InMemoryScopedStore()
        let saved = URL(string: "https://saved.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: saved, title: "Saved")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let opened = URL(string: "https://opened-first.example.invalid/")!
        model.openNewTab(url: opened)
        await model.restore()
        await model.persistenceSettled()

        XCTAssertEqual(model.tabs.map(\.url), [saved, opened],
                       "the restore replaced a tab set the user had already opened a tab in")
        XCTAssertEqual(model.selected?.url, opened,
                       "the restore moved the panel off the tab the user was on")
    }

    /// The quit flush drains what the gate is holding as well as what the store is.
    ///
    /// A mutation waiting on the restoration has not made its commit yet, so a flush that waited
    /// only on the persistence chain would return having written the set *before* the last thing
    /// the user did — which at quit is G3 losing it.
    func testTheFlushDrainsAMutationStillWaitingOnTheRestoration() async throws {
        let backing = InMemoryScopedStore()
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let opened = URL(string: "https://opened-before-the-restore.example.invalid/")!
        model.openNewTab(url: opened)
        await model.flush()

        let document = try await backing.document(BrowserTabSetDocument.self,
                                                  key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.map(\.url), [opened],
                       "the flush returned in front of a mutation the gate was still holding")
    }

    /// The flush waits for commits made while it was suspended, and not only for the ones it saw.
    ///
    /// This is the store's drain one level up, and it is a **different** defect: a commit made
    /// while the flush is waiting joins the persistence chain behind its predecessor, so it has not
    /// submitted anything to the store when the store's own drain looks — nothing pending there,
    /// nothing in flight there, and a drain that answered from the store alone returns in front of
    /// it. `QuitGuard` drains exactly once, so what it misses here is what G3 loses at quit.
    ///
    /// Two commits are made and not one, for the reason the store's twin of this test records: the
    /// second is behind the first by the whole of a write and cannot have reached the store
    /// whichever way the wake-up goes.
    func testTheFlushWaitsForCommitsMadeWhileItWasSuspended() async throws {
        let completions = CompletionCounter()
        let backing = GatedScopedStore(completions: completions)
        let model = BrowserModel(store: BrowserTabStore(store: backing, sleep: ManualSleeper().sleep),
                                 factory: BrowserWebViewFactory(),
                                 openExternally: { _ in
                                     XCTFail("no test in this file may reach the system opener")
                                 })
        await model.restore()

        // One structural commit, whose write is held at the gate.
        model.openNewTab(url: URL(string: "https://one.example.invalid/")!)
        let arrived = expectation(description: "the first write reached the store")
        await backing.expectWriteArrivals(1, arrived)
        await fulfillment(of: [arrived], timeout: Self.webDeadline)

        // The flush suspends on the chain that commit is on. The count is read in the same breath
        // as the return, for the reason the store's own drain test gives.
        let flushed = Task { await model.flush(); return completions.value }
        for _ in 0..<Self.yields { await Task.yield() }

        // Two more, made underneath it. Each waits for its predecessor before it submits anything,
        // so neither is pending or in flight at the *store* when the store's drain looks.
        model.openNewTab(url: URL(string: "https://two.example.invalid/")!)
        model.openNewTab(url: URL(string: "https://three.example.invalid/")!)
        for _ in 0..<Self.yields { await Task.yield() }

        await backing.openGate()
        let atReturn = await flushed.value
        await model.persistenceSettled()

        XCTAssertEqual(atReturn, 3,
                       "the flush returned with \(3 - atReturn) commit(s) made while it waited unwritten")
    }

    /// **The quit drain is the last word, not a snapshot** (E4/E2).
    ///
    /// `QuitGuard` drains and then awaits `shutdownForQuit()`, which has suspension points of its
    /// own. `trackChrome` is still running through all of them: a page's title reaches the web view
    /// runloop turns after its navigation settles, so an edit can be submitted *after* the drain has
    /// returned and sit in the coalescer's trailing window until the process exits under it. This is
    /// the page settling late, and the question it asks is whether anything was left outstanding.
    func testAPageThatSettlesAfterTheQuitDrainIsNotLeftPending() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, backing, _) = await makeModel()
        await settling(model, "the page loads") { model.openNewTab(url: server.url("/one")) }

        await model.closeForQuit()
        let written = await backing.attemptedWrites

        // What `trackChrome` does while `shutdownForQuit` is suspended.
        await settling(model, "a second page settles after the drain") {
            model.selected?.web?.navigate(to: server.url("/two"))
        }
        await model.persistenceSettled()
        // A second drain, which production does not have: it is how this test asks whether the
        // first one left anything behind.
        await model.flush()

        let after = await backing.attemptedWrites
        XCTAssertEqual(after, written,
                       "\(after - written) write(s) were still outstanding after the final drain")
    }

    /// The same barrier at the other door: a mutation made after the drain.
    ///
    /// A structural change writes at once, so this one is not merely left pending — it is a write
    /// racing the exit, and whether the document survives it is up to how far `shutdownForQuit`
    /// gets. A closed panel accepts neither.
    func testAMutationMadeAfterTheQuitDrainChangesNothing() async throws {
        let (model, backing, _) = await makeModel()
        let saved = URL(string: "https://saved.example.invalid/")!
        model.openNewTab(url: saved)

        await model.closeForQuit()
        let written = await backing.attemptedWrites

        model.openNewTab(url: URL(string: "https://after-the-drain.example.invalid/")!)
        await model.persistenceSettled()
        await model.flush()

        let after = await backing.attemptedWrites
        XCTAssertEqual(after, written,
                       "a mutation made after the final drain reached the store")
        let document = try await backing.document(BrowserTabSetDocument.self,
                                                  key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.tabs.map(\.url), [saved],
                       "the document a quit left behind is \(String(describing: document?.tabs.map(\.url)))")
    }

    /// The order the user made two mutations in survives the restoration boundary.
    ///
    /// The gate is only half of first-in-first-out. `performRestore` opens the gate *before* the
    /// operations queued behind it have run, and a routed link joins the restoration on its own
    /// account, so both a control used after the read lands and a link that was waiting on it can
    /// run in front of a mutation queued earlier. A routed open of the current tab would then
    /// navigate the restored selection before an earlier New Tab had run — the link in the wrong
    /// tab, which is the user-visible half of this.
    func testMutationsKeepTheirOrderAcrossTheRestorationBoundary() async throws {
        let backing = InMemoryScopedStore()
        let saved = URL(string: "https://saved.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: saved, title: "Saved")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        await backing.holdReads()
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let restoring = Task { await model.restore() }
        let reading = expectation(description: "the restore reached the store")
        await backing.expectReadArrival(reading)
        await fulfillment(of: [reading], timeout: Self.webDeadline)

        // The `+` control first, queued behind the read...
        let first = URL(string: "https://queued-first.example.invalid/")!
        model.openNewTab(url: first)
        // ...and then a routed link, which joins the same restoration by another door.
        let second = URL(string: "https://routed-second.example.invalid/")!
        let routed = Task { await model.openRouted(second, in: .newTab) }
        for _ in 0..<Self.yields { await Task.yield() }

        await backing.releaseReads()
        await restoring.value
        await routed.value
        await model.flush()

        XCTAssertEqual(model.tabs.map(\.url), [saved, first, second],
                       "a mutation made later reached the tab set in front of one made earlier")
        XCTAssertEqual(model.selected?.url, second, "the panel is not on the last tab the user asked for")
    }

    /// The other door onto the same boundary: a caller that waits for the restoration itself.
    ///
    /// `performRestore` marks itself restored before the operations queued behind it resume, so
    /// anything that waits on the read and then mutates — a routed link, a control the user reaches
    /// the moment the panel draws — is let straight through in front of a queue that has not run
    /// yet. The queue is what the order lives in, so a mutation made later joins it rather than
    /// stepping around it.
    func testAMutationMadeWhenTheReadLandsRunsBehindOneQueuedBeforeIt() async throws {
        let backing = InMemoryScopedStore()
        let saved = URL(string: "https://saved.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: saved, title: "Saved")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        await backing.holdReads()
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let restoring = Task { await model.restore() }
        let reading = expectation(description: "the restore reached the store")
        await backing.expectReadArrival(reading)
        await fulfillment(of: [reading], timeout: Self.webDeadline)

        let first = URL(string: "https://queued-first.example.invalid/")!
        model.openNewTab(url: first)
        let second = URL(string: "https://after-the-read.example.invalid/")!
        let later = Task { @MainActor in
            await model.restore()
            model.openNewTab(url: second)
        }
        for _ in 0..<Self.yields { await Task.yield() }

        await backing.releaseReads()
        await restoring.value
        await later.value
        await model.flush()

        XCTAssertEqual(model.tabs.map(\.url), [saved, first, second],
                       "a mutation made when the read landed ran in front of one queued before it")
    }

    /// And the reverse order: a link that arrived first is not overtaken by a control used after it.
    ///
    /// A routed open that waited on the restoration *on its own account* took its place in the
    /// queue when the read landed rather than when the link arrived, so every mutation made in
    /// between was ahead of it. It joins the queue where it was made, like everything else.
    func testARoutedLinkKeepsItsPlaceInFrontOfAControlUsedAfterIt() async throws {
        let backing = InMemoryScopedStore()
        let saved = URL(string: "https://saved.example.invalid/")!
        try await backing.write(BrowserTabSetDocument(tabs: [PersistedTab(url: saved, title: "Saved")],
                                                      selectedIndex: 0),
                                key: BrowserTabStore.storeKey)
        await backing.holdReads()
        let (model, _, _) = await makeModel(store: backing, restored: false)

        let restoring = Task { await model.restore() }
        let reading = expectation(description: "the restore reached the store")
        await backing.expectReadArrival(reading)
        await fulfillment(of: [reading], timeout: Self.webDeadline)

        let link = URL(string: "https://routed-first.example.invalid/")!
        let routed = Task { await model.openRouted(link, in: .newTab) }
        // The task's body does not begin until this one suspends, so the link has genuinely arrived
        // first only after these yields — and it can get no further than the queue.
        for _ in 0..<Self.yields { await Task.yield() }
        let clicked = URL(string: "https://clicked-second.example.invalid/")!
        model.openNewTab(url: clicked)

        await backing.releaseReads()
        await restoring.value
        await routed.value
        await model.flush()

        XCTAssertEqual(model.tabs.map(\.url), [saved, link, clicked],
                       "a control used after a link reached the tab set in front of it")
    }

    /// A bounded number of cooperative yields: enough for a call that does not wait to run to its
    /// return, and never enough for one that is waiting on a gate the test has not opened.
    private static let yields = 50

    // MARK: Q5's pop-out consequence

    /// An `NSView` has one superview, so the web views follow the pop-out and the surface they left
    /// draws a short state instead. The model carries which surface holds them; the view renders it.
    func testTheWebViewsFollowThePopOutAndComeBack() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        XCTAssertEqual(model.attachedTo, .panel)
        XCTAssertTrue(model.rendersWebViews(on: .panel))
        XCTAssertFalse(model.rendersWebViews(on: window))

        model.attach(to: window)

        XCTAssertFalse(model.rendersWebViews(on: .panel),
                       "the panel cannot draw web views that moved to the pop-out")
        XCTAssertTrue(model.rendersWebViews(on: window))

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
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

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
    func testAPoppedOutWindowTakesTheWebViewsAndClosingHandsThemBack() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        let all = [PanelSurface.panel, window]
        model.surfaceAppeared(.panel)
        XCTAssertEqual(Self.surfacesRendering(model, among: all), [.panel])

        model.surfaceAppeared(window)

        XCTAssertEqual(Self.surfacesRendering(model, among: all), [window],
                       "the pop-out did not take the web views, or did not take them exclusively")

        model.surfaceDisappeared(window)

        XCTAssertEqual(Self.surfacesRendering(model, among: all), [.panel],
                       "closing the pop-out did not hand the web views back")
    }

    /// **Two windows are two claimants, and only one of them can hold the pages.**
    ///
    /// `popOut` keys windows by (tab, channel), so a second channel's pop-out is a second window on
    /// screen at the same time. A surface that named only "a popped-out window" made both of them
    /// the same claimant: each drew the one `WKWebView` into its own hierarchy, and closing either
    /// handed the pages back out of the one still open.
    func testTwoPoppedOutWindowsAreTwoClaimantsAndOnlyOneHoldsThePages() async {
        let (model, _, _) = await makeModel()
        let first = Self.window("first")
        let second = Self.window("second")
        let all = [PanelSurface.panel, first, second]

        model.surfaceAppeared(.panel)
        model.surfaceAppeared(first)
        XCTAssertEqual(Self.surfacesRendering(model, among: all), [first])

        model.surfaceAppeared(second)

        XCTAssertEqual(Self.surfacesRendering(model, among: all), [second],
                       "two windows claimed the same pages")

        // The second window closes. It is the one holding the pages, so they move; the first
        // window is still on screen and is where they go.
        model.surfaceDisappeared(second)

        XCTAssertEqual(Self.surfacesRendering(model, among: all), [first],
                       "closing one window took the pages away from the other one as well")
    }

    /// The main panel is on screen for as long as its window is, so it must not claim on
    /// appearance: a re-render of the column would otherwise take the pages out of a pop-out window
    /// that is still open.
    func testTheMainPanelAppearingDoesNotTakeTheWebViewsFromAWindow() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        model.surfaceAppeared(window)

        model.surfaceAppeared(.panel)

        XCTAssertEqual(Self.surfacesRendering(model, among: [.panel, window]), [window],
                       "the panel took the web views back from a window that is still open")
    }

    /// A surface going away while it holds nothing changes nothing.
    func testASurfaceThatHoldsNothingHandsNothingBack() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        model.surfaceAppeared(.panel)
        model.surfaceAppeared(window)

        model.surfaceDisappeared(.panel)

        XCTAssertEqual(Self.surfacesRendering(model, among: [.panel, window]), [window])
    }

    /// **Pages are never stranded on a surface that is gone.**
    ///
    /// Switching the main panel to another tab removes the Browser view while its window stays
    /// open, so the surface holding the pages disappears. Handing them back to `.panel` there is
    /// handing them to nothing: a window that is plainly on screen sits drawing the "elsewhere"
    /// placeholder until the user reclaims them by hand. They go to a surface that is drawing.
    func testPagesLeaveASurfaceThatGoesAwayForOneThatIsOnScreen() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        let all = [PanelSurface.panel, window]
        model.surfaceAppeared(.panel)
        model.surfaceAppeared(window)
        // The deliberate move back, which is what the "Bring them back here" control does.
        model.attach(to: .panel)
        XCTAssertEqual(Self.surfacesRendering(model, among: all), [.panel])

        // The panel switches to another tab: the Browser view goes away while the window remains.
        model.surfaceDisappeared(.panel)

        XCTAssertEqual(Self.surfacesRendering(model, among: all), [window],
                       "the pages were stranded on a surface that is no longer drawing")
    }

    /// With nothing left on screen the pages rest on the main panel, which is where the next
    /// surface to draw this panel finds them.
    func testPagesRestOnTheMainPanelWhenNoSurfaceIsLeft() async {
        let (model, _, _) = await makeModel()
        let window = Self.window("one")
        model.surfaceAppeared(.panel)
        model.surfaceAppeared(window)

        model.surfaceDisappeared(window)
        model.surfaceDisappeared(.panel)

        XCTAssertEqual(model.attachedTo, .panel)
    }

    /// The other half of D52: the surface is a real input to the view the tab makes. Without this
    /// both surfaces render the same one, and whichever `NSView` hierarchy asked last holds the
    /// web views while the other draws a placeholder that will never come true.
    func testTheViewTheTabMakesIsForTheSurfaceItWasAskedFor() async {
        let (model, _, _) = await makeModel()
        let tab = BrowserTab(model: model)
        let context = makeChannelContext(mark: "surface")
        let session = tab.makeSession(for: context)

        let window = Self.window("one")
        XCTAssertEqual(tab.panelView(session: session, surface: .panel)?.surface, .panel)
        XCTAssertEqual(tab.panelView(session: session, surface: window)?.surface, window,
                       "the popped-out window was handed a view that claims to be the panel")
    }

    /// Every surface that would draw the web views right now.
    private static func surfacesRendering(_ model: BrowserModel,
                                          among surfaces: [PanelSurface]) -> [PanelSurface] {
        surfaces.filter { model.rendersWebViews(on: $0) }
    }

    // MARK: Chrome delegation

    func testBackAndForwardFollowTheSelectedTab() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

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
        let (model, _, _) = await makeModel()

        let opened = observed(model, "a second tab appears") { $0.tabs.count == 2 }
        model.openNewTab(url: opener.url("/opens"))
        await fulfillment(of: [opened], timeout: Self.webDeadline)

        XCTAssertEqual(model.tabs.last?.url, opener.url("/two"))
    }
}
