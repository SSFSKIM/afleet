import SwiftUI
import AfleetCore
import FleetKit

/// The untrusted-project banner (root spec §6.11, acceptance G4).
///
/// While a project is untrusted the engine skips hooks, project plugins and project and local allow
/// rules, so a headless spawn would silently run a reduced harness. The channel therefore opens
/// **history-only**: the transcript is readable and nothing here offers to spawn.
///
/// The sentence names the project in words and never its path. `SpawnPrecondition.untrusted` carries
/// a root, §11 forbids a path in a surfaced string, and the root is not needed here anyway — the
/// terminal action goes through `openInTerminal`, which resolves the directory itself.
///
/// **afleet never writes trust.** The one action is *Review trust in terminal*, which runs `claude`
/// interactively in a Terminal pane; the user grants trust there, in Claude Code's own dialog.
struct TrustBanner: View {

    let isAnswering: Bool
    let review: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(PrecommitModel.untrustedSentence)
                    .font(.callout)
                Text("This channel is history-only until you trust it in Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Review trust in terminal") { review() }
                .disabled(isAnswering)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
