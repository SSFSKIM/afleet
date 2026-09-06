import SwiftUI
import ClaudeWire

/// G3a. The installed engine is older than the protocol baseline the fixtures were recorded on, so
/// afleet refuses to open a channel and says which two versions disagree.
///
/// Both versions are on the screen because "your Claude Code is too old" without them is a sentence
/// the user cannot act on, and because the baseline is a number this build carries rather than one
/// the engine reports.
struct UpgradeView: View {
    let installed: SemanticVersion
    let baseline: SemanticVersion
    let checkAgain: () async -> Void

    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Claude Code needs updating")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Installed").foregroundStyle(.secondary)
                    Text(installed.description).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Required").foregroundStyle(.secondary)
                    Text(baseline.description).font(.system(.body, design: .monospaced))
                }
            }

            Text("""
                 afleet speaks the headless stream-json protocol as it was recorded on \
                 \(baseline.description). It opens no channel against an older engine rather than \
                 guessing at what changed.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CommandRow(command: "claude update")

            HStack {
                Button("Check again") {
                    Task {
                        checking = true
                        await checkAgain()
                        checking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(checking)

                if checking { ProgressView().controlSize(.small) }
            }
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 300, alignment: .topLeading)
    }
}
