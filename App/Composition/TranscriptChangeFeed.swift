import Foundation
import FleetKit

/// One `TranscriptWatching.changes` fanned out to every consumer that needs it.
///
/// `TranscriptWatcher.changes` is a **single** `AsyncStream<[URL]>`, and a second `for await` on
/// one `AsyncStream` does not duplicate its elements — it splits them between the two loops,
/// non-deterministically. Spec §2 step 10 has two consumers: `index.update(changed:)`, which the
/// composition root drives, and `StreamIngestion.fileChanged(_:)` for the open channel, which is
/// Task 7's. Consuming the watcher's stream directly from the composition root would therefore
/// have taken the only subscription there is and left the second consumer with no way in that did
/// not rewrite `LaunchSequence`.
///
/// So the composition root subscribes to this instead, and so does everybody else.
/// **Task 7 calls `Workspace.changes.subscribe()`** and pumps what it yields into
/// `StreamIngestion.fileChanged(_:)`; it needs no change here and none in `LaunchSequence`.
///
/// A subscriber sees every batch from its own subscription onward and none from before it, which
/// is the right shape for a live filesystem feed: a channel opened at 10:00 has no use for a
/// change from 09:59, and the index — which does — is subscribed before `run()` returns.
actor TranscriptChangeFeed {
    private var continuations: [UUID: AsyncStream<[URL]>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var finished = false

    /// Starts pumping `source` immediately. `source` is consumed exactly once, here.
    init(source: AsyncStream<[URL]>) {
        Task { await self.start(source) }
    }

    private func start(_ source: AsyncStream<[URL]>) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            for await batch in source {
                await self?.deliver(batch)
            }
            await self?.finish()
        }
    }

    /// A fresh stream carrying every batch from now on. Finishing the returned stream's iteration
    /// is enough; the subscription is dropped when its continuation is terminated.
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
