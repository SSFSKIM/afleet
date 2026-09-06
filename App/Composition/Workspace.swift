import Foundation
import ClaudeWire
import FleetKit

/// Everything the launch resolved, constructed once and read from the main actor. A plain value
/// holding references rather than an actor: nothing here is mutated after construction, and the
/// three live things inside it (`store`, `index`, `fleet`) serialise their own state.
struct Workspace: Sendable {
    let configHome: ConfigHome
    let environment: ResolvedEnvironment
    let binary: URL
    let installed: SemanticVersion
    let store: any StateStore
    let index: any IndexAccess
    let fleet: any AppFleet
    /// Nil when the Developer toggle left the watcher stopped (spec §2 step 10).
    let watcher: (any TranscriptWatching)?
}

/// The fleet as the app uses it. `LifecycleAPI` is what C4 published for C5, C6 and C7, but it
/// carries neither `start()` nor `register(_:cwd:recent:)` — both are `Fleet`'s own — and the
/// composition root needs each. The protocol exists so `fleetFactory` can be a closure, which is
/// what makes "no `Fleet` was ever constructed" an assertion a test can make.
protocol AppFleet: LifecycleAPI {
    func start() async
    func register(_ key: ChannelKey, cwd: URL, recent: Bool) async
    func shutdown() async
}

/// `Fleet.register` and `Fleet.flushDiagnostics` are synchronous actor members; a cross-actor call
/// to either is `async`, which is exactly what the protocol asks for.
extension Fleet: AppFleet {}

/// C3's index as the app uses it. A protocol because the ordering test needs a `build()` that
/// blocks until the test releases it, and `TranscriptIndex` is a concrete actor.
protocol IndexAccess: Sendable {
    func loadPersisted() async throws -> IndexSnapshot?
    @discardableResult func build() async throws -> IndexSnapshot
    func update(changed: [URL]) async -> IndexDelta
    func persist() async throws
    func entry(_ id: SessionID) async -> IndexEntry?
    /// `TranscriptIndex.snapshot` is a property, so the requirement is spelled as a method to be
    /// witnessable by one.
    var currentSnapshot: IndexSnapshot { get async }
}

extension TranscriptIndex: IndexAccess {
    var currentSnapshot: IndexSnapshot { snapshot }
}
