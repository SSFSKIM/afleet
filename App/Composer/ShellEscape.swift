import Foundation
import AfleetCore
import ClaudeWire
import PanelHostAPI
import FleetKit

/// The `!` host-side escape (spec §6.6, C6.2 *`@` and `!`*).
///
/// A line beginning `!` runs the rest of it on this machine, in the channel's directory, with the
/// channel's resolved environment, and its output goes into the conversation as one ordinary user
/// frame wrapped in the tags the terminal's own `!` path uses.
///
/// **Three things this file does not do, each deliberately.**
///
/// 1. *It hardens nothing.* `ShellEnvelope.wrap(command:stdout:stderr:)` is C2's, and it is called
///    here and never copied: no tag list, no truncation rule, no UTF-8 replacement and no escaping
///    of this leaf's own exists anywhere in `App/Composer/`. The envelope already caps each stream
///    at 64 KiB with a byte-count notice and replaces invalid UTF-8, and a second opinion about any
///    of that would be a second sanitiser to keep in step with the engine.
/// 2. *It never learns an exit code.* `HostCommandOutput` carries the two streams and nothing else,
///    so no `<bash-exit-code>` element can be emitted even by accident. That element belongs to the
///    `bash_command` frame path, which §6.6 says this design does not use; the terminal's `!` submit
///    path emits `<bash-input>`, `<bash-stdout>` and `<bash-stderr>` and no exit code.
/// 3. *It opens no descriptor on the channel's directory.* The directory is handed to the child as
///    its working directory and nothing here stats, opens or enumerates it — C5's finding that
///    `open(2)` on a user-content directory is TCC-gated and blocks on a consent dialog.

/// What a host-side command left behind. Two streams, kept apart all the way to the envelope, so
/// each lands in its own element even when the command interleaved them (§6.6).
struct HostCommandOutput: Sendable {
    var stdout: Data
    var stderr: Data
    /// True when the command outlived its budget and was stopped. Reported to the user inline, never
    /// added to the envelope: what goes inside the elements is what the command wrote.
    var timedOut: Bool = false
    /// True when a stream reached the retention cap and the command was ended for it. Reported
    /// inline for the same reason `timedOut` is, and for one more: the envelope's own notice counts
    /// the bytes *it* dropped, which after a capped capture is the margin alone and not what the
    /// command actually produced. The sentence names the fact; the number is unknowable by
    /// construction, since the bytes past the cap were never read.
    var outputLimited: Bool = false
}

/// Runs one short-lived command through the channel's shell.
///
/// **Why not `ClaudeWire`'s `FoundationProcessRunner`.** Its `ProcessRunner` protocol takes an
/// executable, arguments, an environment and a timeout — and no working directory, which is the one
/// thing this path exists to set. Widening that protocol is a `ClaudeWire` edit outside this leaf's
/// fence, and the alternative of prefixing a `cd` to the user's command would put a line in front of
/// what they typed. So the spawn is here; its settlement is modelled on what `ProcessJob` and C7.3's
/// `ToolRunner` learned — the child's **exit** is the completion condition, never end-of-file on its
/// pipes, because a grandchild that inherited stdout (a `!` that starts a daemon) holds the write end
/// open for as long as it lives, and reads are non-blocking for the same reason.
struct HostShellRunner: Sendable {

    /// How long a `!` may run before it is stopped. A command in a chat field is a short one; a long
    /// one belongs in a pane. What it wrote up to that point is still posted.
    static let budget = Duration.seconds(120)

    /// The most one stream may retain before the command is ended for it.
    ///
    /// The envelope's cap is not a bound on this process's memory: it is applied to whatever `run`
    /// returns, and until it returns a `!yes` writes into an unbounded `Data` for the whole budget.
    /// So the retention is bounded here instead, at the envelope's own per-stream cap plus a margin.
    /// The margin is what keeps §6.6's truncation *shape* intact — the envelope's byte-count notice
    /// is emitted only for a stream longer than its cap, so a capture stopping exactly at the cap
    /// would hand the model output that looks complete.
    static let defaultOutputLimitBytes = ShellEnvelope.perStreamCap + 8 * 1024

    /// The cap for this runner. Injectable so a test can reach it with a producer that runs in a
    /// moment rather than one that has to write 72 KiB into a pipe the drain is emptying.
    var outputLimitBytes: Int = HostShellRunner.defaultOutputLimitBytes

    /// Runs the command and answers what it wrote, or **nil** when the awaiting task was cancelled.
    ///
    /// Cancellation is not a result: nothing is posted for it, and the child's whole process group is
    /// ended on the way out. A released composer that left a command running would post into a
    /// channel the user has moved on from, minutes later.
    func run(command: String, shell: String, in directory: URL,
             environment: [String: String],
             timeout: Duration = HostShellRunner.budget) async -> HostCommandOutput? {
        // Asked before the spawn and not only around the await: a task cancelled before this call was
        // entered would otherwise run the user's command and then kill what it had just started.
        guard !Task.isCancelled else { return nil }
        let child = ShellChild(command: command, shell: shell, directory: directory,
                               environment: environment, outputLimitBytes: outputLimitBytes)
        do {
            try child.start()
        } catch {
            // A shell that will not start is a failure of the command as far as the user is
            // concerned, so it is reported the same way one is: inside `<bash-stderr>`. The sentence
            // names no path (§11).
            return HostCommandOutput(stdout: Data(),
                                     stderr: Data("afleet could not start a shell for this command.\n".utf8))
        }
        // The cancellation handler is the only way out of a child that is not coming back: a checked
        // continuation is not cancellation-aware by itself, so without it a cancelled run holds the
        // child, its two descriptors and everything it has written until the budget expires.
        let output = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.finish(timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            child.cancel()
        }
        return child.wasCancelled ? nil : output
    }
}

/// One pass over a descriptor that is being drained, and the bound on how much it takes.
///
/// Internal rather than private because the bound is the whole point and a black-box test cannot see
/// it: whether the timeout happens to fire against one producer on one machine is not the property.
/// The property is that **one readable event takes a bounded amount of work**, and it is stated here
/// and tested directly.
enum HostPipeDrain {

    /// One `read(2)`'s buffer.
    static let chunk = 64 * 1024

    /// The most one pass takes before it returns the queue to whatever else is waiting on it —
    /// sixteen full reads.
    ///
    /// Why a bound at all: the timeout, the `SIGKILL` escalation, the settlement and the *other*
    /// pipe's passes all run on the same serial queue as this one, so work done here is time none of
    /// them can run. An unbounded pass — read while data keeps arriving, return only on `EAGAIN` —
    /// hands the queue to whichever producer can keep the pipe fed, and `!yes` is exactly such a
    /// producer. Bounded, the worst case is one mebibyte of copying between two turns of the queue.
    static let bytesPerPass = 16 * chunk

    /// What a pass found.
    enum Outcome: Equatable {
        /// The descriptor is still usable: it ran dry, or the pass had taken enough. Either way the
        /// reader comes back — on the next readable event, or on the exit path's last pass.
        case open
        /// End of file, or an error that makes further reads pointless.
        case closed
    }

    /// Reads what `fd` holds right now, appending each read's bytes, and stops at `bytesPerPass`.
    /// `EINTR` is retried and does not count against the bound, because no bytes came with it.
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

/// Single owner of the child, its two pipes and what they produced. Every mutation happens on
/// `queue`, which also carries the timers, so nothing here needs a lock.
///
/// **Why `posix_spawn` rather than `Process`.** The child has to lead a process group of its own, and
/// Foundation offers no way to ask for one. A `!` line is the one place in afleet where the user
/// writes the command, so `sh -c` starting descendants is the ordinary case rather than the exotic
/// one: `Process.terminate()` reaches the child, the `SIGKILL` that follows names a single pid, and
/// Foundation reaps that pid the moment it exits — after which the group can no longer be signalled
/// at all. Owning the spawn is what lets this class own the group *and* the reap, which are two
/// decisions rather than one: the reap ends the leader, and the group id it named goes on naming the
/// group for as long as anything is still in it. C7.3's `ToolRunner`
/// makes the same move for the same reason, and this is a second copy of it rather than a shared
/// dependency because the App may not import a panel core for its composer.
///
/// **Internal rather than private, for the same reason `HostPipeDrain` is.** What this class owes the
/// group is an *ordering* between four things that share one queue — the exit, the budget, the
/// escalation and the final drain — and two of those orderings are reachable only in windows of tens
/// of microseconds when the class is driven through `HostShellRunner.run`. Driven directly, a test
/// chooses when `finish` is called and how long the grace is, and the ordering becomes the assertion
/// rather than a race the machine wins or loses.
final class ShellChild: @unchecked Sendable {

    /// After the first signal, how long the tree gets before `SIGKILL`, and then before the result is
    /// handed over anyway. Per instance so a test can put the budget's expiry *inside* it.
    static let defaultGrace = DispatchTimeInterval.milliseconds(500)
    private let grace: DispatchTimeInterval

    private let queue = DispatchQueue(label: "afleet.composer.shell-escape")
    private let command: String
    private let shell: String
    private let directory: URL
    private let environment: [String: String]
    /// The most either stream retains before the command is ended for it.
    private let outputLimitBytes: Int

    private let out = Pipe(), err = Pipe()
    private var stdout = Data(), stderr = Data()
    private var retainedOut = 0, retainedErr = 0
    private var limitReached = false
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
    private var exited = false, reaped = false, terminating = false
    /// Whether the `SIGKILL` a termination owes the group has been sent. Separate from `settled`: the
    /// shell's exit and the group's quiescence are two facts, and the run can be over while the tree
    /// is not.
    private var escalated = false
    private var accepting = false, settled = false, pendingSettle = false
    private var timedOut = false, cancelled = false
    private var completion: (@Sendable (HostCommandOutput) -> Void)?

    init(command: String, shell: String, directory: URL, environment: [String: String],
         outputLimitBytes: Int, grace: DispatchTimeInterval = ShellChild.defaultGrace) {
        self.grace = grace
        self.command = command
        // The channel's own shell, as `ResolvedEnvironment` captured it (X11's single capture).
        self.shell = shell.isEmpty ? "/bin/sh" : shell
        self.directory = directory
        self.environment = environment
        self.outputLimitBytes = outputLimitBytes
    }

    /// Spawns the child into a process group of its own, releasing every descriptor if it fails.
    func start() throws {
        try queue.sync { [self] in
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            // Never this process's stdin: a `!` line that decides to prompt must fail rather than
            // block on an input nobody is watching.
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
            // The one place the channel's directory is used: handed to the child, never opened here.
            posix_spawn_file_actions_addchdir(&actions, directory.path(percentEncoded: false))

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // `pgroup` 0 means "a new group led by the child itself", which is what makes the child's
            // pid the name of the whole tree for signalling purposes.
            posix_spawnattr_setpgroup(&attributes, 0)
            var defaulted = sigset_t()
            sigfillset(&defaulted)
            posix_spawnattr_setsigdefault(&attributes, &defaulted)
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            posix_spawnattr_setsigmask(&attributes, &unblocked)
            // Dispositions and mask reset so the child does not inherit the app's; every descriptor
            // but the three named above closed, so nothing of afleet's leaks into a user's command.
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT
            posix_spawnattr_setflags(&attributes, Int16(flags))

            var child: pid_t = 0
            // `-c`, which is how the terminal runs a `!` line too, and exactly the dictionary the
            // channel resolved — never merged with this process's own (X11).
            let code = Self.withVectors(executable: shell, arguments: ["-c", command],
                                        environment: environment) { argv, envp in
                posix_spawn(&child, shell, &actions, &attributes, argv, envp)
            }
            guard code == 0 else {
                closeAllHandles()
                // `posix_spawn` returns the error number rather than setting `errno`. The domain and
                // the code, never a localized description: the description spells out the path (§11).
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            pid = child
            // `POSIX_SPAWN_SETPGROUP` with a `pgroup` of 0 makes the child its own group leader, so
            // the group's id *is* the child's pid — recorded separately because the pid stops being
            // usable at the reap and the group id does not.
            group = child
            // The parent's copies of the write ends, so the pipes report end-of-file when the last
            // writer in the child's tree is gone.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()

            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
            source.setEventHandler { [self] in childDidExit() }
            exitSource = source
            source.resume()
        }
    }

    func finish(timeout: Duration, completion: @escaping @Sendable (HostCommandOutput) -> Void) {
        // Synchronously, so that no timeout — however small — can latch `settled` before there is a
        // continuation to resume.
        queue.sync { [self] in
            self.completion = completion
            drain(out.fileHandleForReading) { [self] chunk in accept(chunk, into: .out) }
            drain(err.fileHandleForReading) { [self] chunk in accept(chunk, into: .err) }
            accepting = true
            // A child fast enough to have exited already, or a run cancelled before it was awaited:
            // this is the first moment there is anyone to tell.
            if pendingSettle { settle() } else { settleIfComplete() }
        }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000
            + Int(timeout.components.attoseconds / 1_000_000_000)
        // Weakly: a settled child's timer still fires at the full budget, and a strong capture would
        // hold everything it accumulated alive until then. `run` holds the child across its await, so
        // it cannot go away before it settles.
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [weak self] in
            guard let self, !self.settled else { return }
            // The kernel is asked before the verdict is reached: `exited` is set by a *queued* event,
            // so a child that exited microseconds before this deadline can still be waiting behind
            // this block and would be reported as an overrun of a budget it met.
            self.reapIfExited()
            if self.exited {
                // Answers the caller even when a termination is already under way — a shell that
                // exited on the `SIGTERM` has nothing more to write. What it does *not* do is call
                // that termination off: the escalation is owed to the group, not to the caller.
                self.settle()
            } else if !self.terminating {
                self.timedOut = true
                self.beginTermination()
            }
        }
    }

    /// Ends the awaiting caller's interest: the tree is signalled exactly as a timeout signals it and
    /// `run` answers nil rather than a result.
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
    /// *group*, and the group can outlive the run: the shell exits on `SIGTERM` while a descendant
    /// that ignores it does not, and the awaiting caller can be answered in between — by a budget
    /// that expired inside the grace, or by a final drain that overran the cap after settlement had
    /// begun. Skipping the `SIGKILL` because there is nobody left to tell leaves that descendant on
    /// the machine, which is the one outcome this path exists to prevent. The escalation therefore
    /// runs until it has run, and `escalated` — not `settled` — is what says it has.
    ///
    /// The two escalation blocks hold `self` **strongly**, unlike the budget's own timer: they are a
    /// second apart rather than two minutes, and a weak capture would hand the group's fate to
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
    /// The negative pid is the whole point: `sh -c 'sleep 30 & wait'` is a shell that exits on
    /// `SIGTERM` while the `sleep` it started survives, and a run reported as stopped that leaves a
    /// descendant on the machine is the defect. The child leads a group of its own, so one call
    /// reaches every descendant and nothing else.
    ///
    /// The group is signalled **whether or not the leader has been reaped**, because those are two
    /// different questions: `waitpid` collects one process, and the group is whatever is still in it.
    /// A pid that names a group with members is not reused, so the negative form is safe here for as
    /// long as there is anything for it to reach. The single-process fallback is not: `kill(pid, …)`
    /// after the reap could name a stranger, so it is asked only while the pid is still reserved.
    private func signalTree(_ signal: Int32) {
        guard group > 0 else { return }
        if kill(-group, signal) != 0 && errno == ESRCH && !reaped && pid > 0 { _ = kill(pid, signal) }
    }

    /// The exit source fired. Outside a termination the child is reaped here and the run settles;
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

    // MARK: - the pipes

    private enum Stream { case out, err }

    /// Accumulates one pipe as it fills, without ever blocking `queue` — the timers above share it.
    /// The cancel handler closes the handle, which releases the descriptor even when the writer never
    /// went away.
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
    /// Bounding the *pass* and bounding the *buffer* are different properties. The pass returns the
    /// queue to the timers every mebibyte, which is what keeps a flooding child killable; the
    /// accumulated `Data` grows for as long as the child writes, and `!yes` reaches whatever the
    /// machine has long before a two-minute budget expires. Past the cap nothing is retained and the
    /// tree is ended: the command has nothing more to say that will be shown, because the envelope
    /// would drop it.
    private func accept(_ chunk: Data, into stream: Stream) {
        let retained = stream == .out ? retainedOut : retainedErr
        let room = max(outputLimitBytes - retained, 0)
        let kept = chunk.count < room ? chunk : chunk.prefix(room)
        if !kept.isEmpty {
            switch stream {
            case .out: stdout.append(kept); retainedOut += kept.count
            case .err: stderr.append(kept); retainedErr += kept.count
            }
        }
        guard chunk.count >= room else { return }
        // The cause is whichever came first. A child already under `SIGTERM` for a timeout or a
        // cancellation can still write during its grace, and relabelling that as an output overrun
        // would report the wrong thing; nothing is lost by not latching it, because `room` is zero
        // from here on and no further byte is retained.
        guard !terminating else { return }
        limitReached = true
        beginTermination()
    }

    /// One pass over a pipe, cancelling its source once the writer is gone or the descriptor is
    /// unusable. A pass that stopped because it had taken enough leaves the source armed: the event
    /// fires again while the descriptor still holds data, so the rest arrives on a later turn of this
    /// queue rather than on this one.
    private func readAvailable(_ fd: Int32, into append: (Data) -> Void, source: DispatchSourceRead) {
        if HostPipeDrain.pass(fd, into: append) == .closed { source.cancel() }
    }

    /// Closes every pipe handle this child holds. The failure path's half of `start`.
    private func closeAllHandles() {
        for handle in [out.fileHandleForReading, out.fileHandleForWriting,
                       err.fileHandleForReading, err.fileHandleForWriting] {
            try? handle.close()
        }
    }

    // MARK: - settlement

    private func settleIfComplete() { if exited && accepting { settle() } }

    private func settle() {
        guard !settled else { return }
        guard accepting else { pendingSettle = true; return }
        settled = true
        // The last pass over each pipe: everything written before the exit is in the kernel's buffer
        // by now, whoever else still holds the write end. Bounded like every other pass, and
        // deliberately *one* of them — looping until a surviving grandchild's pipe runs dry would
        // hand the queue to a process the child no longer controls.
        //
        // This pass can be the one that overruns the cap — a shell that exits leaving a descendant on
        // its stdout is exactly the shape — and `accept` ends the tree for it like any other. That
        // termination is begun *here*, after `settled` and possibly after the leader was reaped, and
        // both are why neither is a condition on it.
        for d in drains { readAvailable(d.fd, into: d.append, source: d.source) }
        for d in drains where !d.source.isCancelled { d.source.cancel() }
        // The reap a termination deferred: after this the pid is nobody's to signal, though the group
        // it named still is.
        reapIfExited()
        abandonUnreapedChild()
        let output = HostCommandOutput(stdout: stdout, stderr: stderr,
                                       timedOut: timedOut, outputLimited: limitReached)
        let finish = completion
        completion = nil
        finish?(output)
    }

    // MARK: - the C vectors

    /// Runs `body` with a null-terminated `argv` and `envp`, freed on the way out. `argv[0]` is the
    /// shell's own path, as every exec convention expects.
    private static func withVectors<R>(executable: String, arguments: [String],
                                       environment: [String: String],
                                       body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                              UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }
        return body(&argv, &envp)
    }
}

// MARK: - The composer's half

extension ComposerModel {

    /// The command a `!` line names, or nil when the line is not one or names nothing.
    ///
    /// The `!` is dropped and the rest is passed through untouched: what the user typed is what the
    /// shell is given, and it is also what goes inside `<bash-input>`.
    static func shellCommand(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return nil }
        let command = String(trimmed.dropFirst())
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
    }

    /// Whether a send on this origin would be **accepted**, which is exactly `ChannelSupervisor.send`'s
    /// own division: the three origins it refuses `heldElsewhere` on are the three refused here.
    ///
    /// Not a second opinion about eligibility — it is the ownership question X5 answers through
    /// `state(of:)`, asked before anything runs. A `!` on a channel the user's own terminal holds
    /// would otherwise touch the filesystem and *then* have its post refused, which is the one
    /// ordering that cannot be undone.
    static func sendWouldBeAccepted(on origin: ChannelOrigin) -> Bool {
        switch origin {
        case .foreignLive, .backgroundJob, .owned(.contended): false
        case .owned(.ready), .owned(.dormant), .owned(.connecting), .archived: true
        }
    }

    /// Runs the line host-side and posts exactly one `sendPrompt(UserInput)` — the only write this
    /// path makes, and the only one it is allowed (contract Y5).
    ///
    /// A non-zero exit and a command that does not exist both still post: the shell's complaint is
    /// what the model needs to see, and it is already inside `<bash-stderr>` because that is where
    /// the command wrote it.
    @discardableResult
    func runShellEscape(_ line: String) async -> Bool {
        guard let command = Self.shellCommand(in: line) else {
            refusal = "There is no command after `!`, so nothing ran."
            return false
        }
        // Without a context there is no directory and no environment. Running anyway would run in
        // whatever directory the app happens to be in, and doing nothing silently would leave the
        // user believing a command ran — so it says which it is.
        guard let context else {
            refusal = "afleet does not know this channel's working directory yet, so `!` cannot run here."
            return false
        }
        // **The whole run, including the question that precedes it, is one cancellable task, and it is
        // registered before the question goes out.** `stop()` ends whatever `hostShell` names, and the
        // send that reaches here was launched from a `Task` the view does not retain, so a release can
        // land at any suspension point in it. The first of those is the ownership question below: a
        // handle registered only after it leaves a window in which `stop()` finds nothing to cancel
        // and the far side of the await spawns a shell for a composer that is already gone, then posts
        // through a lifecycle the user has moved on from.
        let running = Task { [weak self] () -> HostCommandOutput? in
            guard let self else { return nil }
            // Asked **before** the spawn. A channel the fleet owns no supervisor for answers nil, and
            // that is not a refusal: the send would build one and apply its own guards, and nothing is
            // known here that would justify refusing ahead of it.
            let state = await self.lifecycle.state(of: self.key)
            // The release that arrived during that await lands here, and it is the *only* thing said
            // about it: a run cancelled before it spawned starts nothing, explains nothing and posts
            // nothing, because there is no longer a composer for any of it to appear in.
            guard !Task.isCancelled else { return nil }
            if let state, !Self.sendWouldBeAccepted(on: state.origin) {
                self.refusal = Self.explanation(of: .heldElsewhere(state.observed))
                return nil
            }
            return await HostShellRunner().run(command: command,
                                               shell: context.environment.shell,
                                               in: context.cwd,
                                               environment: context.environment.variables)
        }
        hostShell = running
        let output = await running.value
        if hostShell == running { hostShell = nil }
        // A cancelled run is not a result: nothing is posted, and the tree is already ended.
        guard let output else { return false }
        // C2's sanitiser, called. The three inputs go in exactly as they came back.
        let text = ShellEnvelope.wrap(command: command, stdout: output.stdout, stderr: output.stderr)
        // Through `post(_:)`, the one place a `UserInput` becomes a prompt: the engine answers a
        // `<bash-stdout>`-bearing user frame with a turn (the live gate's item 12 is exactly that), so
        // this send attributes like every other. While it was issued as `perform(.send)` with no
        // raise — as it was until Task 7 — that turn reduced as `.unprompted`.
        let posted = await post(UserInput(text: text))
        if posted, output.timedOut {
            let seconds = HostShellRunner.budget.components.seconds
            refusal = "The command was still running after \(seconds) second(s) and was stopped; what it had written was sent."
        } else if posted, output.outputLimited {
            refusal = "The command wrote more than `!` keeps and was stopped; what was kept was sent."
        }
        return posted
    }

    /// Ends a `!` command still running for this composer. Called from `stop()`.
    func cancelHostShell() {
        hostShell?.cancel()
        hostShell = nil
    }
}
