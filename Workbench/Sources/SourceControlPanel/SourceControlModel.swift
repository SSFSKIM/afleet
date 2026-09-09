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
        /// A delivery into a channel whose repository could not be **read**. Distinct from
        /// `noRepository`, which says the folder is in none: telling the user their folder is not
        /// a repository when `git` merely failed sends them to look at the wrong thing, so this
        /// row names the tool it was about.
        case notReadable(hash: String, tool: Tool)
        /// The search was interrupted — superseded by a background cycle, or cancelled — and the
        /// retry was interrupted too. §7 is binding that a click is owed an answer, so an
        /// interruption is reported rather than dropped.
        case searchInterrupted(hash: String)
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
    /// The root the armed stream is watching. It is a field of its own because a cycle that
    /// resolves a *different* repository must re-arm on it (§7), and "a watch exists" cannot say
    /// whether it is the right one.
    public private(set) var watchedRoot: URL?
    /// A watch that was **asked for** and could not be created. It is kept apart from
    /// `isWatchArmed` because a model built without a watch at all is not a panel with a broken
    /// one, and only the second has something to say to the user.
    public private(set) var watchFailedToArm = false

    /// **Supersession is claimed per field group** (§5, as amended at T5's review).
    ///
    /// A single counter makes every read a peer of every other, and the two reads here are not
    /// peers: a cycle writes the window, the status and the lanes, while the watch's working-tree
    /// answer writes the status alone. Given one counter the cheap read wins by starting later —
    /// it supersedes the cycle, re-assigns lanes over the *old* window, and the commit the user
    /// pressed Refresh to see never appears with nothing on screen saying so.
    ///
    /// So whoever will write the window claims `windowEpoch`, whoever will write the status claims
    /// `statusEpoch`, and a read publishes only the groups it still holds. A partial write can no
    /// longer invalidate a document that holds strictly more than it does.
    private var windowEpoch = 0
    private var statusEpoch = 0
    /// The **detail** read's own epoch. A commit's changed-file list does not depend on the window
    /// around it, so a watch delivery landing while the list is in flight must not throw the list
    /// away — a repository under an active `claude` session delivers often enough that a shared
    /// counter would empty the detail pane whenever the user clicked at the wrong moment.
    ///
    /// It is bumped by every **selection** change as well as by every root change, because those
    /// are the two things that make an answer in flight the wrong answer, and neither is visible
    /// to a counter the detail read claims for itself.
    private var detailEpoch = 0

    /// How many reads have claimed an epoch and not yet settled. `isLoading` is a function of it
    /// rather than a flag each path remembers to clear: a flag cleared on the success path alone
    /// latches on the path that skips it, and a latched flag here also disables `activate()`'s
    /// first read for the rest of the session.
    private var readsInFlight = 0
    private var detailReadsInFlight = 0

    /// Set by `deactivate()` and cleared by `activate()`. It fences a read suspended across the
    /// teardown: without it a `load()` that resumes afterwards arms an FSEvents stream nobody will
    /// stop while the session sits in the host's cache.
    private var isTornDown = false

    /// Which armed stream a queued delivery belongs to.
    ///
    /// The watch's callback hands its event to the main actor rather than handling it there, so a
    /// delivery outlives the stream that raised it: `stop()` cannot withdraw a task already
    /// queued. Bumping this on every arm and every stop is that withdrawal — an old watcher's
    /// `.rootGone` can no longer erase the repository that replaced it, and nothing enqueued
    /// before a teardown reads through the fence.
    public private(set) var armedWatchGeneration = 0

    /// The first read, held so that a `.commit` delivery arriving **before or during** it waits
    /// for it instead of racing it (Design §7, G3's headline clause).
    ///
    /// The host creates the session, schedules `activate()` separately and delivers the link; a
    /// delivery that read `state.root` in between answered `.noRepository` about a repository
    /// nobody had looked at yet. Whoever needs the first read takes this door, and the read
    /// happens once however the host orders the two.
    private var firstRead: Task<Void, Never>?

    /// The branch this panel last reported, and `nil` for "never reported one" — which is not the
    /// same as having reported a detached `HEAD`.
    private var reportedBranch: String??

    /// Called whenever the branch the panel is showing changes, including to none (Design §5,
    /// §8). The GitHub tab's session is wired to it by the app, so an external checkout re-reads
    /// that tab instead of leaving it on the branch it read first.
    ///
    /// A closure rather than a reference to the other session: the two tabs share no state (§2),
    /// and what crosses between them is a message. Whoever installs it captures weakly.
    @ObservationIgnored public var onBranchChange: (@MainActor (String?) -> Void)?

    /// Bumped by the one place `selection` is written, so a paging search that resumes after the
    /// user selected something else can tell that it is answering a question they have moved on
    /// from (§7). A detail read cannot see this through `detailEpoch` alone, which its own reads
    /// bump as well.
    private var selectionEpoch = 0

    /// One read's claim on the field groups it will write. Nil is "this read does not write that
    /// group and has no say in it".
    private struct Claim {
        var window: Int?
        var status: Int?
    }

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
    ///
    /// The watch is armed on every activation, not only on the one that read: a session that was
    /// deactivated and shown again holds its document and still needs a stream.
    public func activate() async {
        isTornDown = false
        if !hasRead, readsInFlight == 0 || firstRead != nil { await readFirst() }
        armWatchIfNeeded()
    }

    /// The first read, shared by whoever gets here first.
    ///
    /// `activate()` and a `.commit` delivery both need the document to exist, and the host runs
    /// them in whichever order it likes — so the read is a task both await rather than work either
    /// one owns. Nothing about it re-reads: a second caller joins the flight, and a caller that
    /// arrives after it finished sees `hasRead` and asks for nothing.
    private func readFirst() async {
        let mine: Task<Void, Never>
        if let firstRead {
            mine = firstRead
        } else {
            mine = Task { @MainActor [weak self] in await self?.load() }
            firstRead = mine
        }
        await mine.value
        if firstRead == mine { firstRead = nil }
    }

    /// The user asked. Always reads.
    ///
    /// It is also the answer to a delivery notice's own hint, so it clears one — which the
    /// background cycle deliberately does not (§7).
    public func refresh() async {
        deliveryNotice = nil
        await load()
        armWatchIfNeeded()
    }

    /// Tears the watch down and fences every read in flight. The host calls it when the session
    /// goes away.
    public func deactivate() {
        isTornDown = true
        invalidateEveryEpoch()
        stopWatch()
    }

    /// Selects row zero and reads what the working tree holds that `HEAD` does not.
    public func selectWorkingTree() async {
        deliveryNotice = nil
        select(.workingTree)
        await loadDetail(for: .workingTree)
    }

    /// The `.commit` delivery (Design §7), and the door a graph row's click takes.
    ///
    /// `hash` may be abbreviated — a timeline row is likelier to carry seven characters than forty
    /// — and is resolved by **unambiguous** prefix.
    ///
    /// **A click is owed an answer** (§7, as amended). §5's rule that a cancelled read publishes
    /// no notice governs the *background* reads the user did not ask for; this one the user made,
    /// so a delivery whose search was superseded or cancelled is retried, and reported if the
    /// retry cannot get through either. It is never dropped: a link that reached a live target and
    /// produced nothing on screen is the failure §17.7 exists to prevent.
    public func select(commit hash: String) async {
        deliveryNotice = nil
        // A delivery into a session whose first read has not finished waits for that read rather
        // than answering `.noRepository` about a repository nobody has looked at yet. It is here
        // and not in the tab because a delivery must work whatever order the host does things in.
        if !hasRead, !isTornDown { await readFirst() }
        for _ in 0...Self.deliveryRetries {
            guard !isTornDown else { return }
            if case .answered = await deliver(commit: hash) { return }
        }
        guard !isTornDown else { return }
        deliveryNotice = .searchInterrupted(hash: hash)
    }

    /// How many times a superseded or cancelled delivery is tried again before it is reported.
    ///
    /// One retry and not a loop: the thing that interrupts a delivery is a background cycle or a
    /// cancellation, both of which are over by the time the retry starts, and a panel that kept
    /// re-reading until it won would spend a repository's worth of `git log` on a click.
    public static let deliveryRetries = 1

    /// Whether one attempt at a delivery reached an answer, or was interrupted by something the
    /// user did not do.
    private enum Delivery {
        case answered
        case interrupted
    }

    private func deliver(commit hash: String) async -> Delivery {
        guard let root = state.root else {
            // The two are not the same thing to say. A folder in no repository is the empty state;
            // a root that did not resolve because `git` failed is a failure that must name the
            // tool it was about, or the user is sent to look at a repository that is fine.
            deliveryNotice = state.error.map { .notReadable(hash: hash, tool: $0.tool) }
                          ?? .noRepository(hash: hash)
            return .answered
        }
        // A **full** hash is decided against the window at once: it cannot become ambiguous
        // further down the history. A prefix can, and is walked (§7).
        if let exact = state.commits.first(where: { $0.hash == hash }) {
            await choose(exact)
            return .answered
        }
        return await page(for: hash, root: root)
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
    /// The door the stream's callback takes, carrying the stream it came from.
    ///
    /// Two things a queued delivery cannot otherwise know: that the session was torn down while it
    /// waited — and would then claim fresh epochs and publish through the teardown fence — and
    /// that its stream has been replaced, whose `.rootGone` would erase the repository that
    /// replaced it.
    func handle(_ event: RepositoryWatch.Event, from generation: Int) async {
        guard !isTornDown, generation == armedWatchGeneration else { return }
        await handle(event)
    }

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
    ///
    /// **And it does not latch** (§5, as amended). A `mv`, a `git worktree` churn or a checkout
    /// that replaces the directory reaches this routinely, so the read flag is cleared and the
    /// next activation reads again; the empty state's own notice carries the action that recovers
    /// it. An empty state with no way out is a panel that has to be restarted.
    private func rootWentAway() {
        invalidateEveryEpoch()
        stopWatch()
        state = RepositoryState()
        select(nil)
        deliveryNotice = nil
        hasRead = false
        reportBranchIfChanged()
    }

    /// Tells whoever asked that the branch changed, and stays quiet when it did not.
    ///
    /// Quiet is the load-bearing half: the GitHub tab's reads are network round trips on the
    /// user's own rate limit and Design §8 forbids polling them, so a notification on every cycle
    /// would be a poll by another name.
    private func reportBranchIfChanged() {
        let branch = state.status?.branch
        guard reportedBranch != .some(branch) else { return }
        reportedBranch = .some(branch)
        onBranchChange?(branch)
    }

    /// Arms the stream, or moves it onto a root that has changed under the panel (§7).
    ///
    /// `watch == nil` is not the condition: a cycle that resolves a *different* repository leaves
    /// the old stream on the old root, and edits in the new one then produce no working-tree row
    /// and `.rootGone` can never fire.
    private func armWatchIfNeeded() {
        guard watchesForChanges, !isTornDown, let root = state.root else { return }
        guard watchedRoot != root else { return }
        stopWatch()
        armedWatchGeneration += 1
        let generation = armedWatchGeneration
        let watch = RepositoryWatch(root: root) { [weak self] event in
            // The watch invokes this under its own lock and forbids re-entry, so the work is
            // handed to the main actor rather than done here — which is why the delivery carries
            // the stream it came from: a queued task outlives `stop()`.
            Task { @MainActor [weak self] in await self?.handle(event, from: generation) }
        }
        self.watch = watch
        watchedRoot = root
        isWatchArmed = watch.start()
        watchFailedToArm = !isWatchArmed
        if !isWatchArmed {
            self.watch = nil
            watchedRoot = nil
        }
    }

    private func stopWatch() {
        // Withdraws whatever this stream has already queued: `stop()` ends the stream and cannot
        // reach a task the main actor has not run yet.
        armedWatchGeneration += 1
        watch?.stop()
        watch = nil
        watchedRoot = nil
        isWatchArmed = false
        watchFailedToArm = false
    }

    // MARK: - the epochs, and the one place a loading flag is cleared

    private func claim(window: Bool, status: Bool) -> Claim {
        var claim = Claim()
        if window {
            windowEpoch += 1
            claim.window = windowEpoch
        }
        if status {
            statusEpoch += 1
            claim.status = statusEpoch
        }
        return claim
    }

    private func holdsWindow(_ claim: Claim) -> Bool { claim.window == windowEpoch }
    private func holdsStatus(_ claim: Claim) -> Bool { claim.status == statusEpoch }
    /// True when a read holds none of the groups it claimed, and therefore has nothing to say.
    private func isSuperseded(_ claim: Claim) -> Bool { !holdsWindow(claim) && !holdsStatus(claim) }

    /// Every read in flight is about a document that no longer exists: a different root, a
    /// teardown, a root that went away.
    private func invalidateEveryEpoch() {
        windowEpoch += 1
        statusEpoch += 1
        detailEpoch += 1
    }

    /// The one door in and the one door out of a read, so that **every** terminal path — published,
    /// superseded, cancelled, failed — clears the flag the spinner is drawn from.
    private func beginRead() {
        readsInFlight += 1
        isLoading = true
    }

    private func endRead() {
        readsInFlight = max(0, readsInFlight - 1)
        isLoading = readsInFlight > 0
    }

    private func beginDetailRead() {
        detailReadsInFlight += 1
        isLoadingDetail = true
    }

    private func endDetailRead() {
        detailReadsInFlight = max(0, detailReadsInFlight - 1)
        isLoadingDetail = detailReadsInFlight > 0
    }

    // MARK: - the read cycle (Design §3)

    private func load() async {
        let claim = claim(window: true, status: true)
        beginRead()
        defer { endRead() }

        let loaded = await reader.load(limit: windowLimit)
        guard !isSuperseded(claim) else { return }
        if let error = loaded.error, Self.isCancellation(error) {
            // A cancelled read is one this panel asked to stop, not a failure the user is owed a
            // row about: the document that was on screen stands, nothing is published, and
            // `hasRead` is not latched — otherwise the tab shows an empty graph with no notice and
            // `activate()` never reads again.
            return
        }
        publish(loaded, claim: claim)
        // The working tree's list is drawn against `HEAD`, and a cycle is how this panel learns
        // that `HEAD` moved: without this, an external commit leaves the detail listing files
        // against a `HEAD` the graph has already replaced.
        await refreshWorkingTreeDetailIfSelected()
    }

    /// Writes only the groups this read still holds.
    ///
    /// A **different root** is the one case that is not a merge of two documents: the window, the
    /// status, the selection and the changed-file list of the repository that was on screen all
    /// describe a repository this panel is no longer showing, and a `.diff` link assembled from
    /// two of them would hand C7.5's resolver a triple that never existed (§7).
    private func publish(_ loaded: RepositoryState, claim: Claim) {
        defer { reportBranchIfChanged() }
        // A read that resolved a **different** repository and no longer owns the window has
        // nothing to say about the document on screen: its status describes repository B, and
        // writing it beside A's root, window and watcher composes a document that never existed.
        // The group that would have handled the change of root is the one it lost.
        if loaded.error == nil, loaded.root != state.root, !holdsWindow(claim) { return }
        if holdsWindow(claim), loaded.root != state.root {
            invalidateEveryEpoch()
            state = loaded
            select(nil)
            deliveryNotice = nil
            hasRead = true
            // A new root is watched; *no* root leaves nothing to watch, and the stream that was
            // armed on the old one has to go with it.
            if state.root == nil { stopWatch() } else { armWatchIfNeeded() }
            return
        }
        if let error = loaded.error {
            // A failed cycle has no window and no status to publish: it publishes the row.
            if holdsWindow(claim) { state.root = loaded.root }
            state.error = error
            hasRead = true
            return
        }
        if holdsWindow(claim) {
            state.root = loaded.root
            state.commits = loaded.commits
            state.error = nil
        }
        if holdsStatus(claim) {
            state.status = loaded.status
            state.error = nil
        }
        state.assignment = LaneAssignment.assign(commits: state.commits,
                                                 headOID: state.status?.headOID,
                                                 workingTreeIsDirty: state.status?.isClean == false)
        hasRead = true
        reconcileSelection()
    }

    /// §5's working-tree answer: **the status only**, and the lanes recomputed over the window
    /// already held.
    ///
    /// It is one `git status` and no `git log`, because a working-tree write cannot change the
    /// history — and `LaneAssignment.assign` is a pure function, so row zero appears and vanishes
    /// without a second process. That is what G1.5's one-second bound is bought with. It claims
    /// the status group and nothing else, so a cycle reading the window alongside it survives.
    private func readStatus() async {
        guard let root = state.root else { return }
        let claim = claim(window: false, status: true)
        beginRead()
        defer { endRead() }

        let status: WorkingTreeStatus
        do {
            status = try await WorkingTreeStatus.read(root: root,
                                                      environment: environment.variables,
                                                      runner: runner)
        } catch ToolError.notARepository {
            guard holdsStatus(claim) else { return }
            // The root stopped being a repository between two reads. The empty state is the
            // truthful answer, and the same one `.rootGone` gives.
            rootWentAway()
            return
        } catch {
            guard holdsStatus(claim) else { return }
            let failure = RepositoryError(error)
            guard !Self.isCancellation(failure) else { return }
            state.error = failure
            return
        }
        guard holdsStatus(claim) else { return }
        state.status = status
        state.error = nil
        state.assignment = LaneAssignment.assign(commits: state.commits, headOID: status.headOID,
                                                 workingTreeIsDirty: !status.isClean)
        reconcileSelection()
        reportBranchIfChanged()
        await refreshWorkingTreeDetailIfSelected()
    }

    /// Drops a selection the new state does not hold.
    ///
    /// Only two of them: the empty state holds no rows at all, and a working tree that went clean
    /// no longer has a row zero to keep selected. A commit selected and then paged out of the
    /// window keeps its detail — the commit still exists, and the pane it is drawn in is not the
    /// graph. (A change of root is not reconciled here: it drops the selection outright, in
    /// `publish`, because the commit itself is one this panel is no longer showing.)
    private func reconcileSelection() {
        if state.isEmptyState {
            select(nil)
            return
        }
        if selection == .workingTree, state.status?.isClean != false {
            select(nil)
        }
    }

    /// The one place `selection` is written.
    ///
    /// It bumps the detail epoch, because a selection change invalidates a detail read in flight
    /// through a channel that read cannot otherwise see — and a detail read that returns to find
    /// its selection gone would leave its loading flag set for ever.
    private func select(_ next: Selection?) {
        detailEpoch += 1
        selectionEpoch += 1
        selection = next
        changes = []
    }

    private func refreshWorkingTreeDetailIfSelected() async {
        guard selection == .workingTree else { return }
        await loadDetail(for: .workingTree)
    }

    // MARK: - the detail (Design §6)

    private func choose(_ commit: GitCommit) async {
        select(.commit(commit.hash))
        await loadDetail(for: .commit(commit.hash))
    }

    /// One read per selection, and the answer is published only if it is still the selection.
    private func loadDetail(for selection: Selection) async {
        guard let root = state.root else { return }
        detailEpoch += 1
        let mine = detailEpoch
        beginDetailRead()
        defer { endDetailRead() }

        let result: RepositoryResult<[FileChange]>
        switch selection {
        case .workingTree:
            result = await reader.workingTreeChanges(root: root)
        case .commit(let hash):
            result = await reader.changes(in: hash, root: root)
        }
        // The selection may have moved on, or the whole repository may have been re-read under a
        // different root; both bump this epoch, and a stale answer writes nothing.
        guard mine == detailEpoch else { return }
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
    ///
    /// **A prefix is unique in the history the walk covered, not in one page** (§7, as amended).
    /// One match on page one and another on page two is an ambiguous prefix, and deciding at the
    /// first page that yields a single match is exactly the arbitrary pick §7 forbids — so the
    /// walk reaches its bound, or the end of the history, before it calls a prefix unique. A full
    /// hash is the one answer settled early, in `deliver`, because it cannot become ambiguous.
    private func page(for hash: String, root: URL) async -> Delivery {
        let claim = claim(window: true, status: false)
        beginRead()
        defer { endRead() }

        let selectionWhenAsked = selectionEpoch
        var window = state.commits
        pages: for _ in 0..<Self.pagingBound {
            let result = await reader.page(after: window, root: root, limit: windowLimit)
            guard holdsWindow(claim) else { return .interrupted }
            // The user selected something else while this search was out. They answered the
            // question themselves, and a search that selected over them would move the panel off
            // the row they are looking at — so this is answered, and silently.
            guard selectionEpoch == selectionWhenAsked else { return .answered }
            switch result {
            case .notARepository:
                rootWentAway()
                deliveryNotice = .noRepository(hash: hash)
                return .answered
            case .failed(let error):
                guard !Self.isCancellation(error) else { return .interrupted }
                state.error = error
                deliveryNotice = .notReadable(hash: hash, tool: error.tool)
                return .answered
            case .value(let paged):
                let grew = paged.count > window.count
                window = paged
                if let exact = window.first(where: { $0.hash == hash }) {
                    publish(window: window)
                    await choose(exact)
                    return .answered
                }
                // Two matches settle the question as surely as the bound does.
                if window.filter({ $0.hash.hasPrefix(hash) }).count > 1 { break pages }
                if !grew { break pages }
            }
        }
        guard selectionEpoch == selectionWhenAsked else { return .answered }
        switch Self.match(hash, in: window) {
        case .one(let found):
            publish(window: window)
            await choose(found)
        case .ambiguous(let count):
            deliveryNotice = .ambiguousPrefix(prefix: hash, matches: count)
        case .none:
            deliveryNotice = .commitNotFound(hash: hash)
        }
        return .answered
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
