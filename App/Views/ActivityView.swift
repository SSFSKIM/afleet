import SwiftUI
import AfleetCore
import FleetKit

/// Activity (spec §5): one row per decision, rate-limit notice and authentication problem across
/// the whole fleet, with an inline answer for a plain permission ask.
///
/// It decides nothing. Which rows exist is `ActivityQuery`'s, which of them may be answered where
/// they stand is `ActivityModel`'s, and this file draws the answer and routes the two buttons.
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
            if let failure = activity.answerFailure {
                Divider()
                Text(failure)
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

/// Spike S-C5-1's in-app fallback, drawn. Present only when the system declined to deliver.
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

/// One row. Two shapes: a plain permission ask, which is answered here, and everything else, which
/// opens its channel — §5's rule that Activity *lists* every decision kind and *answers* one.
private struct ActivityRowView: View {

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
                Text(item.row.text.isEmpty ? item.kindLabel : item.row.text)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let ask = item.ask {
                Button("Allow once") { Task { await activity.allowOnce(ask, on: item.key) } }
                Button("Deny") { Task { await activity.deny(ask, on: item.key) } }
            } else {
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
