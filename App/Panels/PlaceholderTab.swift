import Foundation
import Observation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// C5's one shipped panel tab: the G4 witness and a standing diagnostic (spec §7).
///
/// It reads the `ChannelContext` back out — the session, the working directory, how many variables
/// X11's capture holds, and how many URLs X4's query returns — and renders them. That is its whole
/// purpose: a panel written against `PanelHostAPI` alone, proving every member of the context is
/// reachable from inside a tab.
///
/// **It registers under `.thread`, and C6 takes that id by `unregister(.thread)` and then its own
/// `register`.** `register` refuses a duplicate, so the pair is the handover; without it the
/// duplicate check would make the seven ids permanently first-come.
@MainActor
final class PlaceholderTab: PanelTab {

    let id: PanelTabID = .thread
    var title: String { id.defaultTitle }
    var systemImage: String { id.defaultSystemImage }

    init() {}

    /// Available for every channel. A tab that can render a context can render any context.
    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        PlaceholderTabSession()
    }

    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let session = session as? PlaceholderTabSession else { return AnyView(EmptyView()) }
        return AnyView(PlaceholderTabView(session: session, context: context))
    }
}

/// The placeholder's per-channel state: the recent-URL count, kept current from the feed.
///
/// It is where the count lives rather than the view's `@State` for the reason the whole session
/// contract exists — SwiftUI discards a subtree's state when the subtree unmounts, and a channel
/// switch unmounts this one. The host retains this object, so the count survives the switch.
@MainActor
@Observable
final class PlaceholderTabSession: PanelTabSession {

    private(set) var recentURLCount = 0

    @ObservationIgnored private var watcher: Task<Void, Never>?

    init() {}

    deinit { watcher?.cancel() }

    /// Reads the feed once and then follows it. Idempotent: a re-render does not start a second
    /// reader.
    func follow(_ feed: any RecentURLFeed, limit: Int) {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            let current = await feed.current(limit: limit)
            self?.recentURLCount = current.count
            for await urls in feed.updates {
                guard let self else { return }
                self.recentURLCount = urls.count
            }
        }
    }
}

/// The four readouts, and nothing else.
private struct PlaceholderTabView: View {

    let session: PlaceholderTabSession
    let context: ChannelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PanelTabID.thread.defaultTitle).font(.headline)
            Text("Contract X7's host is rendering this tab. C6 replaces it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            readout("Session", context.session.description)
            readout("Working directory", context.cwd.path)
            readout("Environment variables", "\(context.environment.variables.count)")
            readout("Recent URLs", "\(session.recentURLCount)")
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: context.key) {
            session.follow(context.recentURLs, limit: PanelHostModel.recentURLLimit)
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
