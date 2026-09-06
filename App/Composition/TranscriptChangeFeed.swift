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
/// **Task 7 calls `Workspace.changes?.subscribe()`** and pumps each batch's `paths` into
/// `StreamIngestion.fileChanged(_:)`. A `subscribe()` taken after `start()` sees batches from its
/// own attachment onward and none from before it, which is the right shape for a live filesystem
/// feed: a channel opened at 10:00 has no use for a change from 09:59, and the index — which does
/// need the earlier ones — holds `changes` from construction.
/// One batch of changed transcript paths, stamped when the feed took it off the watcher's stream.
///
/// The stamp is the only way a consumer can tell "the filesystem has been quiet" from "the pump has
/// not run": an `AsyncStream` carries no time of its own, and the moment a batch first enters our
/// code is the earliest one anybody can measure from. `TranscriptChangePump` reads it and
/// `LaunchSequence` reports on it.
struct TranscriptChangeBatch: Sendable {
    let paths: [URL]
    let receivedAt: ContinuousClock.Instant
}

actor TranscriptChangeFeed {
    /// The primary subscription, created with the feed. The composition root pumps this into
    /// `index.update(changed:)`.
    nonisolated let changes: AsyncStream<TranscriptChangeBatch>

    private let source: AsyncStream<[URL]>
    private var continuations: [UUID: AsyncStream<TranscriptChangeBatch>.Continuation]
    private var pump: Task<Void, Never>?
    private var finished = false

    /// Registers the primary subscription and reads nothing. `start()` begins the pump.
    init(source: AsyncStream<[URL]>) {
        self.source = source
        let (stream, continuation) = AsyncStream<TranscriptChangeBatch>.makeStream(bufferingPolicy: .unbounded)
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
            for await paths in source {
                // Stamped here, the moment the batch leaves the watcher and enters our code.
                await self?.deliver(TranscriptChangeBatch(paths: paths, receivedAt: .now))
            }
            await self?.finish()
        }
    }

    /// A fresh stream carrying every batch from now on. Dropping the returned stream's iteration
    /// terminates its continuation and the subscription with it.
    func subscribe() -> AsyncStream<TranscriptChangeBatch> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TranscriptChangeBatch>.makeStream(bufferingPolicy: .unbounded)
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

    private func deliver(_ batch: TranscriptChangeBatch) {
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


/// The rule the composition root's change pump applies to each batch it takes off the feed.
///
/// A type of its own, and one static function, because the interesting part is a decision — is this
/// delivery late enough to be worth a line in the log — and a decision buried inside a detached
/// `for await` is a decision no test can reach.
enum TranscriptChangePump {
    /// How long a batch may sit between the feed receiving it and the pump handling it before the
    /// delay is worth reporting.
    ///
    /// Two seconds, chosen against three numbers that already exist rather than by feel.
    /// `TranscriptWatcher` coalesces FSEvents at 0.1 s, and an incremental `update(changed:)` is a
    /// head-and-tail read of the files named — tens of milliseconds on a warm home — so normal is
    /// two orders of magnitude below this and ordinary scheduling jitter does not come near it.
    /// The ceiling is G1d's five-second budget for the fleet to be listed and current: a report at
    /// two seconds lands while the app is still inside that budget, so the log says the sidebar is
    /// falling behind *before* the gate would call it stale rather than after.
    ///
    /// It is a reporting threshold and nothing else. Nothing waits on it, nothing fails on it, and
    /// a batch past it is delivered exactly as a batch inside it is.
    static let stallThreshold: Duration = .seconds(2)

    /// The notice this delivery deserves, or nil when it was timely.
    static func notice(for batch: TranscriptChangeBatch,
                       handledAt now: ContinuousClock.Instant = .now) -> AppNotice? {
        let waited = batch.receivedAt.duration(to: now)
        guard waited >= stallThreshold else { return nil }
        return .transcriptChangeStalled(paths: batch.paths.count, waitedMs: waited.milliseconds)
    }
}

extension Duration {
    /// Whole milliseconds, for a log line that carries counts and never a floating-point duration.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
