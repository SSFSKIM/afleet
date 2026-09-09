// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import AfleetCore
import FleetKit
import Foundation
import Observation
import PanelHostAPI

/// The question a pane asks before it closes a child that is still alive (spec Design §2, gate
/// G3.3).
///
/// It is state rather than an `NSAlert` so that both answers can be given headlessly, and it
/// carries `namesChannelReturn` as a fact rather than as a phrase for a test to match: a hatch
/// pane holds a channel X5 released, and closing it is what makes the channel owned again.
public struct PaneCloseConfirmation: Hashable, Sendable {
    /// Which pane is being closed. Identity, because a pane carries no id of its own.
    public let paneID: ObjectIdentifier
    public let question: String
    public let namesChannelReturn: Bool
}

/// One channel's pane stack: the panes, the selection, the W6 document, and the single obligation
/// the panel owes X5 — exactly one `PaneExit` per pane that came from a `PaneRequest`, and none at
/// all for a pane the panel made itself.
///
/// The host retains one of these per (tab, channel) and hands it to every renderer of that pair,
/// which is why a pane's life is anchored here and never in SwiftUI `@State`: a tab that kept its
/// pane in `@State` would lose it on every channel switch.
@MainActor
@Observable
public final class TerminalPanelSession: PanelTabSession {
    /// The channel this session was made for. Every pane it opens takes its cwd, its environment
    /// and its shell from here, and every exit it reports leaves through here.
    public let context: ChannelContext

    public private(set) var panes: [TerminalPane] = []
    public private(set) var selectedIndex: Int?

    /// The standing question, if one has been asked. The view renders it; ``confirmPendingClose()``
    /// and ``cancelPendingClose()`` are the two answers.
    public private(set) var pendingClose: PaneCloseConfirmation?

    public var selectedPane: TerminalPane? {
        guard let selectedIndex, panes.indices.contains(selectedIndex) else { return nil }
        return panes[selectedIndex]
    }

    /// Called whenever the pane count changes, so the registry can move a session between its
    /// strong and weak halves. It is a callback rather than observation because the retention rule
    /// has to be exact at the moment the count crosses zero, not at the next observation turn.
    @ObservationIgnored public var paneCountDidChange: (@MainActor (TerminalPanelSession) -> Void)?

    /// Which panes have already had their one exit reported. Keyed by identity because the answer
    /// is about *this* pane object, and a pane carries no id of its own.
    @ObservationIgnored private var reportedPanes: Set<ObjectIdentifier> = []
    /// The write in flight, chained so two mutations in one turn cannot land out of order. The
    /// document has one writer, so serialising it here is the whole of the concurrency story.
    @ObservationIgnored private var persistence: Task<Void, Never>?
    /// How far the one read of the W6 document has got. Nothing is written before it is `.done`:
    /// a session that wrote first would write over shells it has never seen (see
    /// ``schedulePersist()``).
    @ObservationIgnored private var reading: DocumentRead = .pending
    /// The one restore, kept so a re-render can be told it already happened and so a test can wait
    /// for it. `nil` until the first render — or the first pane — asks (see ``restoreOnce()``).
    @ObservationIgnored private var restoration: Task<Void, Never>?
    /// The closes in flight, by pane. A second close of one pane joins the first and mutates
    /// nothing: both would otherwise be holding a position in `panes` from before the suspension,
    /// so the second would remove a neighbour and report a second exit for one request.
    ///
    /// It is kept even though `TerminalPane.close()` now coalesces its own teardown, because the
    /// two guard different things: the pane's coalescing is about the child, the loop and the
    /// surface, and this is about *this session's* stack, its selection and its one exit per pane.
    /// It is also what `restart(_:)` and ``tearDown()`` read to know a close is still standing.
    @ObservationIgnored private var closes: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The pane the standing question is about, held by reference because the confirmation value
    /// carries only its identity.
    @ObservationIgnored private var paneAwaitingClose: TerminalPane?
    /// Whether this session has been torn down. A released session writes nothing, restores
    /// nothing and spawns nothing, whenever the read it is suspended in comes back: its owner has
    /// gone, so a pane opened from here is a child nobody is left to close.
    @ObservationIgnored private var isReleased = false
    /// Whether a pane has ever stood in this stack. The difference between a session that has done
    /// nothing yet and one whose stack is empty because the user emptied it (see ``restore``).
    @ObservationIgnored private var hasEverHeldAPane = false
    /// The teardown of whatever session held this channel before, if one is still finishing. The
    /// read waits for it, because two sessions writing one key with nothing between them is the
    /// one ordering the document's single-writer rule does not cover.
    @ObservationIgnored var precedingWork: Task<Void, Never>?

    /// The three states of the one document read, in order. They exist because the read is a
    /// suspension the rest of the session goes on running through.
    private enum DocumentRead {
        /// Nobody has asked yet, and nothing may be written.
        case pending
        /// The read is in flight. A mutation is welcome; its write waits for the read to land.
        case reading
        /// Read, and reconciled with whatever the session held. Writes go out from here on.
        case done
    }

    public init(context: ChannelContext) {
        self.context = context
    }

    public var storeKey: String { TerminalPanelState.storeKey(for: context.key) }

    /// Brings a pane to the front. The selection is part of the W6 document, so choosing a pane is
    /// a write like opening one.
    public func select(_ index: Int) {
        guard panes.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        schedulePersist()
    }

    // MARK: Opening

    /// A pane the panel made itself: `ResolvedEnvironment.shell` with `-i`, in the channel's cwd
    /// unless one is named, with `ResolvedEnvironment.variables`.
    ///
    /// `-i` and not `-l`. X11's capture already *is* the login shell's environment, so a login
    /// shell would re-source the login files and prepend PATH a second time, breaking item 23's
    /// equality; an interactive shell still sources the user's rc file, which is what makes
    /// aliases and the prompt appear.
    @discardableResult
    public func openShellPane(cwd: URL? = nil) -> TerminalPane {
        let pane = TerminalPane()
        pane.startShell(
            executable: URL(fileURLWithPath: context.environment.shell),
            arguments: ["-i"],
            cwd: cwd ?? context.cwd,
            environment: context.environment.variables
        )
        append(pane)
        return pane
    }

    /// An X5-originated pane. The request is run unchanged and its exit is echoed back with the
    /// request by value, `id` included.
    @discardableResult
    public func run(_ request: PaneRequest) -> TerminalPane {
        let pane = TerminalPane()
        pane.onTerminated = { [weak self, weak pane] termination in
            guard let self, let pane else { return }
            report(PaneSpawn.exit(of: request, termination: termination, at: Date()), for: pane)
        }
        pane.start(request)
        append(pane)
        // The failed-spawn arm. A spawn that never executed fires no termination, so without this
        // C4 would wait on the request's id for ever and the channel it released would never come
        // back. 127 is the one status the panel synthesises rather than observes.
        if case .failed = pane.state {
            report(
                PaneExit(request: request, code: PaneSpawn.unexecutableExitCode, observedAt: Date()),
                for: pane
            )
        }
        return pane
    }

    // MARK: Closing

    /// The close a person asks for. A pane whose child is still alive raises the question instead
    /// of closing; a pane whose child has ended closes at once, because there is nothing to lose.
    public func requestClose(_ pane: TerminalPane) async {
        guard panes.contains(where: { $0 === pane }) else { return }
        guard pane.hasLiveChild else {
            await close(pane)
            return
        }
        paneAwaitingClose = pane
        pendingClose = confirmation(for: pane)
    }

    /// Yes. The pane closes, which hangs its child up and — for an X5-originated pane — reports
    /// the one exit C4 is waiting on.
    public func confirmPendingClose() async {
        guard let pane = paneAwaitingClose else { return }
        pendingClose = nil
        paneAwaitingClose = nil
        await close(pane)
    }

    /// No. The pane and its child are left exactly as they were.
    public func cancelPendingClose() {
        pendingClose = nil
        paneAwaitingClose = nil
    }

    /// Reopens a shell pane in its own slot, in the directory it was running in.
    ///
    /// Only a pane the panel made itself: a `PaneRequest` pane is nobody's to re-run here (spec
    /// Design §6), which is why this returns `nil` rather than restarting one.
    @discardableResult
    public func restart(_ pane: TerminalPane) async -> TerminalPane? {
        guard pane.request == nil,
              panes.contains(where: { $0 === pane }),
              closes[ObjectIdentifier(pane)] == nil
        else {
            return nil
        }
        let cwd = pane.spawn?.cwd
        await pane.close()
        // Asked again after the suspension, and this is the whole of the arbitration between the
        // two. The check on the way in cannot see a close the user asks for *inside* the teardown,
        // and which of the two resumes first is the runtime's to decide: a restart that resumed
        // first dropped the pane and put a fresh shell in its slot, so the close resuming after it
        // could no longer find a pane of its own to remove and returned — telling the user their
        // pane had closed while the slot held a running child. A restart yields, because a person
        // who has asked for a pane to go has said the later thing about it.
        guard closes[ObjectIdentifier(pane)] == nil else { return nil }
        // Resolved after the suspension and never before it: a pane opened or closed while the
        // child was being torn down has moved every position after its own, and the old one now
        // names a neighbour — or nothing at all.
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return nil }
        // Whether the pane being replaced still held the selection, asked at the position it
        // actually sits in now. The user goes on using the panel through the suspension above, and
        // a restart that took the selection unconditionally pulled the tab off the pane they chose
        // — or the pane they opened — inside it, and wrote that over the document.
        let wasSelected = selectedIndex == index
        panes.remove(at: index)
        reportedPanes.remove(ObjectIdentifier(pane))
        if paneAwaitingClose === pane { cancelPendingClose() }
        let fresh = TerminalPane()
        fresh.startShell(
            executable: URL(fileURLWithPath: context.environment.shell),
            arguments: ["-i"],
            cwd: cwd ?? context.cwd,
            environment: context.environment.variables
        )
        // The removal and the insertion are at one index, so every other position is unchanged and
        // a selection standing on one of them still names the pane it named.
        panes.insert(fresh, at: index)
        if wasSelected { selectedIndex = index }
        paneCountDidChange?(self)
        schedulePersist()
        return fresh
    }

    /// A hatch pane names what is waiting on it; every other pane says only that a process is
    /// running, because that is all that is true of it.
    private func confirmation(for pane: TerminalPane) -> PaneCloseConfirmation {
        let isHatch: Bool = if case .hatch = pane.request?.purpose { true } else { false }
        return PaneCloseConfirmation(
            paneID: ObjectIdentifier(pane),
            question: isHatch
                ? "This channel is in the CLI's own client and is waiting to become owned again. "
                    + "Closing this pane ends that client and returns the channel."
                : "A process is still running in this pane. Closing it ends that process.",
            namesChannelReturn: isHatch
        )
    }

    /// Ends the pane, drops it, moves the selection to a neighbour and rewrites the document.
    /// Closing the last pane leaves none: a Terminal tab with no pane is a state the view renders,
    /// not one this method papers over by opening another.
    ///
    /// Two closes of one pane are one close: the second awaits the first and returns, rather than
    /// mutating a second time over a position the first is still holding.
    public func close(_ pane: TerminalPane) async {
        let identity = ObjectIdentifier(pane)
        if let inFlight = closes[identity] {
            await inFlight.value
            return
        }
        // The entry is cleared inside the task and not after the await, so that by the time anyone
        // waiting on this close is resumed the close is no longer standing. ``tearDown()`` reads
        // the map to decide whether it may put the session away, and an entry outliving its own
        // work would leave it looping over a close that has already finished.
        let close = Task { @MainActor [weak self] in
            guard let self else { return }
            await performClose(pane)
            closes[identity] = nil
        }
        closes[identity] = close
        await close.value
    }

    /// Whether a close of this pane is standing. Diagnostic: it exists so "the user's close was
    /// already registered" is an assertion rather than a recollection.
    func isClosing(_ pane: TerminalPane) -> Bool {
        closes[ObjectIdentifier(pane)] != nil
    }

    private func performClose(_ pane: TerminalPane) async {
        guard panes.contains(where: { $0 === pane }) else { return }
        // A question about a pane that is going away has nothing left to ask.
        if paneAwaitingClose === pane { cancelPendingClose() }
        await pane.close()
        // Resolved after the suspension: the stack may have moved while the child was being torn
        // down, and a pane that is no longer here has already been reported and dropped.
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        reportExitIfOwed(by: pane)
        let wasSelected = selectedIndex == index
        panes.remove(at: index)
        reportedPanes.remove(ObjectIdentifier(pane))
        if panes.isEmpty {
            selectedIndex = nil
        } else if wasSelected {
            selectedIndex = min(index, panes.count - 1)
        } else if let selectedIndex, selectedIndex > index {
            self.selectedIndex = selectedIndex - 1
        }
        paneCountDidChange?(self)
        schedulePersist()
    }

    /// Ends every pane because the session itself is going — `AppModel.bindWorkspace` rebinding,
    /// or a context from another workspace arriving for this channel.
    ///
    /// It differs from ``close(_:)`` in the one way that decides the channel's next launch:
    /// **nothing is written**. The W6 document belongs to the channel and not to this session, so a
    /// teardown that persisted its own emptying would hand the channel back with no shell and no
    /// selection — the user's saved setup destroyed by the act of putting it away. A user closing
    /// a pane is the only thing that removes it from the document.
    ///
    /// Which is why it **waits for the closes already standing** before it puts anything away. A
    /// close suspends while its child is torn down, and a teardown that emptied `panes` inside
    /// that suspension left it with no pane to find and nothing to persist — the shell the user
    /// had explicitly closed still in the document, to be restored the next time the channel
    /// opened. The two rules are not in tension once they are ordered: the user's removal is
    /// written by the close that was already in flight, and the teardown still writes nothing of
    /// its own.
    func tearDown() async {
        // The **live** map, not a snapshot of it. A user closing a second shell while this is
        // waiting is an ordinary click, and a close begun inside the wait was not in the snapshot:
        // emptying the stack under it left it unable to find its own pane, so it wrote nothing and
        // the shell the user had closed came back the next time the channel opened.
        while let close = closes.values.first { await close.value }
        isReleased = true
        paneCountDidChange = nil
        pendingClose = nil
        paneAwaitingClose = nil
        let ending = panes
        panes = []
        selectedIndex = nil
        for pane in ending {
            await pane.close()
            // Still owed: C4 is waiting on the id of every X5-originated pane, and a workspace
            // going away does not make that pane's exit stop having happened.
            reportExitIfOwed(by: pane)
        }
        // The writes the user's own actions had already scheduled are let land, and are awaited
        // here rather than abandoned: what a caller may not be left with after `settleRelease()`
        // is a write of this session's still in flight, racing the session that replaces it.
        await persistence?.value
        persistence = nil
    }

    // MARK: W6

    /// Reopens the shell panes the document records, or one shell pane when there is nothing to
    /// read. An absent document and one written under a `schemaVersion` this build does not know
    /// are the same answer and neither throws: a panel that refused to open because its own state
    /// file was from another version would be a channel the user cannot get a terminal in.
    ///
    /// Read once, and once only — the second ask is a no-op, because reading the same document
    /// into the panes it already opened is how a stack doubles.
    public func restore() async {
        await restore(openingDefaultPane: true)
    }

    /// `openingDefaultPane` is the difference between the two askers. A renderer must not be shown
    /// an empty Terminal tab, so it gets one shell pane when there is nothing to read; the read a
    /// pane request triggers is only there to make the write safe, and a panel that opened a shell
    /// nobody asked for in a channel nobody is looking at would be spawning on its own initiative.
    private func restore(openingDefaultPane: Bool) async {
        guard reading == .pending, !isReleased else { return }
        reading = .reading
        // The session this channel had before this one, if its teardown is still landing. Reading
        // in front of its last write would restore a document a moment older than the truth.
        await precedingWork?.value
        let document = try? await context.store.read(TerminalPanelState.self, key: storeKey)
        // Released inside the read. `reading` is deliberately left short of `.done`, so nothing
        // this session is asked for afterwards can write either: a teardown that has already been
        // settled must not be followed by panes, children or a document.
        guard !isReleased else { return }
        // Read after the suspension: whatever the session did during it is what the document is
        // being reconciled with, and it is that state — not the empty one this began in — that
        // decides whether there is a tab to fill and a selection to leave alone.
        let held = !panes.isEmpty
        let selectionHeld = selectedIndex
        if let document,
           document.schemaVersion == TerminalPanelState.currentSchemaVersion,
           !document.panes.isEmpty {
            for persisted in document.panes {
                openShellPane(cwd: persisted.cwd.map { URL(fileURLWithPath: $0) })
            }
            if held {
                // The session chose a pane before the document arrived. That choice is the user's
                // and the document's is stale, so the restored shells go behind it.
                selectedIndex = selectionHeld
            } else if let selected = document.selected, panes.indices.contains(selected) {
                selectedIndex = selected
            }
        } else if openingDefaultPane, !held, !hasEverHeldAPane {
            // The one shell of an empty document belongs to a session that has done nothing yet.
            // A user who opened a pane inside this read and closed it again has already said what
            // the tab holds, and `close()` leaves the last pane's place empty on purpose.
            openShellPane()
        }
        reading = .done
        // The one write of everything the two halves came to: the panes the document named, the
        // panes the session opened while it was being read, and the selection standing over them.
        schedulePersist()
    }

    /// Reads the W6 document once for the life of this session, and never again.
    ///
    /// The tab calls it on every render because a render is a moment a session can be sure of:
    /// it may have been made by the pane runner for a channel no window was showing, long before
    /// anything rendered. Idempotent, so the second render is not a second restore — which would
    /// otherwise double the channel's panes on every redraw.
    public func restoreOnce() {
        requestRead(openingDefaultPane: true)
    }

    /// Returns once the one restore has landed. Tests await it; nothing in the app needs to.
    public func settleRestore() async {
        await restoration?.value
    }

    /// Returns once every scheduled write has landed — including the one a restore still owes,
    /// since nothing is written before the document has been read. Tests await it; nothing in the
    /// app needs to.
    public func settlePersistence() async {
        await restoration?.value
        await persistence?.value
    }

    private func requestRead(openingDefaultPane: Bool) {
        guard restoration == nil, reading == .pending else { return }
        restoration = Task { await self.restore(openingDefaultPane: openingDefaultPane) }
    }

    private func schedulePersist() {
        // Nothing is written until the document has been read. A session the pane runner made for
        // a channel no window is showing holds no persistable pane at all, so its write would be
        // an empty document over the channel's saved shells — and a mutation standing inside the
        // read would race the reconciliation. Both wait for the same moment; ``restore`` ends by
        // asking for this write again.
        guard reading == .done, !isReleased else { return }
        let shellPanes = panes.enumerated().filter { $0.element.request == nil }
        let document = TerminalPanelState(
            panes: shellPanes.map { PersistedPane(cwd: $0.element.spawn?.cwd.path) },
            // An index into the array being written, and not into the full stack: the restore
            // reads it back against the shell panes alone, so a stack with a request pane in front
            // of them would come back selecting the pane after the right one.
            selected: selectedIndex.flatMap { selected in
                shellPanes.firstIndex { $0.offset == selected }
            }
        )
        let store = context.store
        let key = storeKey
        let previous = persistence
        persistence = Task {
            await previous?.value
            try? await store.write(document, key: key)
        }
    }

    // MARK: Internals

    private func append(_ pane: TerminalPane) {
        // A pane is the first thing that could put a write in front of the read, so it is also
        // what makes the document be read when no renderer has asked yet.
        requestRead(openingDefaultPane: false)
        hasEverHeldAPane = true
        panes.append(pane)
        selectedIndex = panes.count - 1
        paneCountDidChange?(self)
        schedulePersist()
    }

    /// The close arm of "exactly one `PaneExit` per X5-originated pane, ever". A pane the user
    /// closes while its child is alive was hung up by `close()`, so it is reported with the status
    /// a hung-up child carries; one that had already exited reports what was observed.
    private func reportExitIfOwed(by pane: TerminalPane) {
        guard let request = pane.request else { return }
        let code: Int32 = switch pane.state {
        case let .exited(termination): termination.paneExitCode
        case .failed: PaneSpawn.unexecutableExitCode
        case .starting, .running, .stopped: TerminalPane.closedExitCode
        }
        report(PaneExit(request: request, code: code, observedAt: Date()), for: pane)
    }

    private func report(_ exit: PaneExit, for pane: TerminalPane) {
        let identity = ObjectIdentifier(pane)
        guard !reportedPanes.contains(identity) else { return }
        reportedPanes.insert(identity)
        let reporter = context.reportPaneExit
        Task { await reporter(exit) }
    }
}
