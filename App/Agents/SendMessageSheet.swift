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
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func send() {
        let draft = text
        dismiss()
        Task { await actions.sendMessage(draft, to: content) }
    }
}
