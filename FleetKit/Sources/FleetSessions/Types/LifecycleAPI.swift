import Foundation
import AfleetCore
import ClaudeWire

/// What C5, C6 and C7 call. Nothing else spawns.
public protocol LifecycleAPI: Sendable {
    func state(of key: ChannelKey) async -> ChannelState?
    func states() async -> [ChannelState]
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState
    /// The §7.4 open-in-terminal row up to the handoff; purpose `.hatch`.
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest
    /// `claude attach <short>`; purpose `.attach`.
    func attach(_ job: JobShort) async throws -> PaneRequest
    /// `claude logs <short>`; purpose `.logs`.
    func logs(_ job: JobShort) async throws -> PaneRequest
    /// The panel's report; X5 re-adopts a hatch whose record is gone.
    func paneExited(_ exit: PaneExit) async
    /// Every roster job, conversation or exec, with or without a session.
    func jobs() async -> [JobEntry]
    /// `claude stop|respawn|rm <short>` through the runner; no PTY.
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws
    func isDormantEligible(_ key: ChannelKey) async -> Bool
    /// The §6.12 write.
    func declineProjectServers(_ names: [String], project: URL) async throws
    /// Store only.
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async
    /// nil unless owned; a fresh unbounded fan-out per call, finished when the channel archives.
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>?
    /// Every transition, coalesced per channel.
    var updates: AsyncStream<ChannelState> { get }
}
