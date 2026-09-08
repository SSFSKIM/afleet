import SwiftUI

/// The composer, below the timeline in the channel column (spec §8.5). Thin over `ComposerModel`:
/// it draws the inline refusal, the field, and the reason the field is closed, and it decides
/// nothing.
///
/// Mounted by `ChannelComposerMount`, below the channel's list.
struct ComposerView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refusal = model.refusal {
                Text(refusal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if model.surface.isDisabled, let reason = model.surface.disabledReason {
                Label(reason, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ComposerField(text: $model.draft,
                          isEnabled: !model.surface.isDisabled,
                          onSend: { Task { await model.send() } })
                .frame(minHeight: 34, maxHeight: 160)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .opacity(model.surface.isDisabled ? 0.5 : 1)
            // Esc, Shift+Tab and Cmd+Shift+Esc. Beside the field rather than inside it because a
            // `.keyboardShortcut` is a command-table binding and `keyDown` is not.
            ComposerShortcutBar(model: model)
        }
        .padding(8)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
