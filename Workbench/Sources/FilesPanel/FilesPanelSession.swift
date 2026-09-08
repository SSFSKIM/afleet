// C7.5 spec Design §1, §7, §8 and §9: the session X7's host retains per (tab, channel).
import Foundation
import Observation
import AfleetCore
import EditorCore
import LinkRouting
import PanelHostAPI
import SourceControlCore

/// The seam between this panel and the editor (spec Design §1).
///
/// Declared here rather than in `EditorCore` because C7.2 is merged and this leaf does not edit
/// another leaf's target; if C7.7 wants it too, promoting it is a W4 amendment and a one-line move.
/// The point of the seam is that every assertion this leaf's gates make is on *the sequence of
/// `EditorCommand`s a session emits*, which is the observable behaviour C7.7 and the human both
/// see — a `WKWebView` in a package test would prove WebKit works and nothing else.
@MainActor public protocol EditorSurface: AnyObject {
    func send(_ command: EditorCommand)
    var onEvent: (@MainActor @Sendable (EditorEvent) -> Void)? { get set }
}

/// `MonacoEditorView` satisfies the seam exactly as C7.2 shipped it: `send(_:)` and an `onEvent`
/// of the same function type. The conformance is stated here, in this leaf's own module, so no
/// line of another leaf's target moves for it.
extension MonacoEditorView: EditorSurface {}

/// The Files tab's per-channel state machine: which files are open, which one is on screen, each
/// one's cursor, dirty and conflict state, one `FileWatch` per open file, the tree, the store, the
/// diff resolver and the two link targets.
///
/// **Main-actor and not an actor.** It is main-actor state a main-actor view reads, and the
/// bridge's `send` is main-actor; an actor here would buy hops and no isolation this does not
/// already have (spec Design §1, *Rejected*).
///
/// **Nothing here throws into the channel.** A file that cannot be read, a write that failed, a
/// diff with no text side and the bridge's own refusal are all `Issue` values on this object —
/// the panel-local states root spec §10 asks for — and none of them is logged, because a log line
/// naming a file is what §11 forbids.
@MainActor
@Observable
public final class FilesPanelSession: PanelTabSession {

    // MARK: - What the panel holds

    /// One open file. The `lastLoaded`/`lastWritten` pair is what `WatchPolicy` compares, and it
    /// is the reason a save's own echo is not a refresh.
    public struct OpenFile: Identifiable, Sendable {
        public let url: URL
        public var kind: FileKind
        public var language: String
        /// The cursor the session last heard from the editor, restored after every refresh.
        public var line: Int
        public var column: Int
        public var isDirty: Bool
        /// Markdown is rendered by default; the toggle opens the source in Monaco (Design §4).
        public var rendersMarkdown: Bool
        /// The banner: the file changed under a dirty buffer.
        public var hasConflict: Bool
        /// *Keep mine*: the next save is an overwrite rather than a refusal.
        public var keepsMine: Bool
        /// The file was there when it was opened and is not there now.
        public var isMissing: Bool
        /// The text the editor was handed, for the surfaces that draw it themselves.
        public var text: String
        var lastLoaded: FileSnapshot
        var lastWritten: FileSnapshot?

        public var id: URL { url }
        public var path: String { url.path(percentEncoded: false) }
        public var name: String { url.lastPathComponent }

        /// Whether this file's surface is Monaco. Markdown is the one kind that moves between
        /// surfaces, and it does so on a toggle the user owns.
        public var usesEditor: Bool {
            switch kind {
            case .code: true
            case .markdown: !rendersMarkdown
            default: false
            }
        }
    }

    /// The panel-local states (root spec §10). Every one of them is drawn in the panel's own area
    /// and none reaches the conversation.
    public enum Issue: Equatable, Sendable {
        /// The file could not be read at all — gone, unreadable, or above the panel's cap.
        case unreadableFile
        /// The write did not land. The buffer is still dirty and nothing was saved.
        case saveFailed
        /// The bridge refused a `save` because a diff is on screen. It is refused editor-side and
        /// there is no command that asks; this is the state the refusal lands in.
        case saveRefusedWhileDiffShown
        /// Any other `error` the editor reported. The message is deliberately not carried.
        case editorReported
        /// The base does have this path, but there is no text diff to show for it.
        case noTextDiff(DiffPairResolution.Reason)
        /// The repository could not answer at all — no git, no repository, a read that failed.
        case diffUnavailable
    }

    public private(set) var openFiles: [OpenFile] = []
    /// The absolute path of the selected file, if one is selected.
    public private(set) var selectedPath: String?
    public private(set) var issue: Issue?
    /// Whether the diff editor is the surface on screen. The bridge refuses `save` while it is.
    public private(set) var isShowingDiff = false
    /// The destination the last delivered link carried.
    ///
    /// Recorded because §9 makes the handler's receipt of the destination binding while its
    /// *behaviour* is the same for both cases: without this, "the handler receives the
    /// destination" is unobservable and a handler that dropped the argument would pass every
    /// assertion. It is state, not a log line, and carries no part of the link.
    public private(set) var lastOpenedDestination: LinkDestination?

    /// The directory listing. Its toggles are part of the persisted document.
    public let tree: FileTree

    public var selected: OpenFile? {
        guard let selectedPath else { return nil }
        return openFiles.first { $0.path == selectedPath }
    }

    // MARK: - What the panel is built over

    private let store: FilesPanelStore
    private let resolver: DiffPairResolver
    private let links: any LinkRouterCapability
    private let anchor: SessionAnchor
    private let watchMode: FileWatch.Mode
    private let watchCoalescingDelay: Duration
    private let watchPollInterval: Duration

    private var surface: (any EditorSurface)?
    /// Commands emitted before a surface was attached. The view is built after the session, and a
    /// restore runs before either; the bridge queues before `ready`, but there is nothing to queue
    /// into until `attach(_:)`.
    private var pending: [EditorCommand] = []
    private var watches: [URL: FileWatch] = [:]
    /// The path whose text is in the editor's buffer right now.
    private var presentedPath: String?

    public init(context: ChannelContext,
                runner: any ToolRunning = ToolRunner(),
                surface: (any EditorSurface)? = nil,
                coalescingInterval: Duration = .milliseconds(250),
                watchMode: FileWatch.Mode = .vnode,
                watchCoalescingDelay: Duration = .milliseconds(120),
                watchPollInterval: Duration = .milliseconds(500)) {
        self.links = context.links
        self.store = FilesPanelStore(store: context.store, configHome: context.key.configHome,
                                     session: context.session,
                                     coalescingInterval: coalescingInterval)
        self.tree = FileTree(root: context.cwd, environment: context.environment, runner: runner)
        // The `language:` seam of `DiffPairResolver` wired to this leaf's one map, so a file and
        // its diff are never highlighted two different ways (Design §2).
        self.resolver = DiffPairResolver(runner: runner, environment: context.environment,
                                         language: { MonacoLanguage.id(for: URL(filePath: $0)) })
        self.anchor = SessionAnchor()
        self.watchMode = watchMode
        self.watchCoalescingDelay = watchCoalescingDelay
        self.watchPollInterval = watchPollInterval
        self.anchor.bind(self)
        if let surface { attach(surface) }
    }

    /// Registers the link targets and restores the channel's document, in that order.
    public func activate() async {
        await registerLinkTargets()
        await restore()
    }

    /// Hands the session the editor it draws into. Anything emitted before this arrives now, in
    /// the order it was emitted.
    public func attach(_ surface: any EditorSurface) {
        self.surface = surface
        surface.onEvent = { [weak self] event in self?.handle(event) }
        let queued = pending
        pending = []
        for command in queued { surface.send(command) }
    }

    /// Stops every watcher and writes the document. **The store coalesces**, so a session torn
    /// down without this loses whatever the last burst left pending.
    public func teardown() async {
        for watch in watches.values { await watch.stop() }
        watches = [:]
        await store.save(currentState())
        await store.flush()
    }

    // MARK: - The link targets (Design §9)

    /// The specificity both targets carry. Above W5's fallback and equal to each other; nothing
    /// else claims either case today, and the tie-break is C7.2's canonical order.
    public static let linkSpecificity = 100

    /// Registers `.file` and `.diff` for `tab: .files`.
    ///
    /// **The target holds the session weakly.** `LinkRouterCapability` has no per-registration
    /// withdrawal and `unregister(tab:)` withdraws every channel's targets at once, which is right
    /// at teardown and wrong at eviction: a session released by the host's LRU must leave an inert
    /// target rather than resurrect itself. `handles` consults the anchor as well, so a released
    /// session's target stops claiming links and the router takes W5's fallback instead of
    /// delivering into nothing.
    public func registerLinkTargets() async {
        for target in linkTargets() { await links.register(target) }
    }

    func linkTargets() -> [LinkTarget] {
        let anchor = self.anchor
        let handler: @MainActor @Sendable (WorkspaceLink, LinkDestination) async -> Void = {
            link, destination in
            // The destination is received and deliberately not branched on: the host has already
            // popped the tab out for `.newWindow` before the handler runs, and a popped-out window
            // draws *this* session, because the host retains one per (tab, channel). Recorded here
            // so a later reader does not read the absence of a branch as a dropped case (§9).
            await anchor.session()?.open(link, from: destination)
        }
        return [
            LinkTarget(tab: .files, specificity: Self.linkSpecificity,
                       handles: { link in
                           guard case .file = link else { return false }
                           return anchor.isAlive
                       },
                       open: handler),
            LinkTarget(tab: .files, specificity: Self.linkSpecificity,
                       handles: { link in
                           guard case .diff = link else { return false }
                           return anchor.isAlive
                       },
                       open: handler),
        ]
    }

    /// What a delivered link does. `.file` opens the file at the line; `.diff` resolves the pair
    /// and shows it. Every other kind is not this panel's and is ignored.
    public func open(_ link: WorkspaceLink, from destination: LinkDestination) async {
        lastOpenedDestination = destination
        switch link {
        case .file(let url, let line):
            await openFile(at: url, line: line)
        case .diff(let reference):
            await showDiff(reference)
        default:
            break
        }
    }

    // MARK: - Opening a file

    /// Opens `url`, revealing `line` when the link named one.
    ///
    /// Re-opening the path that is already open is the normal case — the bridge reuses the model
    /// at that URI — so this updates the record it already has rather than building a second one.
    public func openFile(at url: URL, line: Int?) async {
        guard let loaded = read(url) else {
            issue = .unreadableFile
            return
        }
        if let index = openFiles.firstIndex(where: { $0.url == url }) {
            openFiles[index].kind = loaded.kind
            openFiles[index].language = loaded.language
            openFiles[index].text = loaded.text
            openFiles[index].lastLoaded = loaded.snapshot
            openFiles[index].isMissing = false
            if let line { openFiles[index].line = max(1, line) }
        } else {
            openFiles.append(OpenFile(url: url, kind: loaded.kind, language: loaded.language,
                                      line: max(1, line ?? 1), column: 1, isDirty: false,
                                      rendersMarkdown: true, hasConflict: false, keepsMine: false,
                                      isMissing: false, text: loaded.text,
                                      lastLoaded: loaded.snapshot, lastWritten: nil))
            await beginWatching(url, baseline: loaded.snapshot)
        }
        issue = nil
        selectedPath = url.path(percentEncoded: false)
        present(url, revealing: line)
        await persist()
    }

    /// Selects an already-open file and draws it.
    public func select(_ url: URL) async {
        guard openFiles.contains(where: { $0.url == url }) else { return }
        selectedPath = url.path(percentEncoded: false)
        issue = nil
        present(url, revealing: nil)
        await persist()
    }

    /// Closes a file: its watcher stops with it, and its banner goes with it (§8).
    public func close(_ url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        openFiles.remove(at: index)
        if let watch = watches.removeValue(forKey: url) { await watch.stop() }
        let path = url.path(percentEncoded: false)
        if presentedPath == path { presentedPath = nil }
        if selectedPath == path {
            selectedPath = openFiles.first?.path
            if let next = openFiles.first { present(next.url, revealing: nil) }
        }
        await persist()
    }

    /// The markdown source/rendered toggle, per open file and part of the document (Design §4).
    public func setRendersMarkdown(_ renders: Bool, for url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              openFiles[index].rendersMarkdown != renders else { return }
        openFiles[index].rendersMarkdown = renders
        if selectedPath == openFiles[index].path { present(url, revealing: nil) }
        await persist()
    }

    /// Puts a file on the editor's surface, or takes the editor off screen for a file that has a
    /// native viewer. `line` is the link's, and it rides on the `open` rather than following it,
    /// because that is the one command that reveals a line while building the buffer.
    private func present(_ url: URL, revealing line: Int?) {
        guard let file = openFiles.first(where: { $0.url == url }) else { return }
        guard file.usesEditor else {
            presentedPath = nil
            return
        }
        isShowingDiff = false
        presentedPath = file.path
        send(.open(path: file.path, language: file.language, text: file.text, line: line))
    }

    /// What one read of a file yielded, or nothing when it could not be read.
    private func read(_ url: URL) -> (kind: FileKind, language: String, text: String,
                                      snapshot: FileSnapshot)? {
        let kind = FileKind.of(url: url)
        guard let snapshot = FileSnapshot.read(url) else { return nil }
        let language = switch kind {
        case .code(let language): language
        default: MonacoLanguage.id(for: url)
        }
        // Only the surfaces that take a string read the bytes here; an image, a PDF, a media file
        // and anything above the cap are drawn from the file by their own viewer.
        var text = ""
        switch kind {
        case .code, .markdown:
            guard let data = try? Data(contentsOf: url) else { return nil }
            text = String(decoding: data, as: UTF8.self)
        default:
            break
        }
        return (kind, language, text, snapshot)
    }

    // MARK: - Save (Design §7)

    /// *Save*. W4's vocabulary is closed, so the editor cannot report a key press: the button and
    /// the menu item both land here, and the `saveRequested` that comes back is written.
    public func save() {
        send(.save)
    }

    /// Writes the buffer the editor answered with.
    ///
    /// **The save side of the conflict rule** (§8): the file's snapshot is re-read immediately
    /// before the write, because a watcher event that has not been delivered yet is not the same
    /// as a file that has not changed. A file whose bytes are neither what was loaded nor what was
    /// last written belongs to another writer, and the write is refused into the banner unless the
    /// user has already chosen *Keep mine*.
    private func write(path: String, text: String) {
        guard let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
        let file = openFiles[index]
        let data = Data(text.utf8)
        let observed = FileSnapshot.read(file.url)

        if !file.keepsMine, let observed {
            let known = observed.hasSameContents(as: file.lastLoaded)
                || (file.lastWritten.map(observed.hasSameContents(as:)) ?? false)
            if !known {
                openFiles[index].hasConflict = true
                return
            }
        }

        // `lastWritten` is recorded from the bytes **before** the rename lands, so the echo cannot
        // arrive before the record of it (§8). A write that fails puts the previous record back,
        // because a snapshot of bytes that are not on disk would make a real change look like an
        // echo and swallow it.
        let previouslyWritten = file.lastWritten
        openFiles[index].lastWritten = FileSnapshot.predicted(contents: data)
        do {
            try Self.atomicallyWrite(data, to: file.url)
        } catch {
            openFiles[index].lastWritten = previouslyWritten
            issue = .saveFailed
            return
        }
        openFiles[index].isDirty = false
        openFiles[index].hasConflict = false
        openFiles[index].keepsMine = false
        openFiles[index].isMissing = false
        openFiles[index].text = text
        // `lastLoaded` is deliberately **not** moved to the bytes just written. It is what the
        // buffer was loaded from, and the record that answers the echo is `lastWritten` — §8's
        // first rule, keyed on the digest. Re-reading the file into `lastLoaded` here would make
        // rule 2 answer the echo instead and leave rule 1 carrying nothing, which is a
        // suppression that no test could tell from its own absence.
        issue = nil
    }

    /// Write a sibling temporary, then `rename`. What keeps the file whole if the app dies
    /// mid-write, and what makes the watcher's re-arm the ordinary path rather than a special one.
    private static func atomicallyWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".afleet-save-\(UUID().uuidString)")
        try data.write(to: temporary)
        let moved = url.withUnsafeFileSystemRepresentation { destination in
            temporary.withUnsafeFileSystemRepresentation { source in
                guard let source, let destination else { return false }
                return rename(source, destination) == 0
            }
        }
        guard moved else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - The watcher and the conflict (Design §8)

    private func beginWatching(_ url: URL, baseline: FileSnapshot) async {
        let watch = FileWatch(url: url, mode: watchMode, coalescingDelay: watchCoalescingDelay,
                              pollInterval: watchPollInterval) { [weak self] event in
            Task { @MainActor in self?.observed(event, at: url) }
        }
        watches[url] = watch
        await watch.start(baseline: baseline)
    }

    /// One observation, run through the policy.
    ///
    /// A vanished file reaches here distinctly and is treated as one: the buffer is *not* replaced
    /// with nothing, because a file the agent is in the middle of replacing by rename is deleted
    /// for a moment and the user's text is not what is stale. It is marked missing, and a dirty
    /// buffer over it is a conflict like any other.
    private func observed(_ event: FileWatch.Event, at url: URL) {
        guard let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        let file = openFiles[index]
        switch event {
        case .deleted:
            openFiles[index].isMissing = true
            if file.isDirty { openFiles[index].hasConflict = true }
        case .changed(let snapshot):
            openFiles[index].isMissing = false
            switch WatchPolicy.outcome(observed: snapshot, lastLoaded: file.lastLoaded,
                                       lastWritten: file.lastWritten, isDirty: file.isDirty) {
            case .ignore:
                break
            case .conflict:
                openFiles[index].hasConflict = true
            case .refresh:
                refresh(url)
            }
        }
    }

    /// The refresh: `open` with the new text and then `gotoLine` with the cursor the session last
    /// heard from the editor, **in that order**, on the ordered send chain. The bridge reuses the
    /// model at that URI, so markers, decorations and view state survive; the cursor does not,
    /// which is why it is restored explicitly.
    private func refresh(_ url: URL) {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              let loaded = read(url) else { return }
        openFiles[index].kind = loaded.kind
        openFiles[index].language = loaded.language
        openFiles[index].text = loaded.text
        openFiles[index].lastLoaded = loaded.snapshot
        // The last write no longer describes what is on disk, so it stops answering for it.
        openFiles[index].lastWritten = nil
        openFiles[index].isDirty = false
        openFiles[index].hasConflict = false
        let file = openFiles[index]
        guard file.usesEditor, presentedPath == file.path, !isShowingDiff else { return }
        send(.open(path: file.path, language: file.language, text: file.text, line: nil))
        send(.gotoLine(line: file.line, column: file.column))
    }

    /// *Reload*: discard the buffer, refresh, clear the banner.
    public func reload(_ url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        openFiles[index].isDirty = false
        openFiles[index].keepsMine = false
        refresh(url)
        await persist()
    }

    /// *Keep mine*: leave the buffer, clear the banner, and make the next save an overwrite.
    public func keepMine(_ url: URL) {
        guard let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        openFiles[index].hasConflict = false
        openFiles[index].keepsMine = true
    }

    // MARK: - The diff (Design §5)

    /// Resolves a `.diff` link and shows the pair. `.noTextDiff` is a panel-local state and not an
    /// error: a binary change, a submodule and a path this base did not touch are ordinary answers.
    public func showDiff(_ reference: DiffRef) async {
        do {
            switch try await resolver.resolve(reference) {
            case .pair(let command):
                issue = nil
                isShowingDiff = true
                presentedPath = nil
                send(command)
            case .noTextDiff(let reason):
                issue = .noTextDiff(reason)
            }
        } catch {
            issue = .diffUnavailable
        }
    }

    // MARK: - The theme

    /// The panel's appearance control. The session sends **no** `setTheme` of its own: C7.2's view
    /// follows the system until a host sets one, and a session that announced a theme on every
    /// open would fight it.
    public func setTheme(name: String) {
        send(.setTheme(name: name))
    }

    // MARK: - Events

    private func handle(_ event: EditorEvent) {
        switch event {
        case .ready:
            break
        case .dirty(let path, let isDirty):
            guard let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
            openFiles[index].isDirty = isDirty
        case .cursor(let line, let column):
            guard let path = presentedPath,
                  let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
            openFiles[index].line = line
            openFiles[index].column = column
            Task { await self.persist() }
        case .saveRequested(let path, let text):
            write(path: path, text: text)
        case .error:
            // The bridge refuses `save` while a diff is on screen, and `error` is the whole
            // vocabulary for a refusal. It becomes a panel-local state and is not logged: the
            // message is the editor's and a host log naming a file is what §11 forbids.
            issue = isShowingDiff ? .saveRefusedWhileDiffShown : .editorReported
        }
    }

    private func send(_ command: EditorCommand) {
        guard let surface else {
            pending.append(command)
            return
        }
        surface.send(command)
    }

    // MARK: - Persistence (Design §6)

    /// Restores the channel's document: the toggles, the open files, the selection, and the
    /// selected file reopened at its stored line.
    ///
    /// A recorded file that is no longer on disk is **dropped** rather than opened as an error,
    /// and a document from a future schema arrives here as the empty state because the store
    /// refuses it before decoding.
    public func restore() async {
        guard openFiles.isEmpty else { return }
        let state = await store.load()
        tree.showsHiddenFiles = state.showsHiddenFiles
        await tree.setHidesIgnoredFiles(!state.showsGitIgnored)
        for record in state.openFiles {
            let url = URL(filePath: record.path)
            guard let loaded = read(url) else { continue }
            openFiles.append(OpenFile(url: url, kind: loaded.kind, language: loaded.language,
                                      line: max(1, record.line), column: max(1, record.column),
                                      isDirty: false, rendersMarkdown: record.rendersMarkdown,
                                      hasConflict: false, keepsMine: false, isMissing: false,
                                      text: loaded.text, lastLoaded: loaded.snapshot,
                                      lastWritten: nil))
            await beginWatching(url, baseline: loaded.snapshot)
        }
        if let recorded = state.selectedPath,
           let file = openFiles.first(where: { $0.path == recorded }) {
            selectedPath = file.path
            present(file.url, revealing: file.line)
        }
    }

    /// The document as it stands.
    public func currentState() -> FilesPanelState {
        var state = FilesPanelState()
        state.openFiles = openFiles.map {
            FilesPanelState.OpenFile(path: $0.path, line: $0.line, column: $0.column,
                                     rendersMarkdown: $0.rendersMarkdown)
        }
        state.selectedPath = selectedPath
        state.showsHiddenFiles = tree.showsHiddenFiles
        state.showsGitIgnored = !tree.hidesIgnoredFiles
        return state
    }

    private func persist() async {
        await store.save(currentState())
    }

    /// The store's key, for a diagnostic that names the key and nothing in it.
    public nonisolated var storeKey: String { store.key }
}

/// The weak half of Design §9's registration rule.
///
/// A `LinkTarget`'s `handles` is `@Sendable` and not main-actor, so "is my session still alive?"
/// cannot be answered by touching the session. This box answers it: the session is held weakly
/// behind a lock, `handles` asks only whether it is still there, and the delivery itself hops to
/// the main actor to reach it. A session released by the host's LRU therefore leaves a target that
/// claims nothing, and the router takes W5's fallback rather than resurrecting it.
final class SessionAnchor: Sendable {
    private nonisolated(unsafe) weak var held: FilesPanelSession?
    private let lock = NSLock()

    func bind(_ session: FilesPanelSession) {
        lock.lock()
        defer { lock.unlock() }
        held = session
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held != nil
    }

    @MainActor func session() -> FilesPanelSession? {
        lock.lock()
        defer { lock.unlock() }
        return held
    }
}
