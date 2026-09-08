import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// Everything this child draws around a channel's conversation rather than inside it: the §6.11
/// trust banner, the §6.12 consent sheet, and the line that says why the last one of those did not
/// happen (spec D3, acceptance G4).
///
/// **One entry point and one mount.** `App/Views/ChannelColumnView.swift` is C5's file that C6
/// replaces whole; D3 rules that this child inserts exactly one line into it, and this is what that
/// line applies. A second insertion — one per surface — is the shape D3 exists to prevent.
///
/// It is a `ViewModifier` because the sheet has to attach to the column rather than sit beside it,
/// and because the mount has to survive a nil selection: with no channel open there is nothing to
/// evaluate and the column is passed through untouched.
struct ChannelDecorations: ViewModifier {

    /// The selected channel, or nil when nothing is selected.
    let channel: ChannelKey?
    /// The channel's working directory. A decline is recorded against the project, and C4 resolves
    /// the canonical root from it; a row with no directory has no project to record against.
    let project: URL?
    let lifecycle: any LifecycleAPI
    let panels: any PanelHost

    /// Built on the first evaluation and kept across them. Nil until then, which is what a column
    /// with no channel selected keeps.
    @State private var model: PrecommitModel?

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let model {
                if model.isHistoryOnly {
                    TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
                    Divider()
                }
                if let banner = model.banner {
                    Text(banner.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
            content
        }
        .sheet(isPresented: .constant(model?.consentServers != nil)) {
            if let model, let servers = model.consentServers {
                ConsentSheet(servers: servers,
                             isAnswering: model.isAnswering,
                             accept: { model.accept(servers) },
                             decline: { model.decline(servers.map(\.name)) })
            }
        }
        // Keyed by the channel: the verdict is per channel, and a selection that moves has to read
        // the new one rather than keep drawing the old channel's banner.
        .task(id: channel) {
            guard let channel, let project else { return }
            let model = self.model ?? PrecommitModel(lifecycle: lifecycle, panels: panels)
            self.model = model
            await model.evaluate(channel: channel, project: project)
        }
    }
}
