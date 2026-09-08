import SwiftUI
import AfleetCore
import FleetKit

/// The conversation column: a channel's header and its timeline (spec §8).
///
/// **Superseded 2026-09-08 (C6.1 Task 2, C6.2).** The paragraph below is C5's and is refuted where
/// it says what this column does not have. The composer is mounted (C6.2) and the placeholder `List`
/// is gone (C6.1): the timeline is `TimelineListView`, an `NSTableView` virtualized by `ItemID` with
/// markdown, streaming and the scroll behaviours parity §41.8 names. What survives unchanged is the
/// column's *shape* — the header above, the placeholder branches, and the two lifecycle modifiers —
/// because three leaves edit this one body and each owns disjoint lines of it.
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
                ChannelTimelineColumn(model: app.timelines.model(for: row.key), row: row,
                                      composers: app.composers)
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
    /// C6.2's per-channel composers, handed down rather than read from the environment: the column
    /// already receives `AppModel` and threading the one registry it needs keeps the mount a plain
    /// value a test can walk, with no environment and no test-only seam.
    let composers: ComposerRegistry

    var body: some View {
        VStack(spacing: 0) {
            ChannelHeaderView(header: model.header)
            ChannelHeaderActionsSlot(key: row.key, row: row, composers: composers)
            Divider()
            if let failure = model.failure {
                PlaceholderColumn(title: "This channel could not be read", detail: failure)
            } else if model.rows.isEmpty {
                PlaceholderColumn(title: model.hasOpened ? "Nothing in this transcript yet" : "Opening…",
                                  detail: "This channel's history is read from its transcript on disk.")
            } else {
                // Every row is resolved through contract Y1's registry — the slot draws whichever
                // builder owns the item's kind. C6.1 has claimed eleven of the thirteen; `decision`
                // and `sentFile` are C6.3's and draw C5's placeholder row until that leaf lands.
                TimelineListView(model: model)
                    .id(row.key)
            }
            // The row's listing policy travels with the mount: a read-only row is a teammate's transcript, and the
            // composer is the one surface in this column that can write to a channel.
            ChannelComposerMount(key: row.key, cwd: row.cwd, readOnly: row.readOnlyReason, composers: composers)
        }
        // The header and the opening are two concerns, and keying one task on both was a defect.
        // The header has to follow a channel that goes busy, raises a banner or crashes while it
        // stays selected, so it moves on every change to §8's four live fields; the ingestion has to
        // run once per channel, so it is keyed by the channel alone. Folding the header into the
        // task's id made a live state change cancel an in-flight read — and cancellation reaches
        // `StreamIngestion.open`'s settle sleep, which half-closes the actor.
        .onChange(of: ChannelHeader(row: row), initial: true) { _, header in
            model.adopt(header)
        }
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
