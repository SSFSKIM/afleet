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
}

/// Runs one short-lived command through the channel's shell.
///
/// **Why not `ClaudeWire`'s `FoundationProcessRunner`.** Its `ProcessRunner` protocol takes an
/// executable, arguments, an environment and a timeout — and no working directory, which is the one
/// thing this path exists to set. Widening that protocol is a `ClaudeWire` edit outside this leaf's
/// fence, and the alternative of prefixing a `cd` to the user's command would put a line in front of
/// what they typed. So the spawn is here; its settlement is modelled on what `ProcessJob` learned —
/// the child's **exit** is the completion condition, never end-of-file on its pipes, because a
/// grandchild that inherited stdout (a `!` that starts a daemon) holds the write end open for as
/// long as it lives, and reads are non-blocking for the same reason.
struct HostShellRunner: Sendable {

    /// How long a `!` may run before it is stopped. A command in a chat field is a short one; a long
    /// one belongs in a pane. What it wrote up to that point is still posted.
    static let budget = Duration.seconds(120)

    func run(command: String, shell: String, in directory: URL,
             environment: [String: String], timeout: Duration = HostShellRunner.budget) async -> HostCommandOutput {
        await withCheckedContinuation { continuation in
            let child = ShellChild(command: command, shell: shell, directory: directory, environment: environment)
            child.start(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }
}

/// Single owner of the child, its two pipes and what they produced. Every mutation happens on
/// `queue`, which also carries the timers, so nothing here needs a lock.
private final class ShellChild: @unchecked Sendable {

    /// After the budget expires, how long the child gets to exit before SIGKILL, and then before the
    /// result is handed over anyway.
    private static let grace = DispatchTimeInterval.milliseconds(500)

    private let queue = DispatchQueue(label: "afleet.composer.shell-escape")
    private let process = Process()
    private let out = Pipe(), err = Pipe()
    private var stdout = Data(), stderr = Data()
    private var drains: [(fd: Int32, source: DispatchSourceRead, append: (Data) -> Void)] = []
    private var started = false, exited = false, accepting = false, settled = false, timedOut = false
    private var completion: (@Sendable (HostCommandOutput) -> Void)?

    init(command: String, shell: String, directory: URL, environment: [String: String]) {
        // The channel's own shell, as `ResolvedEnvironment` captured it (X11's single capture), and
        // `-c`, which is how the terminal runs a `!` line too.
        process.executableURL = URL(fileURLWithPath: shell.isEmpty ? "/bin/sh" : shell)
        process.arguments = ["-c", command]
        // The one place the channel's directory is used. Set on the child; never opened here.
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { [self] _ in queue.async { [self] in exited = true; settleIfComplete() } }
    }

    func start(timeout: Duration, completion: @escaping @Sendable (HostCommandOutput) -> Void) {
        queue.sync { [self] in
            self.completion = completion
            do {
                try process.run()
                started = true
            } catch {
                // A shell that will not start is a failure of the command as far as the user is
                // concerned, so it is reported the same way one is: inside `<bash-stderr>`. The
                // sentence names no path (§11).
                stderr = Data("afleet could not start a shell for this command.\n".utf8)
                accepting = true
                settle()
                return
            }
            drain(out.fileHandleForReading) { [self] in stdout.append($0) }
            drain(err.fileHandleForReading) { [self] in stderr.append($0) }
            accepting = true
            // A child fast enough to have exited already.
            settleIfComplete()
        }
        guard queue.sync(execute: { started }) else { return }
        let nanos = Int(timeout.components.seconds) * 1_000_000_000 + Int(timeout.components.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos)) { [self] in
            guard !settled else { return }
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

    /// Accumulates one pipe as it fills, without ever blocking `queue` — the timers above share it.
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

    private func readAvailable(_ fd: Int32, into append: (Data) -> Void, source: DispatchSourceRead) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { append(Data(buffer[0..<n])); continue }
            if n == 0 { source.cancel(); return }
            if errno == EINTR { continue }
            if errno == EAGAIN { return }
            source.cancel()
            return
        }
    }

    private func settleIfComplete() { if exited && accepting { settle() } }

    private func settle() {
        guard !settled, accepting else { return }
        settled = true
        // The last pass over each pipe: everything written before the exit is in the kernel's buffer
        // by now, whoever else still holds the write end.
        for d in drains { readAvailable(d.fd, into: d.append, source: d.source) }
        for d in drains where !d.source.isCancelled { d.source.cancel() }
        let output = HostCommandOutput(stdout: stdout, stderr: stderr, timedOut: timedOut)
        let finish = completion
        completion = nil
        finish?(output)
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
        let output = await HostShellRunner().run(command: command,
                                                 shell: context.environment.shell,
                                                 in: context.cwd,
                                                 environment: context.environment.variables)
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
        }
        return posted
    }
}
