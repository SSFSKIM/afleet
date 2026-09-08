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

    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
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

    public init() {}

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
        let job = ToolJob(executable: executable, arguments: arguments, cwd: cwd, environment: environment)
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
        return await withCheckedContinuation { continuation in
            job.finish(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }
}

/// Single owner of a `Process`, its pipes and the accumulated output.
///
/// The invariant: every mutation of this object's state, and every `isRunning`, `terminate()` and
/// `terminationStatus` access, happens on `queue`.
///
/// The exit is learned from `terminationHandler`, which Foundation calls on its own queue as soon
/// as it reaps, and never from `waitUntilExit()`. `waitUntilExit()` spins the *calling thread's*
/// run loop, and the exit is posted to the run loop of the thread that launched the process —
/// which here is a `DispatchQueue` worker whose run loop nobody spins. The two threads never meet,
/// so the wait can outlast the child by an unbounded margin: C2 measured a shell that exited in
/// 30 ms reported as still running for 31 seconds. That is what produced settlement with the
/// child already reaped and an exit code of `-1`.
///
/// Settlement is keyed to the child's exit, never to end-of-file on its pipes. A grandchild that
/// inherited stdout and outlives the child — and `git` starts them: a pager, a credential helper,
/// a hook that backgrounds something — holds the write end open indefinitely, so waiting for EOF
/// would burn the whole timeout on a child that exited in a second and report the SIGTERM that
/// followed. Reads are event-driven, non-blocking `DispatchSourceRead`s for the same reason, and
/// the exit path takes one last non-blocking pass over each pipe so that everything the child
/// wrote before exiting is in the result. A blocking read on the same queue as the timers would
/// stall the very timers meant to bound the call.
private final class ToolJob: @unchecked Sendable {

    /// After `terminate()`, how long the child gets to exit before `SIGKILL`, and then before we
    /// settle anyway.
    private static let grace = DispatchTimeInterval.milliseconds(500)

    private let queue = DispatchQueue(label: "afleet.source-control.tool-runner")
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var stdoutData = Data(), stderrData = Data()
    /// One entry per pipe still open, holding what is needed to make a final read of it.
    private var drains: [(fd: Int32, source: DispatchSourceRead, append: (Data) -> Void)] = []
    private var exited = false
    private var timedOut = false
    private var settled = false
    private var completion: (@Sendable (ToolOutput) -> Void)?

    /// True once `finish` has installed a completion. Until then an exit is recorded but not acted
    /// on: the handler below can fire before the caller has asked for the result, and settling then
    /// would latch `settled` against a continuation that does not exist yet.
    private var accepting = false

    init(executable: URL, arguments: [String], cwd: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        // Exactly the dictionary the caller passed, never merged with this process's own. The
        // resolved environment is what X11 says every git and gh process afleet spawns runs with,
        // and a merge would quietly hand the child whatever the app happened to be launched with.
        process.environment = environment
        // The cwd is set here rather than through `git -C` or `env -C`, so that it applies to `gh`
        // and to any tool added later without each wrapper remembering a flag.
        process.currentDirectoryURL = cwd
        // Never a terminal and never this process's stdin: a `git` that decides to prompt for a
        // credential must fail rather than block on an input nobody is watching.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        // Installed before the child can possibly exist, so no exit can be missed.
        process.terminationHandler = { [self] _ in queue.async { [self] in exited = true; settleIfComplete() } }
    }

    /// Starts the child, releasing everything this job holds if the spawn fails.
    ///
    /// Both halves are needed and both were measured. The termination handler is nilled because it
    /// closes a `ToolJob → process → handler → ToolJob` cycle that nothing on the failure path
    /// breaks; the four pipe handles are closed because Foundation's own failure path leaves the
    /// descriptors it opened open, whatever happens to the objects. Without them, 20 failed spawns
    /// leaked exactly 80 descriptors. This is not an exotic path: a panel polling `git` in a
    /// directory the user has deleted takes it on every refresh.
    func start() throws {
        do {
            try queue.sync { try process.run() }
        } catch {
            process.terminationHandler = nil
            for handle in [out.fileHandleForReading, out.fileHandleForWriting,
                           err.fileHandleForReading, err.fileHandleForWriting] {
                try? handle.close()
            }
            throw error
        }
    }

    func finish(timeout: Duration, completion: @escaping @Sendable (ToolOutput) -> Void) {
        // Synchronously, so that no timeout — however small — can latch `settled` before there is
        // a continuation to resume.
        queue.sync { [self] in
            self.completion = completion
            drain(out.fileHandleForReading) { [self] in stdoutData.append($0) }
            drain(err.fileHandleForReading) { [self] in stderrData.append($0) }
            accepting = true
            // A child fast enough to have exited already: its handler has run and gone home, and
            // this is the first moment there is anyone to tell.
            settleIfComplete()
        }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000
            + Int(timeout.components.attoseconds / 1_000_000_000)
        // Scheduled on `queue`, so the body is already serialised with every other access. Weakly,
        // all three: a settled job's timer still fires at the full budget, and a strong capture
        // would hold the job and everything it accumulated — the whole of stdout — alive until
        // then, thirty seconds after the call returned for a git read. `run` holds the job across
        // its `await`, so the job cannot go away before it settles and nothing here is missed.
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [weak self] in
            guard let self, !self.settled else { return }
            // The `exited` guard is what keeps a child that finished microseconds before this timer
            // from being called an overrun.
            if !self.exited {
                self.timedOut = true
                if self.process.isRunning { self.process.terminate() }
            }
            self.queue.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
                guard let self, !self.settled else { return }
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                self.queue.asyncAfter(deadline: .now() + Self.grace) { [weak self] in self?.settle() }
            }
        }
    }

    /// Accumulates one pipe as it fills. The cancel handler closes the handle, which releases the
    /// descriptor even when the writer never went away.
    private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in _ = readAvailable(fd, into: append, source: source) }
        source.setCancelHandler { [self] in
            try? handle.close()
            drains.removeAll { $0.fd == fd }
        }
        drains.append((fd: fd, source: source, append: append))
        source.resume()
    }

    /// Reads what the pipe holds right now, appending it. Returns false once the writer is gone or
    /// the descriptor is unusable, having cancelled the source.
    @discardableResult
    private func readAvailable(_ fd: Int32, into append: (Data) -> Void, source: DispatchSourceRead) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { append(Data(buffer[0..<n])); continue }
            if n == 0 { source.cancel(); return false }
            if errno == EINTR { continue }
            if errno == EAGAIN { return true }
            source.cancel(); return false
        }
    }

    /// The last pass over each pipe, on the exit path: everything the child wrote before it exited
    /// is in the kernel's buffer by now, whoever else still holds the write end.
    private func drainRemaining() { for d in drains { readAvailable(d.fd, into: d.append, source: d.source) } }

    /// The child's exit is the whole of the completion condition — see the type's note on EOF —
    /// once there is somebody to hand the result to.
    private func settleIfComplete() { if exited && accepting { settle() } }

    private func settle() {
        guard !settled, accepting else { return }
        settled = true
        drainRemaining()
        for d in drains where !d.source.isCancelled { d.source.cancel() }
        let output = ToolOutput(stdout: stdoutData, stderr: stderrData,
                                exitCode: exited ? process.terminationStatus : -1,
                                timedOut: timedOut)
        let finish = completion
        completion = nil
        finish?(output)
    }
}
