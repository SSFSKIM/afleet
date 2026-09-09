import AppKit
import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.1 Task 2: the list, and the four properties that make it a table rather than a `List`.
///
/// **What each of these would catch.** A whole-table reload on a streaming delta; a height cache
/// dropped wholesale on every publish; a viewport shoved down by content arriving above it; a
/// sticky-to-bottom rule that needs an affordance pressed to re-arm. Each of the four was run
/// against a deliberately broken controller before it was accepted.
///
/// Nothing here asserts over an `ItemID` or over anything holding one (§11): `ItemID.stream` carries
/// the config home, so the answers are row counts, reload counts, measurement counts and offsets in
/// points, and identity is compared as a `.key` string this suite invented.
@MainActor
final class TimelineListTests: XCTestCase {

    // MARK: - Streaming reloads one row

    /// **The discriminating test, and the reason the list is not a SwiftUI `List`.**
    ///
    /// One delta into a hundred-item channel reloads one row. A `List` re-evaluates its content
    /// closure over the whole collection on every change to the array it was given, and the array
    /// the model publishes is rebuilt whole on every delta — so against a whole-table reload this
    /// counts the table.
    func testStreamingReloadsOneRow() {
        let controller = TimelineTableController()
        let items = Self.rows(100)
        controller.apply(TimelineRenderInput(rows: items, preview: Self.preview("a first sentence.")))
        // The floor: a controller that drew nothing would reload nothing and pass the count below.
        XCTAssertEqual(controller.rows.count, 101,
                       "the table holds \(controller.rows.count) row(s), not the 100 items and the streaming preview")

        controller.apply(TimelineRenderInput(rows: items,
                                             preview: Self.preview("a first sentence. And a"),
                                             changes: [.previewChanged]))

        XCTAssertEqual(controller.reloadedRows.count, 1,
                       "one delta reloaded \(controller.reloadedRows.count) row(s) of \(controller.rows.count)")
        XCTAssertEqual(controller.reloadedRows.first, 100,
                       "the delta reloaded a row other than the streaming one")
    }

    // MARK: - Heights

    /// A publish naming one id costs one height measurement, not a table of them.
    ///
    /// Measured through the delegate the table calls rather than by reading the cache: what matters
    /// is how many heights the table has to compute, and a cache that retained its entries but was
    /// never consulted would not be a cache.
    func testHeightsAreCachedPerIdAndInvalidatedOnlyForChangedIds() {
        let controller = TimelineTableController()
        let items = Self.rows(30)
        controller.apply(TimelineRenderInput(rows: items))
        Self.measureEveryRow(of: controller)
        let measured = controller.heightMeasurements
        // The floor: a table that answered a constant height would measure nothing and pass the
        // selective-invalidation assertion below without ever having cached anything.
        XCTAssertGreaterThanOrEqual(measured, 30,
                                    "the first sweep measured \(measured) height(s) for 30 row(s)")
        Self.measureEveryRow(of: controller)
        XCTAssertEqual(controller.heightMeasurements, measured,
                       "a second sweep re-measured \(controller.heightMeasurements - measured) row(s), so the cache is not one")

        var changed = items
        changed[7] = Self.row(index: 7, text: "an edited line, materially longer than the one it replaced")
        let baseline = controller.heightMeasurements
        controller.apply(TimelineRenderInput(rows: changed, changes: [.updated(changed[7].id)]))
        Self.measureEveryRow(of: controller)

        XCTAssertEqual(controller.heightMeasurements - baseline, 1,
                       "a publish naming one id re-measured \(controller.heightMeasurements - baseline) row(s) of 30")
    }

    // MARK: - The scroll behaviours

    /// Away from the bottom, new items do not move the viewport; back at the bottom, they follow
    /// again with nothing pressed.
    ///
    /// Hosted in a real window, because an `NSScrollView` outside one has no clip-view bounds and
    /// every assertion here would pass against a viewport that never existed.
    func testStickyBottomRepinsSilently() {
        let controller = TimelineTableController()
        FrameTimeHarness.hosted(controller.scrollView, size: Self.viewport) { hosting in
            Self.commit(Self.rows(60), to: controller, in: hosting)
            XCTAssertGreaterThan(controller.tableView.bounds.height, Self.viewport.height,
                                 "the table is no taller than its viewport, so nothing here could scroll")
            XCTAssertTrue(controller.isAtBottom, "a first render did not land at the bottom")

            Self.scroll(controller, to: controller.tableView.bounds.height / 2)
            XCTAssertFalse(controller.scroll.isPinnedToBottom,
                           "the viewport still reports itself pinned after scrolling into the middle")
            let parked = controller.scrollView.contentView.documentVisibleRect.minY

            Self.commit(Self.rows(65), to: controller, in: hosting)
            let moved = abs(controller.scrollView.contentView.documentVisibleRect.minY - parked)
            XCTAssertLessThan(moved, 1,
                              "5 new item(s) moved a parked viewport by \(Int(moved)) point(s)")
            XCTAssertEqual(controller.scroll.unseenCount, 5,
                           "the unseen count reads \(controller.scroll.unseenCount) after 5 item(s) arrived away from the bottom")

            // Back to the bottom by scrolling, which is the whole of the re-pin: nothing is pressed
            // and no caller sets a flag.
            Self.scroll(controller, to: controller.tableView.bounds.height)
            XCTAssertTrue(controller.scroll.isPinnedToBottom, "scrolling back to the bottom did not re-pin")
            XCTAssertEqual(controller.scroll.unseenCount, 0,
                           "the unseen count survived the re-pin, at \(controller.scroll.unseenCount)")

            Self.commit(Self.rows(70), to: controller, in: hosting)
            XCTAssertTrue(controller.isAtBottom, "new items did not follow a re-pinned viewport")
            XCTAssertEqual(controller.rows.count, 70,
                           "the table holds \(controller.rows.count) row(s) after three commits of 60, 65 and 70")
        }
    }

    /// Content arriving above the viewport leaves the item nearest its top edge exactly where it was.
    ///
    /// Fails against a list that shoves the view: without the correction the anchored row moves down
    /// by the whole height of what arrived above it.
    func testScrollAnchoringHoldsTheTopItem() throws {
        let controller = TimelineTableController()
        try FrameTimeHarness.hosted(controller.scrollView, size: Self.viewport) { hosting in
            Self.commit(Self.rows(60, from: 100), to: controller, in: hosting)
            XCTAssertGreaterThan(controller.tableView.bounds.height, Self.viewport.height,
                                 "the table is no taller than its viewport, so nothing here could scroll")

            Self.scroll(controller, to: controller.tableView.bounds.height / 2)
            XCTAssertFalse(controller.scroll.isPinnedToBottom,
                           "the viewport still reports itself pinned after scrolling into the middle")

            let anchor = try XCTUnwrap(Self.topRowKey(of: controller),
                                       "no row was found at the viewport's top edge, so there is no anchor to hold")
            let before = try XCTUnwrap(Self.offset(ofRowKeyed: anchor, in: controller),
                                       "the anchored row has no rectangle before the commit")

            // Ten items above the anchor, which is what a repair, a backfill or a late overlay item
            // does to a channel a reader has scrolled back into.
            Self.commit(Self.rows(10, from: 0) + Self.rows(60, from: 100), to: controller, in: hosting)
            XCTAssertEqual(controller.rows.count, 70,
                           "the table holds \(controller.rows.count) row(s) after 10 were inserted above 60")

            let after = try XCTUnwrap(Self.offset(ofRowKeyed: anchor, in: controller),
                                      "the anchored row is not in the table after the commit")
            XCTAssertEqual(after, before, accuracy: 1,
                           "the anchored row moved \(Int(abs(after - before))) point(s) after 10 item(s) arrived above it")
        }
    }

    // MARK: - The column's one-expression swap

    /// The column draws the renderer for a populated channel and its placeholders for the other
    /// three branches, with the header slot above the timeline and the composer below it.
    ///
    /// Walked through `ViewTree`'s reflection, whose limits tracker 81 records: the answers are type
    /// names, positions and counts, and nothing here prints a view's value.
    func testTheColumnDrawsTheRendererAndKeepsItsOtherBranches() async throws {
        let rig = try Self.makeRig()
        let (app, column) = try await Self.makeColumn(rig)
        let row = try XCTUnwrap(app.browser?.row(LaunchFixtures.sessionA),
                                "the launch painted no channel row, so there is no column to walk")

        // Before the channel is opened: the "Opening…" branch, and no timeline.
        let unopened = ComposerViewTree.order(of: Self.landmarks, in: try Self.channelBody(of: column))
        XCTAssertTrue(unopened.contains("PlaceholderColumn"),
                      "an unopened channel drew \(unopened.count) landmark(s) and none of them a placeholder")
        XCTAssertFalse(unopened.contains("TimelineListView"),
                       "an unopened channel drew the timeline, which has nothing to draw")

        // Opened, with items: the timeline, between the header's slot and the composer.
        let model = app.timelines.model(for: row.key)
        await model.open(row)
        XCTAssertGreaterThan(model.rows.count, 0,
                             "the opened channel holds \(model.rows.count) row(s), so the populated branch is unreachable")
        let populated = ComposerViewTree.order(of: Self.landmarks, in: try Self.channelBody(of: column))
        guard let slot = populated.firstIndex(of: "ChannelHeaderActionsSlot"),
              let timeline = populated.firstIndex(of: "TimelineListView"),
              let composer = populated.lastIndex(of: "ChannelComposerMount") else {
            return XCTFail("the populated column drew \(populated.count) landmark(s), not the three this asserts on")
        }
        XCTAssertTrue(slot < timeline, "the header's action slot is drawn after the timeline, not above it")
        XCTAssertTrue(timeline < composer, "the composer is drawn before the timeline, not below it")
        XCTAssertFalse(populated.contains("PlaceholderColumn"),
                       "the populated column drew a placeholder beside its timeline")

        // The failure branch: a transcript that went away under an index that still lists it.
        let failing = try await Self.makeFailingColumn()
        let broken = ComposerViewTree.order(of: Self.landmarks, in: try Self.channelBody(of: failing))
        XCTAssertTrue(broken.contains("PlaceholderColumn"),
                      "a channel that could not be read drew \(broken.count) landmark(s) and none of them a placeholder")
        XCTAssertFalse(broken.contains("TimelineListView"),
                       "a channel that could not be read drew the timeline")
    }

    // MARK: - The context's two capabilities

    /// Contract Y1's link router and contract Y7's host-signal raise both reach the running objects.
    ///
    /// **Asserted by observing a call on each, never by reading the value back.** A context whose
    /// `links` was an empty closure and whose `signal` went nowhere would satisfy any assertion that
    /// only checked the fields were non-nil, and that is precisely the failure both contracts exist
    /// to prevent — a row that answers a decision, succeeds, and leaves the card `.pending` for ever.
    /// So the link capability is exercised against a registered target that records its delivery, and
    /// the raise is exercised against a relocation the fold refuses, whose refusal is a banner this
    /// side can see.
    ///
    /// The context is built by the view's own construction, which is the only one in the tree.
    func testTheContextCarriesLiveCapabilities() async throws {
        let rig = try Self.makeRig()
        let (app, _) = try await Self.makeColumn(rig)
        let row = try XCTUnwrap(app.browser?.row(LaunchFixtures.sessionA),
                                "the launch painted no channel row to build a context for")
        let model = app.timelines.model(for: row.key)
        await model.open(row)
        XCTAssertNil(model.failure, "the channel could not be read, so it has no fold to raise a signal at")

        let context = TimelineListView(model: model).context(in: app)

        // The link half. The target is registered on the **host's** router and the link is opened
        // through the **context's**, so the assertion fails unless they are the same object: a
        // context carrying a router of its own would deliver nowhere and record nothing.
        let deliveries = Deliveries()
        await app.panels.links.register(LinkTarget(tab: .thread, specificity: 100,
                                                   handles: { if case .file = $0 { true } else { false } },
                                                   open: { _, _ in deliveries.record() }))
        await context.links.open(.file(rig.temp.root.appending(path: "invented.txt"), line: nil),
                                 from: .currentPanel)
        XCTAssertEqual(deliveries.count, 1,
                       "the link capability delivered \(deliveries.count) time(s) to a registered target")

        // The raise half: a move the fold refuses, which it answers with a banner. A resolvable path
        // would be reduced silently and would prove nothing about whether the raise arrived.
        let before = model.timeline.overlay.banners.count
        XCTAssertEqual(before, 0, "the channel raised \(before) banner(s) before the move")
        let elsewhere = rig.configHome
            .appending(path: "projects/invented-not-this-session", directoryHint: .isDirectory)
            .appending(path: "00000000-0000-4000-8000-0000000000ff.jsonl")
        await context.signal(.relocated(mainPath: elsewhere))

        // No wait: `signal(_:)` awaits the fold and republishes before it returns, so the banner is
        // there or the raise never arrived.
        let raised = model.timeline.overlay.banners.count
        XCTAssertEqual(raised, 1, "the raise reached the fold with \(raised) banner(s), not 1")
        XCTAssertEqual(model.timeline.overlay.banners.first?.kind, .compatibility,
                       "the fold raised a banner of a kind a refused relocation does not produce")
    }

    // MARK: - The mutating capability, gated on the channel (round 1, scalpel-3 #2)

    /// **A task card's *Stop* is offered only on a channel afleet owns.**
    ///
    /// A `taskRun` item is read out of the transcript, so a colleague's session — which C5 lists
    /// read-only, and which afleet may show and may not act on — draws the same running task the
    /// owner's does. The context supplied the workspace lifecycle to every channel and the card
    /// offered *Stop* on the item's status alone, so the button was there, it went to
    /// `stop_task`, and X5 refused it as `notOwned`: an action that looks available, does nothing,
    /// and says so only after it has been pressed.
    ///
    /// Both arms over one launch, so the gate is about the listing policy and not about task cards
    /// having stopped being built: the owned row's card offers *Stop* and the read-only row gets no
    /// card at all. The premises are booleans; no assertion prints a row (§11).
    func testStopIsOfferedOnlyOnAnOwnedChannel() async throws {
        let rig = try Self.makeRig(sessions: [LaunchFixtures.sessionA, LaunchFixtures.sessionB],
                                   teammates: [LaunchFixtures.sessionB])
        let (app, _) = try await Self.makeColumn(rig)
        let owned = try XCTUnwrap(app.browser?.row(LaunchFixtures.sessionA),
                                  "the launch painted no owned row")
        let teammate = try XCTUnwrap(app.browser?.row(LaunchFixtures.sessionB),
                                     "the launch painted no read-only row")
        XCTAssertTrue(owned.offersOwnedActions, "the first row is not an owned candidate, so the floor proves nothing")
        XCTAssertFalse(teammate.offersOwnedActions,
                       "the second row is not read-only, so this proves nothing about an unowned channel")

        let mine = TimelineListView(model: app.timelines.model(for: owned.key)).context(in: app)
        let card = try XCTUnwrap(mine.makeTaskCard(Self.runningTask(in: owned.key)),
                                 "an owned channel's running task was given no card at all")
        XCTAssertTrue(card.offersStop, "an owned channel's running task offers no Stop")

        let theirs = TimelineListView(model: app.timelines.model(for: teammate.key)).context(in: app)
        XCTAssertNil(theirs.makeTaskCard(Self.runningTask(in: teammate.key)),
                     "a read-only channel's running task was given a card, whose Stop reaches a refusal")
    }

    /// A running task on one channel, invented throughout (§11).
    private static func runningTask(in key: ChannelKey) -> TaskRunItem {
        let stream = LogicalStream(configHome: key.configHome, sessionID: key.session, name: .main)
        return TaskRunItem(id: ItemID(stream: stream, key: "task-invented-1"),
                           timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                           provenance: Provenance(stream: stream, origin: .file),
                           taskID: "task_invented0001",
                           kind: .localAgent,
                           description: "an invented errand",
                           status: .running)
    }

    /// What a registered link target saw. A class so the closure the router stores and the assertion
    /// below it read one count.
    @MainActor
    private final class Deliveries {
        private(set) var count = 0
        func record() { count += 1 }
    }

    // MARK: - The preview's incarnations (review scalpel-2#1)

    /// A preview that **restarts** is redrawn, not appended to.
    ///
    /// C3 clears the preview on the `assistant` frame and lets a later `content_block_start` open a
    /// fresh one, and a preview with no message id keys as `preview:streaming` either time — so two
    /// incarnations arrive under one key. Coalescing hides the reset in between, and a continuation
    /// rule that reads only "same key, no shorter" then splices the second message's tail onto the
    /// first: "alpha" followed by "bravo!" drew "alpha!". The rule is a prefix, which the two
    /// incarnations of one message satisfy and two different messages do not.
    func testARestartedPreviewIsRedrawnRatherThanAppendedTo() {
        let controller = TimelineTableController()
        let items = Self.rows(3)
        controller.apply(TimelineRenderInput(rows: items, preview: Self.preview("alpha")))
        XCTAssertEqual(controller.previewRow?.tail, "alpha",
                       "the first incarnation drew \(controller.previewRow?.tail ?? "nothing")")

        // Same key, longer text, and not a continuation of it: a second incarnation.
        controller.apply(TimelineRenderInput(rows: items, preview: Self.preview("bravo!"),
                                             changes: [.previewChanged]))
        XCTAssertEqual(controller.previewRow?.tail, "bravo!",
                       "a restarted preview drew \(controller.previewRow?.tail ?? "nothing")")

        // The continuation itself still costs a fragment and not a rebuild, which is what §4 is.
        controller.apply(TimelineRenderInput(rows: items, preview: Self.preview("bravo! and more"),
                                             changes: [.previewChanged]))
        XCTAssertEqual(controller.previewRow?.tail, "bravo! and more",
                       "a continuation drew \(controller.previewRow?.tail ?? "nothing")")
        XCTAssertEqual(controller.reloadedRows.count, 1,
                       "a continuation reloaded \(controller.reloadedRows.count) row(s)")
    }

    // MARK: - Heights that the cache cannot see (review scalpel-3#1)

    /// A narrower table re-measures every row.
    ///
    /// The cache is keyed by the row's id alone, and a height is a function of the id **and** the
    /// width it was measured at. Without an invalidation on width, a window dragged narrow keeps
    /// drawing every row at the height it had when it was wide, so wrapped text is clipped for the
    /// life of the channel.
    func testAWidthChangeInvalidatesEveryCachedHeight() {
        let controller = TimelineTableController()
        FrameTimeHarness.hosted(controller.scrollView, size: NSSize(width: 900, height: 400)) { window in
            controller.setRows((0..<8).map { RenderedRow(key: "doc-\($0)", source: Self.paragraph) })
            window.layoutIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()
            let wide = Self.totalHeight(of: controller)
            XCTAssertGreaterThan(controller.tableView.bounds.width, 500,
                                 "the table is \(Int(controller.tableView.bounds.width)) point(s) wide in a 900-point window, so no width changes here")

            window.setContentSize(NSSize(width: 360, height: 400))
            window.layoutIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()
            let narrow = Self.totalHeight(of: controller)

            XCTAssertGreaterThan(narrow, wide * 1.2,
                                 "8 wrapped row(s) measured \(Int(narrow)) point(s) narrow against \(Int(wide)) wide")
        }
    }

    /// Content that grows after it is mounted tells the table, and the row grows with it.
    ///
    /// A disclosure opening and a card mounting asynchronously both change a row's height with no
    /// publish behind them, and the only height invalidation this controller had accompanied an
    /// explicit reload. The hosted row reports its own size, so what a row is allocated follows
    /// what it draws.
    func testHostedContentThatGrowsUpdatesItsRowHeight() throws {
        let controller = TimelineTableController()
        controller.setRows([RenderedRow(key: "doc-0", source: Self.paragraph)])
        let before = controller.tableView(controller.tableView, heightOfRow: 0)
        let host = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0) as? TimelineRowHostView,
                                 "the table mounted a row that cannot report its own height")

        host.update(root: AnyView(Color.clear.frame(width: 200, height: 400)), context: nil)

        let after = controller.tableView(controller.tableView, heightOfRow: 0)
        XCTAssertEqual(after, 400, accuracy: 2,
                       "hosted content of 400 point(s) is allocated \(Int(after)), from \(Int(before))")
        XCTAssertEqual(controller.hostedHeightNotes, 1,
                       "the table was told of \(controller.hostedHeightNotes) height change(s) by its hosted rows")
    }

    // MARK: - The neighbourhood across a preview delta (review scalpel-2#3)

    /// A publish that moved only the preview reuses the neighbourhood the items already had.
    ///
    /// Building one walks every item in the channel and fills two dictionaries from them, and the
    /// merge that hands it those items sorts both halves of the timeline — while the list's body
    /// evaluates on every streaming delta, thirty a second, and a delta changes no item at all. So
    /// what a delta cost grew with the history behind it. The floor is the second half: items that
    /// really did move rebuild it, or this would be a cache that never notices anything.
    func testAPreviewOnlyPublishReusesTheNeighbourhood() {
        let cache = TimelineNeighbourhoodCache()
        var timeline = ChannelTimeline(durable: DurableProjection(items: Self.items(50)))
        let first = cache.neighbourhood(for: timeline)
        XCTAssertEqual(first.precedingTimestamps.count, 49,
                       "the neighbourhood of 50 item(s) knows \(first.precedingTimestamps.count) preceding instant(s), not 49")

        timeline.preview = Self.preview("a first sentence.")
        _ = cache.neighbourhood(for: timeline)
        timeline.preview = Self.preview("a first sentence. And a second one, arriving a character at a time.")
        let third = cache.neighbourhood(for: timeline)

        XCTAssertEqual(cache.builds, 1,
                       "two preview delta(s) rebuilt the neighbourhood \(cache.builds) time(s), not once for the items")
        XCTAssertEqual(third.precedingTimestamps.count, 49,
                       "the reused neighbourhood knows \(third.precedingTimestamps.count) preceding instant(s), not the 49 it was built with")

        timeline.durable.items = Self.items(51)
        let fourth = cache.neighbourhood(for: timeline)
        XCTAssertEqual(cache.builds, 2,
                       "an item that arrived left the neighbourhood at \(cache.builds) build(s), so the items never reach it")
        XCTAssertEqual(fourth.precedingTimestamps.count, 50,
                       "the rebuilt neighbourhood knows \(fourth.precedingTimestamps.count) preceding instant(s), not 50")
    }

    /// The list reads the channel's neighbourhood rather than building its own.
    ///
    /// The cache above is only worth having if the construction site uses it, and the site is one
    /// argument inside a context the column builds per body evaluation.
    func testTheContextReadsTheChannelsNeighbourhood() async throws {
        let app = AppModel(registry: RowRegistry())
        let model = ChannelTimelineModel(key: ChannelKey(configHome: Self.stream.configHome,
                                                         session: Self.stream.sessionID),
                                         workspace: nil)
        let view = TimelineListView(model: model)
        _ = view.context(in: app)
        _ = view.context(in: app)

        XCTAssertEqual(model.neighbourhoods.builds, 1,
                       "two context(s) built the channel's neighbourhood \(model.neighbourhoods.builds) time(s), not once")
    }

    // MARK: - Reaching a row by index (review scalpel-2#2)

    /// The indexed accessors answer exactly what the list of rows answers, with and without a
    /// preview, at both ends and in the middle.
    ///
    /// The list is the whole history concatenated afresh on every access, and the table asks for a
    /// row per visible row per layout — `heightOfRow` asked for it before it even consulted its
    /// height cache. So the arithmetic replaces it on the hot paths, and this is what says the two
    /// agree: an off-by-one at the preview's index would draw the last message into the preview's
    /// row, and a preview the index cannot find would lose the reader's anchor on every delta.
    func testIndexedRowAccessAgreesWithTheList() {
        let controller = TimelineTableController()
        for preview in [nil, Self.preview("a streaming line")] as [StreamingPreview?] {
            controller.apply(TimelineRenderInput(rows: Self.rows(5), preview: preview))
            let list = controller.rows
            XCTAssertEqual(controller.rowCount, list.count,
                           "the table counts \(controller.rowCount) row(s) against a list of \(list.count)")
            for index in list.indices {
                XCTAssertEqual(controller.row(at: index)?.key, list[index].key,
                               "row \(index) of \(list.count) is a different row read by index")
                XCTAssertEqual(controller.index(ofKey: list[index].key), index,
                               "the key at row \(index) of \(list.count) is found at another index")
            }
            XCTAssertNil(controller.row(at: -1), "the table answered a row for index -1")
            XCTAssertNil(controller.row(at: list.count), "the table answered a row one past its last")
            XCTAssertNil(controller.index(ofKey: "item-nothing-here"),
                         "the table found an index for a key it does not hold")
        }
    }

    // MARK: - The scroll after a hosted row grew (review scalpel-1#1)

    /// A card that grows after it is mounted leaves a pinned reader at the bottom.
    ///
    /// The document grows with no publish behind it, so nothing takes the anchor and nothing settles
    /// the scroll: a viewport pinned to the bottom keeps its old offset, is no longer at the bottom,
    /// and every later publish then holds it where the growth left it. Growth away from the bottom
    /// is the same fault seen from the other side — the row the reader is on is shoved down by the
    /// whole height of what grew above it.
    func testHostedGrowthKeepsAPinnedViewportAtTheBottom() throws {
        let controller = TimelineTableController()
        try FrameTimeHarness.hosted(controller.scrollView, size: Self.viewport) { window in
            Self.commit(Self.rows(60), to: controller, in: window)
            XCTAssertGreaterThan(controller.tableView.bounds.height, Self.viewport.height,
                                 "the table is no taller than its viewport, so nothing here could scroll")
            XCTAssertTrue(controller.isAtBottom, "a first render did not land at the bottom")

            // The last row's card finishes mounting and is 400 points tall.
            let last = controller.rows.count - 1
            let host = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: last) as? TimelineRowHostView,
                                     "the table mounted a row that cannot report its own height")
            host.update(root: AnyView(Color.clear.frame(width: 200, height: 400)), context: nil)
            window.layoutIfNeeded()

            XCTAssertTrue(controller.isAtBottom,
                          "a row that grew by 400 point(s) left a pinned viewport \(Int(controller.tableView.bounds.height - controller.scrollView.contentView.documentVisibleRect.maxY)) point(s) short of the bottom")
        }
    }

    /// The same growth, away from the bottom: the reader's row does not move.
    func testHostedGrowthAboveTheViewportHoldsTheAnchoredRow() throws {
        let controller = TimelineTableController()
        try FrameTimeHarness.hosted(controller.scrollView, size: Self.viewport) { window in
            Self.commit(Self.rows(60), to: controller, in: window)
            Self.scroll(controller, to: controller.tableView.bounds.height / 2)
            XCTAssertFalse(controller.scroll.isPinnedToBottom,
                           "the viewport still reports itself pinned after scrolling into the middle")

            let anchor = try XCTUnwrap(Self.topRowKey(of: controller),
                                       "no row was found at the viewport's top edge, so there is no anchor to hold")
            let before = try XCTUnwrap(Self.offset(ofRowKeyed: anchor, in: controller),
                                       "the anchored row has no rectangle before the growth")

            // The first row's card mounts, 400 points tall, far above where the reader is sitting.
            let host = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0) as? TimelineRowHostView,
                                     "the table mounted a row that cannot report its own height")
            host.update(root: AnyView(Color.clear.frame(width: 200, height: 400)), context: nil)
            window.layoutIfNeeded()

            let after = try XCTUnwrap(Self.offset(ofRowKeyed: anchor, in: controller),
                                      "the anchored row is not in the table after the growth")
            XCTAssertEqual(after, before, accuracy: 2,
                           "the anchored row moved \(Int(abs(after - before))) point(s) when a row above it grew")
        }
    }

    // MARK: - The mounted row across reloads (review sweep#4, scalpel-1#3)

    /// A reload updates the row that is already mounted rather than building a second one.
    ///
    /// The disposable state SwiftUI keeps for a row — a card's in-flight guard, a question's draft —
    /// belongs to the hosting view, so a fresh one per reload silently discards it. A message
    /// streaming beside a half-typed answer reloads its neighbour thirty times a second.
    func testAReloadReusesTheRowAlreadyMounted() {
        let controller = TimelineTableController()
        let items = Self.rows(3)
        controller.apply(TimelineRenderInput(rows: items))
        let first = controller.tableView(controller.tableView, viewFor: nil, row: 1)

        var edited = items
        edited[1] = Self.row(index: 1, text: "an edited line")
        controller.apply(TimelineRenderInput(rows: edited, changes: [.updated(edited[1].id)]))
        let second = controller.tableView(controller.tableView, viewFor: nil, row: 1)

        XCTAssertTrue(first === second, "a reload replaced the mounted row rather than updating it")
        let other = controller.tableView(controller.tableView, viewFor: nil, row: 2)
        XCTAssertFalse(first === other, "two rows of the table are one view")
    }

    /// A context that changed reaches the rows that are already mounted.
    ///
    /// The context is a value captured in each hosted root, so a row mounted before the channel
    /// learnt its cwd — or before its overlay went stale — keeps drawing against the old one until
    /// something unrelated reloads it.
    func testAContextChangeReachesMountedRows() throws {
        let controller = TimelineTableController()
        let collapse = TimelineCollapseState()
        let items = Self.rows(3)
        controller.apply(TimelineRenderInput(rows: items),
                         context: InventedItems.context(collapse: collapse))
        let host = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0) as? TimelineRowHostView,
                                 "the table mounted a row that does not record the context it drew against")
        XCTAssertNil(host.renderedContext?.cwd, "the row was mounted against a context that already had a cwd")

        let cwd = URL(fileURLWithPath: "/tmp/afleet-timeline-list/invented-project")
        controller.apply(TimelineRenderInput(rows: items),
                         context: InventedItems.context(collapse: collapse, cwd: cwd))

        XCTAssertEqual(host.renderedContext?.cwd, cwd,
                       "the mounted row still draws against the context it was built with")
    }

    /// A capability that changed reaches the rows that are already mounted (review scalpel-3#1).
    ///
    /// Ownership and the composer are what contract Y6 gates *Edit* on, and both live on the context
    /// the mounted roots captured. A comparison that reads only the cwd, the flags and the shared
    /// objects calls a channel that was just adopted — or that has just acquired a composer —
    /// unchanged, and every mounted row goes on offering, or omitting, the action the old context
    /// allowed.
    ///
    /// Every channel-scoped object is held fixed across the publishes, because a fresh one is itself
    /// a difference: a test that let them be rebuilt would pass on the identity comparison alone and
    /// assert nothing about the capabilities.
    func testACapabilityChangeReachesMountedRows() throws {
        let controller = TimelineTableController()
        let collapse = TimelineCollapseState()
        let editing = TimelineEditState()
        let retraction = RetractionRegistry()
        let decisions = DecisionReservations()
        let items = Self.rows(3)
        func context(owned: Bool, composer: (any ComposerSite)? = nil) -> TimelineRenderContext {
            InventedItems.context(collapse: collapse, composer: composer, editing: editing,
                                  decisions: decisions, isOwned: owned, retraction: retraction)
        }

        controller.apply(TimelineRenderInput(rows: items), context: context(owned: false))
        let host = try XCTUnwrap(controller.tableView(controller.tableView, viewFor: nil, row: 0) as? TimelineRowHostView,
                                 "the table mounted a row that does not record the context it drew against")
        XCTAssertEqual(host.renderedContext?.isOwned, false, "the row was mounted against an owned context")

        // Ownership alone: the channel was adopted, nothing else moved.
        controller.apply(TimelineRenderInput(rows: items), context: context(owned: true))
        XCTAssertEqual(host.renderedContext?.isOwned, true,
                       "an adopted channel did not reach the rows already mounted")

        // The composer alone: the same ownership, a capability that was nil and now is not.
        let composer = RecordingComposerSite()
        controller.apply(TimelineRenderInput(rows: items), context: context(owned: true, composer: composer))
        XCTAssertTrue(host.renderedContext?.composer === composer,
                      "a composer the channel has just acquired did not reach the rows already mounted")

        // And away again: a channel that lost its composer keeps none on its mounted rows.
        controller.apply(TimelineRenderInput(rows: items), context: context(owned: true))
        XCTAssertNil(host.renderedContext?.composer,
                     "a composer the channel has lost is still held by the rows already mounted")
    }

    // MARK: - The anchor across the durable replacement (review scalpel-2#6)

    /// The reader's place survives the moment the streaming message becomes an item.
    ///
    /// The anchor is a row key, and the preview's key belongs to no item: when the durable message
    /// lands the anchored row is gone, and a publish that also inserted items above it then shoves
    /// the viewport by their whole height. The anchor moves to the item that replaced it.
    func testTheAnchorFollowsThePreviewToItsDurableItem() throws {
        let controller = TimelineTableController()
        try FrameTimeHarness.hosted(controller.scrollView, size: Self.viewport) { window in
            // A preview taller than the viewport, so the reader can sit at its top edge and still
            // not be at the document's bottom.
            let streaming = Self.preview(Self.paragraph + "\n\n" + Self.paragraph)
            controller.apply(TimelineRenderInput(rows: Self.rows(20, from: 100), preview: streaming))
            window.layoutIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()

            let previewIndex = controller.rows.count - 1
            Self.scroll(controller, to: controller.tableView.rect(ofRow: previewIndex).minY)
            XCTAssertFalse(controller.scroll.isPinnedToBottom,
                           "the viewport reports itself pinned while parked on a preview taller than it")
            let anchored = try XCTUnwrap(Self.topRowKey(of: controller),
                                         "no row sits at the viewport's top edge, so there is no anchor")
            XCTAssertTrue(anchored.hasPrefix("preview:"),
                          "the row at the top edge is not the preview, so this asserts nothing about it")
            let before = try XCTUnwrap(Self.offset(ofRowKeyed: anchored, in: controller),
                                       "the anchored preview has no rectangle before the commit")

            // The turn settles: the preview becomes item 120, and a backfill lands ten items above.
            let settled = Self.rows(10, from: 0) + Self.rows(20, from: 100) + [Self.row(index: 120)]
            controller.apply(TimelineRenderInput(rows: settled, preview: nil,
                                                 changes: [.inserted(settled[settled.count - 1].id)]))
            window.layoutIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()

            let after = try XCTUnwrap(Self.offset(ofRowKeyed: "item-120", in: controller),
                                      "the durable replacement is not in the table after the commit")
            XCTAssertEqual(after, before, accuracy: 2,
                           "the reader's place moved \(Int(abs(after - before))) point(s) when the preview became an item")
        }
    }

    // MARK: - The preview's own channel (round 3, scalpel-4 #4)

    /// The **streaming preview** is drawn against the channel's context, as every item row is.
    ///
    /// **Discriminating.** The context was injected onto the item roots and the preview root was
    /// returned bare, so a link pressed in the message being streamed reached `open` with no
    /// context, was declined, and fell through to the system — where a relative path names a file
    /// in the app's own directory or no file at all. The reader cannot tell a streaming message
    /// from a settled one, and the link works in one and not the other.
    ///
    /// The witness is the capability, not the injection: the context found on the preview root is
    /// used to open a relative destination, and the recording router is asked what it received.
    func testThePreviewRowIsDrawnAgainstTheChannelsContext() async throws {
        let controller = TimelineTableController()
        let router = RecordingLinkRouter()
        let cwd = URL(fileURLWithPath: "/tmp/afleet-timeline-list/invented-project")
        controller.apply(TimelineRenderInput(rows: Self.rows(2),
                                             preview: Self.preview("an invented streaming line")),
                         context: InventedItems.context(links: router, cwd: cwd))
        let preview = try XCTUnwrap(controller.previewRow, "the table holds no preview row to draw")

        let carried = ViewTree.values(of: TimelineRenderContext.self, in: controller.root(for: preview))
        XCTAssertEqual(carried.count, 1,
                       "the preview root carries \(carried.count) render context(s), not the channel's one")
        let context = try XCTUnwrap(carried.first)

        let relative = try XCTUnwrap(TimelineLinkDestination.url(for: "notes.md"))
        XCTAssertTrue(TimelineLinkDestination.open(relative, in: context),
                      "a relative link in the preview was declined, so it falls through to the system")
        var delivered = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await router.opened.count == 1 { delivered = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(delivered, "the channel's link capability received nothing within the wait")
        let opened = await router.opened
        XCTAssertEqual(opened.first, .file(cwd.appending(path: "notes.md"), line: nil),
                       "the preview's relative link was not resolved against the channel's directory")

        // The floor: an item row carried one all along, so this asserts about the preview and not
        // about the injection having been removed everywhere.
        let item = try XCTUnwrap(controller.rows.first, "the table holds no item row")
        XCTAssertEqual(ViewTree.values(of: TimelineRenderContext.self, in: controller.root(for: item)).count, 1,
                       "an item root no longer carries the channel's context")
    }

    // MARK: - Fixtures

    /// The window every scroll assertion is made in. Short enough that sixty rows overflow it, which
    /// is what makes "scrolled into the middle" a place and not a rounding error.
    private static let viewport = NSSize(width: 520, height: 300)

    private static let landmarks: Set<String> = ["ChannelHeaderActionsSlot", "TimelineListView",
                                                 "PlaceholderColumn", "ChannelComposerMount"]

    /// An invented stream: a repeated-nibble session id and a config home under the process's own
    /// temporary directory, so no committed byte and no real path is in this suite (§11).
    private static let stream = LogicalStream(
        configHome: URL(fileURLWithPath: "/tmp/afleet-timeline-list/config-home"),
        sessionID: SessionID("d4d4d4d4-4444-4444-8444-444444444444")!,
        name: .main)

    /// One row, keyed by its index so a test can name the same item across two commits without
    /// holding an `ItemID`.
    private static func row(index: Int, text: String? = nil) -> TimelineRow {
        let id = ItemID(stream: stream, key: "item-\(index)")
        return TimelineRow(.userMessage(UserMessageItem(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
            provenance: Provenance(stream: stream, origin: .file),
            text: text ?? "an invented line, number \(index)")))
    }

    private static func rows(_ count: Int, from first: Int = 0) -> [TimelineRow] {
        (first..<(first + count)).map { row(index: $0) }
    }

    /// The same invented items, as the timeline holds them.
    private static func items(_ count: Int) -> [TimelineItem] {
        rows(count).map(\.item)
    }

    /// A paragraph long enough that its height is a function of the width it is measured at, and
    /// tall enough that it overflows the test's viewport. Invented text, as everything here is.
    private static let paragraph = String(repeating:
        "an invented sentence about nothing in particular, long enough to wrap and to wrap again. ",
        count: 12)

    /// What the table would allocate to every row it holds, asked for the way it asks.
    private static func totalHeight(of controller: TimelineTableController) -> CGFloat {
        controller.rows.indices.reduce(into: CGFloat(0)) {
            $0 += controller.tableView(controller.tableView, heightOfRow: $1)
        }
    }

    private static func preview(_ text: String) -> StreamingPreview {
        StreamingPreview(messageID: "msg-invented-1",
                         blocks: [PreviewBlock(index: 0, kind: .text, text: text)])
    }

    /// Every row's height, asked for the way the table asks for it.
    private static func measureEveryRow(of controller: TimelineTableController) {
        for index in controller.rows.indices {
            _ = controller.tableView(controller.tableView, heightOfRow: index)
        }
    }

    /// A publish, laid out. The layout is not decoration: `rect(ofRow:)` answers from the last
    /// layout, so an assertion made before one reads the arrangement from before the commit.
    private static func commit(_ rows: [TimelineRow], to controller: TimelineTableController,
                               in hosting: NSWindow) {
        controller.apply(TimelineRenderInput(rows: rows))
        hosting.layoutIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()
    }

    /// Scrolls the viewport, the way a reader's scroll wheel does: the clip view moves and says so,
    /// which is the notification the sticky-bottom rule listens to.
    private static func scroll(_ controller: TimelineTableController, to y: CGFloat) {
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        controller.scrollView.reflectScrolledClipView(clip)
    }

    /// The key of the row at the viewport's top edge.
    private static func topRowKey(of controller: TimelineTableController) -> String? {
        let visible = controller.scrollView.contentView.documentVisibleRect
        let index = controller.tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard controller.rows.indices.contains(index) else { return nil }
        return controller.rows[index].key
    }

    /// How far below the viewport's top edge a named row sits.
    private static func offset(ofRowKeyed key: String, in controller: TimelineTableController) -> CGFloat? {
        guard let index = controller.rows.firstIndex(where: { $0.key == key }) else { return nil }
        let visible = controller.scrollView.contentView.documentVisibleRect
        return controller.tableView.rect(ofRow: index).minY - visible.minY
    }

    // MARK: - The launch the column is walked in

    private struct Rig {
        let temp: TempTree
        let configHome: URL
        let sequence: LaunchSequence
    }

    /// A launch that reaches a workspace with the listed channels. Everything is invented and every
    /// path is under the process's temporary directory (X9).
    ///
    /// `teammates` are the sessions C5's listing policy lists **read-only** — a colleague's
    /// transcript, which afleet may show and may not act on.
    private static func makeRig(sessions: [SessionID] = [LaunchFixtures.sessionA],
                                teammates: Set<SessionID> = []) throws -> Rig {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        // The slug matches `LaunchFixtures.snapshot`'s entry path, so the index the launch is
        // given names the transcript that is actually on disk and the channel opens with items.
        for session in sessions {
            try LaunchFixtures.transcript(in: configHome, slug: "invented", session: session)
        }
        let index = StubIndex(persisted: nil,
                              built: LaunchFixtures.snapshot(configHome: configHome,
                                                             ids: sessions,
                                                             teammates: teammates),
                              delta: IndexDelta(added: sessions))
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in index },
            fleetFactory: { _, _, _, _, _, _ in LifecycleDouble() },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })
        return Rig(temp: temp, configHome: configHome, sequence: sequence)
    }

    /// The column as the window draws it, with the one channel selected.
    private static func makeColumn(_ rig: Rig) async throws -> (app: AppModel, column: ChannelColumnView) {
        let app = AppModel(registry: RowRegistry(), sequence: rig.sequence)
        await app.launch()
        let workspace = try XCTUnwrap(app.route.workspace, "the launch reached no workspace to draw")
        app.shell.select(LaunchFixtures.sessionA)
        return (app, ChannelColumnView(app: app, shell: app.shell, workspace: workspace))
    }

    /// A column whose channel is listed but whose transcript is gone, which is the `failure` branch.
    private static func makeFailingColumn() async throws -> ChannelColumnView {
        let rig = try makeRig()
        let (app, column) = try await makeColumn(rig)
        let row = try XCTUnwrap(app.browser?.row(LaunchFixtures.sessionA),
                                "the launch painted no channel row to break")
        // A transcript that cannot be read, rather than one that is merely absent: an absent file
        // reads as an empty channel, and what the `failure` branch is about is a read that failed.
        // The path is replaced by a directory, which every read of it refuses.
        let transcript = rig.configHome.appending(path: "projects/invented/\(LaunchFixtures.sessionA).jsonl")
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: false)
        let model = app.timelines.model(for: row.key)
        await model.open(row)
        XCTAssertNotNil(model.failure, "a channel whose transcript went away reported no failure")
        return column
    }

    /// The inner per-channel view, which is `private` to `ChannelColumnView.swift` and so is reached
    /// by opening the body rather than by naming the type.
    private static func channelBody(of column: ChannelColumnView) throws -> Any {
        let inner = try XCTUnwrap(ComposerViewTree.view(named: "ChannelTimelineColumn", in: column.body),
                                  "the column drew no per-channel view, so there is no branch to assert on")
        return ComposerViewTree.body(of: inner)
    }
}
