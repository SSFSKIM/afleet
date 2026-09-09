import SwiftUI
import AfleetCore
import FleetKit

/// Activity (spec §5): one row per decision, rate-limit notice and authentication problem across
/// the whole fleet, with an inline answer for a plain permission ask.
///
/// It decides nothing. Which rows exist is `ActivityQuery`'s, which of them may be answered where
/// they stand is `ActivityModel`'s, and the card that answers them is `DecisionCardView`'s.
struct ActivityView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        Group {
            if let activity = app.activity {
                content(activity)
            } else {
                PlaceholderColumn(title: "Activity",
                                  detail: "Decisions, rate limits and authentication problems across the fleet arrive here.")
            }
        }
        .navigationTitle("Activity")
    }

    @ViewBuilder
    private func content(_ activity: ActivityModel) -> some View {
        VStack(spacing: 0) {
            if !activity.banners.isEmpty {
                BannerStack(activity: activity)
                Divider()
            }
            if activity.items.isEmpty {
                PlaceholderColumn(title: "Nothing waiting",
                                  detail: "Decisions, rate limits and authentication problems across the fleet arrive here.")
            } else {
                List(activity.items) { item in
                    ActivityRowView(item: item,
                                    title: title(of: item.key.session),
                                    activity: activity,
                                    shell: shell)
                }
                .listStyle(.inset)
            }
            if let failure = activity.answering.banner {
                Divider()
                Text(failure.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The channel's own title, never its session id: §11 keeps identifiers out of what is drawn as
    /// readily as out of what is reported.
    private func title(of session: SessionID) -> String {
        app.browser?.row(session)?.title ?? "A channel"
    }
}

/// Spike S-C5-1's in-app fallback, drawn. Used when system authorisation is absent or afleet is foregrounded.
private struct BannerStack: View {

    let activity: ActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activity.banners, id: \.identifier) { banner in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title).font(.callout.weight(.semibold))
                        Text(banner.body).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { activity.dismiss(banner) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
    }
}

/// One row. Two shapes: a plain permission ask, which is answered here through the shared card
/// component in its compact presentation, and everything else, which opens its channel — §5's rule
/// that Activity *lists* every decision kind and *answers* one (spec D4).
///
/// Nothing here builds a card or an answer. The buttons, the actions they emit and the bodies those
/// actions map to are `DecisionCardView`'s, `DecisionAction`'s and `DecisionCard.answer(_:)`'s
/// (contract Y2).
struct ActivityRowView: View {

    let item: ActivityItem
    let title: String
    let activity: ActivityModel
    let shell: ShellModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.kindLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let card = item.card {
                    // Keyed by the request. The card holds view state of its own and this row is
                    // one of a reused list; without an identity that moves with the request, a
                    // replacement request inherits the previous card's state.
                    DecisionCardView(card: card,
                                     presentation: .compact,
                                     in: item.key,
                                     answering: activity.answering)
                        .id(card.requestID.rawValue)
                } else {
                    Text(item.row.text.isEmpty ? item.kindLabel : item.row.text)
                }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if item.card == nil {
                Button("Go to channel") { shell.select(item.key.session) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The empty state the three column stubs share until their tasks land. One type so that three
/// files do not each grow their own, and so removing it is a compile error in every place that
/// still has one.
struct PlaceholderColumn: View {

    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
