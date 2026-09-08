import Foundation

public struct ProcessOutput: Sendable {
    public var stdout: Data; public var stderr: Data; public var exitCode: Int32; public var timedOut: Bool
    /// What the child looked like at the instant its budget ran out, and nil when it did not run out. A child we
    /// had to abandon reports an exit code that says nothing — the signal that ended it, or `-1` for a wait that
    /// never returned — so the state it was actually in is the only thing that separates a hung child from one we
    /// failed to observe. Identifiers, states and counts only.
    public var timeoutState: String?
    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool, timeoutState: String? = nil) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.timedOut = timedOut
        self.timeoutState = timeoutState
    }
}
public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput
}

/// Runs a short-lived process to completion, draining both pipes, and settles within the timeout plus a
/// small grace whatever the child leaves behind.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        let job = ProcessJob(executable: executable, arguments: arguments, environment: environment)
        try job.start()
        return await withCheckedContinuation { cont in job.finish(timeout: timeout) { cont.resume(returning: $0) } }
    }
}

/// One pass over a descriptor that is being drained, and the bound on how much it takes.
///
/// Internal rather than private, because the bound is the whole point and no black-box test can see
/// it: a child flooding a pipe still gets timed out and killed with the pass unbounded, since the
/// producer is slower than the drain and the loop reaches `EAGAIN` between events. The property that
/// has to hold is not "the timeout fires against this producer" but "one readable event takes a
/// bounded amount of work", and that is stated here and tested directly.
enum PipeDrain {

    /// One `read(2)`'s buffer.
    static let chunk = 64 * 1024

    /// The most one pass takes before it returns the queue to whatever else is waiting on it —
    /// sixteen full reads.
    ///
    /// Why a bound at all: the timeout, the `SIGKILL` escalation and the settlement all run on the
    /// *same* serial queue as these passes (`ProcessJob.queue`), so work done here is time none of
    /// them can run. An unbounded pass — read while data keeps arriving, return only on `EAGAIN` —
    /// hands the queue to whichever producer can keep the pipe fed, and the engine processes this
    /// runner drives are long-lived and talkative. Bounded, the worst case is one mebibyte of
    /// copying between two turns of the queue.
    static let bytesPerPass = 16 * chunk

    /// What a pass found.
    enum Outcome: Equatable {
        /// The descriptor is still usable: it ran dry, or the pass had taken enough. Either way the
        /// reader comes back.
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

/// Single owner of a Process, its pipes and the accumulated output.
///
/// The invariant: every mutation of this object's state, and every `isRunning`, `terminate()` and
/// `terminationStatus` access, happens on `queue`.
///
/// The exit is learned from `terminationHandler`, which Foundation calls on its own queue as soon as it reaps,
/// and never from `waitUntilExit()`. `waitUntilExit()` spins the *calling thread's* run loop, and the exit is
/// posted to the run loop of the thread that launched the process — which here is a `DispatchQueue` worker whose
/// run loop nobody spins. The two threads never meet, so the wait can outlast the child by an unbounded margin:
/// measured here, a shell that exited in 30 ms was reported as still running for 31 seconds, until an unrelated
/// grandchild died. That is what produced settlement with `exited` still false and an exit code of `-1` for a
/// child the kernel had already forgotten.
///
/// Settlement is keyed to the child's exit, never to end-of-file on its pipes. A grandchild that inherited
/// stdout and outlives the child — a `.zshrc` that backgrounds a daemon, or the CLI's own `bg spare` host —
/// holds the write end open indefinitely, so waiting for EOF would burn the whole timeout on a child that
/// exited in a second and report the SIGTERM that followed. Reads are event-driven, non-blocking
/// `DispatchSourceRead`s for the same reason, and the exit path takes one last non-blocking pass over each
/// pipe so that everything the child wrote before exiting is in the result.
private final class ProcessJob: @unchecked Sendable {
    /// After `terminate()`, how long the child gets to exit before SIGKILL, and then before we settle anyway.
    private static let grace = DispatchTimeInterval.milliseconds(500)

    private let queue = DispatchQueue(label: "afleet.process-runner")
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var stdoutData = Data(), stderrData = Data()
    /// One entry per pipe still open, holding what is needed to make a final read of it.
    private var drains: [(fd: Int32, source: DispatchSourceRead, append: (Data) -> Void)] = []
    private var exited = false
    private var timedOut = false
    /// Sampled once, at the moment the budget expires and before anything is signalled: after a SIGTERM the
    /// child's state is one we caused, and the question is what state it reached on its own.
    private var timeoutState: String?
    private var settled = false
    private var completion: (@Sendable (ProcessOutput) -> Void)?

    /// True once `finish` has installed a completion. Until then an exit is recorded but not acted on: the
    /// handler below can fire before the caller has asked for the result, and settling then would latch
    /// `settled` against a continuation that does not exist yet.
    private var accepting = false

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        // Installed before the child can possibly exist, so no exit can be missed.
        process.terminationHandler = { [self] _ in queue.async { [self] in exited = true; settleIfComplete() } }
    }
    func start() throws { try queue.sync { try process.run() } }

    func finish(timeout: Duration, completion: @escaping @Sendable (ProcessOutput) -> Void) {
        // Synchronously, so that no timeout — however small — can latch `settled` before there is a
        // continuation to resume.
        queue.sync { [self] in
            self.completion = completion
            drain(out.fileHandleForReading) { [self] in stdoutData.append($0) }
            drain(err.fileHandleForReading) { [self] in stderrData.append($0) }
            accepting = true
            // A child fast enough to have exited already: its handler has run and gone home, and this is the
            // first moment there is anyone to tell.
            settleIfComplete()
        }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        // Scheduled on `queue`, so the body is already serialised with every other access: no nested sync.
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [self] in
            guard !settled else { return }
            timeoutState = describeAtTimeout()
            // The overrun is keyed to the wait not having returned, not to the child still running. A child that
            // is gone or a zombie at the budget has overrun it just as surely — that is the case where the exit
            // code is `-1` — and treating it as an ordinary failure is what threw the state away last time. The
            // `exited` guard is what keeps a child that finished microseconds before this timer from being
            // called an overrun.
            if !exited {
                timedOut = true
                if process.isRunning { process.terminate() }
            }
            queue.asyncAfter(deadline: .now() + Self.grace) { [self] in
                guard !settled else { return }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                queue.asyncAfter(deadline: .now() + Self.grace) { [self] in settle() }
            }
        }
    }

    /// Accumulates one pipe as it fills. The cancel handler closes the handle, which releases the descriptor
    /// even when the writer never went away.
    private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
        let fd = handle.fileDescriptor
        // The handlers and the settlement timers share `queue`: a read that blocked would stall the very
        // timers meant to bound this call, and the EAGAIN arm below could never be reached.
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

    /// One pass over a pipe, cancelling its source once the writer is gone or the descriptor is
    /// unusable. A pass that stopped because it had taken enough leaves the source armed: the event
    /// fires again while the descriptor still holds data, so the rest arrives on a later turn of this
    /// queue rather than on this one, and the timeout, the kill and the settlement get their turn.
    private func readAvailable(_ fd: Int32, into append: (Data) -> Void, source: DispatchSourceRead) {
        if PipeDrain.pass(fd, into: append) == .closed { source.cancel() }
    }

    /// The last pass over each pipe, on the exit path: everything the child wrote before it exited is in the
    /// kernel's buffer by now, whoever else still holds the write end.
    ///
    /// Bounded like every other pass, and deliberately *one* of them. A pipe holds at most its own
    /// buffer — 64 KiB here, a sixteenth of the bound — so one pass empties whatever the child left
    /// behind. What one pass cannot empty is a pipe a *surviving* grandchild is still filling, and
    /// looping until that one runs dry would hand the queue to a process the child no longer
    /// controls, at the moment the caller is owed its answer. Settlement is keyed to the child's exit
    /// and not to end-of-file (see the type's note), and this is that ruling applied to the last read.
    private func drainRemaining() { for d in drains { readAvailable(d.fd, into: d.append, source: d.source) } }

    /// The three explanations a budget overrun has, and the facts that separate them. `gone` with `exited`
    /// still false means something collected the child's status and the wait will never return — an observation
    /// defect here. `zombie` means it exited and nobody reaped it. `alive` means it genuinely has not exited,
    /// which is the child's behaviour rather than ours. `pipesOpen` says whether end-of-file had arrived, which
    /// is the separate question of whether anything still holds the write end.
    private func describeAtTimeout() -> String {
        let state = probeProcessState(process.processIdentifier)
        return "\(state) waitReturned=\(exited) pipesOpen=\(drains.count)"
    }

    /// The child's exit is the whole of the completion condition — see the type's note on EOF — once there is
    /// somebody to hand the result to.
    private func settleIfComplete() { if exited && accepting { settle() } }

    private func settle() {
        guard !settled, accepting else { return }
        settled = true
        drainRemaining()
        for d in drains where !d.source.isCancelled { d.source.cancel() }
        let output = ProcessOutput(stdout: stdoutData, stderr: stderrData,
                                   exitCode: exited ? process.terminationStatus : -1, timedOut: timedOut,
                                   timeoutState: timeoutState)
        let finish = completion; completion = nil
        finish?(output)
    }
}
