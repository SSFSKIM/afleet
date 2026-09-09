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

/// The identity of one attached editor.
///
/// A counter the session hands out, and neither the surface nor its `ObjectIdentifier`: a released
/// web view's address is reused by the next allocation, so an identity derived from it answers
/// "yes, that is me" for a window that never existed — and a reference would keep a dead window's
/// web view alive. Every correlation in this file — whose reply this is, which window holds the
/// unsaved text — is made against this value.
public struct SurfaceID: Hashable, Sendable {
    let value: Int
}

/// The buffer of one open file: its text, the bytes on disk that text is measured against, the
/// surface that holds edits nobody else has, and the cursor.
///
/// **It is a type of its own so that the session cannot assign any of it.** Two review rounds found
/// defects of exactly one shape: a site that moved the text, the dirty flag or the owner *before*
/// it had checked the path, the surface or the presentation the change belonged to. Stating the
/// invariants and enforcing them at each known site is what left five more sites to find. Here the
/// fields are `private(set)` to a declaration the session is not part of, so the only ways into
/// them are the operations below — an editor event through `apply(_:from:)`, which validates the
/// path and the owner first; a captured buffer through `capture(text:for:from:)`, which validates
/// the path; and bytes from disk through `load` and the write pair, which only this file's reader
/// and writer call. A site that forgets to validate does not compile.
///
/// **Dirty is derived, never stored.** It is the editor's own report *or* a difference from
/// `lastLoaded`, the disk bytes the text was read from: C7.2's `replaceModel` adopts whatever text
/// it is given as the editor's saved version, so a re-opened stash makes unsaved text the editor's
/// baseline and its clean reports stop meaning anything (Design §7).
public struct BufferState: Sendable {
    /// The file this buffer holds. An event, a reply or a capture naming another one is not about
    /// this buffer and changes nothing in it.
    public let path: String
    public private(set) var text: String
    /// The bytes the text was read from, and `nil` for a file that was never read.
    private(set) var lastLoaded: FileSnapshot?
    /// The bytes this panel last wrote, which is what tells the watcher a save's echo from a
    /// change (§8).
    private(set) var lastWritten: FileSnapshot?
    /// The surface that reported this buffer dirty. While the buffer is dirty that surface is the
    /// only one holding the text, so it is the only one whose clean report may be believed.
    public private(set) var owner: SurfaceID?
    /// The editor's own flag, which is evidence and not the definition.
    private(set) var editorReportsDirty = false
    /// Whether `text` is this file's contents at all. An image, a PDF, a media file and anything
    /// above the cap are drawn from the file by their own viewer and never read into a buffer:
    /// they still carry a `lastLoaded`, because the watcher and the native previews both key on
    /// it, but measuring an empty buffer against it would report every one of them as unsaved
    /// work — and a watcher observing an "unsaved" file raises a conflict instead of refreshing.
    private(set) var holdsText: Bool
    public private(set) var line: Int
    public private(set) var column: Int
    /// How many times the bytes behind this buffer have been replaced from disk or by a save.
    ///
    /// It is what a capture is checked against: the vocabulary's only way to obtain the buffer is a
    /// round trip, and *Reload* — the user discarding those very edits — can land inside it. The
    /// answer then describes a buffer that no longer exists, and recording it put the discarded
    /// text straight back over the contents just loaded.
    private(set) var revision = 0

    init(path: String, text: String, holdsText: Bool, lastLoaded: FileSnapshot?,
         line: Int, column: Int) {
        self.path = path
        self.text = text
        self.holdsText = holdsText
        self.lastLoaded = lastLoaded
        self.line = max(1, line)
        self.column = max(1, column)
    }

    public var isDirty: Bool { editorReportsDirty || differsFromDiskBaseline }

    /// Whether the text this buffer holds is not the bytes it was loaded from. A file with no
    /// baseline — one above the cap, which is never read — has nothing to differ from.
    var differsFromDiskBaseline: Bool {
        guard holdsText, let lastLoaded else { return false }
        return !FileSnapshot.predicted(contents: Data(text.utf8)).hasSameContents(as: lastLoaded)
    }

    /// The surface holding text no other surface has, or nothing while the buffer is clean. The
    /// dirty flag *is* the ownership state, so nothing has to be cleared (Design §7).
    public var holder: SurfaceID? { isDirty ? owner : nil }

    /// The one door an editor event has into this buffer, and the whole of the owner rule.
    ///
    /// A `dirty` report for another path answers for another buffer; a *clean* report from a
    /// surface that is not holding the edits is that surface's model being replaced and never the
    /// user having saved — believing it dropped the unsaved marker from a buffer whose edits were
    /// all still there, and handed the next save to the window that did not have them. A `dirty`
    /// report takes ownership, because it is the user typing.
    ///
    /// Answers whether the event was accepted, which is what the session keys the *focus* on: an
    /// event this buffer refused moves nothing at all.
    mutating func apply(_ event: EditorEvent, from surface: SurfaceID) -> Bool {
        switch event {
        case .dirty(let reported, let isDirty):
            guard reported == path else { return false }
            if isDirty {
                owner = surface
                editorReportsDirty = true
                return true
            }
            guard holder == nil || holder == surface else { return false }
            editorReportsDirty = false
            if !differsFromDiskBaseline { owner = nil }
            return true
        case .cursor(let line, let column):
            self.line = max(1, line)
            self.column = max(1, column)
            return true
        case .ready, .saveRequested, .error:
            return false
        }
    }

    /// The text the editor answered a stash with. The editor's flag is dropped with it: the
    /// capture *is* the buffer, so from here dirtiness is the disk baseline's answer alone.
    @discardableResult
    mutating func capture(text: String, for path: String, from surface: SurfaceID,
                          expecting revision: Int) -> Bool {
        guard path == self.path, revision == self.revision else { return false }
        self.text = text
        editorReportsDirty = false
        owner = differsFromDiskBaseline ? surface : nil
        return true
    }

    /// Bytes read from disk: an open, a refresh, a reload. Both baselines are retired with them —
    /// a `lastWritten` kept past its own `lastLoaded` goes on answering for bytes that are not
    /// there and swallows the next real change as this panel's save echo.
    mutating func load(text: String, holdsText: Bool, snapshot: FileSnapshot?) {
        revision += 1
        self.text = text
        self.holdsText = holdsText
        lastLoaded = snapshot
        lastWritten = nil
        editorReportsDirty = false
        owner = nil
    }

    /// The bytes a save is about to put on disk, recorded **before** the rename lands so the echo
    /// cannot arrive before the record of it (§8). Answers the record it replaced, which a failed
    /// write puts back: a snapshot of bytes that are not on disk would make a real change look
    /// like an echo and swallow it.
    mutating func beginWrite(_ predicted: FileSnapshot) -> FileSnapshot? {
        let previous = lastWritten
        lastWritten = predicted
        return previous
    }

    mutating func abandonWrite(restoring previous: FileSnapshot?) {
        lastWritten = previous
    }

    /// A write that landed. **Both** baselines are now the bytes just written: `lastLoaded`
    /// describes what the buffer holds, and after a save that is no longer what the file was
    /// opened from.
    mutating func completeWrite(text: String) {
        revision += 1
        self.text = text
        lastLoaded = lastWritten
        editorReportsDirty = false
        owner = nil
    }

    /// The line a link asked to be revealed.
    mutating func reveal(line: Int) {
        self.line = max(1, line)
    }
}

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

    /// One open file: what it *is* — its kind, its viewer, its banners — and, in `buffer`, the one
    /// piece of state every review round found being mutated out of turn.
    ///
    /// Everything here is assignable except the buffer, whose fields belong to `BufferState` and
    /// are reachable only through that type's own operations (see `BufferState`).
    public struct OpenFile: Identifiable, Sendable {
        public let url: URL
        public var kind: FileKind
        public var language: String
        /// Markdown is rendered by default; the toggle opens the source in Monaco (Design §4).
        public var rendersMarkdown: Bool
        /// The banner: the file changed under a dirty buffer.
        public var hasConflict: Bool
        /// *Keep mine*: the next save is an overwrite rather than a refusal.
        public var keepsMine: Bool
        /// The file was there when it was opened and is not there now.
        public var isMissing: Bool
        /// The bytes did not round-trip through UTF-8, so this file is drawn and never edited
        /// (see `read`). It is not derivable from the kind: an image and a file above the cap are
        /// `.binary` too, and neither of them is a file the user asked to edit and cannot.
        public var isNotText: Bool
        /// The text, the baseline it is dirty against, the surface that owns it and the cursor.
        public var buffer: BufferState

        /// The text the editor was handed, for the surfaces that draw it themselves, kept current
        /// with the buffer: every presentation that replaces the buffer stashes it here first
        /// (Design §7), so nothing the user typed is discarded by the panel showing something else.
        public var text: String { buffer.text }
        /// Whether the text differs from the bytes on disk it was read from (Design §7).
        public var isDirty: Bool { buffer.isDirty }
        /// The cursor the session last heard from the editor, restored after every refresh.
        public var line: Int { buffer.line }
        public var column: Int { buffer.column }
        /// The bytes the buffer was loaded from, and `nil` for a file that was never read: one
        /// above the cap draws its size and offers *Reveal in Finder* (Design §4), and is neither
        /// watched nor editable, so it has no baseline to compare against.
        var lastLoaded: FileSnapshot? { buffer.lastLoaded }
        var lastWritten: FileSnapshot? { buffer.lastWritten }

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
        /// The file's bytes are not text, so it is drawn rather than edited: a buffer filled from
        /// bytes that do not round-trip is not the file, and saving it would replace what is
        /// there with something the user never typed.
        case fileIsNotText
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
        /// The editor did not answer the request for the buffer, so the panel could not show
        /// something else without discarding what the user typed. The file on screen stays.
        case editorDidNotAnswer
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
    /// The identities handed out so far. It only ever counts up, so no window inherits another's.
    private var surfaceCount = 0
    /// The surface the user is in: the one that most recently reported an event this session
    /// accepted. `save` and the stash below go to it.
    private var focused: SurfaceID?
    /// The theme a host set before any surface existed. **One slot, not a queue**: the session is
    /// built before the view and a restore runs before either, so there is a window in which
    /// nothing can be told anything — but a presentation is *state*, and a surface attaching is
    /// brought up to date from it (`bringUpToDate`), so the only thing a queue would carry that
    /// state does not is the theme, of which the latest is the only one that matters.
    private var pendingTheme: String?
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
    /// The presentation generation, claimed by `beginPresentation()` and bumped by nothing else,
    /// so a diff resolved over several `git` calls cannot land on top of a newer one — or of the
    /// file the user opened while it was resolving.
    private var presentation = 0
    /// The generation of the last presentation that actually **reached the surface**, which is
    /// what a suspension taken *before* a presentation is checked against (see `openFile`): a
    /// presentation that has only started has taken nothing from anybody.
    private var presented = 0
    /// One `save` this session sent, and what it sent it for. The vocabulary's only way to obtain
    /// the buffer is `save` → `saveRequested`, so a presentation that is about to replace the
    /// buffer asks for it with `.stash`: the text is recorded on the open file and **nothing is
    /// written**.
    ///
    /// The reply carries no identity of its own — it is one message for three questions — so the
    /// identity is held here and the correlation is positional: the bridge answers each `save` it
    /// receives exactly once and in order, so the oldest request a surface has not answered is the
    /// one its next reply belongs to. A reply that matches no request is dropped, and so is one
    /// that matches a request already `isRetired` — the expiry below retires a request without
    /// being able to cancel the answer that may still be on its way.
    /// One `save` this session sent, keyed by **(surface, generation, path)**: the window it went
    /// to, the presentation it was issued under, and the file it is about. A reply is matched
    /// against all three, and a request whose key has been overtaken is retired rather than
    /// forgotten, so an answer still on its way is recognisable as belonging to something that is
    /// over.
    private struct BufferRequest {
        /// Why the buffer was asked for. `.refusalOnly` is the `save` sent *at* a diff, whose
        /// answer is the bridge's refusal and never a buffer.
        enum Kind { case write, stash, refusalOnly }
        let id: Int
        let kind: Kind
        /// The file the request is about. A reply naming another one answers nothing.
        let path: String
        /// The buffer as it stood when the request went out. A capture is against that buffer and
        /// no later one.
        let revision: Int
        /// The surface the request went to, which is the only one that may answer it. An identity
        /// and not a reference: a weak surface reads `nil` once its window has gone, and `nil`
        /// compared equal to every other surface's reply — an expired request on a closed window
        /// then ate the answer another window was owed.
        let surface: SurfaceID
        /// The presentation this request was issued under.
        let generation: Int
        var isRetired = false
    }
    private var bufferRequests: [BufferRequest] = []
    private var requestCount = 0
    /// The presentation waiting for a stash to come back, and the request it is waiting for.
    /// Resumed by `saveRequested`, by the editor's `error`, or by the bound below — never twice,
    /// and never not at all. The id is what stops an expiry that fired for a retired request from
    /// resolving whichever waiter happens to exist by then. It carries **whether the buffer was
    /// captured**: an expiry and a refusal are failures, and a presentation that replaced the
    /// buffer on one of them would discard exactly the text the stash exists to keep.
    private var stashWaiter: CheckedContinuation<Bool, Never>?
    private var stashWaiterID: Int?
    /// The presentations that arrived while that stash was already in flight. One request is
    /// asked and its answer is every waiter's answer: a second `save` would ask the editor a
    /// question it is already answering, and going ahead without waiting would replace the buffer
    /// with text nobody has captured yet.
    private var stashObservers: [CheckedContinuation<Bool, Never>] = []
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
        surfaceCount += 1
        let id = SurfaceID(value: surfaceCount)
        surfaces.append(SurfaceBox(id: id, surface: surface))
        surface.onEvent = { [weak self] event in self?.handle(event, from: id) }
        if let pendingTheme { surface.send(.setTheme(name: pendingTheme)) }
        bringUpToDate(surface)
    }

    /// Drops a surface whose window is going away. Nothing here may keep a dead web view alive,
    /// and a detached surface stops answering for the session's buffer: its outstanding requests
    /// go with it, because the window that would have answered them is gone.
    public func detach(_ surface: any EditorSurface) {
        let leaving = surfaces.filter { $0.surface === surface }.map(\.id)
        surfaces.removeAll { $0.surface === surface || $0.surface == nil }
        surface.onEvent = nil
        if let focused, leaving.contains(focused) { self.focused = nil }
        for id in leaving { retireRequests { $0.surface == id } }
        prune()
    }

    /// What a newly attached surface has to be told to show what the session is already showing:
    /// the presented file's text and the cursor, or the diff pane it is in.
    ///
    /// **This, and not a queue of commands, is what a window that missed a presentation is caught
    /// up with.** A session outlives its windows and goes on presenting while none is attached —
    /// every external change of an open file is another presentation — so a queue grew for as long
    /// as the panel was off screen and then drained the whole history into the first window to
    /// arrive. What the session is presenting is state, and state is bounded and always the latest.
    private func bringUpToDate(_ surface: any EditorSurface) {
        // A diff is a presentation like any other, and the pair is the only thing that describes
        // it: nothing on disk does, because one side is a git object.
        if isShowingDiff, let presentedDiff {
            note(presentedDiff)
            surface.send(presentedDiff)
            return
        }
        guard let path = presentedPath,
              let file = openFiles.first(where: { $0.path == path }) else { return }
        let open = EditorCommand.open(path: file.path, language: file.language, text: file.text,
                                      line: nil)
        let cursor = EditorCommand.gotoLine(line: file.line, column: file.column)
        // Noted rather than broadcast, so the positions this window will report back are recorded
        // as the session's own: a remounted window echoing the cursor it was given is no more the
        // user moving than any other host-issued move.
        note(open)
        note(cursor)
        surface.send(open)
        surface.send(cursor)
    }

    /// Drops the boxes whose surface has been released, and retires what those surfaces were
    /// asked: a reply can no longer come from a window that is gone.
    private func prune() {
        let released = surfaces.filter { $0.surface == nil }.map(\.id)
        guard !released.isEmpty else { return }
        surfaces.removeAll { $0.surface == nil }
        if let focused, released.contains(focused) { self.focused = nil }
        for id in released { retireRequests { $0.surface == id } }
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
    ///
    /// **Arming the watcher is a suspension, and this open has to survive it.** Opening a file the
    /// session has never seen waits on `beginWatching` before it presents anything, and a selection
    /// the user made inside that wait can complete first — the older open then drew over it. What
    /// the wait is checked against is the last presentation that actually *reached the surface*: a
    /// generation claimed before the wait would also lose to one that had merely started, which is
    /// all any concurrently dispatched call looks like from here.
    public func openFile(at url: URL, line: Int?) async {
        guard let loaded = read(url) else {
            issue = .unreadableFile
            return
        }
        let mark = presented
        let path = url.path(percentEncoded: false)
        if let index = openFiles.firstIndex(where: { $0.url == url }) {
            openFiles[index].isMissing = false
            if let line { openFiles[index].buffer.reveal(line: line) }
            if !openFiles[index].isDirty {
                openFiles[index].kind = loaded.kind
                openFiles[index].language = loaded.language
                openFiles[index].isNotText = loaded.isNotText
                openFiles[index].buffer.load(text: loaded.text, holdsText: loaded.holdsText,
                                             snapshot: loaded.snapshot)
            }
        } else {
            openFiles.append(OpenFile(url: url, kind: loaded.kind, language: loaded.language,
                                      rendersMarkdown: true, hasConflict: false, keepsMine: false,
                                      isMissing: false, isNotText: loaded.isNotText,
                                      buffer: BufferState(path: path, text: loaded.text,
                                                          holdsText: loaded.holdsText,
                                                          lastLoaded: loaded.snapshot,
                                                          line: line ?? 1, column: 1)))
            // A file above the cap has no snapshot and is not watched: it is drawn from disk by
            // `UnsupportedFileViewer` and never loaded (Design §4).
            if let snapshot = loaded.snapshot { await beginWatching(url, baseline: snapshot) }
        }
        guard presented == mark else { return }
        let generation = beginPresentation()
        issue = note(for: path)
        selectedPath = path
        await present(url, revealing: line, under: generation)
        await persist()
    }

    /// Selects an already-open file and draws it.
    public func select(_ url: URL) async {
        guard openFiles.contains(where: { $0.url == url }) else { return }
        let generation = beginPresentation()
        selectedPath = url.path(percentEncoded: false)
        issue = note(for: selectedPath)
        await present(url, revealing: nil, under: generation)
        await persist()
    }

    /// What the panel-local area says about a file being opened, which for a file whose bytes are
    /// not text is why it is drawn rather than edited. Nothing else survives a presentation.
    private func note(for path: String?) -> Issue? {
        openFiles.first { $0.path == path }?.isNotText == true ? .fileIsNotText : nil
    }

    /// Closes a file: its watcher stops with it, its banner goes with it (§8), and so does anything
    /// the editor was asked about it — a reply about a file the panel no longer holds authorises
    /// nothing.
    public func close(_ url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        openFiles.remove(at: index)
        if let watch = watches.removeValue(forKey: url) { await watch.stop() }
        let path = url.path(percentEncoded: false)
        retireRequests { $0.path == path }
        if presentedPath == path { presentedPath = nil }
        if selectedPath == path {
            selectedPath = openFiles.first?.path
            if let next = openFiles.first {
                await present(next.url, revealing: nil, under: beginPresentation())
            }
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
    ///
    /// **The toggle is a presentation and is flipped last.** It moves the file between two
    /// surfaces, so the buffer has to be captured before it moves; flipping first and awaiting the
    /// capture afterwards meant a capture that failed left the toggle where the user put it and
    /// the readout drew the Markdown viewer over text the session had not been given.
    public func setRendersMarkdown(_ renders: Bool, for url: URL) async {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              openFiles[index].rendersMarkdown != renders else { return }
        guard selectedPath == openFiles[index].path else {
            openFiles[index].rendersMarkdown = renders
            await persist()
            return
        }
        let generation = beginPresentation()
        guard await captureBuffer(under: generation),
              let index = openFiles.firstIndex(where: { $0.url == url }) else { return }
        openFiles[index].rendersMarkdown = renders
        show(openFiles[index], revealing: nil)
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
    private func present(_ url: URL, revealing line: Int?, under generation: Int) async {
        guard await captureBuffer(under: generation),
              let file = openFiles.first(where: { $0.url == url }) else { return }
        show(file, revealing: line)
    }

    /// Claims the next presentation generation, **synchronously**: it is the caller's ticket, and
    /// it is claimed before any suspension the caller makes — the watcher it arms, the `git` calls
    /// it waits on, the stash round trip — because everything a presentation does after a
    /// suspension is conditional on still being the newest one, and a presentation that claimed
    /// its ticket afterwards could not tell that it had already lost.
    ///
    /// Claiming it retires the requests of the presentation it supersedes. A `.stash` is the
    /// exception: its answer is a *capture*, which records on a named buffer exactly what the
    /// editor holds for it and is therefore never invalidated by anything happening elsewhere —
    /// and its waiter, which a newer presentation may itself be waiting on, is correlated by its
    /// own id.
    private func beginPresentation() -> Int {
        presentation += 1
        retireRequests { $0.generation < self.presentation && $0.kind != .stash }
        return presentation
    }

    /// Whether `generation` is still the presentation on screen.
    private func isCurrent(_ generation: Int) -> Bool { generation == presentation }

    /// The capture every replacement of the buffer goes through, and the only thing that
    /// authorises one.
    ///
    /// Answers `false` when the presentation may not go on: either the editor did not give the
    /// buffer back — the text on screen is then the only copy of what the user typed, so it stays,
    /// the selection goes back to the file that is on the surface, and the panel says so — or a
    /// newer presentation took the surface while this one waited.
    private func captureBuffer(under generation: Int) async -> Bool {
        guard await stashPresentedBuffer() else {
            guard isCurrent(generation) else { return false }
            issue = .editorDidNotAnswer
            if let retained = presentedPath { selectedPath = retained }
            return false
        }
        return isCurrent(generation)
    }

    /// The synchronous half of a presentation: nothing here suspends, so nothing can overtake it
    /// between the checks and the commands.
    private func show(_ file: OpenFile, revealing line: Int?) {
        presented = presentation
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
                                      holdsText: Bool, snapshot: FileSnapshot?, isNotText: Bool)? {
        let kind = FileKind.of(url: url)
        let language = switch kind {
        case .code(let language): language
        default: MonacoLanguage.id(for: url)
        }
        // Only the surfaces that take a string read the bytes here; an image, a PDF, a media file
        // and anything above the cap are drawn from the file by their own viewer.
        switch kind {
        case .code, .markdown:
            // **One read**, both derived from it: the buffer the editor is handed and the baseline
            // the watcher compares it against are the same bytes or they describe two different
            // files, and a file replaced between two reads leaves the panel drawing text no
            // baseline covers — invisible to §8's rule and overwritten by the next save.
            guard let read = FileSnapshot.readWithContents(url) else { return nil }
            // **Strictly, and confirmed by the round trip.** `String(decoding:as:)` replaces an
            // invalid sequence with U+FFFD and a byte-order mark is dropped by the decoder, so
            // the buffer held text the file does not contain: it measured dirty against the very
            // digest it had been read from, the file opened with an unsaved marker nobody had
            // earned, and *Save* passed the preflight against those original bytes and wrote the
            // replacement over them. A file whose bytes do not come back is not text this panel
            // may edit: it is drawn by `UnsupportedFileViewer` like any other opaque file, with
            // no buffer to be dirty and nothing for a save to write (Design §4, §7).
            guard let text = String(data: read.contents, encoding: .utf8),
                  Data(text.utf8) == read.contents else {
                return (.binary, language, "", false, read.snapshot, true)
            }
            return (kind, language, text, true, read.snapshot, false)
        default:
            // Not read into a buffer at all: its viewer draws it from the file, so the buffer
            // holds no text and has nothing to be dirty against.
            guard Self.isRegularFile(url) else { return nil }
            return (kind, language, "", false, FileSnapshot.read(url), false)
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
        return homes.map { resolvingSymlinks($0) }
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
    static func resolvingSymlinks(_ url: URL, depth: Int = 0) -> URL {
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
            // Component by component, and each one followed if it is a link. `realpath` gives up
            // at the first component that is not there and reports nothing about the ones above
            // it — but a symbolic link whose target is missing is *resolvable*: `readlink` answers
            // for it. Without this a save on such a link renamed onto the link's own name,
            // replacing it with a regular file and leaving the target it names still missing.
            for component in missing.reversed() {
                out = followingLink(out.appending(path: component), depth: depth)
            }
            return out
        }
    }

    /// `url` with a symbolic link at its last component followed, whether or not its target
    /// exists, and the result resolved in turn. Bounded, because links can be a cycle.
    private static func followingLink(_ url: URL, depth: Int) -> URL {
        guard depth < 32, let target = readlink(url) else { return url }
        let joined = target.hasPrefix("/")
            ? URL(filePath: target)
            : url.deletingLastPathComponent().appending(path: target)
        return resolvingSymlinks(joined, depth: depth + 1)
    }

    /// What a symbolic link names, or `nil` for a path that is not one.
    private static func readlink(_ url: URL) -> String? {
        var status = stat()
        let path = url.path(percentEncoded: false)
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = path.withCString { name in
            buffer.withUnsafeMutableBytes { out -> Int in
                guard let base = out.baseAddress else { return -1 }
                return Darwin.readlink(name, base.assumingMemoryBound(to: CChar.self),
                                       out.count - 1)
            }
        }
        guard count >= 0 else { return nil }
        return String(decoding: buffer[..<count], as: UTF8.self)
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
            requestBuffer(.refusalOnly, path: file.path)
            return
        }
        // With no surface attached there is no buffer to ask for and nothing to be refused by:
        // the record is the only copy of the text, and it is what is written.
        if presentedPath == file.path, requestBuffer(.write, path: file.path) { return }
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
    ///
    /// Answers **whether the buffer may now be replaced**: `true` when there was nothing to
    /// capture or the editor gave the text back, `false` when the request expired or the editor
    /// refused it. A failure is not a capture — the text on screen is then the only copy of what
    /// the user typed — so the presentation that asked is refused rather than completed.
    @discardableResult
    private func stashPresentedBuffer() async -> Bool {
        // A stash for this buffer is already in flight. Its answer is this presentation's answer:
        // asking again would put a second `save` on a question the editor is already answering,
        // and not waiting would open over text nobody has captured yet.
        if stashWaiter != nil {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                stashObservers.append(continuation)
            }
        }
        prune()
        guard !isShowingDiff, let target = focusedSurface,
              let path = presentedPath,
              let index = openFiles.firstIndex(where: { $0.path == path }),
              openFiles[index].isDirty else { return true }
        requestCount += 1
        let request = requestCount
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // The waiter is in place **before** the request goes out: an editor that answers
            // synchronously — which is what a recorder does, and what a same-actor bridge could —
            // would otherwise find nothing to resume and leave this suspended for ever.
            stashWaiter = continuation
            stashWaiterID = request
            sendBufferRequest(id: request, kind: .stash, path: path, to: target)
        }
    }

    /// Sends one `save` and records what it was sent for, so the reply can be matched to it.
    /// Answers whether it went anywhere: with no surface attached there is nothing to ask.
    @discardableResult
    private func requestBuffer(_ kind: BufferRequest.Kind, path: String) -> Bool {
        prune()
        guard let target = focusedSurface else { return false }
        requestCount += 1
        sendBufferRequest(id: requestCount, kind: kind, path: path, to: target)
        return true
    }

    /// The half of the above that a stash calls with an id it allocated first — the waiter has to
    /// exist before the `save` goes out, and a recorder answers it inside `send`.
    ///
    /// **Every request expires**, not only a stash. An editor that never answers leaves a request
    /// standing in front of every later reply for as long as the session lives, and a table that
    /// only ever grows outlives the window, the file and the panel it was about.
    private func sendBufferRequest(id: Int, kind: BufferRequest.Kind, path: String,
                                   to target: SurfaceBox) {
        // A retired request is kept so the answer that may still be coming can be recognised as
        // belonging to a request that is over. It is not kept for ever: an editor that has been
        // silent for this many requests is not going to answer any of them, and the correlation
        // it would preserve is meaningless by then.
        while bufferRequests.count > 32, let stale = bufferRequests.firstIndex(where: \.isRetired) {
            bufferRequests.remove(at: stale)
        }
        let revision = openFiles.first { $0.path == path }?.buffer.revision ?? 0
        bufferRequests.append(BufferRequest(id: id, kind: kind, path: path, revision: revision,
                                            surface: target.id, generation: presentation))
        Task { [weak self, stashTimeout] in
            try? await Task.sleep(for: stashTimeout)
            self?.expireRequest(id)
        }
        target.surface?.send(.save)
    }

    /// The request a reply from `surface` answers: the oldest one that surface has not answered
    /// yet, removed as it is taken. `nil` when the surface is answering nothing, which is what a
    /// reply the session must ignore looks like.
    private func takeRequest(answeredBy surface: SurfaceID) -> BufferRequest? {
        guard let index = bufferRequests.firstIndex(where: { $0.surface == surface })
        else { return nil }
        return bufferRequests.remove(at: index)
    }

    /// Retires every request the predicate names, **keeping** it: the editor may still answer one,
    /// and that answer has to be recognisable as belonging to something that is over rather than
    /// stand in front of the next reply or be read as an authorisation of its own.
    private func retireRequests(where predicate: (BufferRequest) -> Bool) {
        for index in bufferRequests.indices where predicate(bufferRequests[index]) {
            bufferRequests[index].isRetired = true
        }
    }

    /// Records the buffer the editor answered a stash with, on the buffer that **names that path**
    /// and on no other.
    private func stash(path: String, text: String, from surface: SurfaceID, revision: Int) {
        guard let index = openFiles.firstIndex(where: { $0.path == path }) else { return }
        openFiles[index].buffer.capture(text: text, for: path, from: surface, expecting: revision)
    }

    /// Resumes the presentation waiting for stash `request`, once.
    ///
    /// The expiry cannot be cancelled once armed, so it arrives for a request that may long since
    /// have been answered — and the waiter it would find then belongs to a *later* presentation,
    /// which is still owed its own answer or its own expiry. The id is what keeps the two apart.
    /// The intent falls back to `.idle` whichever way this request ended, so no reply that arrives
    /// after it is over can be read as an authorisation to write.
    private func finishStash(_ request: Int, captured: Bool) {
        guard stashWaiterID == request, let waiter = stashWaiter else { return }
        stashWaiter = nil
        stashWaiterID = nil
        let observers = stashObservers
        stashObservers = []
        waiter.resume(returning: captured)
        for observer in observers { observer.resume(returning: captured) }
    }

    /// The bound expiring, for a request of any kind. The request is **retired rather than
    /// forgotten**: the editor may still answer it, and that answer has to be recognisable as
    /// belonging to a request that is over so it cannot be read as the answer to whatever was
    /// asked next. `finishStash` does nothing unless this is the stash a presentation is waiting
    /// on.
    private func expireRequest(_ request: Int) {
        retireRequests { $0.id == request }
        finishStash(request, captured: false)
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
        let written = FileSnapshot.predicted(contents: data)
        let previouslyWritten = openFiles[index].buffer.beginWrite(written)
        do {
            try Self.atomicallyWrite(data, to: destination, accepting: accepted)
        } catch {
            openFiles[index].buffer.abandonWrite(restoring: previouslyWritten)
            // A destination that moved while the temporary was being prepared is the same
            // conflict as one that had moved before it, and not a failure the user can retry.
            if error is SaveRefusal {
                openFiles[index].hasConflict = true
            } else {
                issue = .saveFailed
            }
            return
        }
        openFiles[index].hasConflict = false
        openFiles[index].keepsMine = false
        openFiles[index].isMissing = false
        // **Both** baselines are now the bytes just written. `lastLoaded` describes what the buffer
        // holds, and after a save that is no longer what the file was opened from: leaving it
        // behind makes an external writer that restores those bytes invisible to §8's rule 2 and
        // to the preflight above. `lastWritten` stays as well, because it is what covers the
        // window between this record and the rename landing — §8's rule 1, keyed on the digest.
        openFiles[index].buffer.completeWrite(text: text)
        issue = nil
        // The editor's dirty baseline is the host's to clear: `readBuffer` deliberately leaves the
        // flag set, because only the host knows whether the write landed, and `dirty` is reported
        // on a *transition*. Without this the buffer stays dirty editor-side, the next edit
        // reports nothing, *Save* never re-enables and a refresh discards edits nobody was told
        // about. The bridge's own comment names this as the fix.
        //
        // **And the cursor is put back after it.** `setText` replaces the model's contents, which
        // moves the caret to the top of the file: the refresh path restores it and the save
        // acknowledgement did not, so saving with the caret anywhere but line one moved it.
        guard presentedPath == file.path, !isShowingDiff else { return }
        send(.setText(text: text))
        let cursor = openFiles[index].buffer
        if cursor.line > 1 || cursor.column > 1 {
            send(.gotoLine(line: cursor.line, column: cursor.column))
        }
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
    ///
    /// **What the editor was asked about this file is retired here.** The refresh replaces the
    /// text and the baseline it is measured against, so a `save` reply still on its way describes
    /// a buffer that no longer exists — and writing it puts the contents the user discarded back
    /// over the ones that were just loaded.
    @discardableResult
    private func refresh(_ url: URL) -> Bool {
        guard let index = openFiles.firstIndex(where: { $0.url == url }),
              let loaded = read(url) else { return false }
        openFiles[index].kind = loaded.kind
        openFiles[index].language = loaded.language
        openFiles[index].isNotText = loaded.isNotText
        // The last write no longer describes what is on disk, so it stops answering for it.
        openFiles[index].buffer.load(text: loaded.text, holdsText: loaded.holdsText,
                                             snapshot: loaded.snapshot)
        openFiles[index].hasConflict = false
        retireRequests { $0.path == openFiles[index].path }
        let file = openFiles[index]
        // **The selected file, not the presented one.** A file with a native viewer leaves
        // `presentedPath` nil, so a refresh that changes what the file *is* — opaque bytes that
        // become text — had nothing to compare against and sent nothing, while the readout, which
        // follows the kind, drew Monaco over a buffer that was never loaded. The two halves are
        // the same rule: what the selected file needs on screen now.
        guard selectedPath == file.path, !isShowingDiff else { return true }
        guard file.usesEditor else {
            // And the other direction: text that became opaque is drawn by a native viewer, which
            // sends no command of its own, so the presentation has to be given up here.
            if presentedPath == file.path {
                presentedPath = nil
                leaveDiffPane()
            }
            return true
        }
        presentedPath = file.path
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
        _ = beginPresentation()
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
    ///
    /// **The buffer is captured immediately before the pane replaces it, and not before the `git`
    /// calls.** The panel does not stand still while a pair resolves and neither does the user:
    /// capturing first and showing the pair several `git` calls later stashed the text as it stood
    /// before those keystrokes, and *Close diff* then drew that stale copy back over them. A
    /// resolution that turns out to be `.noTextDiff` replaces nothing and so captures nothing.
    public func showDiff(_ reference: DiffRef) async {
        let generation = beginPresentation()
        do {
            let resolution = try await resolver.resolve(reference)
            guard isCurrent(generation) else { return }
            switch resolution {
            case .pair(let command):
                guard await captureBuffer(under: generation) else { return }
                presented = generation
                issue = nil
                isShowingDiff = true
                presentedDiff = command
                presentedPath = nil
                send(command)
            case .noTextDiff(let reason):
                issue = .noTextDiff(reason)
            }
        } catch {
            guard isCurrent(generation) else { return }
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
        let generation = beginPresentation()
        isShowingDiff = false
        presentedDiff = nil
        if issue == .saveRefusedWhileDiffShown { issue = nil }
        // `show` clears the flag itself, and takes the bridge out of its diff pane for a file with
        // a native viewer; the empty state has neither, so it says so here.
        if let url = selected?.url {
            await present(url, revealing: nil, under: generation)
        } else {
            presented = generation
            presentedPath = nil
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
    private func handle(_ event: EditorEvent, from surface: SurfaceID) {
        switch event {
        case .ready:
            break
        case .dirty, .cursor:
            apply(event, from: surface)
        case .saveRequested(let path, let text):
            // The reply belongs to the oldest request this surface has not answered, and to
            // nothing else. A reply that matches no request, one that answers a request already
            // retired, and one naming a file the request was not about all authorise nothing:
            // between them they are an expired stash's late answer being read as a later save,
            // and one file's bytes being recorded on another's.
            guard let request = takeRequest(answeredBy: surface),
                  path == request.path else { return }
            switch request.kind {
            case .write:
                guard !request.isRetired else { return }
                write(path: path, text: text)
            case .stash:
                // A capture is the one thing a late answer may still do: it records on the buffer
                // that names this path exactly what the editor holds for it, which nothing that
                // happened elsewhere makes wrong. What it may not do is resume a waiter that is
                // not the one it belongs to, and the id is what says so.
                stash(path: path, text: text, from: surface, revision: request.revision)
                finishStash(request.id, captured: true)
            case .refusalOnly:
                break
            }
        case .error:
            // The bridge refuses `save` while a diff is on screen, and `error` is the whole
            // vocabulary for a refusal. It becomes a panel-local state and is not logged: the
            // message is the editor's and a host log naming a file is what §11 forbids.
            issue = isShowingDiff ? .saveRefusedWhileDiffShown : .editorReported
            // A refusal is the answer to whatever this surface was asked, so it retires that
            // request: left outstanding it would stand in front of every later reply. It is not a
            // capture — the presentation waiting on a stash is resumed as having failed.
            guard let request = takeRequest(answeredBy: surface) else { return }
            if case .stash = request.kind { finishStash(request.id, captured: false) }
        }
    }

    /// **The one door an editor event has into buffer state**, and the only site in this file that
    /// moves the focus.
    ///
    /// Every defect two review rounds found was a variant of one thing: state moved before the
    /// event that moved it had been checked against the path, the surface and the presentation it
    /// belonged to. So the checks happen here, once, in that order, and the buffer refuses what
    /// fails them — `BufferState.apply` re-checks the path itself, because a buffer that trusts
    /// its caller is a buffer whose next caller forgets.
    ///
    /// The focus follows an event the buffer **accepted**: a `dirty` report the buffer refused is
    /// another window's model being replaced, and taking it as "the window the user is in"
    /// handed the next save to the window that does not hold the edits.
    private func apply(_ event: EditorEvent, from surface: SurfaceID) {
        switch event {
        case .dirty(let path, let isDirty):
            // A clean report the session **caused** is not the user having saved. `open` and
            // `setText` replace the model and leave the buffer clean, and the bridge says so for
            // the path it replaced — including the same path, which is what re-opening a stashed
            // buffer at the file it came from does. Accepting it dropped the unsaved marker from
            // a buffer whose edits are all still there. Only a real transition back to dirty
            // retires the expectation, and a clean report can only follow one.
            if !isDirty, path == replacedBufferPath { return }
            // Only the presented buffer may report its dirtiness, and only about its own path:
            // `replaceModel` reports the *previous* file clean as it swaps the model, and a
            // delayed one of those moved the buffer's owner to the window that had just been given
            // something else to show.
            guard path == presentedPath,
                  let index = openFiles.firstIndex(where: { $0.path == path }),
                  openFiles[index].buffer.apply(event, from: surface) else { return }
            if isDirty {
                replacedBufferPath = nil
                focused = surface
            }
        case .cursor(let line, let column):
            // A move this session asked for is not the user moving: `gotoLine` goes to every
            // window and comes back from every window, and taking that as evidence made a
            // background window the save target.
            let commanded = commandedPositions.contains(Position(line: line, column: column))
            if !commanded {
                commandedPositions.removeAll()
                // And a cursor is not the buffer. A window reports a position for a click or a
                // scroll while holding whatever this session last broadcast to it; the window that
                // reported the buffer *dirty* is the one holding text nobody else has. Moving
                // ownership on a cursor let `save` read the stale window's buffer, write it, and
                // then broadcast `setText` over the edits it had just overwritten.
                let holder = presentedBufferHolder
                if holder == nil || holder == surface { focused = surface }
            }
            guard let path = presentedPath,
                  let index = openFiles.firstIndex(where: { $0.path == path }),
                  openFiles[index].buffer.apply(event, from: surface) else { return }
            Task { await self.persist() }
        case .ready, .saveRequested, .error:
            break
        }
    }

    /// Broadcasts to every attached editor, so the main window and a popped-out one show the same
    /// file. With nothing attached the command is queued for the first surface that arrives.
    private func send(_ command: EditorCommand) {
        note(command)
        prune()
        let live = surfaces.compactMap(\.surface)
        // Nothing to draw into. Nothing is queued either: what the session is presenting is state,
        // and the surface that arrives next is brought up to date from it (`bringUpToDate`).
        guard !live.isEmpty else { return }
        for surface in live { surface.send(command) }
    }

    /// What a command about to reach an editor means for the session's picture of it.
    ///
    /// Which pane the bridge is showing follows from the command, exactly as it does inside the
    /// bridge: `open`, `setText` and `gotoLine` all show the editor first, `showDiff` shows the
    /// diff. Deriving it here is what stops the two from drifting. And what the session is about to
    /// make the editor report back: the buffer it replaces goes clean, and the cursor lands where
    /// the command put it. Both come back as events that look exactly like the user's own, and
    /// neither is (see `apply`).
    private func note(_ command: EditorCommand) {
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
        case .setTheme(let name):
            pendingTheme = name
        case .save:
            break
        }
    }

    /// The surface a `save` is addressed to: the one the user is in, or the only one there is.
    /// Broadcasting `save` would have every window answer for its own buffer, and the last answer
    /// would win.
    private var focusedSurface: SurfaceBox? {
        if let focused, let box = surfaces.first(where: { $0.id == focused && $0.surface != nil }) {
            return box
        }
        return surfaces.last { $0.surface != nil }
    }

    /// The surface holding text no other surface has, for the buffer on screen.
    ///
    /// A dirty presented file *is* that state: the flag was set by the surface that reported it,
    /// and that surface is recorded as the buffer's owner in the same event. So while it stands,
    /// ownership does not move — a `dirty` report from another window is the user typing there and
    /// takes it, a cursor is not. Nothing needs clearing: the flag is the state.
    private var presentedBufferHolder: SurfaceID? {
        guard let presentedPath,
              let file = openFiles.first(where: { $0.path == presentedPath }) else { return nil }
        return file.buffer.holder
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
        // What is on the surface when this started. `selectedPath` alone does not answer it: a
        // diff claims the surface without claiming a selection, so a restore checking only the
        // selection walked straight over one the user asked for inside a suspension below.
        let generation = presentation
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
                                      rendersMarkdown: record.rendersMarkdown,
                                      hasConflict: false, keepsMine: false, isMissing: false,
                                      isNotText: loaded.isNotText,
                                      buffer: BufferState(path: url.path(percentEncoded: false),
                                                          text: loaded.text,
                                                          holdsText: loaded.holdsText,
                                                          lastLoaded: loaded.snapshot,
                                                          line: record.line,
                                                          column: record.column)))
            if let snapshot = loaded.snapshot { await beginWatching(url, baseline: snapshot) }
        }
        guard selectedPath == nil, let recorded = state.selectedPath,
              let file = openFiles.first(where: { $0.path == recorded }) else { return }
        selectedPath = file.path
        // The selection is the document's; the surface is whatever is newest. A diff or a file
        // opened while this was suspended keeps it, and the restored selection is what the panel
        // comes back to when that presentation is dismissed.
        guard isCurrent(generation) else { return }
        await present(file.url, revealing: file.line, under: beginPresentation())
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
    /// The identity every correlation is made against, which outlives the reference below.
    let id: SurfaceID
    weak var surface: (any EditorSurface)?
    init(id: SurfaceID, surface: any EditorSurface) {
        self.id = id
        self.surface = surface
    }
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
