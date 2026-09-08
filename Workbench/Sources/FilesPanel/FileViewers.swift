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
struct MarkdownViewer: View {

    let text: String

    var body: some View {
        ScrollView {
            if let attributed = Self.render(text) {
                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                EmptyState(text: "This file could not be rendered as Markdown.")
            }
        }
    }

    /// `AttributedString(markdown:)` with whitespace preserved, so a document's own line breaks
    /// survive into a `Text`. A document the parser cannot finish is returned as far as it got
    /// rather than thrown away, which is the difference between a rendered page and an empty one
    /// for a file that is halfway through being written.
    static func render(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible))
    }
}

/// Images through `NSImage`.
///
/// A file that reaches here carries its format's own signature — `FileKind` vetoes a name whose
/// bytes contradict it — so the `nil` branch is the truncated-but-signed case, and it is a
/// panel-local state rather than a blank pane (root spec §10).
struct ImageViewer: View {

    let url: URL

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

/// PDFs through PDFKit.
struct PDFViewer: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        guard nsView.document?.documentURL != url else { return }
        nsView.document = PDFDocument(url: url)
    }
}

/// Audio and video through AVKit. One player view, whose item follows the selection.
struct MediaViewer: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
    }
}

/// Everything else macOS already previews, through Quick Look.
struct QuickLookViewer: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard (nsView.previewItem as? URL) != url else { return }
        nsView.previewItem = url as NSURL
    }
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
