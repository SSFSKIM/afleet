import Foundation
import ClaudeWire
import FleetTimeline

/// A moment on the injected clock, kept as a probe rather than as an instant.
///
/// `any Clock<Duration>` cannot hand its `Instant` out — the associated type is erased at the existential — and this
/// package compares no instants of its own anyway: durations are slept, and recency is the cap counter's `UInt64`
/// stamp. What a task frame's arrival needs is neither, but an *age*, and the one clock a test can move is the
/// injected one. So the instant is captured inside a generic function and handed back as the only thing anybody asks
/// of it: how long ago it was, read at the moment of asking.
///
/// The alternative — `Date().timeIntervalSince(entry.lastFrameAt)` over C3's own wall-clock stamp — is a quantity no
/// manual clock can move, and every test of the heartbeat rule would have to sleep on wall time.
struct ClockStamp: Sendable {
    private let elapsed: @Sendable () -> Duration

    init(_ clock: any Clock<Duration>) { elapsed = Self.probe(clock) }

    /// How long ago this stamp was taken, on the clock it was taken from.
    var age: Duration { elapsed() }

    private static func probe<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}

/// One channel's fold of C3's task registry, fed by that channel's own event pump.
///
/// `Fleet.build` gives each supervisor one of these and reads the same object back in `eligibilityInputs`, so the
/// thirty-minute reap, the cap eviction, `perform(.reap)` and `/logout`'s *Stop* all decide over the tasks the
/// channel has *now*. Nothing is re-pumped: the supervisor hands each frame here as it handles it, which is the same
/// fold C3's own reducer performs and G2 drives, through `RegistryMirror.apply(_:at:epoch:)`.
///
/// Two stamps are kept per frame and they answer different questions. C3's `at:` is the wall-clock `Date` its rows
/// carry — the time a row started, ended, was last touched, and what `evictable(asOf:)` ages against. The host's own
/// reading of "how long since a frame named a task" is a `ClockStamp` on the injected clock, because that is the
/// quantity the heartbeat rule compares and the one a test can move.
public final class ChannelTaskMirror: @unchecked Sendable {   // `lock` serialises the mirror and the stamp
    private let lock = NSLock()
    private let clock: any Clock<Duration>
    private var mirror = RegistryMirror()
    private var lastFrame: ClockStamp?

    public init(clock: any Clock<Duration>) { self.clock = clock }

    /// Folds one frame of this channel's pump, and answers whether it touched a task row — which is when the
    /// channel's eligibility can have changed and is worth pushing.
    ///
    /// `tool_progress` is folded beside the five system subtypes because it is the heartbeat the uncertainty rule
    /// measures against: it moves `lastFrameAt` on a row the mirror already holds and creates nothing.
    @discardableResult
    public func note(_ frame: Frame, epoch: ProcessEpoch) -> Bool {
        let arrival = Date()
        let stamp = ClockStamp(clock)
        lock.lock(); defer { lock.unlock() }
        switch frame {
        case .system(let system):
            guard !mirror.apply(system, at: arrival, epoch: epoch).isEmpty else { return false }
        case .toolProgress(let progress):
            let before = mirror
            mirror.apply(toolProgress: progress, at: arrival)
            guard mirror != before else { return false }
        default:
            return false
        }
        lastFrame = stamp
        return true
    }

    /// Forgets everything: the child whose tasks these were has gone. A background shell is a child of the engine's
    /// process and dies with it, and a row nobody will ever notify is live for ever — so a mirror kept across an
    /// exit would leave the channel unreapable and un-evictable on a fact that stopped being true.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        mirror = RegistryMirror()
        lastFrame = nil
    }

    /// The work the host must not call finished, as C3's own `liveWork` defines it. Eligibility reads a list of
    /// rows and asks each whether it is running or armed, so the rows that are neither are left out here rather
    /// than carried: `RegistryMirror` exposes no remover, and a finished row that nothing reads is only memory.
    public var liveEntries: [RegistryEntry] {
        lock.lock(); defer { lock.unlock() }
        return mirror.liveWork(asOf: Date())   // C3's predicate does not age; the argument is not read by it
    }

    /// How long ago the last frame naming a task arrived, on the injected clock, or nil if none ever has.
    public var lastFrameAge: Duration? {
        lock.lock(); defer { lock.unlock() }
        return lastFrame?.age
    }
}
