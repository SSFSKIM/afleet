import Foundation
import XCTest
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
    private var waiters: [(needed: Int, expectation: XCTestExpectation)] = []

    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async {
        calls.append(Call(key: key, cwd: cwd, recent: recent))
        for waiter in waiters where waiter.needed <= calls.count { waiter.expectation.fulfill() }
        waiters.removeAll { $0.needed <= calls.count }
    }

    /// Fulfilled the moment the `count`-th registration arrives. Nothing polls: the registration
    /// itself ends the wait, so the verdict does not depend on how much of the machine a polling
    /// task got. Safe to arm after the stimulus as well as before it.
    func expect(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) registrations")
        if calls.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
        return expectation
    }

    var count: Int { calls.count }
    var keys: Set<ChannelKey> { Set(calls.map(\.key)) }
    var recentKeys: Set<ChannelKey> { Set(calls.filter(\.recent).map(\.key)) }
    var staleKeys: Set<ChannelKey> { Set(calls.filter { !$0.recent }.map(\.key)) }
    func calls(for key: ChannelKey) -> [Call] { calls.filter { $0.key == key } }
}
