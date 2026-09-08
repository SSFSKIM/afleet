import Darwin
import Dispatch
import Foundation
import Synchronization

/// Shared ownership of the pty master descriptor.
///
/// More than one dispatch source watches the descriptor: the read source for the child's output,
/// and one short-lived write source for each wait on writability. Dispatch requires the
/// descriptor to stay valid until the last of those sources has finished cancelling, so the
/// close belongs to whichever cancel handler runs last rather than to the actor. The count is
/// held under a `Mutex` because cancel handlers run on a dispatch queue, off the actor.
final class PTYMasterDescriptor: Sendable {
    let value: Int32
    private let watchers: Mutex<Int>

    /// The initial watcher is the read source, whose cancel handler releases it.
    init(value: Int32) {
        self.value = value
        watchers = Mutex(1)
    }

    func retain() {
        watchers.withLock { $0 += 1 }
    }

    func release() {
        let closing = watchers.withLock { remaining -> Bool in
            remaining -= 1
            return remaining == 0
        }
        if closing {
            _ = Darwin.close(value)
        }
    }
}

public actor PTYProcess {
    // Task 6 replaces this single policy with bounded, coalesced delivery. Keeping the current
    // behavior named here avoids threading an implicit AsyncStream default through the actor.
    private static let eventBufferingPolicy: AsyncStream<PTYEvent>.Continuation.BufferingPolicy =
        .unbounded

    public nonisolated let events: AsyncStream<PTYEvent>
    public nonisolated let processIdentifier: pid_t

    private let master: PTYMasterDescriptor
    private let writeQueue: DispatchQueue
    private let waitQueue: DispatchQueue
    private let eventContinuation: AsyncStream<PTYEvent>.Continuation
    private let readSource: DispatchSourceRead
    private let stopPolicy: PTYStopPolicy
    private var masterIsOpen = true
    private var masterReachedEnd = false
    private var termination: PTYTermination?
    private var childStatusUnavailable = false
    private var streamWasFinished = false

    /// The gate that makes `write` a queue rather than a race. A caller that has to wait for the
    /// master to drain suspends, which lets a second `write` enter the actor; without the gate
    /// the two would interleave their `Darwin.write` calls and shuffle the bytes. Callers are
    /// admitted in the order they reached the gate, so the bytes reach the child in that order.
    ///
    /// Waiting for the gate is cancellable. A queue that could only be left by reaching the front
    /// would make one stalled child hold every later caller — including a pane being torn down —
    /// for as long as the stall lasts. A cancelled caller leaves without ever holding the gate,
    /// so it neither writes a byte nor hands the gate on.
    private var writeInProgress = false
    private var writeGate: [WriteGateWaiter] = []

    private struct WriteGateWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct WritabilityWait {
        let source: DispatchSourceWrite
        let continuation: CheckedContinuation<Void, Error>
    }

    private var writabilityWaits: [UUID: WritabilityWait] = [:]

    public init(spawning request: PTYSpawnRequest) throws {
        let spawned = try DarwinPTY.spawn(request)
        let eventChannel = AsyncStream<PTYEvent>.makeStream(
            bufferingPolicy: Self.eventBufferingPolicy
        )
        let queue = DispatchQueue(label: "app.afleet.terminal-core.pty-read")
        let descriptor = PTYMasterDescriptor(value: spawned.masterDescriptor)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: spawned.masterDescriptor,
            queue: queue
        )

        events = eventChannel.stream
        eventContinuation = eventChannel.continuation
        processIdentifier = spawned.processIdentifier
        master = descriptor
        readSource = source
        // Writability waits get their own queue: a write source stays armed until the actor can
        // take it down, and on the read queue that window would delay the child's output.
        writeQueue = DispatchQueue(label: "app.afleet.terminal-core.pty-write")
        waitQueue = DispatchQueue(label: "app.afleet.terminal-core.pty-wait")
        stopPolicy = request.stopPolicy

        let readDescriptor = spawned.masterDescriptor
        let continuation = eventChannel.continuation
        source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count: Int = bytes.withUnsafeMutableBytes { buffer in
                while true {
                    let result = Darwin.read(readDescriptor, buffer.baseAddress, buffer.count)
                    if result == -1, errno == EINTR {
                        continue
                    }
                    return result
                }
            }
            if count > 0 {
                continuation.yield(.output(Data(bytes.prefix(count))))
            } else if count == 0 || errno != EAGAIN {
                Task { await self?.readEnded() }
            }
        }
        source.setCancelHandler { descriptor.release() }
        source.resume()

        let processIdentifier = spawned.processIdentifier
        // The statuses `waitpid` returns are ordered — a stop, then whatever ended the child —
        // and the actor has to see them in that order: under `.detach` the stop handler is what
        // sends the signals that produce the end. Handing each status to its own unstructured
        // `Task` would put that order up to the scheduler, so the waiter instead delivers one
        // status at a time and blocks until the actor has finished with it. Only this dedicated
        // queue's thread blocks; no cooperative executor is involved, and no further `waitpid`
        // runs until the previous status has been handled.
        waitQueue.async { [weak self] in
            while true {
                var status: Int32 = 0
                let result = Darwin.waitpid(processIdentifier, &status, WUNTRACED)
                // Read out of the weak capture once: the delivery closure needs a value it can
                // carry across the hop, and it is held only for the length of that hop.
                let owner = self
                if result == processIdentifier {
                    let waitStatus = ChildWaitStatus(status)
                    Self.deliver { await owner?.received(waitStatus) }
                    if waitStatus.isTerminal { return }
                } else if result == -1, errno == EINTR {
                    continue
                } else {
                    Self.deliver { await owner?.waiterFinishedWithoutStatus() }
                    return
                }
            }
        }
    }

    /// Runs one actor hop from the waiter queue and waits for it to complete, which is what
    /// keeps successive statuses in the order `waitpid` produced them. Safe to block on: the
    /// caller is the dedicated waiter queue, never a cooperative executor, and the body reaches
    /// the actor through a reference that is already `nil` once the owner has gone away.
    private static func deliver(_ body: @escaping @Sendable () async -> Void) {
        let delivered = DispatchSemaphore(value: 0)
        Task {
            await body()
            delivered.signal()
        }
        delivered.wait()
    }

    deinit {
        // Releasing the last master is the terminal hangup: macOS continues a stopped foreground
        // group, sends it SIGHUP, and the dedicated waiter remains alive long enough to reap it.
        readSource.cancel()
    }

    /// Writes every byte of `data` to the master, suspending rather than blocking whenever the
    /// pty will not take more. The master is non-blocking, so a write larger than the terminal's
    /// input queue — a paste, a heredoc — never parks the actor or its cooperative thread.
    ///
    /// Cancellation stops the wait, not the transfer already made: a cancelled `write` may have
    /// delivered a prefix of `data`, which is the only meaning cancellation can have on a stream.
    public func write(_ data: Data) async throws {
        guard masterIsOpen else { throw PTYError.closed }
        guard !data.isEmpty else { return }

        try await enterWriteGate()
        defer { leaveWriteGate() }
        try Task.checkCancellation()

        var offset = 0
        while offset < data.count {
            guard masterIsOpen else { throw PTYError.closed }
            var failure: Int32 = 0
            let written: Int = data.withUnsafeBytes { buffer in
                let result = Darwin.write(
                    master.value,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if result == -1 {
                    failure = errno
                }
                return result
            }
            if written > 0 {
                offset += written
            } else if failure == EINTR {
                continue
            } else if failure == EAGAIN || failure == EWOULDBLOCK {
                try await awaitWritable()
            } else {
                throw PTYError.systemCall(operation: .write, code: failure)
            }
        }
    }

    public func resize(to size: TerminalSize) throws {
        guard masterIsOpen else { throw PTYError.closed }
        var windowSize = winsize(
            ws_row: UInt16(truncatingIfNeeded: size.rows),
            ws_col: UInt16(truncatingIfNeeded: size.columns),
            ws_xpixel: UInt16(truncatingIfNeeded: size.pixelWidth),
            ws_ypixel: UInt16(truncatingIfNeeded: size.pixelHeight)
        )
        guard ioctl(master.value, TIOCSWINSZ, &windowSize) != -1 else {
            throw PTYError.systemCall(operation: .resize, code: errno)
        }
    }

    public func foregroundProcessGroup() throws -> pid_t {
        guard masterIsOpen else { throw PTYError.closed }
        let group = tcgetpgrp(master.value)
        guard group != -1 else {
            throw PTYError.systemCall(operation: .readForegroundProcessGroup, code: errno)
        }
        return group
    }

    private func enterWriteGate() async throws {
        guard writeInProgress else {
            writeInProgress = true
            return
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The cancellation handler may already have run; both it and this body execute on
                // the actor, so checking here closes the window in either order.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                writeGate.append(WriteGateWaiter(identifier: identifier, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandonWriteGate(identifier) }
        }
    }

    /// Removes a caller that gave up before its turn. A caller already handed the gate is no
    /// longer queued, so this finds nothing and the gate travels on as normal.
    private func abandonWriteGate(_ identifier: UUID) {
        guard let index = writeGate.firstIndex(where: { $0.identifier == identifier }) else {
            return
        }
        let waiter = writeGate.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func leaveWriteGate() {
        if writeGate.isEmpty {
            writeInProgress = false
        } else {
            writeGate.removeFirst().continuation.resume(returning: ())
        }
    }

    private func awaitWritable() async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard masterIsOpen else {
                    continuation.resume(throwing: PTYError.closed)
                    return
                }
                // The cancellation handler may already have run: it and this body both execute on
                // the actor, so checking here closes the window in either order.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let descriptor = master
                descriptor.retain()
                let source = DispatchSource.makeWriteSource(
                    fileDescriptor: descriptor.value,
                    queue: writeQueue
                )
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    Task { await self.finishWritabilityWait(identifier, with: .success(())) }
                }
                source.setCancelHandler { descriptor.release() }
                writabilityWaits[identifier] = WritabilityWait(
                    source: source,
                    continuation: continuation
                )
                source.resume()
            }
        } onCancel: {
            Task { await self.finishWritabilityWait(identifier, with: .failure(CancellationError())) }
        }
    }

    private func finishWritabilityWait(_ identifier: UUID, with result: Result<Void, Error>) {
        guard let wait = writabilityWaits.removeValue(forKey: identifier) else { return }
        wait.source.cancel()
        wait.continuation.resume(with: result)
    }

    private func received(_ status: ChildWaitStatus) {
        switch status {
        case let .stopped(signal):
            eventContinuation.yield(.stopped(signal: signal))
            if stopPolicy == .detach {
                _ = Darwin.kill(-processIdentifier, SIGCONT)
                _ = Darwin.kill(-processIdentifier, SIGHUP)
            }
        case let .ended(childTermination):
            termination = childTermination
            finishIfChildAndMasterEnded()
        }
    }

    /// The waiter gave up without ever seeing a terminal status, which is what happens when
    /// something outside this actor reaps the child first. No status was observed, so no
    /// termination is invented; the stream is only allowed to finish. Not `private`: the arrival
    /// order that has to be remembered — this before the master's end of file — is a race in
    /// production and is driven directly from the tests.
    func waiterFinishedWithoutStatus() {
        childStatusUnavailable = true
        finishIfChildAndMasterEnded()
    }

    /// Not `private` for the same reason as `waiterFinishedWithoutStatus`.
    func readEnded() {
        guard masterIsOpen else { return }
        masterIsOpen = false
        masterReachedEnd = true
        for identifier in Array(writabilityWaits.keys) {
            finishWritabilityWait(identifier, with: .failure(PTYError.closed))
        }
        readSource.cancel()
        finishIfChildAndMasterEnded()
    }

    /// The stream ends once the master has reached end of file and the child's fate is settled.
    /// "Settled" has two shapes: a status the waiter observed, which becomes the `ended` event,
    /// and a status nobody will ever observe because something outside reaped the child first.
    /// The second shape carries no termination, so none is invented — the stream just finishes.
    /// Either half can arrive first, so this is called from both and reconciles what it finds.
    private func finishIfChildAndMasterEnded() {
        guard masterReachedEnd, !streamWasFinished else { return }
        if let termination {
            streamWasFinished = true
            eventContinuation.yield(.ended(termination))
            eventContinuation.finish()
        } else if childStatusUnavailable {
            streamWasFinished = true
            eventContinuation.finish()
        }
    }
}

private enum ChildWaitStatus: Sendable {
    case stopped(signal: Int32)
    case ended(PTYTermination)

    init(_ status: Int32) {
        let waitKind = status & 0x7f
        if waitKind == 0x7f {
            self = .stopped(signal: (status >> 8) & 0xff)
        } else if waitKind == 0 {
            self = .ended(.exited(code: (status >> 8) & 0xff))
        } else {
            self = .ended(.signalled(signal: waitKind))
        }
    }

    var isTerminal: Bool {
        if case .ended = self { return true }
        return false
    }
}
