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
    /// Whether the app is the frontmost one. Not decoration: *Review trust in terminal* hands the
    /// project to a Terminal pane and the user grants trust **there**, so the moment afleet comes
    /// back to the front is the moment its verdict is most likely to be stale.
    let isApplicationActive: Bool
    let lifecycle: any LifecycleAPI
    let panels: any PanelHost
    /// Where a pane's exit is announced, so §6.11's trust review re-reads the verdict after the
    /// user has answered the engine's dialog rather than as soon as the pane was handed over.
    let paneExits: PaneExitAnnouncer?

    /// Built on the first evaluation and kept across them. Nil until then, which is what a column
    /// with no channel selected keeps.
    @State private var model: PrecommitModel?

    /// Everything one evaluation is a function of. Spelled as a value because it is what `.task(id:)`
    /// keys on: a verdict is read for a channel **and** a project — a decline is recorded against the
    /// project, and `ChannelRow.cwd` arrives with an index update rather than with the row — and it
    /// is re-read when the app regains the front, because trust may have been granted while it was
    /// away.
    struct EvaluationKey: Hashable {
        let channel: ChannelKey?
        let project: URL?
        let isApplicationActive: Bool
    }

    var evaluationKey: EvaluationKey {
        EvaluationKey(channel: channel, project: project, isApplicationActive: isApplicationActive)
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let model {
                if model.isHistoryOnly {
                    TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
                    Divider()
                }
                if model.isConsentDeferred {
                    ConsentBanner(isAnswering: model.isAnswering) { model.resumeConsent() }
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
        // **Presented by the evaluation it belongs to, not by a boolean.** The sheet's two answers
        // are closures, and one that captured A's servers while the model had moved on to B's
        // project would record consent for a pair the user was never shown — no out-of-order
        // completion needed, only a selection that moved while the sheet was up. Carrying the whole
        // `ConsentRequest` — servers and evaluation together — is what makes that pair impossible
        // to form, and `item:` is what takes a superseded sheet down: the id is the evaluation's,
        // so a new evaluation is a new item.
        // **Dismissal is *Not now*, and never a decline.** The binding is real rather than constant
        // now that the sheet has a third answer: a window closed by the user records nothing, leaves
        // the verdict untouched and hands the column the banner that brings the sheet back. Writing
        // `.claude/settings.local.json` stays reachable only by pressing *Decline* (§6.12).
        .sheet(item: Binding(get: { model?.consentRequest },
                             set: { presented in
                                 guard presented == nil, let model, let request = model.consentRequest else { return }
                                 model.notNow(request)
                             })) { request in
            if let model {
                ConsentSheet(servers: request.servers,
                             isAnswering: model.isAnswering,
                             accept: { model.accept(request) },
                             decline: { model.decline(request) },
                             notNow: { model.notNow(request) })
            }
        }
        // Keyed by everything the verdict is a function of. A selection that moves has to read the
        // new channel's verdict rather than keep drawing the old one's banner; a row whose cwd
        // arrives late has to be evaluated once it can be; and the return to the front after the
        // terminal handoff has to re-read trust nobody told this side about.
        .task(id: evaluationKey) {
            // **Invalidate first.** A column with no channel evaluates nothing, and a verdict left
            // standing would draw the last channel's banner over an empty column — and, worse, the
            // read still suspended inside `preconditions(for:)` would find its own generation
            // unchanged and publish into it.
            guard let channel, let project else {
                model?.invalidate()
                return
            }
            let model = self.model ?? PrecommitModel(lifecycle: lifecycle, panels: panels,
                                                      paneExits: paneExits)
            self.model = model
            await model.evaluate(channel: channel, project: project)
        }
    }
}
