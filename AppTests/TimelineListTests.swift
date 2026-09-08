import AppKit
import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 2: the list, and the four properties that make it a table rather than a `List`.
///
/// **What each of these would catch.** A whole-table reload on a streaming delta, and a height cache
/// dropped wholesale on every publish. Each was run against a deliberately broken controller before
/// it was accepted.
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

    // MARK: - Fixtures

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
}
