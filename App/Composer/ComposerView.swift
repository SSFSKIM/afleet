import SwiftUI

/// The composer, below the timeline in the channel column (spec §8.5). Thin over `ComposerModel`:
/// it draws the inline refusal, the completion list, `/rewind`'s confirmation, the field, and the
/// reason the field is closed. It decides nothing, and it writes no user-visible sentence of its own.
///
/// Mounted by `ChannelComposerMount`, below the channel's list.
struct ComposerView: View {

    @Bindable var model: ComposerModel

    /// The app, for the one thing the composer cannot resolve for itself: this channel's
    /// `ChannelContext`, which carries the link-routing capability `StrategyUI.open(url:)` hands a
    /// URL to. Read on appearance rather than in the body, and optional, so this view stays drawable
    /// outside a rendered scene — the mount test walks this body by reflection, where no environment
    /// has been installed.
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RefusalSurface(refusal: model.refusal, interception: model.lastInterception)
            CommandCompletionView(model: model)
            RewindConfirmationView(model: model)
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
        .onAppear {
            model.start()
            // The host builds a context for a channel it has drawn; nil for one it has not, and then
            // there is no Browser tab to route a URL to. Nothing is constructed here — the panel host
            // owns the context and this reads the one it already has.
            if model.context == nil { model.context = app?.panels.context(for: model.key) }
        }
        .onDisappear { model.stop() }
    }
}
