import Foundation
import AfleetCore

/// One actor per config home. It watches `sessions/`, `jobs/` and `daemon/` with a vnode source, re-reads
/// everything every five seconds because an in-place edit of a registry record (a TUI changing its status) fires
/// no directory event, and runs `claude agents --json` only on the sixty-second reconciliation, because each run
/// boots the CLI (ruling of 2026-09-05).
public actor FleetObserver {
    private let configHome: ConfigHome
    private let reader: any HolderReader
    private let clock: any Clock<Duration>
    private let ownPIDs: @Sendable () async -> Set<Int32>
    private let pollInterval: Duration
    private let reconcileInterval: Duration

    private var last: HolderSnapshot
    private var timers: [Task<Void, Never>] = []
    private var sources: [any DispatchSourceFileSystemObject] = []
    /// The tail of the refresh chain. A refresh awaits two things, so the actor lets the next one in; chaining
    /// keeps the reads in the order they were asked for and keeps `last` from going backwards.
    private var refreshing: Task<Void, Never>?
    private var published = false
    private let continuation: AsyncStream<HolderSet>.Continuation

    /// Every `HolderSet` that differed from the one before it, the first read included.
    public nonisolated let updates: AsyncStream<HolderSet>

    public init(configHome: ConfigHome, reader: any HolderReader, clock: any Clock<Duration>,
                ownPIDs: @escaping @Sendable () async -> Set<Int32>,
                pollInterval: Duration = .seconds(5), reconcileInterval: Duration = .seconds(60)) {
        self.configHome = configHome; self.reader = reader; self.clock = clock; self.ownPIDs = ownPIDs
        self.pollInterval = pollInterval; self.reconcileInterval = reconcileInterval
        self.last = HolderSnapshot(holders: HolderSet(holders: [], observedAt: .distantPast), jobs: [:], skipped: 0)
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Reading

    /// The holders of the most recent read, published or not: an unchanged read updates this and publishes nothing.
    public func snapshot() -> HolderSet { last.holders }

    /// The last read in full: the jobs and the skip count as well as the holders.
    public func detailedSnapshot() -> HolderSnapshot { last }

    public func holders(for session: SessionID) -> [Holder] {
        last.holders.holders.filter { $0.sessionID == session }
    }

    /// A read that includes `claude agents --json`, awaited to completion. The ownership checks call this.
    @discardableResult
    public func reconcileNow(label: String = OwnershipLabel.poll) async -> HolderSet {
        await refresh(agentsJSON: true, label: label)
        return last.holders
    }

    // MARK: - Lifetime

    public func start() async {
        guard timers.isEmpty, sources.isEmpty else { return }   // idempotent: a second start must not double up
        await refresh(agentsJSON: false, label: OwnershipLabel.poll)
        arm(["sessions", "jobs", "daemon"])
        timers = [
            Task { [weak self, clock, pollInterval] in
                while !Task.isCancelled {
                    guard (try? await clock.sleep(for: pollInterval)) != nil else { return }
                    guard let self else { return }   // the observer went away without stop(); stop sleeping
                    await self.refresh(agentsJSON: false, label: OwnershipLabel.poll)
                }
            },
            Task { [weak self, clock, reconcileInterval] in
                while !Task.isCancelled {
                    guard (try? await clock.sleep(for: reconcileInterval)) != nil else { return }
                    guard let self else { return }
                    await self.refresh(agentsJSON: true, label: OwnershipLabel.poll)
                }
            },
        ]
    }

    public func stop() {
        for timer in timers { timer.cancel() }
        timers = []
        for source in sources { source.cancel() }   // the cancel handler closes the descriptor
        sources = []
        continuation.finish()
    }

    // MARK: - Internals

    private func refresh(agentsJSON: Bool, label: String) async {
        let previous = refreshing
        let task = Task { [weak self] in
            await previous?.value
            await self?.perform(agentsJSON: agentsJSON, label: label)
        }
        refreshing = task
        await task.value
    }

    private func perform(agentsJSON: Bool, label: String) async {
        let pids = await ownPIDs()
        let snapshot = await reader.read(configHome: configHome, ownPIDs: pids, includeAgentsJSON: agentsJSON,
                                         label: label)
        // `observedAt` stamps every read, so compare the holders themselves: an unchanged fleet publishes nothing.
        let changed = !published || snapshot.holders.holders != last.holders.holders
        last = snapshot
        published = true
        if changed { continuation.yield(snapshot.holders) }
    }

    /// A vnode source per watched directory. A directory event says only "something under here moved", so the
    /// handler re-reads everything, exactly as the poll does.
    private func arm(_ names: [String]) {
        for name in names {
            let path = configHome.root.appending(path: name).path(percentEncoded: false)
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .global())
            source.setEventHandler { [weak self] in
                Task { await self?.refresh(agentsJSON: false, label: OwnershipLabel.poll) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }
}
