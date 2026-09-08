import SwiftUI
import FleetKit

/// What the composer says above the field when something did not happen (spec §7.7, §8.5).
///
/// Two sentences reach it and they come from two different places, which is the whole reason this is
/// one view and not two labels: a **local refusal** is `RouterTable`'s own copy, rendered verbatim
/// because contract X10 makes the table the single source; a **lifecycle refusal** is afleet's
/// facade explaining itself, which no table describes. The view writes neither, and a reviewer
/// checking X10 has one place to look.
///
/// The drift interception is shown here too. §7.7 says the engine's refusal is replaced by afleet's
/// explanation of what the command does here or why it is absent, and the replacement is the
/// interceptor's — this view is the surface, not a second opinion about the wording.
struct RefusalSurface: View {

    /// `RouterTable.explanation(forTerminalOnly:)`, `…(forUnknownMode:)`, or
    /// `ComposerModel.explanation(of: LifecycleError)`. Never a sentence composed here.
    let refusal: String?
    /// The most recent replaced engine refusal, if this channel has had one.
    let interception: Intercepted?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refusal {
                Label {
                    Text(refusal)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let interception {
                Label {
                    Text(interception.replacement)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}

/// What *Edit* says when the conversation was not rewound (spec §8.5, gate G4).
///
/// A view of its own rather than a third branch of `RefusalSurface`, because the two say different
/// things: a refusal is a line that did not run, and this is a rewind that was refused **and a fork
/// that was opened instead** — a thing that happened, which the user has to be told about because
/// the conversation they are now typing into is not the one they were reading.
///
/// The sentence is `ComposerModel`'s (`forkNote`, `noForkPointNote`, `explanation(of:)`); nothing is
/// composed here.
struct EditNoteSurface: View {

    let note: String?

    var body: some View {
        if let note {
            Label {
                Text(note)
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}
