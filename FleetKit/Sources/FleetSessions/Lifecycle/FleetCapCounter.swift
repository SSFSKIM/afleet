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

/// What the evicting supervisor observed. Task 5 reports it through `evictionOutcome`.
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
        let occupied = live.count + reserved.count + wedged.count + pendingEvictions.count
        if occupied < capacity {
            let r = Reservation(key: key)
            reserved[r.id] = r
            diagnostics.record(.capDecision(decision: "granted", live: live.count, reserved: reserved.count))
            return .granted(r)
        }
        let candidates = live.filter { $0 != key && eligibility[$0]?.isEligible == true }
        if let victim = candidates.min(by: { (lru[$0] ?? 0) < (lru[$1] ?? 0) }) {
            let r = Reservation(key: key)
            reserved[r.id] = r
            live.remove(victim)
            pendingEvictions[r.id] = victim
            diagnostics.record(.capDecision(decision: "evict", live: live.count, reserved: reserved.count))
            return .evict(victim: victim, r)
        }
        let count = live.count + wedged.count + pendingEvictions.count
        diagnostics.record(.capDecision(decision: "refused", live: count, reserved: reserved.count))
        return .refused(live: count)
    }

    /// A clean handshake turns the reservation into a live slot.
    public func confirm(_ r: Reservation) {
        guard reserved.removeValue(forKey: r.id) != nil else { return }
        live.insert(r.key)
        if lru[r.key] == nil { activityClock += 1; lru[r.key] = activityClock }
    }

    /// Any failure between `acquire` and `confirm`: the reservation is dropped and a named victim returns to `live`.
    public func rollback(_ r: Reservation) {
        reserved.removeValue(forKey: r.id)
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

    public func markWedged(_ key: ChannelKey) {
        live.remove(key)
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

    public var liveCount: Int { live.count + wedged.count + pendingEvictions.count }
    public var occupiedCount: Int { live.count + reserved.count + wedged.count + pendingEvictions.count }
    public func isLive(_ key: ChannelKey) -> Bool { live.contains(key) }
    public func recency(of key: ChannelKey) -> UInt64? { lru[key] }
    /// The last verdict this key's supervisor pushed. The counter never asks a supervisor for it.
    public func verdict(of key: ChannelKey) -> DormantEligibility.Verdict? { eligibility[key] }
}
