import SwiftUI
import ClaudeWire
import FleetKit

/// The bounded read the sent-file preview makes, off the main actor.
///
/// Separate from `FileTextReading` because the two reads are different in kind. A diff needs the
/// *whole* other side of a change and is prepared while a card is built; a row preview needs a head
/// and is drawn in a list, where a blocking read is a stall on every row on screen and, on a
/// consented directory, a wait on a system dialog (C5's TCC finding). So this one is `async`, takes
/// a byte bound, and is never called from a `body`.
protocol FileHeadReading: Sendable {
    /// At most `limit` bytes of the file at `path`, decoded as text.
    func head(atPath path: String, upTo limit: Int) async -> FileText
}

/// The shipped head reader.
///
/// **No descriptor is constructed here either.** The bound comes from mapping the file rather than
/// from seeking in it: `Data(contentsOf:options:.mappedIfSafe)` hands back a value whose pages are
/// faulted in as they are touched, so taking a prefix of it materialises the prefix and not the
/// file. Nothing here builds a `FileHandle`, an `InputStream` or a file descriptor, which is the
/// rule the diff reader beside it follows for the same reason.
///
/// The work runs off the main actor, which is the half a caller cannot arrange for itself: the
/// first `open(2)` on a path the user has not consented to does not return until they answer the
/// system dialog, and on the main actor that is a wedged window rather than a slow row.
struct FileHeadReader: FileHeadReading {

    func head(atPath path: String, upTo limit: Int) async -> FileText {
        await Task.detached(priority: .utility) {
            guard !path.isEmpty else { return FileText.unreadable }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .absent }
            guard !isDirectory.boolValue else { return .unreadable }
            guard let mapped = try? Data(contentsOf: URL(filePath: path), options: .mappedIfSafe) else {
                return .unreadable
            }
            return Self.decode(mapped.prefix(limit))
        }.value
    }

    /// A prefix of bytes as text. A bound cut in the middle of a multi-byte character leaves the
    /// tail undecodable, so up to three trailing bytes are dropped before the read is called
    /// unreadable — a whole file reported as unreadable because its 4096th byte fell mid-character
    /// would be a lie about the file.
    static func decode(_ bytes: Data) -> FileText {
        for dropped in 0...min(3, bytes.count) {
            if let text = String(data: bytes.dropLast(dropped), encoding: .utf8) { return .contents(text) }
        }
        return .unreadable
    }
}

/// Contract Y1's `sentFile` row: the files a turn sent to the engine, with a look at the first
/// of them (root acceptance item 29).
///
/// It reads **`row.item`** and switches on it (spec D1), like the decision row beside it.
///
/// **The preview is read off the main actor, bounded, and only after the row is on screen.** The
/// row draws inside SwiftUI's layout pass, so a read taken while the body is evaluated blocks that
/// pass — for every sent-file row in the list, and indefinitely where the path is under a directory
/// whose consent dialog is still unanswered. The read therefore arrives through `FileHeadReading`
/// from a `.task`, and the row draws whatever has arrived.
///
/// **The path the item carries is the model's, not the engine's.** `SendUserFileTool` resolves a
/// relative path against the channel's cwd and expands a leading `~` before it sends anything, but
/// the timeline item is built from the tool-use input, which is what the model wrote. Reading that
/// string as given resolves it against whatever the app's process directory happens to be — a
/// different file, or none. So the row resolves it the way the tool did.
///
/// **Open in Files is deferred to C6.1's merge, deliberately.** Item 29 spells the affordance
/// as a `WorkspaceLink.file(url, line: nil)` through the render context's `links` capability
/// (spec §"The sent-file item"), and that context — C6.1's `TimelineRenderContext` — is not on
/// `main`. Routing to `ChannelContext.links` from here instead would be the duplicate link
/// registry `HostLinkRouter` exists to prevent, so the paths render as selectable monospaced
/// text and the action lands with the value that carries the capability.
struct SentFileRowView: View {

    let row: TimelineRow
    /// The channel's working directory, which is what a relative path in the item resolves
    /// against. Nil where the host cannot name one; a relative path is then not read at all,
    /// because reading it against the app's own directory would preview a different file.
    var cwd: URL?
    /// The one read seam (see above). A test replaces it; production takes the shipped reader.
    var reader: any FileHeadReading = FileHeadReader()

    /// What has been read of the first file, or nil while nothing has been.
    @State private var loaded: FileText?

    /// How much of the first file the row shows. A head, not a file: this is a row in a list.
    static let previewLines = 8
    static let previewCharacters = 800
    /// What the read asks for. Comfortably more than `previewCharacters` of any encoding, and
    /// small enough that a multi-gigabyte file costs the same as a small one.
    static let previewBytes = 8 * 1024

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
            if let reading = Self.previewReading(loaded) {
                Text(reading)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .task(id: item.files.first) { loaded = await load(for: item) }
    }

    /// `delivered` as the item's status. Nil while the engine has said neither — an item that has
    /// not been acknowledged is not the same as one that was refused, and the row shows no status
    /// rather than guessing at one.
    static func status(of item: SentFileItem) -> String? {
        guard let delivered = item.delivered else { return nil }
        return delivered ? deliveredReading : notDeliveredReading
    }

    /// The first file's head, read the way the tool that sent it resolved the path. Nil for an
    /// item that names no file; `.unreadable` for a path this host cannot resolve, which the row
    /// then reports as a file it could not read rather than reading something else.
    func load(for item: SentFileItem) async -> FileText? {
        guard let first = item.files.first else { return nil }
        guard let path = Self.resolve(first, against: cwd) else { return .unreadable }
        return await reader.head(atPath: path, upTo: Self.previewBytes)
    }

    /// The item's path as a path on this machine — `SendUserFileTool`'s own rule, so the row
    /// previews the file the engine was sent: a leading `~` expands before the absolute test, an
    /// absolute path is taken as given, and anything else resolves against the channel's cwd.
    ///
    /// Nil when the path is relative and no cwd is known. That is the one case where the tool's
    /// rule cannot be followed, and following a different one would read a file nobody named.
    static func resolve(_ path: String, against cwd: URL?) -> String? {
        if let cwd { return SendUserFileTool.resolve(path, against: cwd).path }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(filePath: expanded).standardizedFileURL.path
    }

    /// What the row draws for what the read returned. Nil while nothing has been read — the row
    /// says nothing rather than reporting a file unreadable before anyone has tried to read it.
    static func previewReading(_ text: FileText?) -> String? {
        switch text {
        case .contents(let text): head(of: text)
        case .absent, .unreadable: unreadableReading
        case nil: nil
        }
    }

    /// The file's head: the first `previewLines` lines, capped at `previewCharacters`.
    static func head(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(previewLines)
        let head = lines.joined(separator: "\n")
        return head.count > previewCharacters ? String(head.prefix(previewCharacters)) : head
    }
}
