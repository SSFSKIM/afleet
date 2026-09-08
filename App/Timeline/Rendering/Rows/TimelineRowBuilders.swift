import Foundation
import SwiftUI
import FleetKit

// MARK: - The thirteen kinds, claimed in one place

/// Contract Y1's registration: one builder per kind, claimed once.
///
/// **Superseded 2026-09-09 (C6.1 Task 8).** This said eleven of the thirteen: `decision` and
/// `sentFile` were another leaf's and were claimed separately, in `AppModel.init`, once both leaves
/// were on one branch. Contract Y7's mount is what closes that split — those two rows exist to
/// consume the render context, and the context is this leaf's — so the thirteen are claimed here, in
/// the one call, and the second registration site is gone.
///
/// `RowRegistry.register(kind:builder:)` traps on a second claim of a kind, deliberately, because
/// two leaves owning one kind is a breach of the cut's fence. That trap is about *kinds*, not about
/// processes: a second `AppModel` over the app's shared registry is an ordinary thing for a test to
/// build and is not a double claim, so the claim on `RowRegistry.shared` is made once per process
/// and a registry a caller owns is claimed on every time.
enum TimelineRowKinds {

    /// The kinds this leaf fills — every one of them. Stated as a list rather than as
    /// `allCases`, so the test that asserts the claim compares two written lists in both directions.
    static let claimed: Set<TimelineCategory> = [
        .userMessage, .assistantMessage, .toolCall, .cluster, .taskRun, .hookRun, .notification,
        .peerMessage, .compactBoundary, .turnSummary, .opaque, .decision, .sentFile,
    ]

    /// The kinds nobody claims. Empty since Task 8's mount, and kept as a written list so the
    /// partition below stays an assertion rather than a tautology.
    static let deferred: Set<TimelineCategory> = []

    /// Whether the app's shared registry has been claimed in this process. `@MainActor`, which is
    /// what isolates it: the check and the claim below cannot interleave.
    @MainActor
    private static var hasClaimedSharedRegistry = false

    /// Claims the thirteen on a registry.
    ///
    /// The partition is checked here rather than assumed: `claimed` and `deferred` are two written
    /// lists, and a kind that fell out of both would draw C5's placeholder for ever with nothing
    /// saying so — which is the failure the registry's own trap cannot catch, because the missing
    /// claim is silent where a double claim is loud.
    @MainActor
    static func register(on registry: RowRegistry) {
        precondition(claimed.union(deferred) == Set(TimelineCategory.allCases) && claimed.isDisjoint(with: deferred),
                     "\(claimed.count) claimed and \(deferred.count) deferred kind(s) do not partition \(TimelineCategory.allCases.count)")
        if registry === RowRegistry.shared {
            guard !hasClaimedSharedRegistry else { return }
            hasClaimedSharedRegistry = true
        }
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
        // Contract Y7's two mounts. The cards, the answer mappings and the retraction bookkeeping
        // are another leaf's; these two rows are the wiring that hands them the capabilities a
        // builder is not given — the channel, the link router, the app's one reservation set and the
        // fold's raise — which is what makes a card answered from the list leave `pending`.
        case .decision: DecisionRow(row: row)
        case .sentFile: SentFileRow(row: row)
        }
    }
}
