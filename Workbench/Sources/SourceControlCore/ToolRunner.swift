import Foundation

/// What one invocation of `git` or `gh` produced.
///
/// Bytes, not strings, because git prints paths as raw bytes under `-z` and a path on macOS need
/// not be valid UTF-8. `stdoutText` and `stderrTail` are the lossy views, for the callers that
/// want a banner or a message rather than a parse.
public struct ToolOutput: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    /// The child's exit status, or `-1` when it was abandoned without one. Never interpreted
    /// here: exit codes are data at this layer (D3).
    public var exitCode: Int32
    /// True when the budget expired before the child exited on its own.
    public var timedOut: Bool
    /// The retained-output cap, set **only** when the child reached it and was terminated for it;
    /// nil on every ordinary read. A count, not a limit-was-configured flag: a reader that turns
    /// this into a `ToolError` names the cap it hit rather than the bytes it lost, which are
    /// unbounded by definition.
    public var outputLimitBytes: Int?

    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool,
                outputLimitBytes: Int? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.outputLimitBytes = outputLimitBytes
    }

    /// The one check every reader makes **before** it looks at `exitCode`.
    ///
    /// Why it has to be shared, and why it comes first (R7/1e). `exitCode` alone cannot tell a
    /// finished command from an interrupted one: a child that handles `SIGTERM` and exits 0 after
    /// its budget expired leaves a zero here with half of its output, and a child killed outright
    /// leaves a signal number that reads as an ordinary failure. Both are the process layer's
    /// facts rather than the command's, so they are recorded on this value (D3) and turned into a
    /// typed error at exactly one place, which every wrapper calls.
    ///
    /// `timeout` is the budget the caller passed, carried into the error rather than measured:
    /// `.timedOut(afterMs:)` names the budget, not the elapsed time.
    public func requireCompleted(tool: Tool, timeout: Duration) throws {
        if let limit = outputLimitBytes {
            throw ToolError.outputLimitExceeded(tool: tool, limitBytes: limit)
        }
        if timedOut {
            let milliseconds = Int(timeout.components.seconds) * 1_000
                + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
            throw ToolError.timedOut(tool: tool, afterMs: milliseconds)
        }
    }

    /// stdout as UTF-8 with invalid bytes replaced.
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

    /// The last 512 bytes of stderr, UTF-8 lossy. A tail rather than the whole of it because this
    /// string is what a `.commandFailed` carries into a rendered panel-local error, and a tool's
    /// diagnostic can run to megabytes.
    public var stderrTail: String {
        String(decoding: stderr.suffix(512), as: UTF8.self)
    }
}

/// Runs one `git` or `gh` invocation to completion. A protocol so that command wrappers take a
/// runner rather than reaching for a concrete one, which is what lets a later milestone's tests
/// drive a parser without a process.
public protocol ToolRunning: Sendable {
    func run(_ tool: Tool, arguments: [String], cwd: URL,
             environment: [String: String], timeout: Duration) async throws -> ToolOutput
}

/// Runs a short-lived `git` or `gh` process to completion in a given directory, draining both
/// pipes, and settles within the timeout plus a small grace whatever the child leaves behind.
///
/// **Why this exists at all.** Root spec contract X1 forbids `Workbench` from importing
/// `ClaudeWire`, where C2's `FoundationProcessRunner` lives, and X2 keeps `AfleetCore` to value
/// types, so the mechanics below are deliberately a second copy rather than a shared dependency
/// (ledger D1, tech-debt entry 112). The reasoning C2 paid for is carried across in the comments
/// here, because the reasons do not survive as code: a reader who deletes one of these five
/// precautions gets a green suite and a defect that only appears under load.
public struct ToolRunner: ToolRunning {

    /// The most output one command may retain before it is terminated for it.
    ///
    /// Bounding the *drain* is not bounding the *buffer* (R7/1b): `PipeDrain.bytesPerPass` returns
    /// the queue to the timer every mebibyte, which is what keeps the timeout live, but nothing in
    /// that loop stops the accumulated `Data` from growing. `git cat-file blob` on a tracked file
    /// of arbitrary size is the ordinary way to reach it, and a panel that exhausts the app's
    /// memory has taken the whole conversation down over a source-control read (§10 says a git
    /// failure is panel-local). 64 MiB is far above any listing or blob a panel renders and far
    /// below what an app can afford to lose.
    public static let defaultOutputLimitBytes = 64 * 1024 * 1024

    /// The cap for this runner. Injectable so that a test can reach it with a producer that runs
    /// in a moment rather than one that has to write 64 MiB.
    public let outputLimitBytes: Int

    public init(outputLimitBytes: Int = ToolRunner.defaultOutputLimitBytes) {
        self.outputLimitBytes = outputLimitBytes
    }

    /// The first executable named `tool` on `environment["PATH"]`, or nil.
    ///
    /// D2: the passed `PATH` is scanned in order and nothing else is ever considered — no
    /// `/usr/bin` fallback, no Homebrew prefix, no `Process`'s own environment, no
    /// `/usr/bin/env git` (which resolves through whatever `PATH` the *child* sees and hides the
    /// failure one level down). The point is that the panel runs the same binary the user's own
    /// terminal runs, so that hooks, credential helpers and `gh`'s stored token behave
    /// identically. Relative `PATH` components are dropped: they resolve against the child's cwd,
    /// which here is a repository the user opened, and a `git` found inside it would be the
    /// repository executing code.
    public static func resolve(_ tool: Tool, in environment: [String: String]) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        for component in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard component.hasPrefix("/") else { continue }
            let candidate = URL(filePath: String(component)).appending(path: tool.rawValue)
            guard FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false))
            else { continue }
            // An executable *regular file*, not merely an executable path: every directory carries
            // the execute bit, so `isExecutableFile` alone accepts a `PATH` component holding a
            // directory named `git`, which then fails at spawn instead of resolving honestly to
            // "the passed PATH holds no such tool".
            //
            // Symlinks are followed before the check and *not* in the returned URL. The resource
            // key is lstat-shaped — it reports a symlink to a regular file as not regular — and a
            // Homebrew `git` is exactly that symlink, so checking the unresolved URL would refuse
            // the machine's own git. The candidate is returned unresolved so that the child is
            // spawned at the path the passed `PATH` names (D2).
            guard let values = try? candidate.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            return candidate
        }
        return nil
    }

    /// Resolves `tool` through `environment` and runs it in `cwd`.
    ///
    /// Throws `.binaryNotFound` when the passed `PATH` holds no such tool and `.spawnFailed` when
    /// the process could not be started. A non-zero exit is *not* an error here: it is returned in
    /// `ToolOutput.exitCode`, because only a command wrapper knows which codes mean failure —
    /// `gh pr checks` exits 8 while checks are pending (D3).
    public func run(_ tool: Tool, arguments: [String], cwd: URL,
                    environment: [String: String], timeout: Duration) async throws -> ToolOutput {
        guard let executable = Self.resolve(tool, in: environment) else {
            throw ToolError.binaryNotFound(tool: tool)
        }
        return try await run(executable: executable, arguments: arguments, cwd: cwd,
                             environment: environment, timeout: timeout, tool: tool)
    }

    /// The executable-taking form. Internal because the timeout is a property of this process
    /// layer rather than of `git`, and the only honest way to test it is a child that provably
    /// blocks — `/bin/sleep`, which is not a `Tool`.
    ///
    /// `tool` labels the thrown error and nothing else.
    func run(executable: URL, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration, tool: Tool = .git) async throws -> ToolOutput {
        // Asked before the spawn and not only around the await: a task cancelled before this call
        // was entered — a panel refresh the user scrolled past while it queued — otherwise launched
        // `git`, ran whatever hooks and credential helpers came with it, and cancelled the child it
        // had just started. A cancelled read is a read the panel asked not to happen (D53/c), so
        // the answer is the one the awaiting path already gives, with nothing started to give it
        // about.
        guard !Task.isCancelled else { throw ToolError.cancelled(tool: tool) }
        let job = ToolJob(executable: executable, arguments: arguments, cwd: cwd,
                          environment: environment, outputLimitBytes: outputLimitBytes)
        do {
            try job.start()
        } catch {
            // The domain and the code, not `localizedDescription`: the domain alone is almost
            // always `NSCocoaErrorDomain` and says nothing, while the localized description spells
            // out the executable path, and this message is carried by a `ToolError` that may be
            // rendered in a panel or written to a log (root spec §6.3).
            let failure = error as NSError
            throw ToolError.spawnFailed(tool: tool, message: "\(failure.domain) \(failure.code)")
        }
        // The cancellation handler is the only way out of a child that is not coming back (R7/1d).
        // A checked continuation is not cancellation-aware by itself: without this, cancelling the
        // task that awaits — a panel refresh the user scrolled past, a channel that closed — leaves
        // the child, its two descriptors and everything it has written alive until it exits on its
        // own or the whole budget expires. Cancellation takes exactly the path a timeout takes.
        let output = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.finish(timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            job.cancel()
        }
        if job.wasCancelled { throw ToolError.cancelled(tool: tool) }
        return output
    }
}

/// One pass over a descriptor that is being drained, and the bound on how much it takes.
///
/// Internal rather than private, because the bound is the whole point and a black-box test cannot
/// see it: on this machine a child flooding a pipe still gets timed out and killed, because the
/// producer is slower than the drain and the loop reaches `EAGAIN` between events (measured over
/// five producer shapes, R6/F1). The property that has to hold is not "the timeout fires against
/// this producer" but "one readable event takes a bounded amount of work", and that is stated here
/// and tested directly.
enum PipeDrain {

    /// One `read(2)`'s buffer.
    static let chunk = 64 * 1024

    /// The most one pass takes before it returns the queue to whatever else is waiting on it —
    /// sixteen full reads.
    ///
    /// Why a bound at all: the timeout, the `SIGKILL` escalation and the settlement all run on the
    /// *same* serial queue as these passes (`ToolJob.queue`), so work done here is time none of
    /// them can run. An unbounded pass — read while data keeps arriving, return only on `EAGAIN` —
    /// hands the queue to whichever producer can keep the pipe fed, and a `git` that inherited its
    /// stdout to a hook or a helper is exactly such a producer. Bounded, the worst case is one
    /// mebibyte of copying between two turns of the queue.
    static let bytesPerPass = 16 * chunk

    /// What a pass found.
    enum Outcome: Equatable {
        /// The descriptor is still usable: it ran dry, or the pass had taken enough. Either way
        /// the reader comes back.
        case open
        /// End of file, or an error that makes further reads pointless. The reader does not come
        /// back and the source is cancelled.
        case closed
    }

    /// Reads what `fd` holds right now, appending each read's bytes, and stops at `bytesPerPass`.
    ///
    /// Stopping at the bound reports `.open`, exactly as running dry does: in both cases the
    /// descriptor is still usable and the reader comes back — on the next readable event during the
    /// call, and on the exit path's last pass at the end of it. `EINTR` is retried and does not
    /// count against the bound, because no bytes came with it.
    static func pass(_ fd: Int32, into append: (Data) -> Void) -> Outcome {
        var buffer = [UInt8](repeating: 0, count: chunk)
        var taken = 0
        while taken < bytesPerPass {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { append(Data(buffer[0..<n])); taken += n; continue }
            if n == 0 { return .closed }
            if errno == EINTR { continue }
            if errno == EAGAIN { return .open }
            return .closed
        }
        return .open
    }
}


/// Single owner of one spawned child, its pipes and the accumulated output.
///
/// The invariant: every mutation of this object's state, and every signal, reap and settlement,
/// happens on `queue`.
///
/// **Why `posix_spawn` rather than `Process`.** The child has to be the leader of a process group
/// of its own, and Foundation offers no way to ask for one (R7/1c). It happens to spawn its child
/// into a new group and to document `terminate()` as reaching "all of its subtasks" — measured
/// here, that is true — but the `SIGKILL` that follows is addressed to a single pid, and worse,
/// Foundation reaps the child the moment it exits, so a group whose leader has been reaped can no
/// longer be signalled at all: the pid may already name someone else's group. `git` starts
/// descendants — a pager, a credential helper, a hook that backgrounds something — and a
/// descendant deaf to `SIGTERM` outlives the whole call. Owning the spawn is what lets this class
/// own the group *and* the reap, which are one decision: the pid stays reserved until the
/// escalation has finished with it. C7.1's PTY layer makes the same move for the same reason,
/// there with `SETSID`.
///
/// The exit is learned from a `DispatchSourceProcess`, never from a blocking wait on this queue.
/// A blocking read or wait here would stall the very timers meant to bound the call — the timeout,
/// the escalation, the settlement and the pipe drains all run on this one serial queue.
///
/// Settlement is keyed to the child's exit, never to end-of-file on its pipes. A grandchild that
/// inherited stdout and outlives the child holds the write end open indefinitely, so waiting for
/// EOF would burn the whole timeout on a child that exited in a second and report the `SIGTERM`
/// that followed. Reads are event-driven, non-blocking `DispatchSourceRead`s for the same reason,
/// and the exit path takes one last non-blocking pass over each pipe so that everything the child
/// wrote before exiting is in the result.
///
/// Internal rather than file-private so that a test can drive one child directly. The two orderings
/// this class has to survive — a budget that expires *inside* the escalation's grace, and a final
/// drain that overruns the cap after the leader has been reaped — are reachable only in windows of
/// tens of milliseconds through `ToolRunner.run`, which owns both the timing and the grace. Driven
/// directly, a test chooses when `finish` is called and how long the grace is, and the ordering
/// becomes the assertion rather than a race the machine wins or loses.
final class ToolJob: @unchecked Sendable {

    /// After the first signal, how long the tree gets before `SIGKILL`, and then before we settle
    /// anyway. Per instance so a test can put the budget's expiry *inside* it.
    static let defaultGrace = DispatchTimeInterval.milliseconds(500)
    private let grace: DispatchTimeInterval

    private let queue = DispatchQueue(label: "afleet.source-control.tool-runner")
    private let executable: URL
    private let arguments: [String]
    private let cwd: URL
    private let environment: [String: String]
    /// The most this job retains across both pipes before it ends the command for it.
    private let outputLimitBytes: Int

    private let out = Pipe(), err = Pipe()
    private var stdoutData = Data(), stderrData = Data()
    private var retained = 0
    private var limitReached = false
    /// One entry per pipe still open, holding what is needed to make a final read of it.
    private var drains: [(fd: Int32, source: DispatchSourceRead, append: (Data) -> Void)] = []

    private var pid: pid_t = -1
    /// The group the child leads, kept apart from `pid` because it outlives the reap.
    ///
    /// A reaped pid may be handed to a stranger, so `pid` is unusable the moment `reaped` is set; a
    /// **group** id is not, because the kernel will not reuse a pid that still names a group with
    /// members. `kill(-group, …)` after the leader is reaped therefore either reaches this command's
    /// surviving descendants or answers `ESRCH`, and can never reach anyone else.
    private var group: pid_t = -1
    private var exitSource: DispatchSourceProcess?
    private var exitStatus: Int32 = -1
    private var exited = false
    private var reaped = false
    private var terminating = false
    /// Whether the `SIGKILL` a termination owes the group has been sent. Separate from `settled`:
    /// the child's exit and the group's quiescence are two facts, and the call can be over while
    /// the tree is not.
    private var escalated = false
    private var timedOut = false
    private var cancelled = false
    private var settled = false
    /// Set when a settlement was reached before there was anyone to hand the result to, so that
    /// `finish` performs it the moment there is. Without it a job cancelled before the caller
    /// awaited would settle into nothing and the call would hang to the end of its budget.
    private var pendingSettle = false
    private var completion: (@Sendable (ToolOutput) -> Void)?

    /// True once `finish` has installed a completion. Until then an exit is recorded but not acted
    /// on: the child can be gone before the caller has asked for the result, and settling then
    /// would latch `settled` against a continuation that does not exist yet.
    private var accepting = false

    init(executable: URL, arguments: [String], cwd: URL, environment: [String: String],
         outputLimitBytes: Int, grace: DispatchTimeInterval = ToolJob.defaultGrace) {
        self.grace = grace
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.outputLimitBytes = outputLimitBytes
    }

    /// Spawns the child into a process group of its own, releasing everything this job holds if the
    /// spawn fails.
    ///
    /// Releasing matters and was measured: Foundation's own failure path left the descriptors it
    /// opened open, and 20 failed spawns leaked exactly 80 of them. This path is not exotic — a
    /// panel polling `git` in a directory the user has deleted takes it on every refresh — so the
    /// four pipe handles are closed here whatever happens to the objects.
    func start() throws {
        try queue.sync {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            // Never a terminal and never this process's stdin: a `git` that decides to prompt for a
            // credential must fail rather than block on an input nobody is watching.
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
            // The cwd is set here rather than through `git -C` or `env -C`, so that it applies to
            // `gh` and to any tool added later without each wrapper remembering a flag.
            posix_spawn_file_actions_addchdir(&actions, cwd.path(percentEncoded: false))

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // `pgroup` 0 means "a new group led by the child itself", which is what makes the
            // child's pid the name of the whole tree for signalling purposes.
            posix_spawnattr_setpgroup(&attributes, 0)
            var defaulted = sigset_t()
            sigfillset(&defaulted)
            posix_spawnattr_setsigdefault(&attributes, &defaulted)
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            posix_spawnattr_setsigmask(&attributes, &unblocked)
            // Dispositions and mask reset so the child does not inherit the app's; every descriptor
            // but the three named above closed, so nothing of afleet's leaks into a user's `git`.
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
            posix_spawnattr_setflags(&attributes, Int16(flags))

            var child: pid_t = 0
            // Exactly the dictionary the caller passed, never merged with this process's own. The
            // resolved environment is what X11 says every git and gh process afleet spawns runs
            // with, and a merge would quietly hand the child whatever the app was launched with.
            let code = Self.withVectors(executable: executable, arguments: arguments,
                                        environment: environment) { argv, envp in
                posix_spawn(&child, executable.path(percentEncoded: false), &actions, &attributes,
                            argv, envp)
            }
            guard code == 0 else {
                closeAllHandles()
                // `posix_spawn` returns the error number rather than setting `errno`. The domain
                // and the code, not a localized description: the description spells out the
                // executable path, and this message is carried by a `ToolError` that may be
                // rendered in a panel or written to a log (root spec §6.3).
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            pid = child
            // `POSIX_SPAWN_SETPGROUP` with a `pgroup` of 0 makes the child its own group leader, so
            // the group's id *is* the child's pid — recorded separately because the pid stops being
            // usable at the reap and the group id does not.
            group = child
            // The parent's copies of the write ends, so that the pipes report end-of-file when the
            // last writer in the child's tree is gone.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()

            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit,
                                                          queue: queue)
            source.setEventHandler { [self] in childDidExit() }
            exitSource = source
            source.resume()
        }
    }

    func finish(timeout: Duration, completion: @escaping @Sendable (ToolOutput) -> Void) {
        // Synchronously, so that no timeout — however small — can latch `settled` before there is
        // a continuation to resume.
        queue.sync { [self] in
            self.completion = completion
            drain(out.fileHandleForReading) { [self] chunk in accept(chunk) { stdoutData.append($0) } }
            drain(err.fileHandleForReading) { [self] chunk in accept(chunk) { stderrData.append($0) } }
            accepting = true
            // A child fast enough to have exited already, or a call cancelled before it was
            // awaited: this is the first moment there is anyone to tell.
            if pendingSettle { settle() } else { settleIfComplete() }
        }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000
            + Int(timeout.components.attoseconds / 1_000_000_000)
        // Scheduled on `queue`, so the body is already serialised with every other access. Weakly,
        // all of them: a settled job's timer still fires at the full budget, and a strong capture
        // would hold the job and everything it accumulated — the whole of stdout — alive until
        // then, thirty seconds after the call returned for a git read. `run` holds the job across
        // its `await`, so the job cannot go away before it settles and nothing here is missed.
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [weak self] in
            guard let self, !self.settled else { return }
            // The kernel is asked before the verdict is reached. `exited` is set by the process
            // source's handler, which is a *queued* event: a child that exited microseconds before
            // this deadline can have its status waiting to be collected while its handler is still
            // behind this block on the queue, and the call would then be reported as an overrun of
            // a budget it met. `reapIfExited` is the same non-blocking `waitpid` that handler makes
            // and is safe to make twice, so the verdict below is taken against the child's actual
            // state rather than against how far its notification has travelled.
            self.reapIfExited()
            // The `exited` guard is what keeps a child that finished microseconds before this timer
            // from being called an overrun; the `terminating` guard keeps a call already being torn
            // down for another reason — a cancellation, the output cap — from being relabelled.
            if self.exited {
                // Answers the caller even when a termination is already under way — a child that
                // exited on the `SIGTERM` has nothing more to write. What it does *not* do is call
                // that termination off: the escalation is owed to the group, not to the caller, and
                // is keyed on `escalated` rather than on this settlement.
                self.settle()
            } else if !self.terminating {
                self.timedOut = true
                self.beginTermination()
            }
        }
    }

    /// Ends the awaiting caller's interest in this child: the tree is signalled exactly as a
    /// timeout signals it, and `run` reports `.cancelled` rather than a result.
    func cancel() {
        queue.async { [self] in
            guard !settled, !cancelled else { return }
            cancelled = true
            if exited { settleIfComplete() } else { beginTermination() }
        }
    }

    var wasCancelled: Bool { queue.sync { cancelled } }

    // MARK: - the tree

    /// `SIGTERM` to the whole group, then `SIGKILL` to it after a grace, then settle.
    ///
    /// **Not conditioned on `settled`, at either end.** A termination is a promise made to the
    /// *group*, and the group can outlive the call: `git` exits on `SIGTERM` while a hook's
    /// backgrounded descendant that ignores it does not, and the awaiting caller can be answered in
    /// between — by a budget that expired inside the grace, or by a final drain that overran the cap
    /// after settlement had begun. Skipping the `SIGKILL` because there is nobody left to tell
    /// leaves that descendant on the machine, which is the one outcome this path exists to prevent.
    /// The escalation therefore runs until it has run, and `escalated` — not `settled` — is what
    /// says it has.
    ///
    /// The two escalation blocks hold `self` **strongly**, unlike the budget's own timer: they are a
    /// second apart rather than a whole budget, and a weak capture would hand the group's fate to
    /// whether `run` happened to return first.
    private func beginTermination() {
        guard !terminating else { return }
        terminating = true
        signalTree(SIGTERM)
        queue.asyncAfter(deadline: .now() + grace) { [self] in
            guard !escalated else { return }
            escalated = true
            signalTree(SIGKILL)
            queue.asyncAfter(deadline: .now() + grace) { [self] in settle() }
        }
    }

    /// Signals the child's process group, and the child alone only if the group has already gone.
    ///
    /// The negative pid is the whole point: the child leads a group of its own, so one call reaches
    /// every descendant it started and nothing else on the machine.
    ///
    /// The group is signalled **whether or not the leader has been reaped**, because those are two
    /// different questions: `waitpid` collects one process, and the group is whatever is still in
    /// it. A pid that names a group with members is not reused, so the negative form is safe here
    /// for as long as there is anything for it to reach. The single-process fallback is not:
    /// `kill(pid, …)` after the reap could name a stranger, so it is asked only while the pid is
    /// still reserved.
    private func signalTree(_ signal: Int32) {
        guard group > 0 else { return }
        if kill(-group, signal) != 0 && errno == ESRCH && !reaped && pid > 0 { _ = kill(pid, signal) }
    }

    /// The exit source fired. Outside a termination the child is reaped here and the call settles;
    /// during one the reap is deliberately deferred, because the pid is what names the group the
    /// escalation is still signalling.
    private func childDidExit() {
        guard !reaped, !terminating else { return }
        if reapIfExited() { settleIfComplete() }
    }

    /// Collects the child's status if it is there to collect. Never blocks: this runs on the same
    /// queue as the timers.
    @discardableResult
    private func reapIfExited() -> Bool {
        guard !reaped, pid > 0 else { return false }
        var status: Int32 = 0
        var result = waitpid(pid, &status, WNOHANG)
        while result < 0 && errno == EINTR { result = waitpid(pid, &status, WNOHANG) }
        guard result == pid else { return false }
        reaped = true
        exited = true
        exitStatus = Self.exitCode(from: status)
        exitSource?.cancel()
        exitSource = nil
        return true
    }

    /// A child still alive at settlement — it outlived `SIGKILL`, or it is stopped — is killed once
    /// more and waited for off this queue. A pid nobody waits for is a zombie for the life of the
    /// app, and the wait cannot happen here because this queue owes the caller its answer now.
    private func abandonUnreapedChild() {
        guard !reaped, pid > 0 else { return }
        let orphan = pid
        reaped = true
        exitSource?.cancel()
        exitSource = nil
        DispatchQueue.global(qos: .utility).async {
            _ = kill(-orphan, SIGKILL)
            var status: Int32 = 0
            while waitpid(orphan, &status, 0) < 0 && errno == EINTR {}
        }
    }

    /// A `wait(2)` status as the code this module reports: the exit status for a child that exited
    /// and the signal number for one that was killed — the two values Foundation's
    /// `terminationStatus` reports, so nothing above this layer changes shape.
    private static func exitCode(from status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
    }

    // MARK: - the pipes

    /// Accumulates one pipe as it fills. The cancel handler closes the handle, which releases the
    /// descriptor even when the writer never went away.
    private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in readAvailable(fd, into: append, source: source) }
        source.setCancelHandler { [self] in
            try? handle.close()
            drains.removeAll { $0.fd == fd }
        }
        drains.append((fd: fd, source: source, append: append))
        source.resume()
    }

    /// Appends what one pass produced, up to the cap, and ends the command at it.
    ///
    /// Bounding the *pass* (`PipeDrain.bytesPerPass`) and bounding the *buffer* are different
    /// properties, and only the first was held (R7/1b): the pass returns the queue to the timers
    /// every mebibyte, which is what keeps a flooding child killable, while the accumulated `Data`
    /// grew for as long as the child wrote. `git cat-file blob` on a large tracked file reaches
    /// that in the ordinary course of drawing a diff, and exhausts the app's memory long before any
    /// budget expires — so the timeout is not the bound, and this is.
    ///
    /// The bytes taken up to the cap are kept rather than dropped: they are what a rendered error
    /// or a log line has to describe, and dropping them would make the failure indistinguishable
    /// from a silent one.
    private func accept(_ chunk: Data, into sink: (Data) -> Void) {
        guard !limitReached else { return }
        let room = outputLimitBytes - retained
        if chunk.count < room {
            sink(chunk)
            retained += chunk.count
            return
        }
        sink(chunk.prefix(room))
        retained += max(room, 0)
        // The cause is whichever came first. Once the call is being torn down for another reason
        // — a timeout, a cancellation — the child is under `SIGTERM` and has a grace period in
        // which it can still write, and a child that floods *during* that grace would otherwise
        // relabel a timeout as an output overrun: `requireCompleted` reports the cap before it
        // reports the budget. Nothing is lost by not latching it, because `room` is zero from here
        // on and no further byte is retained.
        guard !terminating else { return }
        limitReached = true
        beginTermination()
    }

    /// One pass over a pipe, cancelling its source once the writer is gone or the descriptor is
    /// unusable. A pass that stopped because it had taken enough leaves the source armed: the
    /// event fires again while the descriptor still holds data, so the rest arrives on a later
    /// turn of this queue rather than on this one.
    private func readAvailable(_ fd: Int32, into append: (Data) -> Void, source: DispatchSourceRead) {
        if PipeDrain.pass(fd, into: append) == .closed { source.cancel() }
    }

    /// The last pass over each pipe, on the exit path: everything the child wrote before it exited
    /// is in the kernel's buffer by now, whoever else still holds the write end.
    ///
    /// Bounded like every other pass, and deliberately *one* of them. A pipe holds at most its own
    /// buffer — 64 KiB here, a sixteenth of the bound — so one pass empties whatever the child left
    /// behind. What one pass cannot empty is a pipe a *surviving* grandchild is still filling, and
    /// looping until that one runs dry would hand the queue to a process the child no longer
    /// controls, at the moment the caller is owed its answer. Settlement is keyed to the child's
    /// exit and not to end-of-file (see the type's note), and this is the same ruling applied to
    /// the last read.
    private func drainRemaining() { for d in drains { readAvailable(d.fd, into: d.append, source: d.source) } }

    /// Closes every pipe handle this job holds. The failure path's half of `start`.
    private func closeAllHandles() {
        for handle in [out.fileHandleForReading, out.fileHandleForWriting,
                       err.fileHandleForReading, err.fileHandleForWriting] {
            try? handle.close()
        }
    }

    // MARK: - settlement

    /// The child's exit is the whole of the completion condition — see the type's note on EOF —
    /// once there is somebody to hand the result to.
    private func settleIfComplete() { if exited && accepting { settle() } }

    private func settle() {
        guard !settled else { return }
        guard accepting else { pendingSettle = true; return }
        settled = true
        // This last pass can be the one that overruns the cap — a `git` that exits leaving a hook's
        // descendant on its stdout is exactly the shape — and `accept` ends the tree for it like any
        // other. That termination is begun *here*, after `settled` and possibly after the leader was
        // reaped, and both are why neither is a condition on it.
        drainRemaining()
        for d in drains where !d.source.isCancelled { d.source.cancel() }
        // The reap a termination deferred: the status is still there to collect, and after this the
        // pid is nobody's to signal, though the group it named still is.
        reapIfExited()
        abandonUnreapedChild()
        let output = ToolOutput(stdout: stdoutData, stderr: stderrData,
                                exitCode: exited ? exitStatus : -1,
                                timedOut: timedOut,
                                outputLimitBytes: limitReached ? outputLimitBytes : nil)
        let finish = completion
        completion = nil
        finish?(output)
    }

    // MARK: - the C vectors

    /// Runs `body` with a null-terminated `argv` and `envp`, freed on the way out. `argv[0]` is the
    /// executable's own path, as every exec convention expects.
    private static func withVectors<R>(executable: URL, arguments: [String],
                                       environment: [String: String],
                                       body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                              UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable.path(percentEncoded: false)] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }
        return body(&argv, &envp)
    }
}
