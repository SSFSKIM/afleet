import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 4: the eleven row kinds, the two that are another leaf's, the clusters, the thinking
/// disclosure, and the rule that a hidden record is never a row.
///
/// Nothing here asserts over an `ItemID`, a `RecordKey` or anything holding one: both carry a
/// `LogicalStream`, and `LogicalStream` carries a config-home path (§11). Identity is compared as a
/// key string and everything else as a count or a sentence this suite wrote.
@MainActor
final class TimelineRowTests: XCTestCase {

    // MARK: - The claim

    /// Contract Y1: every one of the thirteen kinds resolves to a row, and none draws C5's
    /// placeholder.
    ///
    /// **Amended 2026-09-09 (Task 8).** This said eleven, with `decision` and `sentFile` left to the
    /// leaf that owns their cards. Contract Y7's mount is what changed it: those two rows exist to
    /// consume the render context, the context is this leaf's, and the claim is made in one call
    /// rather than two. Both directions are kept and still mean something — `claimed` and `deferred`
    /// are written lists and the loop reports what actually resolved, so a kind dropped from the
    /// registration shows up here as a placeholder rather than as a one-line summary in front of a
    /// reader.
    func testEveryClaimedKindHasABuilderAndNoneDrawsThePlaceholder() {
        let registry = RowRegistry()
        TimelineRowKinds.register(on: registry)

        var claimed: Set<TimelineCategory> = []
        var placeholders: Set<TimelineCategory> = []
        for kind in TimelineCategory.allCases {
            let row = TimelineRow(Self.item(of: kind))
            if ViewTree.values(of: PlaceholderRowView.self, in: registry.view(for: row)).isEmpty {
                claimed.insert(kind)
            } else {
                placeholders.insert(kind)
            }
        }

        XCTAssertEqual(claimed.count, TimelineCategory.allCases.count,
                       "\(claimed.count) kind(s) resolved to a row, not \(TimelineCategory.allCases.count)")
        XCTAssertEqual(placeholders, TimelineRowKinds.deferred,
                       "the kinds still drawing the placeholder are \(placeholders.map(\.rawValue).sorted())")
        XCTAssertTrue(placeholders.isEmpty, "\(placeholders.count) kind(s) still draw C5's placeholder")
        XCTAssertEqual(claimed, TimelineRowKinds.claimed,
                       "the kinds drawing a C6.1 row are \(claimed.map(\.rawValue).sorted())")
    }

    // MARK: - Hidden records

    /// C3 puts synthetic, meta and attachment records in `DurableProjection.hidden` with a reason
    /// and never in `items`, so the obligation on this side is that a hidden record never becomes a
    /// row.
    ///
    /// **The floor comes first.** An ingestion that produced no hidden records at all would satisfy
    /// "no row matches a hidden key" trivially, so the non-emptiness is asserted for the two
    /// fixtures that witness it — `compact-boundary`, the only fixture carrying `isSynthetic` on the
    /// wire, and `session-mirror-resume`, which carries `isMeta` — before the corpus-wide check runs.
    func testHiddenRecordsAreNeverRows() throws {
        let wireHidden = try TimelineCorpus.wire("compact-boundary").durable.hidden
        XCTAssertGreaterThan(wireHidden.filter { $0.reason == .isSynthetic }.count, 0,
                             "the wire fold of the one fixture carrying isSynthetic hid \(wireHidden.count) record(s)")

        let resumeHidden = try TimelineCorpus.durable("session-mirror-resume").hidden
        XCTAssertGreaterThan(resumeHidden.filter { $0.reason == .isMeta }.count, 0,
                             "the file fold of the fixture carrying isMeta hid \(resumeHidden.count) record(s)")

        var rows = 0
        var hidden = 0
        var collisions = 0
        var metaAndSynthetic = 0
        for name in try TimelineCorpus.names() {
            let projection = try TimelineCorpus.durable(name)
            let keys = Set(projection.hidden.map(TimelineCorpus.key(of:)))
            hidden += projection.hidden.count
            metaAndSynthetic += projection.hidden.filter { $0.reason == .isMeta || $0.reason == .isSynthetic }.count
            rows += projection.items.count
            collisions += projection.items.filter { keys.contains($0.id.key) }.count
        }

        // The tally, pinned: four `isMeta` records across three fixtures on the file side. The
        // child spec counts six by adding the wire's own — `compact-boundary`'s `isSynthetic`, and
        // the summary record it hides a second way — so the two halves are counted separately here
        // rather than summed into a number neither half produces.
        XCTAssertEqual(metaAndSynthetic, 4,
                       "the corpus's file fold hid \(metaAndSynthetic) meta or synthetic record(s)")
        XCTAssertGreaterThan(rows, 0, "the corpus folded \(rows) row(s), so nothing was compared")
        XCTAssertGreaterThan(hidden, 0, "the corpus hid \(hidden) record(s), so the check had nothing to exclude")
        XCTAssertEqual(collisions, 0, "\(collisions) of \(rows) row(s) carry the key of a hidden record")
    }

    // MARK: - Thinking

    /// The disclosure reads its duration from the span the channel gives it, and says nothing about
    /// a live token estimate.
    ///
    /// **It cannot.** `system/thinking_tokens` reaches the `default:` arm of C3's `route(_ system:)`
    /// and neither `Overlay` nor `StreamingPreview` carries a field for it, so after the architect's
    /// ruling removed this leaf's own event subscription the estimate has no route to the app at all
    /// (tracker 127). A message with no thinking gets no disclosure, which is the floor: a summary
    /// built for every message would pass the duration assertion alone.
    func testThinkingFoldsWithItsDuration() throws {
        let thinking = InventedItems.assistant([InventedItems.thinking("an invented thought"),
                                                InventedItems.text("an invented answer")],
                                               at: 4)
        let summary = try XCTUnwrap(ThinkingDisclosure.summary(of: thinking, since: InventedItems.epoch),
                                    "a message carrying a thinking block was given no disclosure")
        XCTAssertEqual(summary.blocks, 1, "the disclosure counted \(summary.blocks) thinking block(s)")
        XCTAssertEqual(summary.duration, 4, "the disclosure measured \(summary.duration ?? -1) second(s)")
        XCTAssertEqual(summary.title, "Thought for 4 seconds", "the disclosure reads \(summary.title)")

        let plain = InventedItems.assistant([InventedItems.text("an invented answer with no thinking")])
        XCTAssertNil(ThinkingDisclosure.summary(of: plain, since: InventedItems.epoch),
                     "a message with no thinking block was given a disclosure anyway")
    }

    // MARK: - Clusters

    /// G2's labelled arm.
    ///
    /// **No committed fixture carries a `tool_use_summary` frame** — `ProjectionEqualityTests` in
    /// FleetKit asserts as much, and it is tracker 128 — so the label here is injected rather than
    /// replayed, and this comment is where that is said out loud. What is being asserted is that a
    /// label the engine sent wins over the count the row would otherwise show.
    func testClusterLabelFromAnInjectedSummary() {
        let calls = [InventedItems.toolCall("Read", id: "toolu_invented0001", at: 0),
                     InventedItems.toolCall("Grep", id: "toolu_invented0002", at: 3)]
        let cluster = ToolClusterItem(id: InventedItems.id("cluster:toolu_invented0001"),
                                      timestamp: InventedItems.epoch,
                                      provenance: InventedItems.provenance,
                                      toolUseIDs: calls.map(\.toolUseID),
                                      label: "an invented summary line")
        let content = ClusterRowContent.content(for: cluster, members: calls)

        XCTAssertTrue(content.isLabelled, "an injected tool_use_summary produced an unlabelled cluster")
        XCTAssertEqual(content.title, "an invented summary line",
                       "the labelled cluster reads \(content.title)")
        XCTAssertEqual(content.count, 2, "the cluster names \(content.count) call(s)")
    }

    /// G2's unlabelled arm, which is what the corpus actually produces: the count and the elapsed
    /// span of the calls the cluster names.
    func testClusterFallsBackToCountsAndElapsed() {
        let calls = [InventedItems.toolCall("Read", id: "toolu_invented0001", at: 0),
                     InventedItems.toolCall("Grep", id: "toolu_invented0002", at: 3),
                     InventedItems.toolCall("Glob", id: "toolu_invented0003", at: 6)]
        let cluster = ToolClusterItem(id: InventedItems.id("cluster:toolu_invented0001"),
                                      timestamp: InventedItems.epoch,
                                      provenance: InventedItems.provenance,
                                      toolUseIDs: calls.map(\.toolUseID),
                                      label: nil)
        let content = ClusterRowContent.content(for: cluster, members: calls)

        XCTAssertFalse(content.isLabelled, "a cluster with no summary reported itself labelled")
        XCTAssertEqual(content.elapsed, 6, "the cluster spans \(content.elapsed ?? -1) second(s)")
        XCTAssertEqual(content.title, "3 tool calls · 6s", "the unlabelled cluster reads \(content.title)")

        // The singular, which parity states by slicing the trailing `s` at one.
        let single = ToolClusterItem(id: InventedItems.id("cluster:toolu_invented0001"),
                                     timestamp: InventedItems.epoch,
                                     provenance: InventedItems.provenance,
                                     toolUseIDs: [calls[0].toolUseID], label: nil)
        XCTAssertEqual(ClusterRowContent.content(for: single, members: [calls[0]]).title, "1 tool call",
                       "a one-call cluster reads \(ClusterRowContent.content(for: single, members: [calls[0]]).title)")
    }

    // MARK: - The unmodelled frame

    /// §6.3: a frame this host does not model is a collapsed row with its JSON behind a disclosure —
    /// never nothing, and never fatal.
    func testAnUnmodelledFrameIsACollapsedRow() {
        let item = OpaqueItem(id: InventedItems.id("opaque-invented-1"),
                              timestamp: InventedItems.epoch,
                              provenance: InventedItems.provenance,
                              type: "invented_frame",
                              subtype: "invented_subtype",
                              reason: "unknown type",
                              value: .object(["type": .string("invented_frame"),
                                              "count": .integer(2)]))
        XCTAssertEqual(OpaqueRow.label(of: item), "invented_frame/invented_subtype · unknown type",
                       "the opaque row reads \(OpaqueRow.label(of: item))")
        XCTAssertTrue(OpaqueRow.json(of: item).contains("invented_frame"),
                      "the disclosure carries \(OpaqueRow.json(of: item).count) character(s) of JSON")

        let registry = RowRegistry()
        TimelineRowKinds.register(on: registry)
        let view = registry.view(for: TimelineRow(.opaque(item)))
        XCTAssertTrue(ViewTree.values(of: PlaceholderRowView.self, in: view).isEmpty,
                      "an unmodelled frame drew the placeholder rather than the collapsed row")
        XCTAssertGreaterThan(ViewTree.values(of: String.self, in: view).count, 0,
                             "the opaque row drew no text at all")
    }

    // MARK: - One item of every kind

    /// An invented item per kind, so the registration test can ask the registry for all thirteen.
    private static func item(of kind: TimelineCategory) -> TimelineItem {
        let id = InventedItems.id("item-\(kind.rawValue)")
        let provenance = InventedItems.provenance
        switch kind {
        case .userMessage:
            return .userMessage(UserMessageItem(id: id, provenance: provenance, text: "an invented prompt"))
        case .assistantMessage:
            return .assistantMessage(InventedItems.assistant([InventedItems.text("an invented answer")]))
        case .toolCall:
            return .toolCall(InventedItems.toolCall("Read"))
        case .cluster:
            return .cluster(ToolClusterItem(id: id, provenance: provenance, toolUseIDs: ["toolu_invented0001"]))
        case .taskRun:
            return .taskRun(TaskRunItem(id: id, provenance: provenance, taskID: "task_invented0001",
                                        kind: .localBash, description: "an invented job", status: .running))
        case .decision:
            return .decision(DecisionItem(id: id, provenance: provenance, requestID: RequestID(rawValue: "req_invented0001"),
                                          kind: .permission, title: "an invented ask", state: .pending,
                                          payload: .object([:])))
        case .hookRun:
            return .hookRun(HookRunItem(id: id, provenance: provenance, hookID: "hook_invented0001",
                                        hookName: "an-invented-hook", event: "PreToolUse"))
        case .notification:
            return .notification(NotificationItem(id: id, provenance: provenance, key: "invented_key",
                                                  text: "an invented notice", level: "info"))
        case .peerMessage:
            return .peerMessage(PeerMessageItem(id: id, provenance: provenance, originKind: "teammate",
                                                text: "an invented peer line"))
        case .compactBoundary:
            return .compactBoundary(CompactBoundaryItem(id: id, provenance: provenance, trigger: "auto"))
        case .sentFile:
            return .sentFile(SentFileItem(id: id, provenance: provenance, toolUseID: "toolu_invented0001",
                                          files: ["/invented/path/file.txt"]))
        case .turnSummary:
            return .turnSummary(TurnSummaryItem(id: id, provenance: provenance, subtype: "success",
                                                durationMs: 1200, costUSD: 0.0123, numTurns: 1,
                                                attribution: .unprompted))
        case .opaque:
            return .opaque(OpaqueItem(id: id, provenance: provenance, reason: "unknown type", value: .object([:])))
        }
    }
}
