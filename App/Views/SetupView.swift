import SwiftUI
import AppKit

/// G3c. The screen a launch that could not reach a workspace ends on: what is wrong, the one
/// command that fixes it, and *Check again*, which re-runs the whole launch.
///
/// The commands are literal strings the user can copy, not computed ones. A command afleet
/// assembled from the paths it happens to have resolved is a command the user cannot check against
/// anything, and two of these five states exist precisely because a path was not what afleet
/// thought it was.
struct SetupView: View {
    let state: SetupState
    let checkAgain: () async -> Void

    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("afleet cannot start")
                .font(.title2.weight(.semibold))

            Text(headline)
                .font(.body)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command {
                CommandRow(command: command)
            }

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

    private var headline: String {
        switch state {
        case .engineMissing:
            "No Claude Code engine was found."
        case .engineUnreadable:
            "The Claude Code engine did not report a version."
        case .notSignedIn:
            "This Claude Code config home has no signed-in account."
        case .writeRootInsideConfigHome(let root, _):
            "afleet's \(root == .store ? "state" : "diagnostics") directory overlaps the Claude Code config home."
        case .storeUnavailable:
            "afleet could not open its own state directory."
        }
    }

    private var detail: String {
        switch state {
        case .engineMissing:
            """
            afleet looked on the PATH captured from your login shell, at ~/.local/bin/claude, and \
            at the Developer binary override. Install the engine, then check again.
            """
        case .engineUnreadable(let output):
            """
            The version probe ran and answered with something that is not a version. \
            It said: \(output.isEmpty ? "nothing at all" : output)
            """
        case .notSignedIn:
            """
            afleet reads the account from the config home and never writes to it. Sign in with the \
            command below, then check again.
            """
        case .writeRootInsideConfigHome:
            """
            afleet never writes inside a Claude Code config home. Point CLAUDE_CONFIG_DIR somewhere \
            outside, and not containing, ~/Library/Application Support/afleet or ~/Library/Logs/afleet, \
            then check again. Nothing was created.
            """
        case .storeUnavailable(let reason):
            "The state store refused to open: \(reason)."
        }
    }

    /// Nil for the two states no single command fixes.
    private var command: String? {
        switch state {
        case .engineMissing, .engineUnreadable:
            "npm install -g @anthropic-ai/claude-code"
        case .notSignedIn:
            "claude"
        case .writeRootInsideConfigHome, .storeUnavailable:
            nil
        }
    }
}

/// A command in a monospaced box with a copy button, shared by the setup and upgrade screens.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
        }
    }
}
