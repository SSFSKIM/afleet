import Foundation
import FleetKit

/// One `TranscriptWatching.changes` fanned out to every consumer that needs it, dropping nothing
/// on the floor while those consumers are still arriving.
///
/// **Why a fan-out.** `TranscriptWatcher.changes` is a single `AsyncStream<[URL]>`, and a second
/// `for await` on one `AsyncStream` does not duplicate its elements — it splits them between the
/// two loops, non-deterministically. Spec §2 step 10 has two consumers: `index.update(changed:)`,
/// which the composition root pumps, and `StreamIngestion.fileChanged(_:)` for the open channel,
/// which is Task 7's.
///
/// **The contract, and it is the whole point of this type's shape.** Nothing is read out of
/// `source` until `start()` is called, and the feed's primary subscription — `changes` — is created
/// by `init`, before `start()` can possibly have run. So the primary consumer cannot miss a batch,
/// whatever else happens between construction and the pump starting: the source's own unbounded
/// buffer holds everything, and the first thing the pump does is deliver it to a continuation that
/// already exists. There is no ordering to get wrong, because the primary subscription is not taken
/// — it is handed out with the object.
///
/// The first draft of this type started pumping in `init` and delivered only to whatever
/// continuations existed at that instant. `LaunchSequence` subscribes several suspension points
/// later, across a main-actor hop and the index's `loadPersisted()`, so every batch that arrived in
/// that window was drained and discarded — silently, and the stream this replaced buffered and lost
/// nothing. That is the regression this shape exists to make unrepresentable.
///
/// **Task 7 calls `Workspace.changes?.subscribe()`** and pumps what it yields into
/// `StreamIngestion.fileChanged(_:)`. A `subscribe()` taken after `start()` sees batches from its
/// own attachment onward and none from before it, which is the right shape for a live filesystem
/// feed: a channel opened at 10:00 has no use for a change from 09:59, and the index — which does
/// need the earlier ones — holds `changes` from construction.
actor TranscriptChangeFeed {
    /// The primary subscription, created with the feed. The composition root pumps this into
    /// `index.update(changed:)`.
    nonisolated let changes: AsyncStream<[URL]>

    private let source: AsyncStream<[URL]>
    private var continuations: [UUID: AsyncStream<[URL]>.Continuation]
    private var pump: Task<Void, Never>?
    private var finished = false

    /// Registers the primary subscription and reads nothing. `start()` begins the pump.
    init(source: AsyncStream<[URL]>) {
        self.source = source
        let (stream, continuation) = AsyncStream<[URL]>.makeStream(bufferingPolicy: .unbounded)
        changes = stream
        continuations = [UUID(): continuation]
    }

    /// Begins consuming `source`. Called once, by the composition root, after the workspace is
    /// assembled. Idempotent.
    ///
    /// Deliberately not done in `init`: an actor's synchronous initialiser cannot escape `self`
    /// into a `Task` and go on touching isolated state, and more importantly a pump that starts at
    /// construction is a pump that can run before anybody is listening. Forgetting this call is a
    /// loud failure — no consumer ever sees anything — rather than the silent one it replaces.
    func start() {
        guard pump == nil, !finished else { return }
        pump = Task { [weak self, source] in
            for await batch in source {
                await self?.deliver(batch)
            }
            await self?.finish()
        }
    }

    /// A fresh stream carrying every batch from now on. Dropping the returned stream's iteration
    /// terminates its continuation and the subscription with it.
    func subscribe() -> AsyncStream<[URL]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[URL]>.makeStream(bufferingPolicy: .unbounded)
        if finished {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.drop(id) }
        }
        return stream
    }

    private func deliver(_ batch: [URL]) {
        for continuation in continuations.values { continuation.yield(batch) }
    }

    private func finish() {
        finished = true
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    private func drop(_ id: UUID) {
        continuations[id] = nil
    }

    /// Stops the pump and finishes every subscriber's stream.
    func stop() {
        pump?.cancel()
        pump = nil
        finish()
    }
}
