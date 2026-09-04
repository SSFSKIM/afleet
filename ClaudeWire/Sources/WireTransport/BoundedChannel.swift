import Foundation

/// A lossless bounded FIFO: push suspends when full, pop suspends when empty, both cancellation-aware.
/// finish() lets consumers drain what is buffered, then ends iteration; pushes after finish are dropped.
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

    public func push(_ element: Element) async {
        while !finished && count >= capacity && popWaiters.isEmpty {
            let id = nextWaiterID; nextWaiterID += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in pushWaiters.append((id, c)) }
            } onCancel: {
                Task { await self.cancelPushWaiter(id) }
            }
            if Task.isCancelled { return }                    // a cancelled push never appends
        }
        if finished { return }
        if let w = popWaiters.first { popWaiters.removeFirst(); w.c.resume(returning: element); return }
        buffer.append(element)
    }
    public func pop() async -> Element? {
        if count > 0 {
            let e = buffer[head]; head += 1
            if head > 1024 { buffer.removeFirst(head); head = 0 }
            if let w = pushWaiters.first { pushWaiters.removeFirst(); w.c.resume() }
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
    public func finish() {
        finished = true
        for w in pushWaiters { w.c.resume() }; pushWaiters.removeAll()
        for w in popWaiters { w.c.resume(returning: nil) }; popWaiters.removeAll()
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
