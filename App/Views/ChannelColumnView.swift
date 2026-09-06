import SwiftUI
import AfleetCore
import FleetKit

/// The conversation column: a channel's header and its timeline (spec §8).
///
/// **Deliberately plain, and replaced whole by C6.** A header showing origin, presence, banner and
/// system item; a list of item category, timestamp and a one-line summary. No composer, no
/// markdown, no clustering, no streaming and no cards — each of those is C6's, and each would have
/// to be removed from here first. What this view is for is item 1's UI half: proving that a
/// channel's history reaches the screen from disk.
///
/// It reaches its model through `app.timelines`, the single app-scoped `ChannelTimelineRegistry`,
/// and never constructs one: the panel host's recent-URL feed reads that same registry, and a model
/// made here would be a second one nothing else observes.
struct ChannelColumnView: View {

    @Bindable var app: AppModel
    @Bindable var shell: ShellModel
    let workspace: Workspace

    var body: some View {
        Group {
            if let row {
                ChannelTimelineColumn(model: app.timelines.model(for: row.key), row: row)
            } else {
                PlaceholderColumn(title: "No channel selected",
                                  detail: "Pick a channel in the sidebar, or press Command-K.")
            }
        }
        .navigationTitle(row?.title ?? "afleet")
    }

    /// The selected row, resolved through the browser rather than carried, so a row that changed
    /// since the click is the one drawn.
    private var row: ChannelRow? {
        guard let session = shell.focus.session else { return nil }
        return app.browser?.row(session)
    }
}

/// One channel, drawn. Split out so the `task(id:)` that opens the channel is keyed by the channel
/// and re-runs when the selection moves rather than on every parent body evaluation.
private struct ChannelTimelineColumn: View {

    let model: ChannelTimelineModel
    let row: ChannelRow

    var body: some View {
        VStack(spacing: 0) {
            ChannelHeaderView(header: model.header)
            Divider()
            if let failure = model.failure {
                PlaceholderColumn(title: "This channel could not be read", detail: failure)
            } else if model.rows.isEmpty {
                PlaceholderColumn(title: model.hasOpened ? "Nothing in this transcript yet" : "Opening…",
                                  detail: "This channel's history is read from its transcript on disk.")
            } else {
                List(model.rows) { TimelineRowView(row: $0) }
                    .listStyle(.inset)
            }
        }
        // Keyed by the channel: switching channels opens the new one, and coming back to a channel
        // whose model is already open costs a header refresh and nothing more.
        .task(id: row.key) { await model.open(row) }
    }
}

/// Origin, presence, banner and system item — §8's four, and the title.
private struct ChannelHeaderView: View {

    let header: ChannelHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let glyph = header.glyph {
                    Image(systemName: glyph.systemImage)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(glyph.rawValue)
                }
                Text(header.title).font(.headline)
                Spacer(minLength: 8)
                Text(Self.presenceLabel(header.presence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let banner = header.banner {
                Label(Self.bannerLabel(banner), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let item = header.systemItem {
                Label(Self.systemItemLabel(item), systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every label below names a kind and never a path, a holder's identifier or a session id
    /// (§11). `contended` and `heldElsewhere` carry a `HolderSet`, and what is drawn of it is the
    /// count.
    static func presenceLabel(_ presence: Presence?) -> String {
        switch presence {
        case .none: "no live state"
        case .some(.idle): "idle"
        case .some(.busy): "busy"
        case .some(.waiting(let what)): what.map { "waiting: \($0)" } ?? "waiting"
        case .some(.unknown): "unknown"
        }
    }

    static func bannerLabel(_ banner: ChannelBanner) -> String {
        switch banner {
        case .releasedToTerminal: "Opened in your terminal; afleet released this session."
        case .contended(let holders): "\(holders.foreign.count) other process(es) hold this session."
        case .settingDidNotSurvive(let name): "The setting \(name) did not survive the restart."
        case .mcpDeclineRefused(let reason): "The project-server decline was refused: \(reason)."
        case .managedSettingsPending: "Managed settings have not been applied yet."
        case .untrusted: "This project directory is not trusted."
        case .heldElsewhere(let holders): "Held by \(holders.foreign.count) other process(es)."
        }
    }

    static func systemItemLabel(_ item: SystemItem) -> String {
        switch item {
        case .crashed: "This channel's process crashed."
        case .wedged(let trace, _): "This channel's process did not stop after \(trace.steps.count) step(s)."
        case .forkIdentityTimedOut: "A fork never announced its session id and was ended."
        }
    }
}

/// One line: category, timestamp, one-line summary.
private struct TimelineRowView: View {

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
