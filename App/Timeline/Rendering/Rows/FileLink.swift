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
        paths(in: call.input)
    }

    /// The same reading, over a tool input that arrived without a call to belong to.
    ///
    /// A permission card holds the input the engine is *asking* about, and no `ToolCallItem` exists
    /// for it — the call has not happened. One derivation for both, so the path a card links and the
    /// path the row for that same call links later cannot disagree.
    static func paths(in input: ToolInput) -> [(path: String, line: Int?)] {
        switch input {
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
    ///
    /// **A relative path is resolved against `base`, the channel's own working directory, and
    /// against nothing else.** The engine writes whatever the model typed into a tool input, so a
    /// relative path is ordinary; resolving one against the app process's directory — which is what
    /// both `realpath(3)` and `URL(filePath:)` do with no base — names a file in a different
    /// project, or none. With no base to resolve against it is not resolved at all, which is the
    /// rule `TimelineRenderContext.cwd` already states: opening the wrong file is worse than
    /// opening none.
    static func canonical(_ path: String, relativeTo base: URL? = nil) -> URL? {
        guard !path.isEmpty else { return nil }
        var subject = path
        if !path.hasPrefix("/") {
            guard let base else { return nil }
            subject = base.appending(path: path).path
        }
        if let resolved = realpath(subject, nil) {
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved))
        }
        return URL(filePath: subject).standardizedFileURL
    }

    /// Opens one path through contract Y7's link capability.
    ///
    /// Fire-and-forget on purpose: `LinkRouterCapability.open` is `async` and a row's tap gesture is
    /// not, and the router's own delivery is what reports failure — a row that awaited it would hold
    /// the main actor open for a panel that may be constructing a session.
    ///
    /// **The destination is read here, synchronously, and not inside the task.** It is the modifier
    /// state of the click that caused this call (`LinkActivation`), and by the time a spawned task
    /// runs the user has let the key go — a Cmd-click would then open in the current panel about as
    /// often as it opened a window.
    @MainActor
    static func open(_ path: String, line: Int?, in context: TimelineRenderContext) {
        guard let url = canonical(path, relativeTo: context.cwd) else { return }
        let links = context.links
        let destination = LinkActivation.destination
        Task { await links.open(.file(url, line: line), from: destination) }
    }
}

// MARK: - The view

/// A path drawn as the link it is.
struct FileLinkLabel: View {

    let path: String
    var line: Int?
    /// The context, where the host that draws this label already holds one.
    ///
    /// **Not a second capability route.** It is the same value the environment carries, handed down
    /// by a host that read it once for the whole row rather than read again per label — which is
    /// also what makes an emission from a card assertable without a render pass, since a property
    /// wrapper reads its default outside one. A label drawn with none falls back to the environment,
    /// which is how every tool row draws its paths.
    var context: TimelineRenderContext?

    @Environment(\.timelineContext) private var environmentContext

    /// The context this label acts through: the host's, else the subtree's, else none at all.
    private var capabilities: TimelineRenderContext? { context ?? environmentContext }

    var body: some View {
        Button {
            if let capabilities { FileLink.open(path, line: line, in: capabilities) }
        } label: {
            // The label is a bare `Text` and every modifier is on the button, which draws the same
            // thing: a modifier applied inside the closure makes this a `Button<ModifiedContent<…>>`
            // and the affordance stops being reachable by the type a test can name — an assertion
            // that a link is *drawn* would then have to rebuild it, which asserts nothing.
            Text(line.map { "\(display) : \($0)" } ?? display)
        }
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .buttonStyle(.link)
        // A row outside the timeline's subtree has no context and therefore no capability to call
        // (contract Y7): the label draws, and does nothing, rather than calling a stand-in.
        .disabled(capabilities == nil)
    }

    /// The last two components, which is what a reader recognises a file by; the full path is the
    /// link's own and never printed in a diagnostic (§11).
    ///
    /// **Sanitised, because a filename is engine-supplied text** (§12). A tool input carries
    /// whatever the model typed, and a bidi override inside a name reverses what follows it on
    /// screen — `an-invented-file\u{202E}txt.exe` draws as though its extension were `.txt`. Only
    /// what is *drawn* is stripped: `path` stays as the call wrote it, so the link keeps opening
    /// the file the call actually named.
    private var display: String {
        let parts = path.split(separator: "/")
        return TextSanitiser.sanitise(parts.suffix(2).joined(separator: "/"))
    }
}
