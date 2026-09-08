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
        /// The text the editor was handed, for the surfaces that draw it themselves, kept current
        /// with the buffer: every presentation that replaces the buffer stashes it here first
        /// (Design §7), so nothing the user typed is discarded by the panel showing something else.
        public var text: String
        /// The bytes the buffer was loaded from, and `nil` for a file that was never read: one
        /// above the cap draws its size and offers *Reveal in Finder* (Design §4), and is neither
        /// watched nor editable, so it has no baseline to compare against.
        var lastLoaded: FileSnapshot?
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
        /// The destination is inside a Claude Code config home. afleet never writes there
        /// (CLAUDE.md's first rule, root spec X9); reading the file stays allowed.
        case saveRefusedIntoConfigHome
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
    private let watchMode: FileWatch.Mode
    private let watchCoalescingDelay: Duration
    private let watchPollInterval: Duration
    /// Where the config homes come from. The *set* is derived at every check rather than kept,
    /// because a home is a path and a path is not a directory: a home reached through a symbolic
    /// link that is retargeted after this session was built would otherwise leave the guard
    /// protecting a directory that is no longer the home, and the one that is writable
    /// (CLAUDE.md rule 1, root spec X9).
    private let channelConfigHome: URL
    private let channelVariables: [String: String]

    /// Every attached editor, held **weakly** and one per window (Design §1).
    ///
    /// X7's host returns the same session to the main window and to a popped-out one, and each
    /// builds its own `MonacoEditorView`: a single destination meant the second attachment silently
    /// replaced the first, and *Save* then wrote whichever window happened to have attached last.
    /// Commands are broadcast so both windows show the same file; `save` is not, because there is
    /// one buffer per surface and only the one the user is in may answer for it. Weakly, because a
    /// web view whose window went away must not be kept alive by this list.
    private var surfaces: [SurfaceBox] = []
    /// The surface the user is in: the one that most recently reported a `cursor` or a `dirty`
    /// event. `save` and the stash below go to it.
    private weak var focused: (any EditorSurface)?
    /// Commands emitted before a surface was attached. The view is built after the session, and a
    /// restore runs before either; the bridge queues before `ready`, but there is nothing to queue
    /// into until `attach(_:)`.
    private var pending: [EditorCommand] = []
    private var watches: [URL: FileWatch] = [:]
    /// The path whose text is in the editor's buffer right now.
    private var presentedPath: String?
    /// The path the editor's **model** holds, which outlives the presentation: a native viewer
    /// draws over Monaco without replacing its buffer. Nil until the first `open` reaches a
    /// surface, which is what makes `gotoLine` — the vocabulary's way out of the diff pane —
    /// safe to send.
    private var bufferPath: String?
    /// Which surface the *bridge* is showing, which is not `isShowingDiff`: the panel can move to
    /// a native viewer, which sends no command, while Monaco is still in its diff pane and
    /// refusing `save` (Design §5, §7).
    private var bridgeShowsDiff = false
    /// The `showDiff` the panel is showing, kept so a surface attaching under it can be shown the
    /// same pair. Nothing else describes a diff: one of its two sides is a repository object.
    private var presentedDiff: EditorCommand?
    /// Bumped by every presentation, so a diff resolved over several `git` calls cannot land on
    /// top of a newer one — or of the file the user opened while it was resolving.
    private var presentation = 0
    /// What the `save` in flight is for, and **whether there is one**. The vocabulary's only way
    /// to obtain the buffer is `save` → `saveRequested`, so a presentation that is about to
    /// replace the buffer asks for it with `.stash`: the text is recorded on the open file and
    /// **nothing is written**.
    ///
    /// `.idle` is the state with no request outstanding, and it is what every finished request
    /// falls back to. A reply is only ever acted on when it answers the request this names — a
    /// `saveRequested` is one message for two questions and carries no identity of its own, so
    /// the identity has to be held here. Without `.idle` an expired stash left the session set to
    /// *write*, and the editor's late answer to a request nobody was waiting for any more saved a
    /// file the user never asked to save.
    private enum SaveIntent: Equatable { case idle, write, stash(id: Int, path: String) }
    private var saveIntent: SaveIntent = .idle
    /// The presentation waiting for a stash to come back, and the request it is waiting for.
    /// Resumed by `saveRequested`, by the editor's `error`, or by the bound below — never twice,
    /// and never not at all. The id is what stops an expiry that fired for a retired request from
    /// resolving whichever waiter happens to exist by then.
    private var stashWaiter: CheckedContinuation<Void, Never>?
    private var stashWaiterID: Int?
    private var stashRequests = 0
    private let stashTimeout: Duration
    /// Whether a restore is between its first suspension and its last.
    private var isRestoring = false
    /// One position in the buffer, which is all a `cursor` event says.
    private struct Position: Hashable { let line: Int; let column: Int }
    /// Where **this session** last told the editor to put the cursor.
    ///
    /// The bridge posts a `cursor` for a host-issued move exactly as it does for the user's own,
    /// so a `gotoLine` broadcast to every window comes back from all of them. Taking those as
    /// evidence of where the user is made a background window the save target and handed `write`
    /// its stale buffer. A cursor the session asked for is therefore not ownership; anything else
    /// is, and it clears this.
    private var commandedPositions: Set<Position> = []
    /// The path whose buffer the session itself last replaced. `open` and `setText` leave the
    /// editor clean and the bridge says so — its own echo, not the user saving.
    private var replacedBufferPath: String?

    public init(context: ChannelContext,
                runner: any ToolRunning = ToolRunner(),
                surface: (any EditorSurface)? = nil,
                coalescingInterval: Duration = .milliseconds(250),
                watchMode: FileWatch.Mode = .vnode,
                watchCoalescingDelay: Duration = .milliseconds(120),
                watchPollInterval: Duration = .milliseconds(500),
                stashTimeout: Duration = .seconds(2)) {
        self.stashTimeout = stashTimeout
        self.store = FilesPanelStore(store: context.store, configHome: context.key.configHome,
                                     session: context.session,
                                     coalescingInterval: coalescingInterval)
        self.tree = FileTree(root: context.cwd, environment: context.environment, runner: runner)
        // The `language:` seam of `DiffPairResolver` wired to this leaf's one map, so a file and
        // its diff are never highlighted two different ways (Design §2).
        self.resolver = DiffPairResolver(runner: runner, environment: context.environment,
                                         language: { MonacoLanguage.id(for: URL(filePath: $0)) })
        self.watchMode = watchMode
        self.watchCoalescingDelay = watchCoalescingDelay
        self.watchPollInterval = watchPollInterval
        self.channelConfigHome = context.key.configHome
        self.channelVariables = context.environment.variables
        if let surface { attach(surface) }
    }

    /// Restores the channel's document. The link targets are the **tab's** (Design §9, Parent
    /// revision 4): one pair for `.files` rather than one pair per channel.
    public func activate() async {
        await restore()
    }

    /// Hands the session another editor to draw into.
    ///
    /// Every attached surface is kept, because the main window and a popped-out one are two views
    /// of one session. Anything emitted before any surface existed arrives here in the order it was
    /// emitted, and a surface attaching later is **brought up to date with what the session is
    /// presenting** — a SwiftUI remount rebuilds the panel subtree under a session the host keeps,
    /// and a fresh editor that was told nothing draws a blank page.
    public func attach(_ surface: any EditorSurface) {
        prune()
        guard !surfaces.contains(where: { $0.surface === surface }) else { return }
        surfaces.append(SurfaceBox(surface))
        surface.onEvent = { [weak self, weak surface] event in self?.handle(event, from: surface) }
        let queued = pending
        pending = []
        for command in queued { surface.send(command) }
        // A queue only accumulates while *no* surface is attached, so a surface that drained one
        // has already been told the whole of the presentation; one attaching beside an existing
        // surface has been told nothing.
        if queued.isEmpty { bringUpToDate(surface) }
    }

    /// Drops a surface whose window is going away. Nothing here may keep a dead web view alive,
    /// and a detached surface stops answering for the session's buffer.
    public func detach(_ surface: any EditorSurface) {
        surfaces.removeAll { $0.surface === surface || $0.surface == nil }
        surface.onEvent = nil
        if focused === surface { focused = nil }
    }

    /// What a newly attached surface has to be told to show what the session is already showing:
    /// the presented file's text and the cursor, or the diff pane it is in.
    private func bringUpToDate(_ surface: any EditorSurface) {
        // A diff is a presentation like any other, and the pair is the only thing that describes
        // it: nothing on disk does, because one side is a git object.
        if isShowingDiff, let presentedDiff {
            surface.send(presentedDiff)
            return
        }
        guard let path = presentedPath,
              let file = openFiles.first(where: { $0.path == path }) else { return }
        // Sent to this one surface rather than broadcast, so the positions it will report back are
        // recorded here rather than in `send`: a remounted window echoing the cursor the session
        // gave it is no more the user moving than any other host-issued move.
        commandedPositions.insert(Position(line: 1, column: 1))
        commandedPositions.insert(Position(line: file.line, column: file.column))
        surface.send(.open(path: file.path, language: file.language, text: file.text, line: nil))
        surface.send(.gotoLine(line: file.line, column: file.column))
    }

    /// Drops the boxes whose surface has been released.
    private func prune() {
        surfaces.removeAll { $0.surface == nil }
    }

    /// How many editors this session is drawing into. A count, never a surface (§11).
    public var attachedSurfaceCount: Int {
        surfaces.reduce(0) { $0 + ($1.surface == nil ? 0 : 1) }
    }

    /// Stops every watcher and writes the document. **The store coalesces**, so a session torn
    /// down without this loses whatever the last burst left pending.
    public func teardown() async {
        for watch in watches.values { await watch.stop() }
        watches = [:]
        await store.save(currentState())
        await store.flush()
    }

    /// The eviction path, which is the one nobody calls anything on.
    ///
    /// X7's `PanelTabSession` has no teardown member and `PanelHostModel` releases a session by
    /// setting its slot to nil — under LRU pressure, on `unregister`, and when a channel leaves
    /// the index. So the flush cannot depend on a call: whatever the store is still coalescing is
    /// written when the session goes. The store is an actor and holds the pending document itself,
    /// so this needs nothing from the isolated state a `deinit` may not touch — only the store,
    /// which is a `let` of a `Sendable` type and so is nonisolated, retained by the task that
    /// flushes it.
    ///
    /// It covers the last *recorded* state, not a change never recorded: every mutation records
    /// one, so the two differ only for an edit in flight at the moment of release. `teardown()`
    /// stays the explicit path — it records the state first and stops the watchers, which a
    /// `deinit` cannot await.
    deinit {
        let store = self.store
        Task.detached { await store.flush() }
    }

    // MARK: - The link targets (Design §9)

    /// The specificity both targets carry. Above W5's fallback and equal to each other; nothing
    /// else claims either case today, and the tie-break is C7.2's canonical order.
    public static let linkSpecificity = 100

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
    ///
    /// **What the record already knows survives the reopen.** A link, a tree row and a second Read
    /// row all arrive here, and A-B-A navigation is ordinary: replacing the text discarded the
    /// user's unsaved edits, and replacing `lastLoaded` under a dirty buffer adopted another
    /// writer's bytes as its baseline, which is what §8's conflict rule and the save preflight are
    /// both keyed on. So a dirty record is left exactly as it stands — the file is re-read only to
    /// learn that it can be read — and a clean one adopts the new bytes and retires **both**
    /// baselines with them: a `lastWritten` kept past its own `lastLoaded` goes on answering for
    /// bytes that are not there and swallows the next real change as this panel's save echo.
    public func openFile(at url: URL, line: Int?) async {
        guard let loaded = read(url) else {
            issue = .unreadableFile
            return
        }
        if let index = openFiles.firstIndex(where: { $0.url == url }) {
            openFiles[index].isMissing = false
            if let line { openFiles[index].line = max(1, line) }
            if !openFiles[index].isDirty {
                openFiles[index].kind = loaded.kind
                openFiles[index].language = loaded.language
                openFiles[index].text = loaded.text
                openFiles[index].lastLoaded = loaded.snapshot
                openFiles[index].lastWritten = nil
            }
        } else {
            openFiles.append(OpenFile(url: url, kind: loaded.kind, language: loaded.language,
                                      line: max(1, line ?? 1), column: 1, isDirty: false,
                                      rendersMarkdown: true, hasConflict: false, keepsMine: false,
                                      isMissing: false, text: loaded.text,
                                      lastLoaded: loaded.snapshot, lastWritten: nil))
            // A file above the cap has no snapshot and is not watched: it is drawn from disk by
            // `UnsupportedFileViewer` and never loaded (Design §4).
            if let snapshot = loaded.snapshot { await beginWatching(url, baseline: snapshot) }
        }
        issue = nil
        selectedPath = url.path(percentEncoded: false)
        await present(url, revealing: line)
        await persist()
    }

    /// Selects an already-open file and draws it.
    public func select(_ url: URL) async {
        guard openFiles.contains(where: { $0.url == url }) else { return }
        selectedPath = url.path(percentEncoded: false)
        issue = nil
        await present(url, revealing: nil)
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
            if let next = openFiles.first { await present(next.url, revealing: nil) }
        }
        await persist()
    }

    /// The tree's hidden-files toggle. Part of the document (Design §6), so it is set through the
    /// session rather than on the tree: a toggle written straight to `FileTree` records nothing,
    /// and eviction releases a session with no teardown to notice it.
    public func setShowsHiddenFiles(_ shows: Bool) async {
        guard tree.showsHiddenFiles != shows else { return }
        tree.showsHiddenFiles = shows
        await persist()
    }

    /// The tree's gitignore toggle, through the tree's **async** setter: turning it on is what pays
    /// for the classification (Design §3).
    public func setShowsGitIgnored(_ shows: Bool) async {
        guard tree.hidesIgnoredFiles == shows else { return }
        await tree.setHidesIgnoredFiles(!shows)
        await persist()
    }

    /// The markdown source/rendered toggle, per open file and part of the document (Design §4).
    public func setRendersMarkdown(_ renders: Bool, for url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              openFiles[index].rendersMarkdown != renders else { return }
        openFiles[index].rendersMarkdown = renders
        if selectedPath == openFiles[index].path { await present(url, revealing: nil) }
        await persist()
    }

    /// Puts a file on the editor's surface, or takes the editor off screen for a file that has a
    /// native viewer. `line` is the link's, and it rides on the `open` rather than following it,
    /// because that is the one command that reveals a line while building the buffer.
    ///
    /// **The buffer is stashed first.** `open` replaces the model, and the bridge reports the
    /// buffer clean afterwards, so a presentation that did not ask for the text first would
    /// discard whatever the user had typed — on a switch to another file, on the Markdown source
    /// toggle, and on leaving a diff (Design §7).
    ///
    /// **`isShowingDiff` is cleared before the native-viewer return**, not after it: the readout
    /// prioritises that flag, so a file with a native viewer opened out of a diff would otherwise
    /// draw the diff it just left (Design §4).
    ///
    /// **The stash is a round trip, so this presentation can lose while it waits.** The generation
    /// is claimed before the suspension and re-checked after it, exactly as `showDiff` does across
    /// its `git` calls: the user opening something else while a dirty buffer comes back must not
    /// then be drawn over by the presentation that was waiting.
    ///
    /// **The cursor is restored when the caller has no line of its own.** `open` reveals a line
    /// only when it was given one, and a selection or a toggle has none, so the position this
    /// session is holding for the file — the one G4 persists — is sent after it. A file whose
    /// cursor is the top is already there and is not told so.
    private func present(_ url: URL, revealing line: Int?) async {
        presentation += 1
        let generation = presentation
        await stashPresentedBuffer()
        guard generation == presentation,
              let file = openFiles.first(where: { $0.url == url }) else { return }
        isShowingDiff = false
        presentedDiff = nil
        guard file.usesEditor else {
            presentedPath = nil
            leaveDiffPane()
            return
        }
        presentedPath = file.path
        send(.open(path: file.path, language: file.language, text: file.text, line: line))
        if line == nil, file.line > 1 || file.column > 1 {
            send(.gotoLine(line: file.line, column: file.column))
        }
    }

    /// Takes Monaco out of its diff pane when the panel has moved to a surface that sends no
    /// command of its own.
    ///
    /// W4's vocabulary is closed and none of its six commands says "leave the diff" — but `open`,
    /// `setText` and `gotoLine` all show the editor pane before they do their own work, and
    /// `gotoLine` is the one of the three that changes no text. Without it the bridge stays in
    /// diff mode behind a rendered Markdown file and refuses that file's next `save` (Design §5).
    /// It is sent only once a buffer exists, because `gotoLine` before the first `open` is an
    /// `error` rather than a no-op.
    private func leaveDiffPane() {
        guard bridgeShowsDiff, let path = bufferPath else { return }
        let file = openFiles.first { $0.path == path }
        send(.gotoLine(line: file?.line ?? 1, column: file?.column ?? 1))
    }

    /// What one read of a file yielded, or nothing when it could not be read.
    ///
    /// The snapshot is optional because a file **above the cap** has none: `FileSnapshot.read`
    /// refuses to digest one, and Design §4 says such a file still opens — it draws its size and
    /// offers *Reveal in Finder* through `UnsupportedFileViewer`, unwatched and uneditable.
    /// `.unreadableFile` is kept for the file that genuinely could not be read: a path that is not
    /// a regular file, and a text file whose bytes would not come back.
    private func read(_ url: URL) -> (kind: FileKind, language: String, text: String,
                                      snapshot: FileSnapshot?)? {
        let kind = FileKind.of(url: url)
        let language = switch kind {
        case .code(let language): language
        default: MonacoLanguage.id(for: url)
        }
        // Only the surfaces that take a string read the bytes here; an image, a PDF, a media file
        // and anything above the cap are drawn from the file by their own viewer.
        switch kind {
        case .code, .markdown:
            guard let snapshot = FileSnapshot.read(url),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (kind, language, String(decoding: data, as: UTF8.self), snapshot)
        default:
            guard Self.isRegularFile(url) else { return nil }
            return (kind, language, "", FileSnapshot.read(url))
        }
    }

    /// Whether `url` names a regular file, which is the same `stat(2)` question `FileKind` and
    /// `FileSnapshot` both ask, so the three agree about what a path is.
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    // MARK: - Where a save may not land (CLAUDE.md rule 1, root spec X9)

    /// The directories a save may never land in: the channel's own config home, the
    /// `CLAUDE_CONFIG_DIR` of the channel's environment and of this process, and the default
    /// `~/.claude`.
    ///
    /// Every mutation of a config home goes through the CLI or the control channel (CLAUDE.md's
    /// first rule, root spec X9). `openFile` accepts whatever URL a `.file` link carries, so a
    /// settings file is opened like any other file and *Save* would replace it; the refusal
    /// belongs here, on the write, because **reading** one stays allowed.
    ///
    /// Each home is resolved, and so is the destination: an arbitrary `CLAUDE_CONFIG_DIR`, a
    /// symlink into a home and two spellings of one directory are all the same place.
    static func protectedConfigHomes(channel: URL, variables: [String: String],
                                     processVariables: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = URL(filePath: NSHomeDirectory())) -> [URL] {
        var homes = [channel, home.appending(path: ".claude")]
        for configured in [variables["CLAUDE_CONFIG_DIR"], processVariables["CLAUDE_CONFIG_DIR"]] {
            guard let configured, !configured.isEmpty else { continue }
            homes.append(URL(filePath: configured))
        }
        return homes.map(resolvingSymlinks)
    }

    /// The set of homes as it stands **now** — a home is a path, and the directory a path names
    /// can be replaced under it.
    private var protectedHomes: [URL] {
        Self.protectedConfigHomes(channel: channelConfigHome, variables: channelVariables)
    }

    /// Whether `url` is one of `homes` or lies inside one.
    static func isInside(_ homes: [URL], _ url: URL) -> Bool {
        let candidate = resolvingSymlinks(url)
        let caseSensitive = isCaseSensitiveVolume(candidate)
        return homes.contains { contains($0, candidate, caseSensitive: caseSensitive) }
    }

    /// Identity first — macOS mounts the data volume twice, so one directory has two spellings
    /// that share no components — and components second, for the part of the path that does not
    /// exist yet and so has no inode to compare.
    ///
    /// The component comparison asks the **volume** whether case distinguishes two names, because
    /// neither answer is right everywhere: a macOS volume is case-insensitive by default, where
    /// `.CLAUDE` and `.claude` are one directory and a case-sensitive comparison would let a save
    /// into a config home through; on a case-sensitive volume they are two directories and an
    /// insensitive comparison refuses a save that has nothing to do with a config home. C7.3's
    /// own guard reasons this out in `SourceControlCoreTests/Support/TempTree.swift`, and errs
    /// towards refusal for the same reason the default below does.
    static func contains(_ home: URL, _ candidate: URL, caseSensitive: Bool) -> Bool {
        if sharesIdentity(home, candidate) { return true }
        let inside = candidate.pathComponents, outside = home.pathComponents
        guard inside.count >= outside.count else { return false }
        for (mine, theirs) in zip(inside, outside)
        where !sameComponent(mine, theirs, caseSensitive: caseSensitive) { return false }
        return true
    }

    /// Whether names are distinguished by case on the volume `url` is on, asked of its nearest
    /// existing ancestor — the destination itself is often the file a save is about to create.
    /// A volume that will not answer is treated as case-insensitive, which errs towards refusing
    /// a write rather than letting one into a config home.
    private static func isCaseSensitiveVolume(_ url: URL) -> Bool {
        var probe = url.standardized
        while true {
            if let values = try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = values.volumeSupportsCaseSensitiveNames {
                return sensitive
            }
            let parent = probe.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < probe.pathComponents.count else { return false }
            probe = parent
        }
    }

    /// `standardized` and never `standardizedFileURL`: the file-URL form consults the file system
    /// and strips a `/private` prefix from a path that exists while leaving it on one that does
    /// not, which is the two-spellings failure this walk exists to end (C7.3's `TempTree`
    /// measured it).
    private static func sharesIdentity(_ home: URL, _ candidate: URL) -> Bool {
        guard let target = identity(home) else { return false }
        var probe = candidate.standardized
        while true {
            if let found = identity(probe), found == target { return true }
            let parent = probe.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < probe.pathComponents.count else { return false }
            probe = parent
        }
    }

    private static func identity(_ url: URL) -> (dev_t, ino_t)? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    private static func sameComponent(_ one: String, _ other: String, caseSensitive: Bool) -> Bool {
        one.precomposedStringWithCanonicalMapping
            .compare(other.precomposedStringWithCanonicalMapping,
                     options: caseSensitive ? [] : [.caseInsensitive])
            == .orderedSame
    }

    /// `url` with every symbolic link resolved, keeping the components that do not exist yet.
    /// `resolvingSymlinksInPath()` resolves nothing in a path that is not there, which is the case
    /// this has to get right: a config home that has not been created, and a destination whose
    /// last component a save is about to make.
    static func resolvingSymlinks(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if let resolved = realpath(standardized.path(percentEncoded: false)) {
            return URL(filePath: resolved)
        }
        var missing: [String] = []
        var probe = standardized
        while true {
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            guard parent.pathComponents.count < probe.pathComponents.count else { return standardized }
            missing.append(probe.lastPathComponent)
            probe = parent
            guard let resolved = realpath(probe.path(percentEncoded: false)) else { continue }
            var out = URL(filePath: resolved)
            for component in missing.reversed() { out = out.appending(path: component) }
            return out
        }
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Save (Design §7)

    /// *Save*. W4's vocabulary is closed, so the editor cannot report a key press: the button and
    /// the menu item both land here, and the `saveRequested` that comes back is written.
    ///
    /// **It saves the file the user has selected, or it saves nothing.** The editor answers `save`
    /// out of *its* model, and a native viewer draws over Monaco without replacing that model —
    /// so asking the editor while a rendered Markdown file, an image or a PDF is on screen gets
    /// back the code file that was there before. Three cases, and each is the same rule:
    ///
    /// - the selected file **is** the buffer on screen: ask the editor, as it always did;
    /// - a diff is on screen: ask anyway, because the bridge's refusal is what draws the notice
    ///   that tells the user to close it, and its answer is an `error` and never a buffer;
    /// - a native viewer is on screen: the editor is not showing this file at all, and the
    ///   session already holds its text — every presentation stashes the buffer before replacing
    ///   it (§7) — so the write comes from the record rather than from a round trip.
    public func save() {
        guard let file = selected else { return }
        if isShowingDiff {
            saveIntent = .idle
            sendToFocused(.save)
            return
        }
        if presentedPath == file.path {
            saveIntent = .write
            sendToFocused(.save)
            return
        }
        guard file.isDirty else { return }
        write(path: file.path, text: file.text)
    }

    /// Asks the editor for the buffer and records it on the open file **without writing it**.
    ///
    /// The vocabulary's only way to obtain the buffer is `save` → `saveRequested`, so the two
    /// reasons to ask for it are told apart by the intent this sets rather than by a seventh
    /// command. Everything that replaces the buffer awaits this first; a clean buffer is already
    /// what the record holds, so only a dirty one costs a round trip.
    ///
    /// The wait is bounded, and the continuation is resumed by exactly one of three things: the
    /// buffer coming back, the editor reporting an `error` instead, or the bound expiring. A
    /// presentation that hung on an editor that never answered would be worse than a stale one.
    private func stashPresentedBuffer() async {
        guard stashWaiter == nil, !isShowingDiff, focusedSurface != nil,
              let path = presentedPath,
              let index = openFiles.firstIndex(where: { $0.path == path }),
              openFiles[index].isDirty else { return }
        stashRequests += 1
        let request = stashRequests
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The waiter is in place **before** the request goes out: an editor that answers
            // synchronously — which is what a recorder does, and what a same-actor bridge could —
            // would otherwise find nothing to resume and leave this suspended for ever.
            stashWaiter = continuation
            stashWaiterID = request
            Task { [weak self, stashTimeout] in
                try? await Task.sleep(for: stashTimeout)
                self?.finishStash(request)
            }
            saveIntent = .stash(id: request, path: path)
            sendToFocused(.save)
        }
    }

    /// Records the buffer the editor answered a stash with. Dirtiness is re-derived from the text
    /// against the bytes on disk, because the editor's own flag is about to be reset by the model
    /// replacement this stash is making way for.
    private func stash(path: String, text: String) {
        guard let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
        openFiles[index].text = text
        let buffer = FileSnapshot.predicted(contents: Data(text.utf8))
        openFiles[index].isDirty = openFiles[index].lastLoaded
            .map { !buffer.hasSameContents(as: $0) } ?? false
    }

    /// Resumes the presentation waiting for stash `request`, once.
    ///
    /// The expiry cannot be cancelled once armed, so it arrives for a request that may long since
    /// have been answered — and the waiter it would find then belongs to a *later* presentation,
    /// which is still owed its own answer or its own expiry. The id is what keeps the two apart.
    /// The intent falls back to `.idle` whichever way this request ended, so no reply that arrives
    /// after it is over can be read as an authorisation to write.
    private func finishStash(_ request: Int) {
        guard stashWaiterID == request, let waiter = stashWaiter else { return }
        stashWaiter = nil
        stashWaiterID = nil
        saveIntent = .idle
        waiter.resume()
    }

    /// The same, for an answer that names no request: the editor's `error` is the reply to
    /// whatever is outstanding, and there is at most one.
    private func finishOutstandingStash() {
        guard let request = stashWaiterID else { return }
        finishStash(request)
    }

    /// Writes the buffer the editor answered with.
    ///
    /// **The save side of the conflict rule** (§8): the file's snapshot is re-read immediately
    /// before the write, because a watcher event that has not been delivered yet is not the same
    /// as a file that has not changed. A file whose bytes are neither what was loaded nor what was
    /// last written belongs to another writer, and the write is refused into the banner unless the
    /// user has already chosen *Keep mine*.
    ///
    /// **Only the selected file is ever written.** The path comes from the editor, which answers
    /// out of its own model, and that model outlives the presentation: a native viewer draws over
    /// Monaco without replacing it. A save is the user saving the file they are looking at, so a
    /// path that is not the one on screen is not a file this panel may write.
    private func write(path: String, text: String) {
        guard path == selectedPath,
              let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
        let file = openFiles[index]
        let data = Data(text.utf8)
        // The destination is the file the buffer was read from, which for a link is the link's
        // *target*: `FileSnapshot.read` and the mode lookup both follow the final component, and a
        // rename onto the link's own name would replace the link with a regular file and leave the
        // bytes on screen untouched. C7.3's `workingTreeFile` deliberately resolves nothing,
        // because there a link's own text is the git object; this is the editing path.
        let destination = Self.resolvingSymlinks(file.url)

        guard !Self.isInside(protectedHomes, destination) else {
            issue = .saveRefusedIntoConfigHome
            return
        }

        // **The save side of the conflict rule** (§8). A destination that has *vanished* is a
        // conflict too: a file deleted underneath the buffer is the user's to resolve, not one to
        // recreate silently — the watcher may already have raised the deletion.
        var expected: FileSnapshot?
        if !file.keepsMine {
            guard let observed = FileSnapshot.read(destination),
                  (file.lastLoaded.map(observed.hasSameContents(as:)) ?? false)
                    || (file.lastWritten.map(observed.hasSameContents(as:)) ?? false)
            else {
                openFiles[index].hasConflict = true
                return
            }
            expected = observed
        }
        // *Keep mine* is the user having chosen the overwrite, so it accepts whatever is there.
        let accepted: (FileSnapshot?) -> Bool = { later in
            guard let expected else { return true }
            return later.map { $0.hasSameContents(as: expected) } ?? false
        }

        // `lastWritten` is recorded from the bytes **before** the rename lands, so the echo cannot
        // arrive before the record of it (§8). A write that fails puts the previous record back,
        // because a snapshot of bytes that are not on disk would make a real change look like an
        // echo and swallow it.
        let previouslyWritten = file.lastWritten
        let written = FileSnapshot.predicted(contents: data)
        openFiles[index].lastWritten = written
        do {
            try Self.atomicallyWrite(data, to: destination, accepting: accepted)
        } catch {
            openFiles[index].lastWritten = previouslyWritten
            // A destination that moved while the temporary was being prepared is the same
            // conflict as one that had moved before it, and not a failure the user can retry.
            if error is SaveRefusal {
                openFiles[index].hasConflict = true
            } else {
                issue = .saveFailed
            }
            return
        }
        openFiles[index].isDirty = false
        openFiles[index].hasConflict = false
        openFiles[index].keepsMine = false
        openFiles[index].isMissing = false
        openFiles[index].text = text
        // **Both** baselines are now the bytes just written. `lastLoaded` describes what the buffer
        // holds, and after a save that is no longer what the file was opened from: leaving it
        // behind makes an external writer that restores those bytes invisible to §8's rule 2 and
        // to the preflight above. `lastWritten` stays as well, because it is what covers the
        // window between this record and the rename landing — §8's rule 1, keyed on the digest.
        openFiles[index].lastLoaded = written
        issue = nil
        // The editor's dirty baseline is the host's to clear: `readBuffer` deliberately leaves the
        // flag set, because only the host knows whether the write landed, and `dirty` is reported
        // on a *transition*. Without this the buffer stays dirty editor-side, the next edit
        // reports nothing, *Save* never re-enables and a refresh discards edits nobody was told
        // about. The bridge's own comment names this as the fix.
        if presentedPath == file.path, !isShowingDiff { send(.setText(text: text)) }
    }

    /// A write refused rather than failed: what tells `write` to raise the conflict instead of the
    /// panel's *could not be written*. It carries no path, like every other state here.
    enum SaveRefusal: Error {
        /// The destination changed between the preflight and the rename.
        case destinationChanged
    }

    /// Write a sibling temporary, then `rename`. What keeps the file whole if the app dies
    /// mid-write, and what makes the watcher's re-arm the ordinary path rather than a special one.
    ///
    /// **The destination's mode is carried onto the temporary before the rename**, because a
    /// rename replaces the inode: without it every save re-modes the file to whatever the process
    /// umask gives a fresh file, which silently disarms an executable script and re-opens a file
    /// the user had restricted. A destination that is not there yet has no mode to carry, and the
    /// file that replaces it takes the umask's — which is what creating a file means.
    ///
    /// **`accepting` is consulted immediately before the rename**, on the destination as it stands
    /// then. The caller's content check ran before the temporary was written, and another writer
    /// landing in that window would otherwise be overwritten unconditionally — and suppressed by
    /// the watcher as this save's own echo. This *narrows* the window; it does not close it. A
    /// replace with no window at all needs an exchange primitive this leaf does not use, so what
    /// is bought here is that a change which **is** detected is refused rather than overwritten.
    static func atomicallyWrite(_ data: Data, to url: URL,
                                accepting: (FileSnapshot?) -> Bool = { _ in true }) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".afleet-save-\(UUID().uuidString)")
        try writeTemporary(data, at: temporary, mode: permissions(of: url))
        guard accepting(FileSnapshot.read(url)) else {
            try? FileManager.default.removeItem(at: temporary)
            throw SaveRefusal.destinationChanged
        }
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

    /// The temporary, created **with** the destination's mode and only then filled.
    ///
    /// Creating it with the umask's mode and `chmod`ing afterwards writes every byte of a 0600 file
    /// into a 0644 one, which anyone who can traverse the directory may read; no later `chmod`
    /// takes that back. The creation mode is the destination's, which the umask may narrow but
    /// cannot widen, and `fchmod` restores it exactly while the file is still empty — a failure
    /// there fails the save rather than publishing the contents. A destination that is not there
    /// yet has no mode to carry and takes the umask's, which is what creating a file means.
    private static func writeTemporary(_ data: Data, at temporary: URL, mode: mode_t?) throws {
        let descriptor = temporary.path(percentEncoded: false)
            .withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode ?? 0o666) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            if let mode, fchmod(descriptor, mode) != 0 { throw CocoaError(.fileWriteNoPermission) }
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The permission bits of a path that exists, and nothing else about it. It follows a symlink
    /// for the same reason the write does: the panel saves the file the user opened, which is the
    /// link's target.
    private static func permissions(of url: URL) -> mode_t? {
        var status = stat()
        guard stat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return status.st_mode & 0o7777
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
            // A file with no baseline is not watched, so this cannot be one; the guard is what
            // says so rather than a force-unwrap.
            guard let lastLoaded = file.lastLoaded else { return }
            switch WatchPolicy.outcome(observed: snapshot, lastLoaded: lastLoaded,
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
    @discardableResult
    private func refresh(_ url: URL) -> Bool {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              let loaded = read(url) else { return false }
        openFiles[index].kind = loaded.kind
        openFiles[index].language = loaded.language
        openFiles[index].text = loaded.text
        openFiles[index].lastLoaded = loaded.snapshot
        // The last write no longer describes what is on disk, so it stops answering for it.
        openFiles[index].lastWritten = nil
        openFiles[index].isDirty = false
        openFiles[index].hasConflict = false
        let file = openFiles[index]
        guard file.usesEditor, presentedPath == file.path, !isShowingDiff else { return true }
        send(.open(path: file.path, language: file.language, text: file.text, line: nil))
        send(.gotoLine(line: file.line, column: file.column))
        return true
    }

    /// *Reload*: discard the buffer, refresh, clear the banner.
    ///
    /// **The buffer is discarded when the new one arrives, not when the user asks for it.** The
    /// refresh is the only thing that replaces the text, and it cannot happen for a file that is
    /// not there to be read — the ordinary state of a file the agent is replacing by rename.
    /// Clearing the dirty state in advance told the user they had nothing unsaved while their
    /// edits were still the only copy.
    public func reload(_ url: URL) async {
        guard openFiles.contains(where: { $0.url == url }) else { return }
        presentation += 1
        guard refresh(url), let index = openFiles.firstIndex(where: { $0.url == url }) else {
            return
        }
        openFiles[index].keepsMine = false
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
    /// **The pair is resolved over several `git` calls**, and the panel does not stand still while
    /// they run: the user may open a file, dismiss this diff, or ask for another one. The
    /// presentation this call belongs to is captured before the first suspension and re-checked
    /// after the last, so neither an older pair nor an older failure can replace a newer surface.
    public func showDiff(_ reference: DiffRef) async {
        // The buffer goes first: the diff pane replaces the editor's surface, and what the user
        // typed is only recoverable while the editor is still showing it (§7). The generation is
        // claimed before that round trip, not after it: the stash is a suspension like the `git`
        // calls below, and a diff superseded while it waits is as stale as one superseded while
        // it resolves.
        presentation += 1
        let generation = presentation
        await stashPresentedBuffer()
        guard generation == presentation else { return }
        do {
            let resolution = try await resolver.resolve(reference)
            guard generation == presentation else { return }
            switch resolution {
            case .pair(let command):
                issue = nil
                isShowingDiff = true
                presentedDiff = command
                presentedPath = nil
                send(command)
            case .noTextDiff(let reason):
                issue = .noTextDiff(reason)
            }
        } catch {
            guard generation == presentation else { return }
            issue = .diffUnavailable
        }
    }

    /// *Close diff*: leaves the diff and puts the selected file's editor back, or the empty state
    /// when nothing is open.
    ///
    /// Without it the only exit from a diff was opening or selecting another editor-backed file —
    /// the only other place `isShowingDiff` is cleared — and the bridge refuses `save` for as long
    /// as the diff is the surface (§7), so a user who arrived here from a link was stuck. The
    /// refusal notice goes with the diff that caused it; any other panel-local state is somebody
    /// else's and stays.
    public func dismissDiff() async {
        guard isShowingDiff else { return }
        isShowingDiff = false
        presentedDiff = nil
        if issue == .saveRefusedWhileDiffShown { issue = nil }
        // `present` clears the flag itself, and takes the bridge out of its diff pane for a file
        // with a native viewer; the empty state has neither, so it says so here.
        if let url = selected?.url {
            await present(url, revealing: nil)
        } else {
            presentedPath = nil
            presentation += 1
            leaveDiffPane()
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

    /// One event, and which surface it came from.
    ///
    /// `cursor` and `dirty` are the only things the editor says on its own initiative, so between
    /// them they are what "the window the user is in" means: the surface that reported one becomes
    /// the one `save` is addressed to.
    private func handle(_ event: EditorEvent, from surface: (any EditorSurface)?) {
        switch event {
        case .ready:
            break
        case .dirty(let path, let isDirty):
            // A clean report the session **caused** is not the user having saved. `open` and
            // `setText` replace the model and leave the buffer clean, and the bridge says so for
            // the path it replaced — including the same path, which is what re-opening a stashed
            // buffer at the file it came from does. Accepting it dropped the unsaved marker from
            // a buffer whose edits are all still there. Only a real transition back to dirty
            // retires the expectation, and a clean report can only follow one.
            if !isDirty, path == replacedBufferPath { return }
            if isDirty { replacedBufferPath = nil }
            if let surface { focused = surface }
            // Only the presented buffer may report its dirtiness.
            guard path == presentedPath,
                  let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
            openFiles[index].isDirty = isDirty
        case .cursor(let line, let column):
            // A move this session asked for is not the user moving: `gotoLine` goes to every
            // window and comes back from every window, and taking that as evidence made a
            // background window the save target.
            let commanded = commandedPositions.contains(Position(line: line, column: column))
            if !commanded {
                commandedPositions.removeAll()
                if let surface { focused = surface }
            }
            guard let path = presentedPath,
                  let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
            openFiles[index].line = line
            openFiles[index].column = column
            Task { await self.persist() }
        case .saveRequested(let path, let text):
            switch saveIntent {
            case .idle:
                // Nothing is waiting for a buffer. A reply to a request that has already ended —
                // an expired stash, a save already written — authorises nothing.
                break
            case .write:
                saveIntent = .idle
                write(path: path, text: text)
            case .stash(let request, let expected):
                // The reply has to be the one this request asked for. A `saveRequested` naming
                // another file answers no live request, and recording it would put one file's
                // bytes on another's record.
                guard path == expected else { return }
                stash(path: path, text: text)
                finishStash(request)
            }
        case .error:
            // The bridge refuses `save` while a diff is on screen, and `error` is the whole
            // vocabulary for a refusal. It becomes a panel-local state and is not logged: the
            // message is the editor's and a host log naming a file is what §11 forbids.
            issue = isShowingDiff ? .saveRefusedWhileDiffShown : .editorReported
            // A refusal is also the answer to a stash: the presentation waiting on one is owed a
            // resumption whichever way the editor replied.
            finishOutstandingStash()
        }
    }

    /// Broadcasts to every attached editor, so the main window and a popped-out one show the same
    /// file. With nothing attached the command is queued for the first surface that arrives.
    private func send(_ command: EditorCommand) {
        // Which pane the bridge is showing follows from the command, exactly as it does inside the
        // bridge: `open`, `setText` and `gotoLine` all show the editor first, `showDiff` shows the
        // diff. Deriving it here is what stops the two from drifting.
        // What the session is about to make the editor report back: the buffer it replaces goes
        // clean, and the cursor lands where the command put it. Both come back as events that
        // look exactly like the user's own, and neither is (see `handle`).
        switch command {
        case .open(let path, _, _, let line):
            bridgeShowsDiff = false
            bufferPath = path
            replacedBufferPath = path
            commandedPositions = [Position(line: line ?? 1, column: 1)]
        case .setText:
            bridgeShowsDiff = false
            replacedBufferPath = presentedPath
        case .gotoLine(let line, let column):
            bridgeShowsDiff = false
            commandedPositions.insert(Position(line: line, column: column ?? 1))
        case .showDiff:
            bridgeShowsDiff = true
        case .setTheme, .save:
            break
        }
        prune()
        let live = surfaces.compactMap(\.surface)
        guard !live.isEmpty else {
            pending.append(command)
            return
        }
        for surface in live { surface.send(command) }
    }

    /// The surface a `save` is addressed to: the one the user is in, or the only one there is.
    /// Broadcasting `save` would have every window answer for its own buffer, and the last answer
    /// would win.
    private var focusedSurface: (any EditorSurface)? {
        if let focused { return focused }
        return surfaces.compactMap(\.surface).last
    }

    private func sendToFocused(_ command: EditorCommand) {
        prune()
        guard let surface = focusedSurface else {
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
    /// **Nothing restored may overwrite something newer.** `activate()` starts this in a task, and
    /// it suspends on the store and on every watcher it arms; a link delivered inside one of those
    /// suspensions has already opened the file the user asked for. So the emptiness is re-checked
    /// after the load rather than only before it, each record is admitted only if nothing already
    /// holds that file, and the recorded selection is applied only when nothing else has selected
    /// one. A restore that finds the panel busy leaves it alone.
    public func restore() async {
        guard !isRestoring, openFiles.isEmpty else { return }
        isRestoring = true
        defer { isRestoring = false }
        let state = await store.load()
        tree.showsHiddenFiles = state.showsHiddenFiles
        await tree.setHidesIgnoredFiles(!state.showsGitIgnored)
        guard openFiles.isEmpty else { return }
        for record in state.openFiles {
            let url = URL(filePath: record.path)
            guard !openFiles.contains(where: { $0.url == url }), let loaded = read(url) else {
                continue
            }
            openFiles.append(OpenFile(url: url, kind: loaded.kind, language: loaded.language,
                                      line: max(1, record.line), column: max(1, record.column),
                                      isDirty: false, rendersMarkdown: record.rendersMarkdown,
                                      hasConflict: false, keepsMine: false, isMissing: false,
                                      text: loaded.text, lastLoaded: loaded.snapshot,
                                      lastWritten: nil))
            if let snapshot = loaded.snapshot { await beginWatching(url, baseline: snapshot) }
        }
        guard selectedPath == nil, let recorded = state.selectedPath,
              let file = openFiles.first(where: { $0.path == recorded }) else { return }
        selectedPath = file.path
        await present(file.url, revealing: file.line)
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

/// One attached editor, held weakly.
///
/// A class rather than a `weak var` in an array element, because an array cannot hold weak
/// references directly. Boxing is what lets the session keep a list of every window's editor
/// without any of them outliving its window.
@MainActor final class SurfaceBox {
    weak var surface: (any EditorSurface)?
    init(_ surface: any EditorSurface) { self.surface = surface }
}

/// The weak half of Design §9's registration rule.
///
/// A `LinkTarget`'s `handles` is `@Sendable` and not main-actor, so "is the session this target
/// routes to still alive?" cannot be answered by touching the session. This box answers it: the
/// session is held weakly behind a lock, `handles` asks only whether it is still there, and the
/// delivery itself hops to the main actor to reach it. A session released by the host's LRU
/// therefore leaves a target that claims nothing, and the router takes W5's fallback rather than
/// resurrecting it.
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
