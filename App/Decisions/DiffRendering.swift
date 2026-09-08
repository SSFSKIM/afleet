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
///
/// `async`, and deliberately not `@MainActor`: the read is the thing the render pass must not
/// contain (scalpel-5#1), and a member a card *can* call from `body` is one a card eventually will.
protocol FileTextReading: Sendable {
    func read(atPath path: String) async -> FileText
}

/// The one bounded read both file readers in this module are built from.
///
/// **The descriptor lives inside this call and the read has a ceiling** — the amended user-content
/// rule, and the shape C7.3's `GitDiff.workingTreeFile` already holds. The rule it replaces said no
/// descriptor at all, which forced `Data(contentsOf:)` and `String(contentsOf:)`: both are
/// unbounded, and both answer a question about a *name* that a preceding `fileExists` asked about a
/// different moment, so a local writer can substitute something else at the name in between. One
/// `open` answers all of it.
///
/// - `O_NOFOLLOW`: a symbolic link at the final component is refused by the call that would
///   otherwise have followed it, so there is no check-then-read window to slip through.
/// - `O_NONBLOCK`: a FIFO at the path returns rather than parking the reader until a writer appears.
/// - `O_CLOEXEC`: no process this app spawns while the read runs inherits the descriptor.
///
/// `fstat` on the opened descriptor is what makes "a regular file" true of the thing being read
/// rather than of whatever the name pointed at a moment earlier.
enum BoundedFileRead {

    /// What one bounded read found. `truncated` is the fact a caller cannot recover afterwards: a
    /// row preview may take a head of a large file and a diff may not — half a file diffed against
    /// a whole one draws the missing half as a deletion nobody proposed.
    enum Outcome: Sendable {
        case bytes(Data, truncated: Bool)
        case absent
        case unreadable
    }

    static func read(atPath path: String, upTo limit: Int) -> Outcome {
        guard !path.isEmpty, limit > 0 else { return .unreadable }
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unreadable }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit, 64 * 1024))
        while bytes.count < limit {
            let wanted = min(buffer.count, limit - bytes.count)
            let got = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if got < 0 {
                // A signal interrupting the read says nothing about the file; anything else does.
                if errno == EINTR { continue }
                return .unreadable
            }
            if got == 0 { return .bytes(bytes, truncated: false) }
            bytes.append(contentsOf: buffer[0..<got])
        }
        // The ceiling was reached. Whether anything is left is one more read rather than a guess
        // from `st_size`, which a file being appended to has already outgrown.
        var probe: UInt8 = 0
        let more = withUnsafeMutablePointer(to: &probe) { Darwin.read(descriptor, $0, 1) }
        return .bytes(bytes, truncated: more > 0)
    }
}

/// The shipped reader: the **whole** other side of a change, up to a ceiling.
///
/// A diff needs both sides entire, so a file past `limitBytes` is `unreadable` rather than
/// truncated — the card then shows the tool's own input and says why there is no diff, which is
/// true, where a diff against a head would be a change nobody proposed. The ceiling exists because
/// both sides end up in one card: a `Write` over a multi-gigabyte path must not be the thing that
/// exhausts the app.
struct FileTextReader: FileTextReading {

    /// Generous for the unit a `Write` or an `Edit` deals in, and far below what a window can hold.
    /// Injectable so a test can reach the ceiling without writing 16 MiB.
    static let defaultLimitBytes = 16 * 1024 * 1024

    var limitBytes: Int = FileTextReader.defaultLimitBytes

    func read(atPath path: String) async -> FileText {
        let limit = limitBytes
        return await Task.detached(priority: .userInitiated) { Self.bounded(atPath: path, upTo: limit) }.value
    }

    static func bounded(atPath path: String, upTo limit: Int) -> FileText {
        switch BoundedFileRead.read(atPath: path, upTo: limit) {
        case .absent: return .absent
        case .unreadable: return .unreadable
        case .bytes(let data, let truncated):
            guard !truncated, let text = String(data: data, encoding: .utf8) else { return .unreadable }
            return .contents(text)
        }
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

    /// True for the tool inputs `prepare` can answer. A card asks this synchronously so that a tool
    /// which is not a change to a file draws nothing at all rather than an empty container waiting
    /// for a preparation that will never arrive.
    static func changesAFile(_ input: ToolInput) -> Bool {
        switch input {
        case .write, .edit: true
        default: false
        }
    }

    /// What makes two tool inputs the same *source* for the purpose of preparing one.
    ///
    /// The path and the sizes of the strings the tool carries, rather than the strings themselves:
    /// this is recomputed on every render pass, and hashing a whole file's worth of content there is
    /// the cost the preparation was moved off the main actor to avoid. Two different changes to one
    /// path whose inputs agree on every length are the only collision, and a card's input does not
    /// change under it — a new request is a new card.
    static func identity(of input: ToolInput) -> String {
        switch input {
        case .write(let write):
            "write\u{1}\(write.filePath)\u{1}\(write.content.utf8.count)"
        case .edit(let edit):
            "edit\u{1}\(edit.filePath)\u{1}\(edit.oldString.utf8.count)\u{1}\(edit.newString.utf8.count)"
                + "\u{1}\(edit.replaceAll == true)"
        default:
            "none"
        }
    }

    /// `nil` for a tool whose input is not a change to a file.
    static func prepare(_ input: ToolInput, reader: some FileTextReading) async -> DiffPreparation? {
        switch input {
        case .write(let write):
            switch await reader.read(atPath: write.filePath) {
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
            switch await reader.read(atPath: edit.filePath) {
            case .contents(let current):
                let sides = inPlace(old: edit.oldString, new: edit.newString, within: current,
                                    everywhere: edit.replaceAll == true)
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
    ///
    /// **`everywhere` is `Edit.replace_all`, and it changes the shape of the answer rather than
    /// its wording.** A `replace_all` changes every occurrence, which can be anywhere in the file;
    /// there is no one place to take context around, and a window drawn around the first match
    /// would tell the user the change is smaller than it is. So that arm diffs the whole file
    /// against the whole result — which is exactly what the `Write` arm above already does, for
    /// the same reason: the card shows the change the tool would make, not a sample of it.
    static func inPlace(old: String, new: String, within file: String,
                        everywhere: Bool = false) -> (before: String, after: String) {
        guard !old.isEmpty, file.contains(old) else { return (old, new) }
        if everywhere {
            return (file, file.replacingOccurrences(of: old, with: new))
        }
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
///
/// **The preparation is not part of the render pass** (scalpel-5#1). `body` is re-evaluated on every
/// invalidation of anything the card observes — a streaming preview, a sibling row, a window
/// resize — and it used to perform the whole-file read *and* the line-level `difference` each time,
/// on the main actor. The read is now awaited once per source through `.task(id:)` and the
/// difference is cached by the digest of the two sides it was computed from, so a redraw of an
/// unchanged card costs a dictionary lookup.
struct DiffView: View {

    let input: ToolInput
    var reader: any FileTextReading = FileTextReader()
    var renderer: any DiffRendering = AttributedDiffRenderer()

    /// What has been prepared, or nil while nothing has been. A test hands one in; in the app the
    /// `.task` below fills it.
    @State private var prepared: DiffPreparation?

    init(input: ToolInput, reader: any FileTextReading = FileTextReader(),
         renderer: any DiffRendering = AttributedDiffRenderer(), prepared: DiffPreparation? = nil) {
        self.input = input
        self.reader = reader
        self.renderer = renderer
        _prepared = State(initialValue: prepared)
    }

    /// What a card says instead of a diff. The engine's request is still shown in full; what is
    /// missing is the other side of it, and saying so is what keeps a fabricated diff off the
    /// screen.
    static let unreadableNotice = "This file could not be read, so the tool's input is shown instead of a diff."

    var body: some View {
        if DiffSource.changesAFile(input) {
            drawn.task(id: DiffSource.identity(of: input)) { prepared = await prepare() }
        }
    }

    /// The read, off the main actor and once per source. Not private: this is what the `.task`
    /// runs, and a test asserting that the render pass reads nothing has to be able to run it
    /// itself.
    func prepare() async -> DiffPreparation? {
        await DiffSource.prepare(input, reader: reader)
    }

    @ViewBuilder
    private var drawn: some View {
        switch prepared {
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
            // Nothing has been read yet. A card mid-preparation says nothing rather than reporting
            // a file unreadable before anything has tried to read it — the same rule the sent-file
            // row's preview follows.
            Color.clear.frame(height: 0)
        }
    }
}
