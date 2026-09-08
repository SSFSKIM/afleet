import Foundation
import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - A tool call, and what it returned

/// The `toolCall` row (child spec §8): a header naming the tool, the paths it named as links, the
/// per-tool result form under it, and the raw text behind a disclosure.
///
/// An `Agent` call is not drawn here — it is a chip, §9's — and this row delegates to it rather than
/// switching on the name in two places. **The tool is named `Agent` and not `Task`**: the fixtures
/// and the parity map's tool tables carry `Agent`, and a chip keyed on the wrong string renders
/// nothing at all, which is why the routing is a named function a test can ask rather than a
/// condition buried in a body.
struct ToolCallRow: View {

    let item: ToolCallItem

    @Environment(\.timelineContext) private var context

    /// Whether this call draws the chip of §9 rather than the ordinary tool row.
    static func isAgentChip(_ item: ToolCallItem) -> Bool { item.name == "Agent" }

    var body: some View {
        if ToolCallRow.isAgentChip(item) {
            AgentChipRow(item: item)
        } else {
            RowFrame(author: ToolResultForms.userFacingName(of: item.name),
                     badge: ToolResultForms.mcpFamily(of: item.name)?.server,
                     timestamp: item.timestamp) {
                ToolCallHeader(item: item)
                ToolResultBody(id: item.id, form: ToolResultForms.form(for: item))
            }
        }
    }
}

/// What the call asked for: the command, the pattern, the query — and every path it named, as a
/// link (G3).
struct ToolCallHeader: View {

    let item: ToolCallItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let line = ToolCallHeader.subject(of: item) {
                Text(TextSanitiser.sanitise(line))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            ForEach(Array(FileLink.paths(in: item).enumerated()), id: \.offset) { _, path in
                FileLinkLabel(path: path.path, line: path.line)
            }
        }
    }

    /// The one line the terminal prints beside the tool's name. Parity §41.16.7 truncates Bash's at
    /// two lines and 160 characters; the layout above does the truncating, so this is the text.
    static func subject(of item: ToolCallItem) -> String? {
        switch item.input {
        case .bash(let input): input.command
        case .grep(let input): input.pattern
        case .glob(let input): input.pattern
        case .webFetch(let input): input.url
        case .webSearch(let input): input.query
        case .read, .write, .edit: nil            // the path is the subject, and it is a link
        default: nil
        }
    }
}

/// The result, in its form, with the engine's own text behind a disclosure.
struct ToolResultBody: View {

    let id: ItemID
    let form: ToolResultForm

    @Environment(\.timelineContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if form.isRunning { ProgressView().controlSize(.mini) }
                Text(form.headline)
                    .font(.caption)
                    .foregroundStyle(form.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                if let detail = form.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let raw = form.raw, !raw.isEmpty {
                Button {
                    context?.collapse.toggle(id)
                } label: {
                    Text(isExpanded ? "Hide output" : "Show output")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if isExpanded {
                    Text(TextSanitiser.sanitise(raw))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var isExpanded: Bool { context?.collapse.isCollapsed(id) ?? false }
}
