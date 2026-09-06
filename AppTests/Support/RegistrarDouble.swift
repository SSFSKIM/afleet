import Foundation
import AfleetCore
import FleetKit
@testable import Afleet

/// Records every `Fleet.register(_:cwd:recent:)` the composition root makes.
///
/// This double exists because `register` is not on `LifecycleAPI`: a lifecycle double cannot see a
/// registration at all, and "a cold launch registered every listed channel" is not a claim any test
/// could otherwise make. A registrar that nothing calls passes every unit test written about it and
/// leaves a first-ever launch with no supervisors — no live origin, no Activity event and no owned
/// timeline for any row.
actor RegistrarDouble: ChannelRegistering {

    struct Call: Hashable, Sendable {
        var key: ChannelKey
        var cwd: URL
        var recent: Bool
    }

    private(set) var calls: [Call] = []

    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async {
        calls.append(Call(key: key, cwd: cwd, recent: recent))
    }

    var count: Int { calls.count }
    var keys: Set<ChannelKey> { Set(calls.map(\.key)) }
    var recentKeys: Set<ChannelKey> { Set(calls.filter(\.recent).map(\.key)) }
    var staleKeys: Set<ChannelKey> { Set(calls.filter { !$0.recent }.map(\.key)) }
    func calls(for key: ChannelKey) -> [Call] { calls.filter { $0.key == key } }
}
