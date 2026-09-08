import CDarwinWaitStatus
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

/// The signalling right for one spawned process group, shared with the waiter so reaping and
/// signalling have one synchronization point even though they run on different executors.
private final class PTYChildProcessGroup: Sendable {
    private enum State {
        case signalable
        case consumingStatus
        case terminal
    }

    let processIdentifier: pid_t
    private let state = Mutex(State.signalable)

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func beginNonterminalStatusConsumption() {
        state.withLock { state in
            if case .signalable = state {
                state = .consumingStatus
            }
        }
    }

    func finishStatusConsumption(isTerminal: Bool) {
        state.withLock { state in
            if isTerminal {
                state = .terminal
            } else if case .consumingStatus = state {
                state = .signalable
            }
        }
    }

    func markTerminal() {
        state.withLock { $0 = .terminal }
    }

    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        state.withLock { state in
            guard case .signalable = state else { return false }
            // DarwinPTY makes the child a session leader with pgid == sid == pid. Before the
            // waiter reaps it, that pid cannot be recycled and therefore neither can its group.
            // The waiter changes this state to `.terminal` before an observed terminal reap,
            // or to `.consumingStatus` across a reap whose preview was nonterminal. Both states
            // suppress this syscall, so no path can signal after ownership of the pid ends.
            return Darwin.kill(-processIdentifier, signal) == 0
        }
    }
}

func terminalEnvironment(
    overlaying requestEnvironment: [String: String],
    for terminal: TerminalDescription
) -> [String: String] {
    var environment = requestEnvironment
    environment["TERM"] = terminal.term
    if let directory = terminal.terminfoDirectory {
        let directoryPath = directory.path
        if let requestedSearchPath = requestEnvironment["TERMINFO_DIRS"] {
            environment["TERMINFO_DIRS"] = "\(directoryPath):\(requestedSearchPath)"
        } else {
            environment["TERMINFO_DIRS"] = directoryPath
        }
    }
    return environment
}

/// A bounded producer between the pty's serial read queue and the event stream.
///
/// Mutable state and the dispatch-source suspend count are confined to `queue`. Methods entered
/// from another executor enqueue there or use `withQueueConfinedState`; that helper runs inline
/// when a read-handler-held owner deinitializes on `queue`, rather than synchronously redispatching
/// onto the queue itself. The class is `@unchecked Sendable` solely because Dispatch does not
/// express this confinement to Swift's checker.
private final class PTYEventDelivery: @unchecked Sendable {
    private enum PendingItem {
        case output(Data)
        case control(PTYEvent)
    }

    private struct InFlight {
        let event: PTYEvent
        let outputByteCount: Int
    }

    private let queue: DispatchQueue
    private let queueIdentity = DispatchSpecificKey<UInt8>()
    private let continuation: AsyncStream<PTYEvent>.Continuation
    private let privateOutputByteLimit: Int
    private let deliveryByteLimit: Int
    private let coalescingDelay: DispatchTimeInterval
    private var pending: [PendingItem] = []
    private var bufferedOutputByteCount = 0
    private var inFlight: InFlight?
    private var deliverySubmissionIsOutstanding = false
    private var deliveryIsScheduled = false
    private var retryDelayMilliseconds = 1
    private var finishWasRequested = false
    private var terminalDrainLifetimeAnchor: PTYEventDelivery?
    private var isFinished = false
    private var readSource: DispatchSourceRead?
    private var readSourceIsSuspended = false
    private var readingHasEnded = false

    init(
        queue: DispatchQueue,
        continuation: AsyncStream<PTYEvent>.Continuation,
        privateOutputByteLimit: Int,
        deliveryByteLimit: Int,
        coalescingDelay: DispatchTimeInterval
    ) {
        precondition(privateOutputByteLimit > 0)
        precondition(deliveryByteLimit > 0)
        self.queue = queue
        self.continuation = continuation
        self.privateOutputByteLimit = privateOutputByteLimit
        self.deliveryByteLimit = deliveryByteLimit
        self.coalescingDelay = coalescingDelay
        queue.setSpecific(key: queueIdentity, value: 1)
    }

    func start(readSource: DispatchSourceRead) {
        withQueueConfinedState {
            precondition(self.readSource == nil)
            self.readSource = readSource
            readSource.resume()
        }
    }

    /// Called only by the read source's handler, already on `queue`.
    func readOnce(from descriptor: Int32, onEnd: @escaping @Sendable () -> Void) {
        guard !readingHasEnded, !isFinished else { return }
        let available = privateOutputByteLimit - bufferedOutputByteCount
        guard available > 0 else {
            suspendReadSourceIfNeeded()
            return
        }

        var bytes = [UInt8](repeating: 0, count: min(deliveryByteLimit, available))
        var failure: Int32 = 0
        let count: Int = bytes.withUnsafeMutableBytes { buffer in
            while true {
                let result = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                if result == -1, errno == EINTR { continue }
                if result == -1 { failure = errno }
                return result
            }
        }
        if count > 0 {
            pending.append(.output(Data(bytes.prefix(count))))
            bufferedOutputByteCount += count
            if bufferedOutputByteCount == privateOutputByteLimit {
                suspendReadSourceIfNeeded()
            }
            scheduleDelivery(coalescing: true)
        } else if count == 0 || (failure != EAGAIN && failure != EWOULDBLOCK) {
            readingHasEnded = true
            onEnd()
        }
    }

    func enqueue(_ event: PTYEvent) {
        queue.async { [weak self] in
            guard let self, !isFinished else { return }
            pending.append(.control(event))
            scheduleDelivery(coalescing: false)
        }
    }

    func finishWhenDrained() {
        // Teardown must not wait for a full stream slot, but its queued output and `.ended` must
        // outlive the actor. The submitted closure closes the owner-release window, then this
        // anchor lasts until a later consumer drains the stream or cancels it.
        queue.async { [self] in
            guard !isFinished else { return }
            terminalDrainLifetimeAnchor = self
            finishWasRequested = true
            finishIfDrained()
        }
    }

    /// Balances a suspended dispatch source before cancellation. This may be entered from the
    /// actor executor or reentrantly from `queue` while its read handler releases the last owner.
    func stopReading() {
        withQueueConfinedState { stopReadingOnQueue() }
    }

    func abort() {
        withQueueConfinedState {
            isFinished = true
            stopReadingOnQueue()
            pending.removeAll()
            inFlight = nil
            deliverySubmissionIsOutstanding = false
            bufferedOutputByteCount = 0
            terminalDrainLifetimeAnchor = nil
            continuation.finish()
        }
    }

    private func withQueueConfinedState(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueIdentity) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func scheduleDelivery(coalescing: Bool) {
        guard !deliveryIsScheduled, !deliverySubmissionIsOutstanding, !isFinished else { return }
        guard inFlight != nil || !pending.isEmpty else {
            finishIfDrained()
            return
        }
        deliveryIsScheduled = true
        let delay: DispatchTimeInterval
        if inFlight != nil {
            delay = .milliseconds(retryDelayMilliseconds)
        } else if coalescing, firstPendingItemIsOutput, bufferedOutputByteCount < deliveryByteLimit {
            delay = coalescingDelay
        } else {
            delay = .nanoseconds(0)
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginDelivery()
        }
    }

    private var firstPendingItemIsOutput: Bool {
        guard let first = pending.first else { return false }
        if case .output = first { return true }
        return false
    }

    private func beginDelivery() {
        deliveryIsScheduled = false
        guard !deliverySubmissionIsOutstanding, !isFinished else { return }
        if inFlight == nil {
            inFlight = takeNextDelivery()
        }
        guard let delivery = inFlight else {
            finishIfDrained()
            return
        }

        deliverySubmissionIsOutstanding = true
        let continuation = continuation
        Task { @MainActor [weak self] in
            let result = continuation.yield(delivery.event)
            self?.queue.async { [weak self] in
                self?.deliveryCompleted(result)
            }
        }
    }

    private func takeNextDelivery() -> InFlight? {
        guard !pending.isEmpty else { return nil }
        switch pending[0] {
        case let .control(event):
            pending.removeFirst()
            return InFlight(event: event, outputByteCount: 0)
        case .output:
            var output = Data()
            output.reserveCapacity(deliveryByteLimit)
            while output.count < deliveryByteLimit, !pending.isEmpty {
                guard case let .output(bytes) = pending[0] else { break }
                let available = deliveryByteLimit - output.count
                if bytes.count <= available {
                    output.append(bytes)
                    pending.removeFirst()
                } else {
                    output.append(bytes.prefix(available))
                    pending[0] = .output(Data(bytes.dropFirst(available)))
                }
            }
            return InFlight(event: .output(output), outputByteCount: output.count)
        }
    }

    private func deliveryCompleted(
        _ result: AsyncStream<PTYEvent>.Continuation.YieldResult
    ) {
        guard deliverySubmissionIsOutstanding else { return }
        deliverySubmissionIsOutstanding = false
        guard !isFinished, let delivery = inFlight else { return }
        switch result {
        case .enqueued:
            bufferedOutputByteCount -= delivery.outputByteCount
            inFlight = nil
            retryDelayMilliseconds = 1
            resumeReadSourceIfNeeded()
            if pending.isEmpty {
                finishIfDrained()
            } else {
                scheduleDelivery(coalescing: firstPendingItemIsOutput)
            }
        case .dropped:
            // `.bufferingOldest` rejects the offered event. Keep this exact in-flight value and
            // stop reading once the private byte bound fills; retrying after the consumer advances
            // preserves every byte while the kernel's pty queue applies the durable backpressure.
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 50)
            scheduleDelivery(coalescing: false)
        case .terminated:
            consumerTerminated()
        @unknown default:
            consumerTerminated()
        }
    }

    private func consumerTerminated() {
        // Iterator cancellation terminates only the event stream. The actor still owns a live pty,
        // so leave its descriptor open and stop pulling bytes until explicit teardown balances and
        // cancels the source. Closing here would give the child an unrequested hangup while
        // `PTYProcess.masterIsOpen` still says writes and resizes are valid.
        isFinished = true
        suspendReadSourceIfNeeded()
        pending.removeAll()
        inFlight = nil
        bufferedOutputByteCount = 0
        terminalDrainLifetimeAnchor = nil
    }

    private func finishIfDrained() {
        guard finishWasRequested, inFlight == nil, pending.isEmpty, !isFinished else { return }
        isFinished = true
        continuation.finish()
        terminalDrainLifetimeAnchor = nil
    }

    private func suspendReadSourceIfNeeded() {
        guard !readSourceIsSuspended, let readSource, !readingHasEnded else { return }
        readSource.suspend()
        readSourceIsSuspended = true
    }

    private func resumeReadSourceIfNeeded() {
        guard readSourceIsSuspended, bufferedOutputByteCount < privateOutputByteLimit,
              let readSource, !readingHasEnded else { return }
        readSourceIsSuspended = false
        readSource.resume()
    }

    private func stopReadingOnQueue() {
        guard let readSource else { return }
        readingHasEnded = true
        if readSourceIsSuspended {
            readSourceIsSuspended = false
            readSource.resume()
        }
        readSource.cancel()
        self.readSource = nil
    }
}

public actor PTYProcess {
    /// At most 64 KiB is handed to the main actor in one turn: large enough to amortize pty read
    /// and actor-hop overhead, but small enough to bound one renderer parse/invalidation pass.
    static let outputDeliveryByteLimit = 64 * 1024

    /// One MiB bounds output retained between the private queue and the stream. It absorbs sixteen
    /// capped deliveries during ordinary scheduler jitter without turning a stalled renderer into
    /// process-wide memory growth; once full, the pty's kernel queue blocks the child naturally.
    static let outputBufferByteLimit = 1 * 1024 * 1024

    private static let eventSlotLimit = 1
    private static let privateOutputByteLimit = outputBufferByteLimit - outputDeliveryByteLimit

    // A one-millisecond collection window combines the pty's character-sized Darwin reads without
    // adding perceptible terminal latency. A full delivery bypasses the window immediately.
    private static let outputCoalescingDelay = DispatchTimeInterval.milliseconds(1)

    private static let eventBufferingPolicy: AsyncStream<PTYEvent>.Continuation.BufferingPolicy =
        .bufferingOldest(eventSlotLimit)

    // A local pane child normally reports a signal within one scheduler turn. A quarter-second
    // gives SIGHUP handlers time to detach cleanly; SIGTERM gets twice that to run orderly cleanup,
    // while the full escalation still resolves quickly enough not to leave a pane visibly hung.
    private static let hangupGracePeriod = Duration.milliseconds(250)
    private static let terminateGracePeriod = Duration.milliseconds(500)

    public nonisolated let events: AsyncStream<PTYEvent>
    public nonisolated let processIdentifier: pid_t

    private let master: PTYMasterDescriptor
    private let writeQueue: DispatchQueue
    private let waitQueue: DispatchQueue
    private let eventDelivery: PTYEventDelivery
    private let stopPolicy: PTYStopPolicy
    private let processGroup: PTYChildProcessGroup
    private var masterIsOpen = true
    private var termination: PTYTermination?
    private var childIsTerminal = false
    private var childStatusUnavailable = false
    private var streamWasFinished = false
    private var waiterIsConsumingStatus = false
    private var statusConsumptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var terminationSequence: Task<Void, Never>?

    /// The gate that makes `write` a queue rather than a race. A caller that has to wait for the
    /// master to drain suspends, which lets a second `write` enter the actor; without the gate
    /// the two would interleave their `Darwin.write` calls and shuffle the bytes. Callers are
    /// admitted in the order they entered the actor, so the bytes reach the child in that order.
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
        var request = request
        request.environment = terminalEnvironment(
            overlaying: request.environment,
            for: request.terminal
        )
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

        let delivery = PTYEventDelivery(
            queue: queue,
            continuation: eventChannel.continuation,
            privateOutputByteLimit: Self.privateOutputByteLimit,
            deliveryByteLimit: Self.outputDeliveryByteLimit,
            coalescingDelay: Self.outputCoalescingDelay
        )

        events = eventChannel.stream
        eventDelivery = delivery
        processIdentifier = spawned.processIdentifier
        master = descriptor
        processGroup = PTYChildProcessGroup(processIdentifier: spawned.processIdentifier)
        // Writability waits get their own queue: a write source stays armed until the actor can
        // take it down, and on the read queue that window would delay the child's output.
        writeQueue = DispatchQueue(label: "app.afleet.terminal-core.pty-write")
        waitQueue = DispatchQueue(label: "app.afleet.terminal-core.pty-wait")
        stopPolicy = request.stopPolicy

        let readDescriptor = spawned.masterDescriptor
        source.setEventHandler { [weak self, weak delivery] in
            let owner = self
            delivery?.readOnce(from: readDescriptor) {
                Task { await owner?.readEnded() }
            }
        }
        source.setCancelHandler { descriptor.release() }
        delivery.start(readSource: source)

        let processIdentifier = spawned.processIdentifier
        let processGroup = processGroup
        // The statuses `waitpid` returns are ordered — a stop, then whatever ended the child —
        // and the actor has to see them in that order. `waitid(WNOWAIT)` first identifies a
        // terminal status without consuming it, allowing signalling to be disabled before the
        // following `waitpid` reaps the pid. A nonterminal status instead gates actor signalling
        // only while a nonblocking `waitpid` tries to consume it: SIGCONT can discard an unread
        // stop, in which case both gates reopen before `waitid` retries. Synchronous actor
        // delivery prevents a later status from overtaking one that was consumed.
        waitQueue.async { [weak self, processGroup] in
            while true {
                var information = siginfo_t()
                let observed = Darwin.waitid(
                    P_PID,
                    id_t(processIdentifier),
                    &information,
                    WEXITED | WSTOPPED | WNOWAIT
                )
                if observed == -1, errno == EINTR {
                    continue
                }
                guard observed == 0 else {
                    processGroup.markTerminal()
                    let owner = self
                    Self.deliver { await owner?.waiterFinishedWithoutStatus() }
                    return
                }

                let terminalPreview = Self.isTerminalChildStatus(information.si_code)
                let owner = self
                if terminalPreview {
                    processGroup.markTerminal()
                    Self.deliver { await owner?.childWillBeReaped() }
                } else {
                    Self.deliver { await owner?.waiterWillConsumeNonterminalStatus() }
                    processGroup.beginNonterminalStatusConsumption()
                }

                var status: Int32 = 0
                let result: pid_t
                let waitOptions = terminalPreview ? WUNTRACED : WUNTRACED | WNOHANG
                while true {
                    let waited = Darwin.waitpid(processIdentifier, &status, waitOptions)
                    if waited == -1, errno == EINTR { continue }
                    result = waited
                    break
                }
                if result == 0 {
                    // The nonterminal preview was discarded before it could be consumed. Reopen
                    // the process-group gate first so a termination task resumed by the actor gate
                    // can signal, then look again rather than declaring the child's fate unknown.
                    processGroup.finishStatusConsumption(isTerminal: false)
                    if let owner {
                        Self.deliver { await owner.finishStatusConsumption() }
                    } else {
                        // Deinitialization may have tried to terminate while this gate was closed.
                        // Complete that best-effort teardown now that signalling is safe again.
                        Self.bestEffortTerminate(processGroup)
                    }
                    continue
                }
                let waitStatus = result == processIdentifier ? ChildWaitStatus(status) : nil
                if !terminalPreview {
                    processGroup.finishStatusConsumption(
                        isTerminal: waitStatus?.isTerminal ?? true
                    )
                }

                if let owner {
                    if let waitStatus {
                        Self.deliver { await owner.received(waitStatus) }
                    } else {
                        Self.deliver { await owner.waiterFinishedWithoutStatus() }
                    }
                } else if let waitStatus, !waitStatus.isTerminal {
                    // The owner disappeared while a stop was pending. Its deinitializer could
                    // not await this consumption gate, so finish the best-effort teardown here.
                    Self.bestEffortTerminate(processGroup)
                }

                guard let waitStatus, !waitStatus.isTerminal else { return }
            }
        }
    }

    /// Runs one actor hop from the waiter queue and waits for it to complete, which is what
    /// keeps successive statuses in the order `waitpid` produced them. Safe to block on: the
    /// caller is the dedicated waiter queue, never a cooperative executor, and the body reaches
    /// the actor through a reference that is already `nil` once the owner has gone away.
    static func deliver(_ body: @escaping @Sendable () async -> Void) {
        let delivered = DispatchSemaphore(value: 0)
        Task {
            await body()
            delivered.signal()
        }
        delivered.wait()
    }

    private static func isTerminalChildStatus(_ code: Int32) -> Bool {
        switch code {
        case CLD_EXITED, CLD_KILLED, CLD_DUMPED:
            true
        case CLD_TRAPPED, CLD_STOPPED, CLD_CONTINUED:
            false
        default:
            false
        }
    }

    private static func bestEffortTerminate(_ processGroup: PTYChildProcessGroup) {
        processGroup.signal(SIGCONT)
        processGroup.signal(SIGHUP)
        processGroup.signal(SIGTERM)
        processGroup.signal(SIGKILL)
    }

    /// A best-effort safety net only: the owner is expected to call ``teardown()`` and await the
    /// resulting `.ended`. A deinitializer cannot wait through grace periods or wait for `waitpid`,
    /// so abandoning this actor with a live child is a programming error this type mitigates but
    /// cannot repair contractually.
    deinit {
        // A reconciled stream owns its bounded terminal drain independently; aborting it here
        // would discard output or `.ended` that a separately retained stream has not read yet.
        if !streamWasFinished {
            eventDelivery.abort()
        }
        guard termination == nil, !childIsTerminal, !childStatusUnavailable else { return }
        Self.bestEffortTerminate(processGroup)
    }

    /// Closes the pty and terminates the process group, returning only after the waiter has
    /// observed the child's terminal status and made the single `.ended` durable for `events`.
    /// A retained stream may drain its bounded output and that event after teardown returns.
    ///
    /// Teardown first continues a stopped child and sends SIGHUP, then escalates through SIGTERM
    /// and SIGKILL after bounded grace periods. Call this before releasing the last owner.
    public func teardown() async {
        readEnded()
        let sequence = startTerminationSequence()
        await sequence.value
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

    private func startTerminationSequence() -> Task<Void, Never> {
        if let terminationSequence { return terminationSequence }
        let sequence = Task { await runTerminationSequence() }
        terminationSequence = sequence
        return sequence
    }

    private func runTerminationSequence() async {
        guard !childFateIsSettled else { return }

        // A stopped process cannot act on SIGHUP until it is continued. Sending SIGCONT to a
        // running group is harmless and gives explicit teardown the same first step as detach.
        _ = await signalProcessGroup(SIGCONT)
        guard await signalProcessGroup(SIGHUP) else {
            await waitForTermination()
            return
        }
        if await waitForTermination(for: Self.hangupGracePeriod) { return }

        guard await signalProcessGroup(SIGTERM) else {
            await waitForTermination()
            return
        }
        if await waitForTermination(for: Self.terminateGracePeriod) { return }

        guard await signalProcessGroup(SIGKILL) else {
            await waitForTermination()
            return
        }
        // SIGKILL has no handler to wait for. Keep the actor and waiter alive until the kernel's
        // terminal status has become the promised `.ended`, rather than returning on signal send.
        await waitForTermination()
    }

    private func signalProcessGroup(_ signal: Int32) async -> Bool {
        await waitForStatusConsumption()
        guard !childFateIsSettled, !childIsTerminal else { return false }
        return processGroup.signal(signal)
    }

    private func waitForStatusConsumption() async {
        while waiterIsConsumingStatus {
            await withCheckedContinuation { statusConsumptionWaiters.append($0) }
        }
    }

    private func waiterWillConsumeNonterminalStatus() {
        waiterIsConsumingStatus = true
    }

    private func childWillBeReaped() {
        childIsTerminal = true
    }

    private func finishStatusConsumption() {
        guard waiterIsConsumingStatus else { return }
        waiterIsConsumingStatus = false
        let waiters = statusConsumptionWaiters
        statusConsumptionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private var childFateIsSettled: Bool {
        termination != nil || childStatusUnavailable
    }

    private func waitForTermination(for gracePeriod: Duration) async -> Bool {
        guard !childFateIsSettled else { return true }
        let identifier = UUID()
        return await withCheckedContinuation { continuation in
            terminationWaiters[identifier] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: gracePeriod)
                await self?.expireTerminationWait(identifier)
            }
        }
    }

    private func waitForTermination() async {
        guard !childFateIsSettled else { return }
        let identifier = UUID()
        _ = await withCheckedContinuation { continuation in
            terminationWaiters[identifier] = continuation
        }
    }

    private func expireTerminationWait(_ identifier: UUID) {
        terminationWaiters.removeValue(forKey: identifier)?.resume(returning: false)
    }

    private func resumeTerminationWaiters() {
        let waiters = terminationWaiters.values
        terminationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
    }

    private func received(_ status: ChildWaitStatus) {
        finishStatusConsumption()
        switch status {
        case let .stopped(signal):
            eventDelivery.enqueue(.stopped(signal: signal))
            if stopPolicy == .detach {
                // No useful output follows a detached stop. Closing now both performs the terminal
                // hangup and makes `.ended` independent of a surviving slave descriptor.
                readEnded()
                _ = startTerminationSequence()
            }
        case let .ended(childTermination):
            childIsTerminal = true
            termination = childTermination
            finishIfChildAndMasterEnded()
            resumeTerminationWaiters()
        }
    }

    /// The waiter gave up without ever seeing a terminal status, which is what happens when
    /// something outside this actor reaps the child first. No status was observed, so no
    /// termination is invented; the stream is only allowed to finish. Not `private`: the arrival
    /// order that has to be remembered — this before the master's end of file — is a race in
    /// production and is driven directly from the tests.
    func waiterFinishedWithoutStatus() {
        finishStatusConsumption()
        childIsTerminal = true
        childStatusUnavailable = true
        finishIfChildAndMasterEnded()
        resumeTerminationWaiters()
    }

    /// Not `private` for the same reason as `waiterFinishedWithoutStatus`.
    func readEnded() {
        guard masterIsOpen else { return }
        masterIsOpen = false
        for identifier in Array(writabilityWaits.keys) {
            finishWritabilityWait(identifier, with: .failure(PTYError.closed))
        }
        eventDelivery.stopReading()
        finishIfChildAndMasterEnded()
    }

    /// The stream ends once the master has reached end of file and the child's fate is settled.
    /// "Settled" has two shapes: a status the waiter observed, which becomes the `ended` event,
    /// and a status nobody will ever observe because something outside reaped the child first.
    /// The second shape carries no termination, so none is invented — the stream just finishes.
    /// Either half can arrive first, so this is called from both and reconciles what it finds.
    private func finishIfChildAndMasterEnded() {
        guard !masterIsOpen, !streamWasFinished else { return }
        if let termination {
            streamWasFinished = true
            eventDelivery.enqueue(.ended(termination))
            eventDelivery.finishWhenDrained()
        } else if childStatusUnavailable {
            streamWasFinished = true
            eventDelivery.finishWhenDrained()
        }
    }
}

private enum ChildWaitStatus: Sendable {
    case stopped(signal: Int32)
    case ended(PTYTermination)

    init?(_ status: Int32) {
        if afleet_wait_status_stopped(status) {
            self = .stopped(signal: Int32(afleet_wait_stop_signal(status)))
        } else if afleet_wait_status_exited(status) {
            self = .ended(.exited(code: Int32(afleet_wait_exit_status(status))))
        } else if afleet_wait_status_signalled(status) {
            self = .ended(.signalled(signal: Int32(afleet_wait_term_signal(status))))
        } else {
            // `waitpid` is not currently asked for WCONTINUED, but treating an unrecognized status
            // as no event keeps a future option change from misreporting it as a termination.
            return nil
        }
    }

    var isTerminal: Bool {
        if case .ended = self { return true }
        return false
    }
}
