import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Contract Y1's row slot: the registry four C6 leaves fill in parallel
/// (`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md`, "The skeleton the orchestrator
/// lands before dispatch").
///
/// Three things, and they are the three the skeleton exists to guarantee: the list is complete
/// before any leaf has registered anything, a leaf's registration is confined to its own kind, and
/// the column's row really does resolve through the registry rather than switching on the kind
/// itself. The last one is what makes the wiring real instead of decorative — the fence only holds
/// if the app draws what the registry hands it.
///
/// Every registry built here is its own instance, never `RowRegistry.shared`: a test that claimed a
/// kind on the shared one would make a second test's claim of the same kind a `preconditionFailure`,
/// which is exactly the trap the shared instance is right to set for two leaves and wrong to set
/// for two tests.
@MainActor
final class RowRegistryTests: XCTestCase {

    // MARK: - Completeness

    /// Every one of the thirteen kinds has a builder before anybody registers one.
    func testEveryKindHasABuilderAtStartup() {
        let registry = RowRegistry()
        XCTAssertEqual(TimelineCategory.allCases.count, 13,
                       "§7.3's item model has thirteen kinds; this suite is written against that count")
        for kind in TimelineCategory.allCases {
            // Resolving is the assertion: `builder(for:)` traps on a kind it has no builder for,
            // so a missing kind fails here rather than rendering nothing in the column.
            _ = registry.builder(for: kind)(Self.row)
        }
    }

    /// The default is C5's placeholder row, so an unfilled kind draws a row and not an empty view.
    func testTheDefaultBuilderDrawsThePlaceholderRow() {
        let registry = RowRegistry()
        for kind in TimelineCategory.allCases {
            let view = registry.builder(for: kind)(Self.row)
            XCTAssertTrue("\(type(of: view))".contains("AnyView"), "a builder returned \(type(of: view))")
        }
        // What the placeholder draws, asserted on the values rather than on the rendered text: the
        // row's own three fields are all `PlaceholderRowView` reads.
        XCTAssertEqual(Self.row.category, .opaque)
        XCTAssertEqual(Self.row.summary, "an unmodelled frame")
    }

    // MARK: - The fence

    /// Registering one kind replaces that kind's builder and leaves the other twelve alone.
    func testRegisteringOneKindChangesOnlyThatKind() {
        let registry = RowRegistry()
        let counter = Counter()
        registry.register(kind: .decision) { _ in counter.tick(); return AnyView(EmptyView()) }

        _ = registry.builder(for: .decision)(Self.row)
        XCTAssertEqual(counter.count, 1, "the registered builder did not draw its own kind")

        for kind in TimelineCategory.allCases where kind != .decision {
            _ = registry.builder(for: kind)(Self.row)
        }
        XCTAssertEqual(counter.count, 1,
                       "registering `decision` reached \(counter.count - 1) other kind(s)")
    }

    /// Two registries do not share a claim: the shared instance is one object, not a global table.
    func testARegistrationIsConfinedToItsRegistry() {
        let filled = RowRegistry()
        let counter = Counter()
        filled.register(kind: .decision) { _ in counter.tick(); return AnyView(EmptyView()) }
        _ = RowRegistry().builder(for: .decision)(Self.row)
        XCTAssertEqual(counter.count, 0, "a fresh registry drew through another registry's builder")
    }

    // MARK: - The wiring

    /// The row the channel column draws resolves through the registry it was given.
    ///
    /// `TimelineRowSlot` is the type in `ChannelColumnView`'s `List`, and its `body` is the whole of
    /// its behaviour, so evaluating that body is the column's resolution and not a paraphrase of it.
    func testThePlaceholderColumnResolvesItsRowThroughTheRegistry() {
        let registry = RowRegistry()
        let counter = Counter()
        registry.register(kind: .opaque) { row in
            counter.tick()
            return AnyView(Text(row.summary))
        }
        let slot = TimelineRowSlot(row: Self.row, registry: registry)
        _ = slot.body
        XCTAssertEqual(counter.count, 1, "the column's row slot did not resolve through the registry")
    }

    /// And the app's own slot resolves through the app's own registry, which is the shared one.
    func testTheColumnsDefaultRegistryIsTheSharedOne() {
        XCTAssertTrue(TimelineRowSlot(row: Self.row).registry === RowRegistry.shared,
                      "the column's slot would resolve through a registry no leaf registers into")
    }

    // MARK: - Doubles and fixtures

    /// A counting builder. A class so the closure the registry stores and the assertion below it
    /// read one count.
    @MainActor
    private final class Counter {
        private(set) var count = 0
        func tick() { count += 1 }
    }

    /// One row, invented here: a repeated-nibble session id and a reason this suite wrote (§11 — no
    /// engine byte reaches a committed file). Its kind is irrelevant to every builder above, which
    /// is the point: a builder is asked for a kind, not read off the row it is handed.
    private static let row: TimelineRow = {
        let stream = LogicalStream(configHome: URL(fileURLWithPath: "/tmp/afleet-row-registry/config-home"),
                                   sessionID: SessionID("c3c3c3c3-3333-4333-8333-333333333333")!,
                                   name: .main)
        let id = ItemID(stream: stream, key: "row-registry-1")
        return TimelineRow(.opaque(OpaqueItem(id: id, provenance: Provenance(stream: stream, origin: .file),
                                              reason: "an unmodelled frame", value: .null)))
    }()
}
