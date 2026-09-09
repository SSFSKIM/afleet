// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §1, §3, §5, §6, §7. Gates G1.1, G1.3, G1.4, G1.5, G3's `.commit` half, G4.
import Foundation
import Observation
import AfleetCore
import PanelHostAPI
import SourceControlCore

/// The `PanelTabSession` X7's host retains for (`.sourceControl`, channel): the loaded window, the
/// lane assignment, the watch, the selection, the two details, the panel-local error state, and the
/// `.commit` target's delivery.
///
/// **It is a reader** (§9.2, binding). Every invocation it makes goes through `RepositoryReader` or
/// straight into C7.3's `WorkingTreeStatus`, and there is no seam here through which `add`,
/// `commit`, `checkout`, `branch`, `stash`, `reset` or `push` could be spelled: no command line is
/// written in this file. That is what makes G4's claim structural rather than a promise, and
/// `SourceControlReadout.Action` is its other half — the complete inventory of what any surface of
/// this tab offers.
///
/// **A diff is a link and nothing else** (Design §6, ruled at C7.5's merge). Clicking a changed file
/// emits `.diff(DiffRef(…))` through the channel's `LinkRouterCapability`; the Files tab's target
/// opens the pair, brings its tab forward and pops out. This model selects no tab, names no tab id
/// and constructs no editor.
@MainActor
@Observable
public final class SourceControlModel: PanelTabSession {

    /// What the detail pane is showing. Row zero is the working tree's exactly when the tree is
    /// dirty (C7.3's rule), so `.workingTree` is selectable exactly while that row exists.
    public enum Selection: Hashable, Sendable {
        case workingTree
        case commit(String)
    }

    /// The panel-local rows this model raises on its own — the ones that are not a tool failure.
    ///
    /// Every one of them is an answer to a `.commit` delivery that selected nothing (Design §7).
    /// A link that reached a live target and produced nothing on screen is the failure §17.7 exists
    /// to prevent, so there is no silent no-op among these cases and none is elided.
    public enum DeliveryNotice: Hashable, Sendable {
        /// Searched the window and up to `pagingBound` pages beyond it, and did not find it.
        case commitNotFound(hash: String)
        /// An abbreviation that names more than one commit. Never an arbitrary pick.
        case ambiguousPrefix(prefix: String, matches: Int)
        /// A delivery into a channel whose folder is in no repository at all.
        case noRepository(hash: String)
    }

    /// How many pages beyond the loaded window a `.commit` delivery searches (Design §7).
    ///
    /// A bound and not "until the history ends", for the reason `LinkRouter`'s re-resolution bound
    /// is one: an unbounded walk over a million-commit repository is a panel that never answers.
    /// Paging is the *only* answer available — W7 makes every git invocation C7.3's and C7.3 ships
    /// no "does this object exist" reader — which is why this is a search and not a lookup.
    public static let pagingBound = 5

    private let reader: RepositoryReader
    private let environment: ResolvedEnvironment
    private let runner: any ToolRunning
    /// The routing seam. Nil is a model with nowhere to emit — a test double's case, and one where
    /// a click is a no-op rather than a crash.
    private let links: (any LinkRouterCapability)?
    private let windowLimit: Int
    private let watchesForChanges: Bool
    private var watch: RepositoryWatch?

    /// Everything one read cycle produced (spec §3): the root, the status, the window, the lanes,
    /// and the one panel-local error row.
    public private(set) var state = RepositoryState()
    public private(set) var selection: Selection?
    /// The selected row's changed files — a commit's against its first parent, or the working
    /// tree's against `HEAD`. Never `WorkingTreeStatus.entries`, which answers a different question
    /// (Design §6).
    public private(set) var changes: [FileChange] = []
    public private(set) var deliveryNotice: DeliveryNotice?
    public private(set) var isLoading = false
    public private(set) var isLoadingDetail = false
    /// Whether a read cycle has ever finished, so `activate()` is idempotent across the redraws a
    /// channel switch causes. A **cancelled** cycle does not finish and does not latch it.
    public private(set) var hasRead = false
    /// Whether the FSEvents stream is armed. False before the first read, after `deactivate()`,
    /// and after a root that went away.
    public private(set) var isWatchArmed = false
    /// A watch that was **asked for** and could not be created. It is kept apart from
    /// `isWatchArmed` because a model built without a watch at all is not a panel with a broken
    /// one, and only the second has something to say to the user.
    public private(set) var watchFailedToArm = false

    /// The cycle that owns the repository document. Claimed synchronously before the first await
    /// and re-checked after every one: four doors open a read — `activate`, `refresh`, the watch and
    /// a `.commit` delivery's paging — and each of them is a suspension the next can start inside.
    ///
    /// Without it two cycles interleave and the *loser* writes last: a watch-driven re-read that
    /// started first finishes after the user's Refresh and assigns a window read before the commit
    /// the user was waiting to see.
    private var generation = 0
    /// The **detail** read's own generation, kept apart from the cycle's on purpose. A commit's
    /// changed-file list does not depend on the window around it, so a watch delivery landing while
    /// the list is in flight must not throw the list away — a repository under an active `claude`
    /// session delivers often enough that a shared counter would leave the detail pane empty
    /// whenever the user clicked at the wrong moment.
    private var detailGeneration = 0

    public init(cwd: URL, environment: ResolvedEnvironment, runner: any ToolRunning = ToolRunner(),
                links: (any LinkRouterCapability)? = nil,
                windowLimit: Int = GitLog.defaultLimit,
                watchesForChanges: Bool = true) {
        reader = RepositoryReader(cwd: cwd, environment: environment, runner: runner)
        self.environment = environment
        self.runner = runner
        self.links = links
        self.windowLimit = windowLimit
        self.watchesForChanges = watchesForChanges
    }

    public convenience init(context: ChannelContext, runner: any ToolRunning = ToolRunner()) {
        self.init(cwd: context.cwd, environment: context.environment, runner: runner,
                  links: context.links)
    }

    // No `deinit` teardown: main-actor state is unreachable from one, and none is needed —
    // `RepositoryWatch` stops its own stream when the last reference to it goes away, and this
    // model holds the only one. `deactivate()` is the door for stopping it while the model lives.

    public var readout: SourceControlReadout { SourceControlReadout(session: self) }

    // MARK: - the doors

    /// The tab has been shown for this channel. Reads once and not again, and arms the watch.
    public func activate() async {
        guard !hasRead, !isLoading else { return }
        await load()
        armWatchIfNeeded()
    }

    /// The user asked, or the watch reported history. Always reads.
    public func refresh() async {
        await load()
        armWatchIfNeeded()
    }

    /// Tears the watch down. The host calls it when the session goes away; nothing else in this
    /// model needs stopping, because every read is a child task of the call that started it.
    public func deactivate() {
        watch?.stop()
        watch = nil
        isWatchArmed = false
    }

    /// Selects row zero and reads what the working tree holds that `HEAD` does not.
    public func selectWorkingTree() async {
        deliveryNotice = nil
        selection = .workingTree
        changes = []
        await loadDetail(for: .workingTree)
    }

    /// The `.commit` delivery (Design §7), and the door a graph row's click takes.
    ///
    /// `hash` may be abbreviated — a timeline row is likelier to carry seven characters than forty
    /// — and is resolved by **unambiguous** prefix. Four answers and no fifth: selected from the
    /// window, selected after paging (with the window extended so the selected row is on screen),
    /// a named row for a hash no page within the bound holds, and a named row for a prefix that
    /// names several commits.
    public func select(commit hash: String) async {
        deliveryNotice = nil
        guard let root = state.root else {
            deliveryNotice = .noRepository(hash: hash)
            return
        }
        switch Self.match(hash, in: state.commits) {
        case .one(let found):
            await choose(found)
            return
        case .ambiguous(let count):
            deliveryNotice = .ambiguousPrefix(prefix: hash, matches: count)
            return
        case .none:
            break
        }
        await page(for: hash, root: root)
    }

    /// Clicking a changed file. It emits `.diff` and does **nothing else**: no tab selection, no
    /// editor, no knowledge of Monaco (Design §6, and C7.5's target owns all of it).
    ///
    /// A gitlink and a binary file emit **no link at all** — their rows carry a stated reason
    /// instead, because a submodule's two sides are a commit object and a directory and a binary
    /// file has no lines, and a link that resolved to nothing would be worse than no link.
    public func openDiff(for change: FileChange,
                         from destination: LinkDestination = .currentPanel) async {
        guard SourceControlReadout.exclusionReason(for: change) == nil else { return }
        guard let root = state.root, let base = currentBase else { return }
        await links?.open(.diff(DiffRef(repository: root, path: change.path, base: base)),
                          from: destination)
    }

    /// The base a click in the current detail carries.
    private var currentBase: DiffRef.Base? {
        switch selection {
        case .none: nil
        case .workingTree: .workingTreeAgainstHEAD
        case .commit(let hash): .commitAgainstParent(hash)
        }
    }

    // MARK: - the watch (Design §5)

    /// One delivery from `RepositoryWatch`. Internal rather than private so the classification's
    /// three answers are drivable as a table; the stream itself is tested in `RepositoryWatchTests`.
    ///
    /// `.ignore` never arrives — the watch does not deliver it — and is answered with nothing here
    /// so that the exhaustive switch says so in one place.
    func handle(_ event: RepositoryWatch.Event) async {
        switch event {
        case .changed(.workingTree):
            await readStatus()
        case .changed(.history):
            await load()
        case .changed(.ignore):
            return
        case .rootGone:
            rootWentAway()
        }
    }

    /// The root was deleted or replaced.
    ///
    /// **The decision** (the watch reports it and asks its owner for an answer): this becomes the
    /// `.notARepository` **empty state**, not an error row and not a frozen graph. A repository
    /// that is not there and a channel that was never in one are the same thing to look at, and
    /// §3 already makes `.notARepository` the empty state; an error row would offer a remedy for
    /// something the user did on purpose — `rm -rf`, a `mv`, a worktree pruned. The watch is torn
    /// down with it, because a stream armed on an inode nobody will write again goes quiet and the
    /// panel would then show a stale repository for ever.
    private func rootWentAway() {
        generation += 1
        detailGeneration += 1
        deactivate()
        state = RepositoryState()
        selection = nil
        changes = []
        deliveryNotice = nil
        isLoading = false
        isLoadingDetail = false
    }

    private func armWatchIfNeeded() {
        guard watchesForChanges, watch == nil, let root = state.root else { return }
        let watch = RepositoryWatch(root: root) { [weak self] event in
            // The watch invokes this under its own lock and forbids re-entry, so the work is
            // handed to the main actor rather than done here.
            Task { @MainActor [weak self] in await self?.handle(event) }
        }
        self.watch = watch
        isWatchArmed = watch.start()
        watchFailedToArm = !isWatchArmed
        if !isWatchArmed { self.watch = nil }
    }

    // MARK: - the read cycle (Design §3)

    private func load() async {
        generation += 1
        let mine = generation
        isLoading = true

        let loaded = await reader.load(limit: windowLimit)
        guard mine == generation else { return }
        isLoading = false

        if let error = loaded.error, Self.isCancellation(error) {
            // A cancelled read is one this panel asked to stop, not a failure the user is owed a
            // row about: the document that was on screen stands, nothing is published, and
            // `hasRead` is not latched — otherwise the tab shows an empty graph with no notice and
            // `activate()` never reads again.
            return
        }
        state = loaded
        hasRead = true
        deliveryNotice = nil
        reconcileSelection()
        await refreshWorkingTreeDetailIfSelected()
    }

    /// §5's working-tree answer: **the status only**, and the lanes recomputed over the window
    /// already held.
    ///
    /// It is one `git status` and no `git log`, because a working-tree write cannot change the
    /// history — and `LaneAssignment.assign` is a pure function, so row zero appears and vanishes
    /// without a second process. That is what G1.5's one-second bound is bought with.
    private func readStatus() async {
        guard let root = state.root else { return }
        generation += 1
        let mine = generation

        let status: WorkingTreeStatus
        do {
            status = try await WorkingTreeStatus.read(root: root,
                                                      environment: environment.variables,
                                                      runner: runner)
        } catch ToolError.notARepository {
            guard mine == generation else { return }
            // The root stopped being a repository between two reads. The empty state is the
            // truthful answer, and the same one `.rootGone` gives.
            rootWentAway()
            return
        } catch {
            guard mine == generation else { return }
            let failure = RepositoryError(error)
            guard !Self.isCancellation(failure) else { return }
            state.error = failure
            return
        }
        guard mine == generation else { return }
        state.status = status
        state.error = nil
        state.assignment = LaneAssignment.assign(commits: state.commits, headOID: status.headOID,
                                                 workingTreeIsDirty: !status.isClean)
        reconcileSelection()
        await refreshWorkingTreeDetailIfSelected()
    }

    /// Drops a selection the new state does not hold.
    ///
    /// Only two of them: the empty state holds no rows at all, and a working tree that went clean
    /// no longer has a row zero to keep selected. A commit selected and then paged out of the
    /// window keeps its detail — the commit still exists, and the pane it is drawn in is not the
    /// graph.
    private func reconcileSelection() {
        if state.isEmptyState {
            selection = nil
            changes = []
            return
        }
        if selection == .workingTree, state.status?.isClean != false {
            selection = nil
            changes = []
        }
    }

    private func refreshWorkingTreeDetailIfSelected() async {
        guard selection == .workingTree else { return }
        await loadDetail(for: .workingTree)
    }

    // MARK: - the detail (Design §6)

    private func choose(_ commit: GitCommit) async {
        selection = .commit(commit.hash)
        changes = []
        await loadDetail(for: .commit(commit.hash))
    }

    /// One read per selection, and the answer is published only if it is still the selection.
    private func loadDetail(for selection: Selection) async {
        guard let root = state.root else { return }
        detailGeneration += 1
        let mine = detailGeneration
        isLoadingDetail = true

        let result: RepositoryResult<[FileChange]>
        switch selection {
        case .workingTree:
            result = await reader.workingTreeChanges(root: root)
        case .commit(let hash):
            result = await reader.changes(in: hash, root: root)
        }
        // The selection may have moved on, the whole repository may have been re-read under a
        // different root, or the panel may have been torn down; a stale answer writes nothing.
        guard mine == detailGeneration, self.selection == selection, state.root == root else {
            return
        }
        isLoadingDetail = false
        switch result {
        case .value(let changes):
            self.changes = changes
        case .notARepository:
            rootWentAway()
        case .failed(let error):
            guard !Self.isCancellation(error) else { return }
            changes = []
            state.error = error
        }
    }

    // MARK: - paging for a `.commit` delivery (Design §7)

    /// Walks backwards in `windowLimit` steps up to `pagingBound` pages, matching on the full hash
    /// or an unambiguous prefix.
    ///
    /// A page that finds the hash **extends the window**, so the graph the user then sees actually
    /// contains the row that was selected; a search that finds nothing leaves the window exactly as
    /// it was, because a panel that silently grew its graph on a failed delivery would answer a
    /// question nobody asked. The walk also stops early when a page returns no more commits than
    /// the last one: the history has ended, and four more reads of the same listing would say the
    /// same thing.
    private func page(for hash: String, root: URL) async {
        generation += 1
        let mine = generation
        isLoading = true

        var window = state.commits
        for _ in 0..<Self.pagingBound {
            let result = await reader.page(after: window, root: root, limit: windowLimit)
            guard mine == generation else { return }
            switch result {
            case .notARepository:
                rootWentAway()
                deliveryNotice = .noRepository(hash: hash)
                return
            case .failed(let error):
                isLoading = false
                guard !Self.isCancellation(error) else { return }
                state.error = error
                return
            case .value(let paged):
                let grew = paged.count > window.count
                window = paged
                switch Self.match(hash, in: window) {
                case .one(let found):
                    isLoading = false
                    publish(window: window)
                    await choose(found)
                    return
                case .ambiguous(let count):
                    isLoading = false
                    deliveryNotice = .ambiguousPrefix(prefix: hash, matches: count)
                    return
                case .none:
                    guard grew else {
                        isLoading = false
                        deliveryNotice = .commitNotFound(hash: hash)
                        return
                    }
                }
            }
        }
        isLoading = false
        deliveryNotice = .commitNotFound(hash: hash)
    }

    /// Replaces the window and re-assigns lanes over it. The status is the one already held: a
    /// window grown to reach a commit says nothing new about the working tree.
    private func publish(window: [GitCommit]) {
        state.commits = window
        state.assignment = LaneAssignment.assign(commits: window, headOID: state.status?.headOID,
                                                 workingTreeIsDirty: state.status?.isClean == false)
    }

    // MARK: - matching, and the one classification this model makes

    enum Match {
        case none
        case one(GitCommit)
        case ambiguous(Int)
    }

    /// A full hash, or an abbreviation resolved by prefix.
    ///
    /// An exact hash wins outright, so a full hash is never reported ambiguous by a prefix rule.
    /// Several prefix matches are `ambiguous` and never a pick: the arbitrary one is wrong as often
    /// as it is right and says nothing about being either.
    static func match(_ hash: String, in commits: [GitCommit]) -> Match {
        guard !hash.isEmpty else { return commits.isEmpty ? .none : .ambiguous(commits.count) }
        if let exact = commits.first(where: { $0.hash == hash }) { return .one(exact) }
        let matches = commits.filter { $0.hash.hasPrefix(hash) }
        switch matches.count {
        case 0: return .none
        case 1: return .one(matches[0])
        default: return .ambiguous(matches.count)
        }
    }

    /// Whether a row the reader produced is the **cancelled** one.
    ///
    /// `RepositoryError` classifies rather than tags, so the comparison is against the reader's own
    /// mapping of `ToolError.cancelled` and never against a literal: a re-worded detail moves both
    /// sides together, and `SourceControlModelTests` pins the pair. A cancellation is not a failure
    /// — the panel asked the read to stop — so it publishes no row, clears no document and latches
    /// no "has read" flag.
    static func isCancellation(_ error: RepositoryError) -> Bool {
        error == RepositoryError(ToolError.cancelled(tool: error.tool), tool: error.tool)
    }
}
