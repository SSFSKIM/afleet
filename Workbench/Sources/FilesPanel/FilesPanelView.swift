// C7.5 spec Design §1, §3, §4, §7 and §8: the two columns, and nothing that holds session state.
import AppKit
import SwiftUI
import EditorCore
import PanelHostAPI

/// The Files panel: a tree column and a content column.
///
/// **The views only draw.** Which files are open, which is selected, each one's cursor and dirty
/// state, the conflict, the toggles and the persistence all live on `FilesPanelSession`, which the
/// host retains across channel switches; SwiftUI discards a subtree's `@State` when the subtree
/// unmounts, which is the whole reason X7's session contract exists. The only `@State` below is
/// what may be discarded without loss: which directory rows are expanded, and the flattened rows
/// derived from the tree.
public struct FilesPanelView: View {

    let session: FilesPanelSession

    public init(session: FilesPanelSession) {
        self.session = session
    }

    public var body: some View {
        HSplitView {
            FileTreeColumn(session: session)
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 460)
            FilesContentColumn(session: session)
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The tree column (Design §3)

/// The listing, the filter, the two toggles and *Refresh*.
private struct FileTreeColumn: View {

    let session: FilesPanelSession

    /// Which directories are open. View state on purpose: it is not in W6's document, and losing
    /// it on a channel switch costs a re-expansion and nothing the user typed.
    @State private var expanded: Set<URL> = []
    @State private var rows: [Row] = []
    /// Bumped by *Refresh*, which changes no observable property of the tree and so needs its own
    /// reason to re-enumerate.
    @State private var refreshes = 0

    private var tree: FileTree { session.tree }

    struct Row: Identifiable, Hashable {
        let node: FileTree.Node
        let depth: Int
        var id: URL { node.url }
    }

    /// Everything an enumeration depends on. `.task(id:)` over this is what re-reads the tree, so
    /// a filter keystroke, a toggle and an expansion all take the same path.
    private struct Key: Hashable {
        let filter: String
        let showsHidden: Bool
        let hidesIgnored: Bool
        let expanded: Set<URL>
        let refreshes: Int
    }

    private var key: Key {
        Key(filter: tree.filter, showsHidden: tree.showsHiddenFiles,
            hidesIgnored: tree.hidesIgnoredFiles, expanded: expanded, refreshes: refreshes)
    }

    var body: some View {
        @Bindable var tree = session.tree
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter", text: $tree.filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter")
                Button {
                    Task {
                        await session.tree.refreshAll()
                        refreshes += 1
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            HStack(spacing: 12) {
                Toggle("Hidden", isOn: $tree.showsHiddenFiles)
                // The gitignore toggle binds through the tree's **async** setter, because turning
                // it on is what pays for the classification: a plain boolean would hide nothing
                // until the user happened to refresh (Design §3).
                Toggle("Ignored", isOn: Binding(
                    get: { !session.tree.hidesIgnoredFiles },
                    set: { shows in
                        Task { @MainActor in
                            await session.tree.setHidesIgnoredFiles(!shows)
                        }
                    }))
                .disabled(tree.gitignore == .unavailable)
                .help(tree.gitignore == .unavailable
                      ? "This directory is not in a git repository."
                      : "Show files git ignores")
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()

            List(rows) { row in
                FileTreeRow(row: row,
                            isSelected: session.selectedPath == row.node.url.path(percentEncoded: false),
                            isExpanded: expanded.contains(row.node.url)) {
                    if row.node.isDirectory {
                        if expanded.contains(row.node.url) {
                            expanded.remove(row.node.url)
                        } else {
                            expanded.insert(row.node.url)
                        }
                    } else {
                        Task { await session.openFile(at: row.node.url, line: nil) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
            .listStyle(.sidebar)
        }
        .task(id: key) {
            rows = await flatten()
        }
    }

    /// The visible tree, depth-first. `FileTree` enumerates a directory once and answers from its
    /// own listing afterwards, so re-running this is cheap for everything already loaded.
    private func flatten() async -> [Row] {
        var result: [Row] = []
        func walk(_ directory: URL, depth: Int) async {
            for node in await session.tree.children(of: directory) {
                result.append(Row(node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.url) {
                    await walk(node.url, depth: depth + 1)
                }
            }
        }
        await walk(session.tree.root, depth: 0)
        return result
    }
}

private struct FileTreeRow: View {

    let row: FileTreeColumn.Row
    let isSelected: Bool
    let isExpanded: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(row.depth) * 12)
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(row.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
    }

    private var symbol: String {
        if row.node.isSymbolicLink { return "arrow.up.forward.square" }
        if row.node.isDirectory { return isExpanded ? "chevron.down" : "chevron.right" }
        return "doc"
    }
}

// MARK: - The content column (Design §4, §7, §8)

private struct FilesContentColumn: View {

    let session: FilesPanelSession

    private var readout: FilesPanelReadout { FilesPanelReadout(session: session) }

    var body: some View {
        let readout = self.readout
        VStack(spacing: 0) {
            EditorHeader(session: session, readout: readout)
            if readout.showsConflictBanner, let file = session.selected {
                ConflictBanner(session: session, file: file)
            }
            if let notice = readout.notice {
                PanelLocalNotice(text: notice)
            }
            Divider()
            content(readout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The editor is kept in the hierarchy whatever is on screen, so the web view is built and
    /// loaded once for as long as this panel is mounted; a native viewer draws over it. Rebuilding
    /// it every time the user opened a PNG would cost a page load per selection.
    @ViewBuilder
    private func content(_ readout: FilesPanelReadout) -> some View {
        let showsEditor = readout.viewer == .editor || readout.viewer == .diff
        ZStack {
            MonacoEditorSurface(session: session)
                .opacity(showsEditor ? 1 : 0)
                .allowsHitTesting(showsEditor)
            if !showsEditor {
                nativeViewer(readout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    @ViewBuilder
    private func nativeViewer(_ readout: FilesPanelReadout) -> some View {
        if let file = session.selected {
            switch readout.viewer {
            case .markdown: MarkdownViewer(text: file.text)
            case .image: ImageViewer(url: file.url)
            case .pdf: PDFViewer(url: file.url)
            case .media: MediaViewer(url: file.url)
            case .quickLook: QuickLookViewer(url: file.url)
            case .unsupported: UnsupportedFileViewer(url: file.url)
            case .nothing, .editor, .diff: EmptyState(text: Self.emptyMessage)
            }
        } else {
            EmptyState(text: Self.emptyMessage)
        }
    }

    private static let emptyMessage = "Choose a file to open it here."
}

/// The file's name, the dirty marker, and the three things the header does.
private struct EditorHeader: View {

    let session: FilesPanelSession
    let readout: FilesPanelReadout

    var body: some View {
        HStack(spacing: 8) {
            if let name = readout.selectedName {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                if readout.isDirty {
                    Text("●")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unsaved changes")
                }
                if readout.isMissing {
                    Text("missing").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(PanelTabID.files.defaultTitle).font(.headline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if readout.offersMarkdownToggle, let file = session.selected {
                // Design §4: markdown is rendered by default, and the same file's source opens in
                // Monaco on this toggle. Per open file, and part of the persisted document.
                Picker("", selection: Binding(
                    get: { readout.rendersMarkdown },
                    set: { renders in
                        Task { await session.setRendersMarkdown(renders, for: file.url) }
                    })) {
                    Text("Rendered").tag(true)
                    Text("Source").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            // Design §7: W4's vocabulary is closed, so the editor cannot report Cmd+S. The button
            // is the host-side action, and the `saveRequested` that comes back is written.
            Button("Save") { session.save() }
                .disabled(!readout.isDirty)
            if let file = session.selected {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy path")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// The banner Design §8 raises: the file changed under a dirty buffer.
private struct ConflictBanner: View {

    let session: FilesPanelSession
    let file: FilesPanelSession.OpenFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This file changed on disk while you were editing it.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Reload") { Task { await session.reload(file.url) } }
            Button("Keep mine") { session.keepMine(file.url) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

/// The panel's own error area. Root spec §10: a panel's errors stay in the panel, and none of this
/// reaches the conversation or a log line.
private struct PanelLocalNotice: View {

    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

struct EmptyState: View {

    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Monaco

/// `MonacoEditorView` in SwiftUI: created once, `load()`ed once, and handed to the session as its
/// `EditorSurface`.
///
/// There is no coordinator, deliberately: everything a coordinator would hold — the open buffers,
/// the cursor, the dirty flag, the conflict — is on the session already, and a second copy is a
/// second thing to keep true. `updateNSView` does nothing for the same reason: the session drives
/// the view through the command seam, not through this struct's stored properties.
struct MonacoEditorSurface: NSViewRepresentable {

    let session: FilesPanelSession

    func makeNSView(context: Context) -> MonacoEditorView {
        let view = MonacoEditorView()
        // Attach first: anything the session emitted before a surface existed — a restore's `open`
        // is the ordinary case — is drained into the view here, and the bridge queues it behind
        // `ready` exactly as it queues everything sent before the page is live.
        session.attach(view)
        view.load()
        return view
    }

    func updateNSView(_ nsView: MonacoEditorView, context: Context) {}
}
