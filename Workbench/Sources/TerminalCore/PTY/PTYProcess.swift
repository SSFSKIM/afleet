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
    public nonisolated let events: AsyncStream<PTYEvent>
    public nonisolated let processIdentifier: pid_t

    private let master: PTYMasterDescriptor
    private let writeQueue: DispatchQueue
    private let eventContinuation: AsyncStream<PTYEvent>.Continuation
    private let readSource: DispatchSourceRead
    private var masterIsOpen = true

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
        let eventChannel = AsyncStream<PTYEvent>.makeStream()
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
    }

    deinit {
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

    private func readEnded() {
        guard masterIsOpen else { return }
        masterIsOpen = false
        for identifier in Array(writabilityWaits.keys) {
            finishWritabilityWait(identifier, with: .failure(PTYError.closed))
        }
        eventContinuation.finish()
        readSource.cancel()
    }
}
