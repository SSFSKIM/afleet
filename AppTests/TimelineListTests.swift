import AppKit
import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 2: the list, and the four properties that make it a table rather than a `List`.
///
/// **What each of these would catch.** A whole-table reload on a streaming delta; a height cache
/// dropped wholesale on every publish; a viewport shoved down by content arriving above it; a
/// sticky-to-bottom rule that needs an affordance pressed to re-arm. Each was run against a
/// deliberately broken controller before it was accepted.
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

    // MARK: - Fixtures

    /// The window every scroll assertion is made in. Short enough that sixty rows overflow it, which
    /// is what makes "scrolled into the middle" a place and not a rounding error.
    private static let viewport = NSSize(width: 520, height: 300)

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
}
