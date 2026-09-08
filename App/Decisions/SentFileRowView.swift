import SwiftUI
import FleetKit

/// Contract Y1's `sentFile` row: the files a turn sent to the engine, with a look at the first
/// of them (root acceptance item 29).
///
/// It reads **`row.item`** and switches on it (spec D1), like the decision row beside it.
///
/// **The preview holds no descriptor on a user-content directory.** Every read goes through
/// `FileTextReading` — the seam Task 3's diffs already established — whose shipped conformer
/// settles existence with a `stat` and reads bytes with `String(contentsOf:encoding:)`, which
/// opens, reads and closes inside one call. C5's TCC finding is that `open(2)` on a consented
/// directory blocks the caller until the user answers the system dialog, so a second reading
/// route here would be a second way to wedge the row. There is one, and this is not it.
///
/// **Open in Files is deferred to C6.1's merge, deliberately.** Item 29 spells the affordance
/// as a `WorkspaceLink.file(url, line: nil)` through the render context's `links` capability
/// (spec §"The sent-file item"), and that context — C6.1's `TimelineRenderContext` — is not on
/// `main`. Routing to `ChannelContext.links` from here instead would be the duplicate link
/// registry `HostLinkRouter` exists to prevent, so the paths render as selectable monospaced
/// text and the action lands with the value that carries the capability.
struct SentFileRowView: View {

    let row: TimelineRow
    /// The one read seam (see above). A test replaces it; production takes the shipped reader.
    var reader: any FileTextReading = FileTextReader()

    /// How much of the first file the row shows. A head, not a file: this is a row in a list.
    static let previewLines = 8
    static let previewCharacters = 800

    static let deliveredReading = "Delivered."
    static let notDeliveredReading = "Not delivered."
    /// What the row says instead of a preview it could not read. Saying so is what keeps a
    /// fabricated head — an empty file drawn as if it were the file's contents — off the screen.
    static let unreadableReading = "This file could not be read, so no preview is shown."

    var body: some View {
        switch row.item {
        case .sentFile(let item):
            content(for: item)
        default:
            PlaceholderRowView(row: row)
        }
    }

    /// The count line, in the shape §11 asks reports to take: how many files, never which.
    static func countReading(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    @ViewBuilder
    private func content(for item: SentFileItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.countReading(item.files.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let status = Self.status(of: item) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let caption = item.caption, !caption.isEmpty {
                Text(caption).font(.callout).lineLimit(2).truncationMode(.tail)
            }
            ForEach(item.files, id: \.self) { path in
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            preview(of: item)
        }
        .padding(.vertical, 2)
    }

    /// `delivered` as the item's status. Nil while the engine has said neither — an item that has
    /// not been acknowledged is not the same as one that was refused, and the row shows no status
    /// rather than guessing at one.
    static func status(of item: SentFileItem) -> String? {
        guard let delivered = item.delivered else { return nil }
        return delivered ? deliveredReading : notDeliveredReading
    }

    @ViewBuilder
    private func preview(of item: SentFileItem) -> some View {
        if let first = item.files.first {
            switch reader.read(atPath: first) {
            case .contents(let text):
                Text(Self.head(of: text))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            case .absent, .unreadable:
                Text(Self.unreadableReading).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The file's head: the first `previewLines` lines, capped at `previewCharacters`.
    static func head(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(previewLines)
        let head = lines.joined(separator: "\n")
        return head.count > previewCharacters ? String(head.prefix(previewCharacters)) : head
    }
}
