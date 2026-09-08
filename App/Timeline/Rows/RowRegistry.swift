import SwiftUI
import FleetKit

/// The row slot four leaves of C6 fill in parallel — contract Y1 of the C6 composite spec
/// (`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md`, "The skeleton the orchestrator
/// lands before dispatch").
///
/// One builder per `TimelineCategory`, the thirteen kinds of §7.3, and **every kind has one from
/// the moment the registry is constructed**: C5's placeholder row. That is the whole point of the
/// default. C6.1 fills every kind but `decision` and `sentFile`, C6.3 fills those two, and each
/// leaf's branch builds and runs the complete list — a kind nobody has filled yet renders the
/// placeholder row, never nothing, so no branch ever sees a hole where an item should be.
///
/// **A second registration for a kind another leaf already filled is a programming error.** Two
/// leaves owning one kind is a breach of the cut's fence, and the cut is what lets four worktrees
/// build one target; the failure is loud, names the kind, and lands at the merge that introduces it
/// rather than in whichever row happened to be registered last.
@MainActor
final class RowRegistry {

    /// What a leaf hands over: an item's row, drawn. `AnyView` because the thirteen builders have
    /// thirteen different body types and this is the erasure boundary between them; the alternative
    /// — a protocol with an associated view type — buys nothing a leaf can use and costs every leaf
    /// a type to declare.
    typealias RowBuilder = @MainActor (TimelineRow) -> AnyView

    /// The app's registry. The column resolves through this one; a test builds its own.
    static let shared = RowRegistry()

    private var builders: [TimelineCategory: RowBuilder]

    /// The kinds a leaf has claimed, which is not the same as the kinds that have a builder — every
    /// kind has one. This is what makes the second registration detectable.
    private var claimed: Set<TimelineCategory> = []

    init() {
        builders = Dictionary(uniqueKeysWithValues: TimelineCategory.allCases.map { kind in
            (kind, { row in AnyView(PlaceholderRowView(row: row)) } as RowBuilder)
        })
    }

    /// Claims a kind for a leaf. Replaces that kind's builder and no other's.
    func register(kind: TimelineCategory, builder: @escaping RowBuilder) {
        if claimed.contains(kind) {
            preconditionFailure("two row builders registered for \(kind.rawValue); one kind belongs to one C6 leaf")
        }
        claimed.insert(kind)
        builders[kind] = builder
    }

    /// The builder that owns a kind. Total: the initialiser fills all thirteen, so this never
    /// returns nothing and the list is complete on every leaf's branch.
    func builder(for kind: TimelineCategory) -> RowBuilder {
        guard let builder = builders[kind] else {
            preconditionFailure("no row builder for \(kind.rawValue); the registry is built total")
        }
        return builder
    }

    /// The row, drawn by whichever builder owns its kind.
    func view(for row: TimelineRow) -> AnyView { builder(for: row.category)(row) }
}

/// The one row a channel's list draws, resolved through the registry rather than switched on here.
///
/// It exists as a type so the wiring is real on this commit: the column draws this, this resolves
/// through `RowRegistry`, and a test can hand it a registry of its own and watch the resolution
/// happen. `registry` is a property with a default rather than an environment value because the
/// column's list is the only production caller and a test's substitution should not depend on
/// SwiftUI's environment propagation to be observable.
struct TimelineRowSlot: View {

    let row: TimelineRow
    var registry: RowRegistry = .shared

    var body: some View { registry.view(for: row) }
}

/// C5's placeholder row, and the registry's default for every kind: category, timestamp, one-line
/// summary. Moved here from `ChannelColumnView` unchanged, because a default that lives beside the
/// registry is a default a leaf can read before it replaces it.
struct PlaceholderRowView: View {

    let row: TimelineRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.category.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(row.timestamp.map { Self.stamp.string(from: $0) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(row.summary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
