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
    @ObservationIgnored private var isRestoring = false
    /// The one restore, kept so a re-render can be told it already happened and so a test can wait
    /// for it. `nil` until the tab's first render asks (see ``restoreOnce()``).
    @ObservationIgnored private var restoration: Task<Void, Never>?
    /// The pane the standing question is about, held by reference because the confirmation value
    /// carries only its identity.
    @ObservationIgnored private var paneAwaitingClose: TerminalPane?

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
        guard pane.request == nil, let index = panes.firstIndex(where: { $0 === pane }) else {
            return nil
        }
        let cwd = pane.spawn?.cwd
        await pane.close()
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
        panes.insert(fresh, at: index)
        selectedIndex = index
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
    public func close(_ pane: TerminalPane) async {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        // A question about a pane that is going away has nothing left to ask.
        if paneAwaitingClose === pane { cancelPendingClose() }
        await pane.close()
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

    // MARK: W6

    /// Reopens the shell panes the document records, or one shell pane when there is nothing to
    /// read. An absent document and one written under a `schemaVersion` this build does not know
    /// are the same answer and neither throws: a panel that refused to open because its own state
    /// file was from another version would be a channel the user cannot get a terminal in.
    public func restore() async {
        let document = try? await context.store.read(TerminalPanelState.self, key: storeKey)
        isRestoring = true
        defer { isRestoring = false }
        guard let document,
              document.schemaVersion == TerminalPanelState.currentSchemaVersion,
              !document.panes.isEmpty
        else {
            openShellPane()
            isRestoring = false
            schedulePersist()
            return
        }
        for persisted in document.panes {
            openShellPane(cwd: persisted.cwd.map { URL(fileURLWithPath: $0) })
        }
        if let selected = document.selected, panes.indices.contains(selected) {
            selectedIndex = selected
        }
        isRestoring = false
        schedulePersist()
    }

    /// Reads the W6 document once for the life of this session, and never again.
    ///
    /// The tab calls it on every render because a session has no other moment it can be sure of:
    /// it may have been made by the pane runner for a channel no window was showing, long before
    /// anything rendered. Idempotent, so the second render is not a second restore — which would
    /// otherwise double the channel's panes on every redraw.
    public func restoreOnce() {
        guard restoration == nil else { return }
        restoration = Task { await self.restore() }
    }

    /// Returns once the one restore has landed. Tests await it; nothing in the app needs to.
    public func settleRestore() async {
        await restoration?.value
    }

    /// Returns once every scheduled write has landed. Tests await it; nothing in the app needs to.
    public func settlePersistence() async {
        await persistence?.value
    }

    private func schedulePersist() {
        guard !isRestoring else { return }
        let document = TerminalPanelState(
            panes: panes.filter { $0.request == nil }.map { PersistedPane(cwd: $0.spawn?.cwd.path) },
            selected: selectedIndex
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
