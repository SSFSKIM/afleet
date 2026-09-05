import Foundation
import AfleetCore
@testable import FleetSessions

/// Wraps `FileHolderReader` and records every read with the label the ownership check set on `OwnershipLabel`
/// (`beforeSpawn`, `afterHandshake`, `release`) or `poll` when no check did, so a test can assert the sequence
/// `[beforeSpawn, afterHandshake]` around a spawn by set and by order.
///
/// Two seams sit on top of it, and their order matters. A **hook** runs *after* the read it is attached to, so a test
/// can make a record appear between `beforeSpawn` and `afterHandshake`. A **hidden pid** is filtered out of the
/// result of its label's read, so a test can make one check miss a holder the next one finds.
final class RecordingHolderReader: HolderReader, @unchecked Sendable {   // `lock` serialises every field
    struct Call: Hashable, Sendable {
        let label: String
        let includeAgentsJSON: Bool
        /// The fleet's own child pids at the moment of the read: what makes `Holder.isOwnChild` true.
        let ownPIDs: Set<Int32>
    }

    private let base: FileHolderReader
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var hooks: [(label: String, once: Bool, body: @Sendable () -> Void)] = []
    private var hidden: [(label: String, pid: Int32, once: Bool)] = []

    init(base: FileHolderReader) { self.base = base }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var calls: [Call] { locked { _calls } }
    var labels: [String] { calls.map(\.label) }
    /// The labels of the checks only: the observer's own polls are not what a spawn assertion is about.
    var checkLabels: [String] { labels.filter { $0 != OwnershipLabel.poll } }

    /// Runs once (by default) immediately after the read carrying this label has produced its snapshot.
    func onLabel(_ label: String, once: Bool = true, _ body: @escaping @Sendable () -> Void) {
        locked { hooks.append((label, once, body)) }
    }

    /// Removes this pid from the result of the next read carrying this label.
    func hide(pid: Int32, forLabel label: String, once: Bool = true) {
        locked { hidden.append((label, pid, once)) }
    }

    func read(configHome: ConfigHome, ownPIDs: Set<Int32>, includeAgentsJSON: Bool) async -> HolderSnapshot {
        let label = OwnershipLabel.current ?? OwnershipLabel.poll
        locked { _calls.append(Call(label: label, includeAgentsJSON: includeAgentsJSON, ownPIDs: ownPIDs)) }

        var snapshot = await base.read(configHome: configHome, ownPIDs: ownPIDs, includeAgentsJSON: includeAgentsJSON)

        let (pids, due) = locked { () -> (Set<Int32>, [(label: String, once: Bool, body: @Sendable () -> Void)]) in
            let pids = Set(hidden.filter { $0.label == label }.map(\.pid))
            hidden.removeAll { $0.label == label && $0.once }
            let due = hooks.filter { $0.label == label }
            hooks.removeAll { $0.label == label && $0.once }
            return (pids, due)
        }

        if !pids.isEmpty {
            snapshot.holders = HolderSet(holders: snapshot.holders.holders.filter { !pids.contains($0.pid) },
                                         observedAt: snapshot.holders.observedAt)
        }
        for hook in due { hook.body() }
        return snapshot
    }
}
