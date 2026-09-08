import SwiftUI
import FleetKit

/// The slash-command completion list above the field (spec §8.5, *The router UI*).
///
/// It draws `ComposerModel.completions(matching:)`, which is `CommandRouter.autocomplete` filtered by
/// what is typed. **No list is written here.** The names are the engine's own commands merged with
/// the local table minus everything the engine declared terminal-only — a command afleet would refuse
/// is never offered and then refused, which is the point of the subtraction.
///
/// Each row's second line is the local table's own `explanation` where the table has that name. A
/// command the engine offers and the table does not know shows the name alone rather than a sentence
/// this view invented about it (contract X10).
struct CommandCompletionView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        let names = model.completions(matching: model.draft)
        if model.isCompleting {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        Button {
                            // The name and a trailing space: the arguments each row parses are the
                            // router's business, and completing them here would be a second opinion
                            // about a grammar C4 owns.
                            model.draft = name + " "
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.callout.monospaced())
                                if let explanation = RouterTable.command(named: name)?.explanation {
                                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// `/rewind`'s dry run, in front of the user before anything is sent (`StrategyUI.confirm`).
///
/// It states counts and never a path: what a revert would change is *how many* files, insertions and
/// deletions (§11). The three choices are `RewindChoice`'s own cases, so a choice added to C4's enum
/// is a compile error here rather than a button that silently cannot be offered.
struct RewindConfirmationView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        if let preview = model.rewindPreview {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rewinding would change \(preview.filesChanged.count) file(s): "
                     + "\(preview.insertions) insertion(s), \(preview.deletions) deletion(s).")
                    .font(.callout)
                HStack {
                    Button("Conversation and Files") { model.answerRewind(.conversationAndFiles) }
                        .disabled(!preview.canRewind)
                    Button("Conversation Only") { model.answerRewind(.conversationOnly) }
                    Button("Cancel", role: .cancel) { model.answerRewind(.cancel) }
                }
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
