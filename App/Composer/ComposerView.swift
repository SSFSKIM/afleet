import SwiftUI

/// The composer, below the timeline in the channel column (spec §8.5). Thin over `ComposerModel`:
/// it draws the inline refusal, the field, and the reason the field is closed, and it decides
/// nothing.
///
/// Not mounted yet — Task 2 puts it in `ChannelColumnView`.
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
        }
        .padding(8)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
