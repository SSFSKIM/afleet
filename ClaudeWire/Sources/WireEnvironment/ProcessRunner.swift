import Foundation

public struct ProcessOutput: Sendable {
    public var stdout: Data; public var stderr: Data; public var exitCode: Int32; public var timedOut: Bool
    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool) { self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.timedOut = timedOut }
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

/// Single owner of a Process, its pipes and the accumulated output. Every mutation of this object's state,
/// and every `isRunning` / `terminate()` / `terminationStatus` access, happens on `queue`; the one exception
/// is the thread that blocks in `waitUntilExit()`, which touches nothing else and hops back to `queue` to
/// report. Reads are event-driven `DispatchSourceRead`s rather than blocking `readDataToEndOfFile` calls, so
/// settlement never waits on a pipe: a grandchild that inherited stdout and outlives the child (a `.zshrc`
/// that backgrounds a daemon) cannot hold `run` open past the timeout.
private final class ProcessJob: @unchecked Sendable {
    /// After `terminate()`, how long the child gets to exit before SIGKILL, and then before we settle anyway.
    private static let grace = DispatchTimeInterval.milliseconds(500)

    private let queue = DispatchQueue(label: "afleet.process-runner")
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var stdoutData = Data(), stderrData = Data()
    private var sources: [DispatchSourceRead] = []
    private var openDrains = 0
    private var exited = false
    private var timedOut = false
    private var settled = false
    private var completion: (@Sendable (ProcessOutput) -> Void)?

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
    }
    func start() throws { try queue.sync { try process.run() } }

    func finish(timeout: Duration, completion: @escaping @Sendable (ProcessOutput) -> Void) {
        queue.async { [self] in
            self.completion = completion
            drain(out.fileHandleForReading) { [self] in stdoutData.append($0) }
            drain(err.fileHandleForReading) { [self] in stderrData.append($0) }
        }
        DispatchQueue.global().async { [self] in
            process.waitUntilExit()
            queue.async { [self] in exited = true; settleIfComplete() }
        }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        // Scheduled on `queue`, so the body is already serialised with every other access: no nested sync.
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [self] in
            guard !settled else { return }
            if process.isRunning { timedOut = true; process.terminate() }
            queue.asyncAfter(deadline: .now() + Self.grace) { [self] in
                guard !settled else { return }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                queue.asyncAfter(deadline: .now() + Self.grace) { [self] in settle() }
            }
        }
    }

    /// Accumulates one pipe until EOF. The cancel handler closes the handle, which releases the descriptor
    /// even when the writer never went away.
    private func drain(_ handle: FileHandle, into append: @escaping (Data) -> Void) {
        let fd = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        openDrains += 1
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { append(Data(buffer[0..<n])) }
            else if n == 0 { source.cancel() }
            else if errno != EINTR && errno != EAGAIN { source.cancel() }
        }
        source.setCancelHandler { [self] in
            try? handle.close()
            openDrains -= 1
            if openDrains == 0 { sources.removeAll() }
            settleIfComplete()
        }
        sources.append(source)
        source.resume()
    }

    private func settleIfComplete() { if exited && openDrains == 0 { settle() } }

    private func settle() {
        guard !settled else { return }
        settled = true
        for source in sources where !source.isCancelled { source.cancel() }
        let output = ProcessOutput(stdout: stdoutData, stderr: stderrData,
                                   exitCode: exited ? process.terminationStatus : -1, timedOut: timedOut)
        let finish = completion; completion = nil
        finish?(output)
    }
}
