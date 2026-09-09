import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - The sent-file row, mounted on the render context

/// Contract Y1's `sentFile` row as the channel's list draws it: another leaf's row, plus the two
/// things it was written to wait for (root acceptance item 29, contract Y7).
///
/// The row itself — the count, the status, the caption and the bounded head of the first file — is
/// `SentFileRowView`, unchanged. What the mount adds is what a builder could not supply: the
/// channel's **cwd**, so a relative path is resolved the way `SendUserFileTool` resolved it before
/// it sent anything rather than against this process's directory; and ***Open in Files***, which is
/// a `WorkspaceLink.file` through the context's link capability and not a second link registry.
struct SentFileRow: View {

    let row: TimelineRow

    @Environment(\.timelineContext) private var context

    var body: some View {
        SentFileRowContent(row: row, context: context)
    }
}

/// What the sent-file row draws, over a context handed in rather than read from the environment.
/// Split out for `DecisionRowContent`'s reason: a property wrapper reads its default outside a
/// render pass, so a mount that only read one could not be shown to have been made.
struct SentFileRowContent: View {

    let row: TimelineRow
    let context: TimelineRenderContext?

    var body: some View {
        switch row.item {
        case .sentFile(let item):
            VStack(alignment: .leading, spacing: 3) {
                SentFileRowView(row: row, cwd: context?.cwd)
                ForEach(Self.links(of: item, in: context), id: \.self) { path in
                    FileLinkLabel(path: path, context: context)
                }
            }
        default:
            // The registry routes only `.sentFile` here; the placeholder is what a row nobody
            // claimed draws, and a row that vanished would be one nobody could see was missing.
            PlaceholderRowView(row: row)
        }
    }

    /// The files this item names, as paths on this machine — the tool's own resolution rule, so the
    /// link opens the file the engine was sent and not one that merely shares its name.
    ///
    /// Empty without a context: with no link capability there is nothing to open a path *with*, and
    /// the row's own monospaced paths are what remain. Empty, too, for a relative path on a channel
    /// with no cwd, which is the one case the tool's rule cannot be followed.
    static func links(of item: SentFileItem, in context: TimelineRenderContext?) -> [String] {
        guard let context else { return [] }
        return item.files.compactMap { SentFileRowView.resolve($0, against: context.cwd) }
    }
}
