import Foundation
import SwiftUI
import AfleetCore
import FleetKit

/// The two actions at the top of the tree, and what the user is asked before either happens
/// (child spec D9 and D14, gate G3).
///
/// **The copy is C6.2's and is spelled once.** `ComposerConfirmation` already carries
/// `.stopEverything` and `.backgroundAll` with their titles, messages and confirm titles, so this
/// value borrows those strings rather than writing a second set that could drift from them. What it
/// adds is the one sentence only this surface can write: how many live tasks *Stop everything* will
/// end.
///
/// **The dialog is the panel's own and does not route through the composer.** A panel is drawn in a
/// popped-out window where no composer exists, and a read-only channel has none at all — so a
/// confirm that depended on one would be missing in exactly the two places the button is still
/// there to press.
///
/// **The two are not symmetric and the copy must not pretend they are.** *Stop everything*
/// interrupts the turn and stops every registered task, and that work is not something `--resume`
/// can restore. *Background all* stops nothing.
enum AgentTreeConfirm: Hashable, Sendable {
    /// The count is the fleet's own census, taken before the dialog is raised. A **count** and never
    /// the ids (§6.3, §11): the number is what tells the user the size of what they are ending, and
    /// the list of ids tells them nothing they can act on.
    case stopEverything(liveTaskCount: Int)
    case backgroundAll

    /// C6.2's value, for its copy alone. Not a route through the composer — see the type's note.
    var confirmation: ComposerConfirmation {
        switch self {
        case .stopEverything: .stopEverything
        case .backgroundAll: .backgroundAll
        }
    }

    /// X5's member, and the whole of what the affirmative does (contract Y5). Neither is
    /// reimplemented here: `Fleet` owns what *Stop everything* means.
    var action: LifecycleAction {
        switch self {
        case .stopEverything: .stopEverything
        case .backgroundAll: .backgroundAll
        }
    }

    var title: String { confirmation.title }

    var confirmTitle: String { confirmation.confirmTitle }

    /// C6.2's sentence, and for *Stop everything* the census after it.
    var message: String {
        switch self {
        case .stopEverything(let count): confirmation.message + " " + Self.census(count)
        case .backgroundAll: confirmation.message
        }
    }

    /// What the census says, as a count. Zero is worth saying: a user pressing a destructive button
    /// on a channel with nothing running should be told that rather than left to assume the worst.
    static func census(_ count: Int) -> String {
        count == 0
            ? "Nothing is running in this channel right now."
            : "\(count) running task(s) end with it."
    }

    /// The labels the tree's own buttons carry. The ellipsis is the convention for an action that
    /// asks first, which is the whole point of both of these. Values rather than literals, so the
    /// bar and an assertion name the same string.
    static let stopEverythingTitle = "Stop Everything…"
    static let backgroundAllTitle = "Background All…"
}

/// The tree's top bar: the two channel-wide actions, the dialog that gates them, and the banner a
/// refusal leaves behind (gate G3, §6.4).
///
/// The affirmative **claims synchronously** and runs the work in a `Task`, which is C6.2's shape and
/// is load-bearing for its reason: SwiftUI sets the presentation binding false — which is the
/// cancel path — as the affirmative fires, so an action that read the waiting confirm when its task
/// began would read a value the dismissal had already cleared and do nothing at all.
struct AgentTreeActionBar: View {

    /// The channel's actions, not a node's: both are about the turn the channel is running, so they
    /// are drawn wherever the channel has a process — including a pane whose tree is still empty.
    let actions: AgentNodeActions

    var body: some View {
        HStack(spacing: 8) {
            Button(AgentTreeConfirm.stopEverythingTitle,
                   role: .destructive) { Task { await actions.requestStopEverything() } }
            if !actions.backgroundingDisabled {
                Button(AgentTreeConfirm.backgroundAllTitle) { actions.requestBackgroundAll() }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .confirmationDialog(actions.pending?.title ?? "",
                            isPresented: Binding(get: { actions.pending != nil },
                                                 set: { if !$0 { actions.cancelPending() } })) {
            if let pending = actions.pending {
                // Claimed here, synchronously, and run in the `Task` the claim starts.
                Button(pending.confirmTitle, role: .destructive) { actions.answerPending() }
            }
            Button("Cancel", role: .cancel) { actions.cancelPending() }
        } message: {
            Text(actions.pending?.message ?? "")
        }
    }
}
