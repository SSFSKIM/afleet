import Foundation
import SwiftUI
import FleetKit

// MARK: - The eleven kinds C6.1 claims

/// Contract Y1's registration: one builder per kind, claimed once.
///
/// **Eleven of the thirteen.** `decision` and `sentFile` are C6.3's and are never claimed here, so
/// they keep resolving to `PlaceholderRowView` on this branch and to that leaf's cards once both are
/// on `main`. `RowRegistry.register(kind:builder:)` traps on a second claim of a kind — deliberately,
/// because two leaves owning one kind is a breach of the cut's fence — which is why `AppModel` takes
/// its registry as a parameter: production has one model and one claim on the shared registry, a
/// test gives each model its own, and a genuine double claim still traps.
enum TimelineRowKinds {

    /// The kinds this leaf fills. Stated as a list rather than as "everything but two", so the test
    /// that asserts the claim can compare in both directions.
    static let claimed: Set<TimelineCategory> = [
        .userMessage, .assistantMessage, .toolCall, .cluster, .taskRun, .hookRun, .notification,
        .peerMessage, .compactBoundary, .turnSummary, .opaque,
    ]

    /// The two kinds this leaf never claims.
    static let deferred: Set<TimelineCategory> = [.decision, .sentFile]

    /// Claims the eleven on a registry.
    ///
    /// The partition is checked here rather than assumed: `claimed` and `deferred` are two written
    /// lists, and a kind that fell out of both would draw C5's placeholder for ever with nothing
    /// saying so — which is the failure the registry's own trap cannot catch, because the missing
    /// claim is silent where a double claim is loud.
    @MainActor
    static func register(on registry: RowRegistry) {
        precondition(claimed.union(deferred) == Set(TimelineCategory.allCases) && claimed.isDisjoint(with: deferred),
                     "\(claimed.count) claimed and \(deferred.count) deferred kind(s) do not partition \(TimelineCategory.allCases.count)")
        for kind in claimed {
            registry.register(kind: kind) { row in AnyView(view(for: row)) }
        }
    }

    /// One row, drawn by the kind of item it carries.
    ///
    /// The switch is over the **item**, not over the category, which is why contract Y1 was amended
    /// to carry one: a hundred-and-forty-character summary is everything the placeholder drew and
    /// nothing a real row needs.
    @ViewBuilder @MainActor
    static func view(for row: TimelineRow) -> some View {
        switch row.item {
        case .userMessage(let item): UserMessageRow(item: item)
        case .assistantMessage(let item): AssistantMessageRow(item: item)
        case .toolCall(let item): ToolCallRow(item: item)
        case .cluster(let item): ClusterRow(item: item)
        case .taskRun(let item): TaskRunRow(item: item)
        case .hookRun(let item): HookRunRow(item: item)
        case .notification(let item): NotificationRow(item: item)
        case .peerMessage(let item): PeerMessageRow(item: item)
        case .compactBoundary(let item): CompactBoundaryRow(item: item)
        case .turnSummary(let item): TurnSummaryRow(item: item)
        case .opaque(let item): OpaqueRow(item: item)
        // The two another leaf owns. They never reach here — the registry resolves them through
        // their own builders — and the placeholder is what draws them until C6.3 lands.
        case .decision, .sentFile: PlaceholderRowView(row: row)
        }
    }
}
