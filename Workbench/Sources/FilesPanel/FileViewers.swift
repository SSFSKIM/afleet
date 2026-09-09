// C7.5 spec Design §4: the native surfaces, in the composite's own order of preference.
import AppKit
import AVKit
import PDFKit
import QuickLookUI
import SwiftUI

/// Markdown, rendered rather than highlighted — item 25 asks for a `.md` to open in *its native
/// viewer*, and the same file's source is one toggle away in Monaco.
///
/// The text is the session's own copy of the file, so the viewer re-reads nothing: a refresh from
/// the watcher replaces it and the rendered page follows.
/// **Blocks are read here and inline syntax is left to `AttributedString`.** A single
/// `AttributedString(markdown:)` over the whole document draws headings, lists, quotes and fenced
/// code as one run of prose, which is not what item 25 asks a `.md` to open as. This leaf ships no
/// markdown engine and the app's own `Markdown` package is not a Workbench dependency, so the
/// block structure is read line by line — the six block kinds a document is mostly made of — and
/// each block's *text* still goes through `AttributedString` for emphasis, code spans and links.
struct MarkdownViewer: View {

    let text: String

    /// One block of a document, in the order it was written.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [String])
        case quote(String)
        /// A fenced block, verbatim: nothing inside a fence is read as structure.
        case code(String)
        case rule
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(Self.headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            Text(Self.inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                        Text(Self.inline(item)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.secondary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let source):
            Text(source)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .quaternarySystemFill))
        case .rule:
            Divider()
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    /// One block's own text, with inline syntax interpreted. A run the parser cannot finish is
    /// drawn as it was written rather than dropped, which is what a file halfway through being
    /// written looks like.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
    }

    /// The document's blocks, in order.
    ///
    /// Line-oriented and deliberately small: ATX headings, fenced code, blockquotes, bullet and
    /// ordered lists, thematic breaks, and paragraphs for everything else. Indented code blocks,
    /// setext headings, nested lists and tables are not read as their own blocks — they land in a
    /// paragraph or an item, which renders as the text the author wrote.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flush()
                var body: [Substring] = []
                index += 1
                while index < lines.count,
                      fenceMarker(lines[index].trimmingCharacters(in: .whitespaces)) != fence {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }   // the closing fence, when there is one
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var body: [String] = []
                while index < lines.count {
                    let quoted = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    body.append(String(quoted.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
                continue
            }

            if let first = listItem(trimmed) {
                flush()
                var items = [first.text]
                let ordered = first.ordered
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    if let item = listItem(next), item.ordered == ordered {
                        items.append(item.text)
                    } else {
                        // A continuation line belongs to the item above it.
                        items[items.count - 1] += " " + next
                    }
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(String(line))
            index += 1
        }
        flush()
        return blocks
    }

    /// The fence character of an opening or closing fence, or `nil` for a line that is not one.
    private static func fenceMarker(_ line: String) -> Character? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) { return marker.first }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let bare = line.filter { !$0.isWhitespace }
        guard bare.count >= 3, let first = bare.first, "-*_".contains(first) else { return false }
        return bare.allSatisfy { $0 == first }
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first?.isWhitespace == true || rest.isEmpty else { return nil }
        return .heading(level: hashes.count,
                        text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (false, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")",
              rest.dropFirst().first?.isWhitespace == true else { return nil }
        return (true, rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }
}

/// Images through `NSImage`.
///
/// A file that reaches here carries its format's own signature — `FileKind` vetoes a name whose
/// bytes contradict it — so the `nil` branch is the truncated-but-signed case, and it is a
/// panel-local state rather than a blank pane (root spec §10).
struct ImageViewer: View {

    let url: URL
    /// The digest of the bytes the session last read at `url` (see `PreviewIdentity`). It is not
    /// drawn: it is here so that a view whose stored properties are otherwise unchanged is
    /// re-evaluated when the file behind it is not.
    var revision: String = ""

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
        } else {
            EmptyState(text: "This image could not be opened.")
        }
    }
}

/// What a preview was last loaded from: the path, and something that changes when the bytes at
/// that path change.
///
/// A URL alone is not an identity for a file an agent is editing: the path does not move when the
/// contents do, so a view that compares URLs keeps the render of bytes that are gone. The session
/// re-reads the file on every refresh, and the digest of what it read is the value the view layer
/// passes as `revision` — `file.lastLoaded.digest`. An empty revision means "the URL is the whole
/// identity", which is what a caller that has nothing to pass gets.
struct PreviewIdentity: Equatable {
    let url: URL
    let revision: String
}

/// A view that remembers what it was loaded from, so an update that changes nothing loads nothing.
///
/// `updateNSView` takes a `Context` no test can build, so the decision and the load live here and
/// in `load(into:)` instead: a headless test drives the same code the view layer does.
@MainActor
protocol PreviewReloading: AnyObject {
    var identity: PreviewIdentity? { get set }
    /// How many times this view was loaded. `QLPreviewView` cannot be asked what it is showing,
    /// so the count is what a test asserts over.
    var loadCount: Int { get set }
}

extension PreviewReloading {
    /// True when `identity` is new, and records it. False leaves the view exactly as it was.
    func reload(for identity: PreviewIdentity) -> Bool {
        guard self.identity != identity else { return false }
        self.identity = identity
        loadCount += 1
        return true
    }
}

/// PDFs through PDFKit.
struct PDFViewer: NSViewRepresentable {

    let url: URL
    /// The digest of the bytes the session last read at `url` (see `PreviewIdentity`).
    var revision: String = ""

    func makeNSView(context: Context) -> ReloadingPDFView { makeView() }

    func updateNSView(_ nsView: ReloadingPDFView, context: Context) { load(into: nsView) }

    func makeView() -> ReloadingPDFView {
        let view = ReloadingPDFView()
        view.autoScales = true
        load(into: view)
        return view
    }

    func load(into view: ReloadingPDFView) {
        guard view.reload(for: PreviewIdentity(url: url, revision: revision)) else { return }
        view.document = PDFDocument(url: url)
    }
}

final class ReloadingPDFView: PDFView, PreviewReloading {
    var identity: PreviewIdentity?
    var loadCount = 0
}

/// Audio and video through AVKit. One player view, whose item follows the selection.
struct MediaViewer: NSViewRepresentable {

    let url: URL
    /// The digest of the bytes the session last read at `url` (see `PreviewIdentity`).
    var revision: String = ""

    func makeNSView(context: Context) -> ReloadingPlayerView { makeView() }

    func updateNSView(_ nsView: ReloadingPlayerView, context: Context) { load(into: nsView) }

    func makeView() -> ReloadingPlayerView {
        let view = ReloadingPlayerView()
        view.controlsStyle = .inline
        load(into: view)
        return view
    }

    func load(into view: ReloadingPlayerView) {
        guard view.reload(for: PreviewIdentity(url: url, revision: revision)) else { return }
        view.player?.pause()
        // A fresh `AVURLAsset` rather than `AVPlayer(url:)`, so the item is built from the bytes
        // that are there now.
        view.player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
    }
}

final class ReloadingPlayerView: AVPlayerView, PreviewReloading {
    var identity: PreviewIdentity?
    var loadCount = 0
}

/// Everything else macOS already previews, through Quick Look.
struct QuickLookViewer: NSViewRepresentable {

    let url: URL
    /// The digest of the bytes the session last read at `url` (see `PreviewIdentity`).
    var revision: String = ""

    func makeNSView(context: Context) -> ReloadingPreviewView { makeView() }

    func updateNSView(_ nsView: ReloadingPreviewView, context: Context) { load(into: nsView) }

    func makeView() -> ReloadingPreviewView {
        let view = ReloadingPreviewView(frame: .zero, style: .normal) ?? ReloadingPreviewView()
        load(into: view)
        return view
    }

    func load(into view: ReloadingPreviewView) {
        let wasShowingThisPath = view.identity?.url == url
        guard view.reload(for: PreviewIdentity(url: url, revision: revision)) else { return }
        // Assigning the same item again is not a reload; `refreshPreviewItem()` is the API for
        // "the contents under this item changed".
        if wasShowingThisPath { view.refreshPreviewItem() } else { view.previewItem = url as NSURL }
    }
}

final class ReloadingPreviewView: QLPreviewView, PreviewReloading {
    var identity: PreviewIdentity?
    var loadCount = 0
}

/// Design §4's last case: a file that is none of the viewers, or one above the panel's cap. It
/// draws its size and offers the Finder rather than loading bytes nobody meant to open.
struct UnsupportedFileViewer: View {

    let url: URL

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("There is no preview for this file.")
                .font(.callout)
            if let size {
                Text(size.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `stat(2)` rather than a read: the point of this surface is that the file is not opened.
    private var size: Int64? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return Int64(info.st_size)
    }
}
