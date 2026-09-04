import Foundation

public struct ProcessOutput: Sendable {
    public var stdout: Data; public var stderr: Data; public var exitCode: Int32; public var timedOut: Bool
    public init(stdout: Data, stderr: Data, exitCode: Int32, timedOut: Bool) { self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.timedOut = timedOut }
}
public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput
}

/// Runs a short-lived process to completion, draining both pipes concurrently, killing it at the timeout.
/// `Process` is not Sendable: one serial queue owns it; the drains run on their own threads and only hand Data back.
public struct FoundationProcessRunner: ProcessRunner {
    public init() {}
    public func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        let job = ProcessJob(executable: executable, arguments: arguments, environment: environment)
        try job.start()
        return await withCheckedContinuation { cont in job.finish(timeout: timeout) { cont.resume(returning: $0) } }
    }
}

/// Single owner of a Process and its pipes. Every access to the Process happens on `queue`.
private final class ProcessJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "afleet.process-runner")
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var timedOut = false
    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
    }
    func start() throws { try queue.sync { try process.run() } }
    func finish(timeout: Duration, completion: @escaping @Sendable (ProcessOutput) -> Void) {
        let group = DispatchGroup()
        let stdoutBox = DataBox(), stderrBox = DataBox()
        group.enter(); DispatchQueue.global().async { stdoutBox.data = self.out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { stderrBox.data = self.err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { self.process.waitUntilExit(); group.leave() }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        let timer = DispatchWorkItem { [self] in
            // Already running on `queue` (asyncAfter below schedules it there): a nested `queue.sync`
            // would re-enter the serial queue and trap in libdispatch.
            if process.isRunning { timedOut = true; process.terminate() }
            queue.asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos), execute: timer)
        group.notify(queue: queue) { [self] in
            timer.cancel()
            completion(ProcessOutput(stdout: stdoutBox.data, stderr: stderrBox.data, exitCode: process.terminationStatus, timedOut: timedOut))
        }
    }
    private final class DataBox: @unchecked Sendable { var data = Data() }
}
