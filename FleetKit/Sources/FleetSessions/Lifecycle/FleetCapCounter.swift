import Foundation
import AfleetCore

/// One claim on a slot, handed out by `acquire` and given back by `confirm` or `rollback`. Identity, not equality of
/// the key: two supervisors racing for the last slot hold two distinct reservations.
public struct Reservation: Hashable, Sendable {
    public let id: UUID
    public let key: ChannelKey
    public init(id: UUID = UUID(), key: ChannelKey) { self.id = id; self.key = key }
}

/// What the counter decided in the one turn `acquire` ran.
public enum CapDecision: Sendable {
    case granted(Reservation)
    /// Spawn only after evicting this victim; the reservation is already held and the victim has already left the
    /// live set, so a second `acquire` in the same instant names a different victim or is refused.
    case evict(victim: ChannelKey, Reservation)
    case refused(live: Int)
}

/// What the evicting supervisor observed, reported back through `evictionOutcome`.
public enum EvictionOutcome: Hashable, Sendable { case evicted, victimWedged, victimBecameIneligible }

/// The fleet-wide cap of six owned processes, as reservations.
///
/// `acquire` decides in one synchronous actor turn — it awaits nothing, least of all a supervisor — from every
/// occupied slot (live, reserved, wedged and pending eviction) and from `eligibility`, a snapshot the supervisors
/// push on every change. Recency is this actor's own `activityClock`, a fleet-wide `UInt64`: there is no
/// per-supervisor activity sequence, so stamps from different channels are comparable.
///
/// A dormant channel holds no slot: `reap()` released it. Only a wedged ghost keeps a count without a live process.
public actor FleetCapCounter {
    public static let capacity = 6

    private let capacity: Int
    private var live: Set<ChannelKey> = []
    private var reserved: [UUID: Reservation] = [:]
    private var wedged: Set<ChannelKey> = []
    /// Reservation id -> the victim that left `live` for it.
    private var pendingEvictions: [UUID: ChannelKey] = [:]
    /// Every victim already named for a reservation. The eligibility a pick reads is a snapshot the supervisors
    /// push, and a victim that re-evaluates itself as running at reap time goes back into `live` with that snapshot
    /// unchanged; without this the same channel would be named again, and again.
    private var attempted: [UUID: Set<ChannelKey>] = [:]
    private var eligibility: [ChannelKey: DormantEligibility.Verdict] = [:]
    private var lru: [ChannelKey: UInt64] = [:]
    private var activityClock: UInt64 = 0
    private let diagnostics: any FleetDiagnosticsSink

    public init(capacity: Int = FleetCapCounter.capacity,
                diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()) {
        self.capacity = capacity; self.diagnostics = diagnostics
    }

    // MARK: - Slots

    /// Decided in one turn, with no suspension point inside it.
    public func acquire(for key: ChannelKey) -> CapDecision {
        let r = Reservation(key: key)
        reserved[r.id] = r
        return pick(for: r)
    }

    /// The evicting supervisor's report on the victim it was named. Runs in one turn, like `acquire`.
    ///
    /// `.evicted` is the only outcome that frees anything: the slot the victim left becomes this reservation's, and
    /// the spawn goes ahead. A wedged victim frees nothing — its ghost still holds the session — and an ineligible
    /// one goes back where it came from; both re-run the pick against the same reservation, so the caller either
    /// gets a second victim or a refusal, and never a slot nobody vacated.
    @discardableResult
    public func evictionOutcome(_ r: Reservation, _ outcome: EvictionOutcome) -> CapDecision {
        let victim = pendingEvictions.removeValue(forKey: r.id)
        if let victim { attempted[r.id, default: []].insert(victim) }
        diagnostics.record(.evictionOutcome(outcome: String(describing: outcome),
                                            victim: victim?.session.description ?? "-"))
        switch outcome {
        case .evicted:
            // The victim's own `release` may have completed this eviction already; either way the slot is the
            // reservation's now. A reservation that was rolled back in between is gone and answers a refusal.
            guard reserved[r.id] != nil else { return refuse() }
            record("granted")
            return .granted(r)
        case .victimWedged:
            if let victim { wedged.insert(victim) }
            return pick(for: r)
        case .victimBecameIneligible:
            if let victim { live.insert(victim) }
            return pick(for: r)
        }
    }

    /// Names the least recently used eligible live channel for a reservation already held, moves it out of `live` in
    /// the same turn — so a concurrent `acquire` counts its slot and cannot pick it — or gives the reservation back.
    private func pick(for r: Reservation) -> CapDecision {
        let occupied = live.count + reserved.count + wedged.count + pendingEvictions.count
        if occupied <= capacity {
            record("granted")
            return .granted(r)
        }
        let alreadyTried = attempted[r.id] ?? []
        let candidates = live.filter {
            $0 != r.key && !alreadyTried.contains($0) && eligibility[$0]?.isEligible == true
        }
        if let victim = candidates.min(by: { (lru[$0] ?? 0) < (lru[$1] ?? 0) }) {
            live.remove(victim)
            pendingEvictions[r.id] = victim
            record("evict")
            return .evict(victim: victim, r)
        }
        reserved.removeValue(forKey: r.id)
        attempted.removeValue(forKey: r.id)
        return refuse()
    }

    /// Called once the refused caller's own reservation is gone, so the count is every slot somebody *else* holds:
    /// a reservation another supervisor is spawning against is as occupied as a live process, which is what makes the
    /// eighth open at the cap read six rather than the five processes it can see.
    private func refuse() -> CapDecision {
        let count = holdingCount + reserved.count
        record("refused")
        return .refused(live: count)
    }

    /// One decision, with the three numbers it was taken against.
    private func record(_ decision: String) {
        diagnostics.record(.capDecision(decision: decision, live: holdingCount, reserved: reserved.count,
                                        pendingEvictions: pendingEvictions.count))
    }

    /// Every slot that holds, or is still holding, a process of ours: a live channel, a ghost, and a victim whose
    /// eviction has not completed. This is the number a decision records as `live`, so "how many processes' worth of
    /// slots does the fleet hold" is one field in every `capDecision` and never has to be reassembled.
    private var holdingCount: Int { live.count + wedged.count + pendingEvictions.count }

    /// A clean handshake turns the reservation into a live slot.
    ///
    /// The key comes from the *stored* reservation and never from the caller's copy: `rekey` rewrites the stored one
    /// when a fork learns its own session id, and the caller is still holding the provisional key. Inserting that
    /// would take a live slot under a key nothing will ever release.
    public func confirm(_ r: Reservation) {
        attempted.removeValue(forKey: r.id)
        guard let stored = reserved.removeValue(forKey: r.id) else { return }
        live.insert(stored.key)
        if lru[stored.key] == nil { activityClock += 1; lru[stored.key] = activityClock }
    }

    /// Any failure between `acquire` and `confirm`: the reservation is dropped and a named victim returns to `live`.
    public func rollback(_ r: Reservation) {
        reserved.removeValue(forKey: r.id)
        attempted.removeValue(forKey: r.id)
        if let victim = pendingEvictions.removeValue(forKey: r.id) { live.insert(victim) }
    }

    /// A key in `live` leaves it; a key pending eviction completes that eviction; a key nowhere is a no-op.
    public func release(_ key: ChannelKey) {
        if live.remove(key) != nil { return }
        if let id = pendingEvictions.first(where: { $0.value == key })?.key {
            pendingEvictions.removeValue(forKey: id)
        }
    }

    /// The one fleet-wide clock every supervisor's activity lands on.
    public func noteActivity(_ key: ChannelKey) {
        activityClock += 1
        lru[key] = activityClock
    }

    public func setEligibility(_ key: ChannelKey, _ verdict: DormantEligibility.Verdict) {
        eligibility[key] = verdict
    }

    /// A ghost keeps its slot occupied. A victim that wedges *mid-eviction* already occupies one as a pending
    /// eviction, so it is not counted a second time here: the evicting supervisor's `.victimWedged` report is what
    /// moves it across, in one turn, and until then `live + reserved + wedged + pendingEvictions` still reads six.
    public func markWedged(_ key: ChannelKey) {
        live.remove(key)
        guard !pendingEvictions.values.contains(key) else { return }
        wedged.insert(key)
    }

    public func clearWedged(_ key: ChannelKey) { wedged.remove(key) }

    /// One turn moving every entry from a fork's provisional key to the id the engine resolved.
    public func rekey(_ provisional: ChannelKey, to resolved: ChannelKey) {
        if live.remove(provisional) != nil { live.insert(resolved) }
        if wedged.remove(provisional) != nil { wedged.insert(resolved) }
        for (id, r) in reserved where r.key == provisional { reserved[id] = Reservation(id: id, key: resolved) }
        for (id, victim) in pendingEvictions where victim == provisional { pendingEvictions[id] = resolved }
        if let stamp = lru.removeValue(forKey: provisional) { lru[resolved] = stamp }
        if let verdict = eligibility.removeValue(forKey: provisional) { eligibility[resolved] = verdict }
    }

    // MARK: - Reading

    public var liveCount: Int { holdingCount }
    public var occupiedCount: Int { live.count + reserved.count + wedged.count + pendingEvictions.count }
    /// What the cap actually bounds. Every pending eviction is the slot one reservation is waiting for — the
    /// incoming process replaces the victim's rather than joining it — so it is counted once, not twice, and this
    /// is at most `capacity` at every moment. `occupiedCount` is deliberately the more conservative number `pick`
    /// compares, which reads one higher for the duration of each eviction.
    public var occupancy: Int { holdingCount + reserved.count - pendingEvictions.count }
    public func isLive(_ key: ChannelKey) -> Bool { live.contains(key) }
    public func recency(of key: ChannelKey) -> UInt64? { lru[key] }
    /// The last verdict this key's supervisor pushed. The counter never asks a supervisor for it.
    public func verdict(of key: ChannelKey) -> DormantEligibility.Verdict? { eligibility[key] }
}
