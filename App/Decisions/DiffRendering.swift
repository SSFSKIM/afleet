import SwiftUI
import ClaudeWire

/// How a card draws a change to a file.
///
/// The seam exists because the drawing is replaceable and the card is not: C7.2's
/// `MonacoEditorView` becomes a second conformer and every caller here keeps compiling. The
/// member takes the two sides and the path and nothing else — no tool input, no card, no
/// channel — so a conformer cannot reach back into the decision it is drawing, and so the
/// card's own code never learns which conformer it holds.
@MainActor
protocol DiffRendering: Sendable {
    func view(before: String, after: String, path: String) -> AnyView
}

/// One line of a rendered change.
enum DiffLineKind: Hashable, Sendable { case added, removed, context }

/// A line as the renderer will draw it, with the numbers it carries on each side.
struct DiffLine: Hashable, Sendable {
    var kind: DiffLineKind
    var text: String
    var beforeNumber: Int?
    var afterNumber: Int?
}

// MARK: - Reading the file the change is against

/// What one read of a path found.
///
/// `absent` and `unreadable` are kept apart deliberately. A `Write` to a path that does not
/// exist is a new file and diffs against empty; a path that exists and cannot be read is not a
/// new file, and drawing it as one would show a whole existing file as additions.
enum FileText: Hashable, Sendable {
    case contents(String)
    case absent
    case unreadable
}

/// The one seam every file read on this path goes through, so a test can assert what was read
/// and what was not.
@MainActor
protocol FileTextReading: Sendable {
    func read(atPath path: String) -> FileText
}

/// The shipped reader.
///
/// **No descriptor is ever held on a user-content directory** (C5's TCC finding: `open(2)` on
/// such a path is gated by the consent dialog and blocks the caller until the user answers).
/// Existence is settled by a `stat`, through `FileManager.fileExists`, and the bytes come from
/// `String(contentsOf:encoding:)`, which opens, reads and closes inside one call and hands back
/// a value. Nothing here constructs a `FileHandle`, an `InputStream` or a file descriptor.
struct FileTextReader: FileTextReading {
    func read(atPath path: String) -> FileText {
        guard !path.isEmpty else { return .unreadable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .absent }
        guard !isDirectory.boolValue else { return .unreadable }
        guard let text = try? String(contentsOf: URL(filePath: path), encoding: .utf8) else { return .unreadable }
        return .contents(text)
    }
}

// MARK: - The two sources

/// One labelled block of the tool's own input, shown when there is no diff to draw.
struct VerbatimSection: Hashable, Sendable {
    var label: String
    var text: String
}

/// What the card should draw for a change: a diff, or the input as the engine sent it.
enum DiffPreparation: Hashable, Sendable {
    case diff(before: String, after: String, path: String)
    case verbatim(path: String, sections: [VerbatimSection])
}

/// Turns a `Write` or an `Edit` into the two sides of a diff (spec D9).
enum DiffSource {

    /// Lines of the file kept either side of an `Edit`, so the change is read in its place.
    static let contextLines = 3

    /// `nil` for a tool whose input is not a change to a file.
    @MainActor
    static func prepare(_ input: ToolInput, reader: some FileTextReading) -> DiffPreparation? {
        switch input {
        case .write(let write):
            switch reader.read(atPath: write.filePath) {
            case .contents(let current):
                return .diff(before: current, after: write.content, path: write.filePath)
            case .absent:
                // Nothing there yet, so the whole write is an addition (spec D9).
                return .diff(before: "", after: write.content, path: write.filePath)
            case .unreadable:
                // A file that exists and cannot be read is **not** a new file. Diffing it
                // against empty would draw an overwrite of an existing file as a fresh one.
                return .verbatim(path: write.filePath,
                                 sections: [VerbatimSection(label: "New contents", text: write.content)])
            }
        case .edit(let edit):
            switch reader.read(atPath: edit.filePath) {
            case .contents(let current):
                let sides = inPlace(old: edit.oldString, new: edit.newString, within: current)
                return .diff(before: sides.before, after: sides.after, path: edit.filePath)
            case .absent:
                // The two strings are the whole change; there is no file to take context from.
                return .diff(before: edit.oldString, after: edit.newString, path: edit.filePath)
            case .unreadable:
                return .verbatim(path: edit.filePath,
                                 sections: [VerbatimSection(label: "Replacing", text: edit.oldString),
                                            VerbatimSection(label: "With", text: edit.newString)])
            }
        default:
            return nil
        }
    }

    /// `old` and `new` set back into the file, with `contextLines` of the file either side.
    ///
    /// When the file does not contain `old` — a stale card, or a replacement the engine will
    /// make somewhere this build cannot see — the two strings are diffed on their own rather
    /// than against a guess at where they belong.
    static func inPlace(old: String, new: String, within file: String) -> (before: String, after: String) {
        guard let range = file.range(of: old) else { return (old, new) }
        let head = String(file[..<range.lowerBound]).components(separatedBy: "\n")
        let tail = String(file[range.upperBound...]).components(separatedBy: "\n")
        let leading = head.suffix(min(head.count, contextLines + 1)).joined(separator: "\n")
        let trailing = tail.prefix(min(tail.count, contextLines + 1)).joined(separator: "\n")
        return (leading + old + trailing, leading + new + trailing)
    }
}

// MARK: - Drawing it

/// The card's view over a change: a diff through whichever `DiffRendering` is installed, or the
/// tool's input verbatim with a line saying why there is no diff.
struct DiffView: View {

    let input: ToolInput
    var reader: any FileTextReading = FileTextReader()
    var renderer: any DiffRendering = AttributedDiffRenderer()

    /// What a card says instead of a diff. The engine's request is still shown in full; what is
    /// missing is the other side of it, and saying so is what keeps a fabricated diff off the
    /// screen.
    static let unreadableNotice = "This file could not be read, so the tool's input is shown instead of a diff."

    var body: some View {
        switch DiffSource.prepare(input, reader: reader) {
        case .diff(let before, let after, let path):
            renderer.view(before: before, after: after, path: path)
        case .verbatim(_, let sections):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.unreadableNotice).font(.caption).foregroundStyle(.secondary)
                ForEach(sections, id: \.self) { section in
                    Text(section.label).font(.caption).foregroundStyle(.secondary)
                    Text(section.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        case nil:
            EmptyView()
        }
    }
}
