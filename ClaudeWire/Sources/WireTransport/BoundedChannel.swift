import Foundation

/// A lossless bounded FIFO: push suspends when full, pop suspends when empty.
/// finish() lets consumers drain what is buffered, then ends iteration; pushes after finish are dropped,
/// which is why `push` reports whether the element was accepted.
///
/// **Cancellation, precisely.** Neither operation can *lose* a cancellation: a waiter is registered
/// synchronously between actor entry and suspension, with no intervening suspension point, so the
/// cancellation handler always finds it. What the type does not promise is an atomic hand-off. The
/// handler is not actor-isolated, so it must hop back through a `Task`, and inside that window a
/// concurrent `push` can still hand its element to a waiter whose task is already cancelled. That
/// consumer's `pop()` then returns the element normally rather than nil, and the element is not lost.
/// A caller that needs "cancelled means definitely no value" must not rely on `pop()` alone.
public actor BoundedChannel<Element: Sendable> {
    public let capacity: Int
    private var buffer: [Element] = []
    private var head = 0
    private var nextWaiterID: UInt64 = 0
    private var pushWaiters: [(id: UInt64, c: CheckedContinuation<Void, Never>)] = []
    private var popWaiters: [(id: UInt64, c: CheckedContinuation<Element?, Never>)] = []
    private var finished = false

    public init(capacity: Int) { self.capacity = max(1, capacity) }
    public var count: Int { buffer.count - head }
    public var isFinished: Bool { finished }

    /// Returns whether the element was accepted. `false` means it was dropped, which happens in exactly
    /// two ways: the channel was already finished, or this push's own task was cancelled while it waited
    /// for room. A producer that must know its element survived — a termination handler publishing the
    /// exit status, say — reads the result rather than trusting ordering discipline elsewhere.
    @discardableResult
    public func push(_ element: Element) async -> Bool {
        while !finished && count >= capacity && popWaiters.isEmpty {
            let id = nextWaiterID; nextWaiterID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in pushWaiters.append((id, c)) }
            } onCancel: {
                Task { await self.cancelPushWaiter(id) }
            }
            if Task.isCancelled {
                // A cancelled push never appends. It may, however, have just consumed the wakeup a pop()
                // handed it, so it passes that wakeup on rather than letting the freed slot sit idle until
                // the next pop: with several producers on one channel another would otherwise stay parked.
                wakeOneProducerIfRoom()
                return false
            }
        }
        if finished { return false }
        if let w = popWaiters.first { popWaiters.removeFirst(); w.c.resume(returning: element); return true }
        buffer.append(element)
        return true
    }
    public func pop() async -> Element? {
        if count > 0 {
            let e = buffer[head]; head += 1
            if head > 1024 { buffer.removeFirst(head); head = 0 }
            wakeOneProducerIfRoom()
            return e
        }
        if finished { return nil }
        let id = nextWaiterID; nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in popWaiters.append((id, c)) }
        } onCancel: {
            Task { await self.cancelPopWaiter(id) }
        }
    }
    /// Publishes a final element and ends the stream, in one step that never suspends: **nothing interleaves
    /// between the terminal element being enqueued and the stream ending**, and no consumer can delay either.
    ///
    /// The terminal element is the one element that must never be dropped or delayed, so it is exempt from
    /// capacity. Routed through the ordinary `push` it inherits that method's back-pressure, and a full channel
    /// whose consumer has stopped reading parks the terminating producer forever — no terminal element, no
    /// `finish()`, and a stream that never ends. Back-pressure exists to stall the producer at the far end of
    /// the pipe; applying it to that producer's own death inverts it. So this appends past `capacity` by
    /// exactly one, and returns `false` in exactly one case: the channel was already finished.
    ///
    /// The `push`/`finish()` pair spelled out by a caller has neither property. Between the two there is a
    /// suspension point, and an element another producer pushes inside that window is delivered *after* the
    /// terminal one. Nor does a caller guarding itself with "don't push once the terminal event is out" — its
    /// check and its push are themselves two steps, so it still races.
    @discardableResult
    public func pushFinal(_ element: Element) -> Bool {
        guard !finished else { return false }
        if let w = popWaiters.first { popWaiters.removeFirst(); w.c.resume(returning: element) }
        else { buffer.append(element) }
        finish()
        return true
    }
    public func finish() {
        finished = true
        for w in pushWaiters { w.c.resume() }; pushWaiters.removeAll()
        for w in popWaiters { w.c.resume(returning: nil) }; popWaiters.removeAll()
    }
    /// Hands one waiting producer the slot that just opened, if a slot is in fact open.
    private func wakeOneProducerIfRoom() {
        guard !finished, count < capacity, !pushWaiters.isEmpty else { return }
        let w = pushWaiters.removeFirst(); w.c.resume()
    }
    private func cancelPushWaiter(_ id: UInt64) {
        if let i = pushWaiters.firstIndex(where: { $0.id == id }) { let w = pushWaiters.remove(at: i); w.c.resume() }
    }
    private func cancelPopWaiter(_ id: UInt64) {
        if let i = popWaiters.firstIndex(where: { $0.id == id }) { let w = popWaiters.remove(at: i); w.c.resume(returning: nil) }
    }
}

/// Read-only AsyncSequence view over a BoundedChannel; the channel itself is not reachable from outside the module,
/// so a consumer can neither inject events nor finish the stream. The transport's `events` is one of these (spec X3, v3).
public struct WireEventStream<Element: Sendable>: AsyncSequence, Sendable {
    let channel: BoundedChannel<Element>
    init(channel: BoundedChannel<Element>) { self.channel = channel }
    public struct Iterator: AsyncIteratorProtocol {
        let channel: BoundedChannel<Element>
        public mutating func next() async -> Element? { await channel.pop() }
    }
    public func makeAsyncIterator() -> Iterator { Iterator(channel: channel) }
}
