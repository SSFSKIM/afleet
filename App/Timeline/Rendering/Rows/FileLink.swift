import Foundation
import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI

// MARK: - A path in a tool row is a link

/// The paths a tool row shows, and the `WorkspaceLink.file` each one opens (child spec §8, gate G3).
///
/// **Nothing here opens a descriptor.** `open(2)` on a directory of user content is TCC-gated on
/// macOS 26: the first call blocks on a consent dialog nobody in a test session can answer, and a
/// renderer that stats a path to canonicalise it while drawing a row would hang the app on the first
/// channel whose transcript names a file under Documents. `realpath(3)` resolves symlinks without
/// opening anything, and a path that does not resolve is standardised lexically instead.
enum FileLink {

    /// The paths one tool call names, with the line each should open at.
    ///
    /// The line is `ReadInput.offset` where the call carried one and **nil** where it did not — a
    /// fabricated line 1 would scroll a reader away from the top of a file they asked to see whole.
    static func paths(in call: ToolCallItem) -> [(path: String, line: Int?)] {
        switch call.input {
        case .read(let input): [(input.filePath, input.offset)]
        case .edit(let input): [(input.filePath, nil)]
        case .write(let input): [(input.filePath, nil)]
        case .glob(let input): input.path.map { [($0, nil)] } ?? []
        case .grep(let input): input.path.map { [($0, nil)] } ?? []
        default: []
        }
    }

    /// A path as a URL, canonicalised without a descriptor.
    ///
    /// `realpath` follows symlinks and resolves `..` for a path that exists; a path that does not
    /// exist — a file the engine wrote and the reader has since moved — is standardised lexically,
    /// so the link still points somewhere a router can reason about rather than being dropped.
    static func canonical(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved))
        }
        return URL(filePath: path).standardizedFileURL
    }

    /// Opens one path through contract Y7's link capability.
    ///
    /// Fire-and-forget on purpose: `LinkRouterCapability.open` is `async` and a row's tap gesture is
    /// not, and the router's own delivery is what reports failure — a row that awaited it would hold
    /// the main actor open for a panel that may be constructing a session.
    @MainActor
    static func open(_ path: String, line: Int?, in context: TimelineRenderContext) {
        guard let url = canonical(path) else { return }
        let links = context.links
        Task { await links.open(.file(url, line: line), from: .currentPanel) }
    }
}

// MARK: - The view

/// A path drawn as the link it is.
struct FileLinkLabel: View {

    let path: String
    var line: Int?

    @Environment(\.timelineContext) private var context

    var body: some View {
        Button {
            if let context { FileLink.open(path, line: line, in: context) }
        } label: {
            Text(line.map { "\(display) : \($0)" } ?? display)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.link)
        // A row outside the timeline's subtree has no context and therefore no capability to call
        // (contract Y7): the label draws, and does nothing, rather than calling a stand-in.
        .disabled(context == nil)
    }

    /// The last two components, which is what a reader recognises a file by; the full path is the
    /// link's own and never printed in a diagnostic (§11).
    private var display: String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}
