import SwiftUI

/// *Send message* on a node (root §8.8, item 51): a field, a *Send*, and a sentence saying what the
/// action actually is.
///
/// **The sentence is not decoration.** What the user is about to do is ask the main agent to relay
/// this message with its `SendMessage` tool — there is no host-initiated resume or messaging control
/// in the protocol (parity §18.25) — and the model may decline, may name another agent, or may be
/// refused. Saying so here is what makes the *Not delivered* readings afterwards a state the user
/// was told about rather than a failure they discover.
///
/// The sheet is presented by the node's action bar and holds only the draft, because a draft is
/// per-press: a message the user typed and did not send is not a thing to carry to another node.
struct SendMessageSheet: View {

    let content: AgentNodeContent
    let actions: AgentNodeActions
    /// Dismisses the sheet. Injected rather than reached through `@Environment(\.dismiss)` so the
    /// send path is a function a test can drive without a presentation.
    let dismiss: () -> Void

    @State private var text = ""
    /// A send is on the wire. The button disables on it, so two presses send once.
    @State private var sending = false
    /// Why the last press did not send, or nil. Stored rather than read out of `actions` at draw
    /// time so the sentence the sheet is about to draw is a value, and cleared on the next press.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send a message to \(AgentNodeRow.title(content))")
                .font(.headline)
            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 360, minHeight: 120)
                .border(.quaternary)
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    /// What the action is, in the words the decision log settles on: a request to the model, not a
    /// delivery.
    static let explanation = """
    afleet asks Claude to relay this with its SendMessage tool — there is no direct channel to an \
    agent. The message shows its delivery state in the conversation, and offers a retry if it does \
    not arrive.
    """

    /// **The draft outlives the press until the send is accepted.**
    ///
    /// The field is the only copy of what the user typed: nothing has been recorded yet — the relay
    /// record opens only after `sendPrompt` answers — so a sheet that dismissed before awaiting the
    /// answer destroys the message on every refusal, with no draft to retry from and no record the
    /// *Retry* on a row could reach. It is `ComposerModel.post(_:)`'s rule over this leaf's subject:
    /// the refusal is drawn and the text stays where it was.
    private func send() {
        guard !sending else { return }
        sending = true
        refusal = nil
        let draft = text
        Task {
            let refused = await Self.send(draft, to: content, through: actions)
            sending = false
            guard let refused else { return dismiss() }
            refusal = refused
        }
    }

    /// One press, as a function: nil where the send was accepted and the sheet may close, else the
    /// sentence to draw beside the draft that is still in the field.
    ///
    /// Static and given its collaborators, so the decision the sheet makes is one a test can drive
    /// without a presentation — a `@State` draft is reachable from nothing else.
    @MainActor
    static func send(_ draft: String, to content: AgentNodeContent,
                     through actions: AgentNodeActions) async -> String? {
        if await actions.sendMessage(draft, to: content) { return nil }
        // The refusal the send left behind — afleet's own for a `LifecycleError`, the engine's own
        // for anything else — and this leaf's sentence for the refusals that raise no banner at
        // all: a press that reported nothing would be the silent failure in its quietest form.
        return actions.banner?.text ?? unsent
    }

    /// What a press that sent nothing and said nothing says. `ComposerModel`'s wording, because it
    /// is the same fact: the message is still where the user typed it.
    static let unsent = "The message was not sent; it is still in the field."
}
