import Foundation
import AfleetCore
import ClaudeWire

/// The engine's own two reports about a channel, as a surface that missed them reads them back.
///
/// Values and never a stream: the handshake and `system/init` each arrive once per process, and what a late
/// surface needs is the newest of each rather than a replay of everything between.
public struct EngineReports: Sendable {
    public var handshake: InitializeResponse?
    public var systemInit: SystemInitFields?
    public init(handshake: InitializeResponse?, systemInit: SystemInitFields?) {
        self.handshake = handshake
        self.systemInit = systemInit
    }
}

/// What C5, C6 and C7 call. Nothing else spawns.
public protocol LifecycleAPI: Sendable {
    func state(of key: ChannelKey) async -> ChannelState?
    func states() async -> [ChannelState]
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition
    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState
    /// Sends a prompt on an owned channel and returns the uuid the engine will echo for it, so the host can raise
    /// `HostSignal.promptSent` before the echo arrives. Every precondition and every refusal is
    /// `perform(.send(input), on:)`'s; only the answer differs.
    @discardableResult func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID
    /// Forks an owned channel and returns the **sibling's** provisional key, so the host can select and prefill the
    /// channel the fork produced. Every precondition and every refusal is `perform(.fork(at: point), on:)`'s; only
    /// the answer differs — `perform` answers the *source's* state, which names the sibling nowhere.
    @discardableResult func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey
    /// **The key that fork ended up filed under**, awaited.
    ///
    /// `fork(at:on:)` answers as soon as the child is up, and at that moment the sibling is keyed on a provisional
    /// id the engine has not confirmed: `--fork-session` makes it mint a fresh session and announce it later on
    /// `auth_status`, and the fleet re-keys the channel onto that id when it arrives. Everything above this contract
    /// — the browser's rows, the window's selection, a composer's pending draft — is keyed by the id that resolves,
    /// so a host that filed anything under the provisional key filed it under a channel nothing will ever reach.
    ///
    /// Separate from `fork` rather than folded into it, because the two answers are wanted at different moments. The
    /// spawn's refusals belong to the click, and a `fork` that waited would hold its caller for the whole identity
    /// budget on a slow engine — and the sibling is legitimately connecting under the provisional key until then,
    /// which is what a caller that only wants to know the spawn succeeded is looking at.
    ///
    /// Answers the provisional key unchanged when no id arrives: a fork whose child died or whose deadline expired
    /// has no other identity to be filed under.
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey
    /// The composer's line, routed against the channel's own handshake, `system/init` and runtime record. A key the
    /// fleet owns no supervisor for routes against the local table alone.
    func route(_ text: String, on key: ChannelKey) async -> Routed
    /// What the engine has already reported about itself on this channel: the handshake and `system/init`. A query,
    /// for a surface that subscribed to `events(of:)` after they arrived — the stream is future-only and neither
    /// report is sent twice. Nil for a key the fleet owns no supervisor for.
    func engineReports(of key: ChannelKey) async -> EngineReports?
    /// The user picked a value for a setting a quiescent restart could not read back. The value is applied first and
    /// only then does the channel's banner advance, so a channel is never released over a setting the engine never
    /// received. The names are `Readback.verify`'s own.
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws
    /// One routed control request, on a channel.
    @discardableResult func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue
    /// One routed strategy, on a channel; `ui` is the browser tab and the confirmation sheet the multi-step
    /// strategies need.
    @discardableResult func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
                                ui: any StrategyUI) async throws -> StrategyOutcome
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
    /// This channel's background tasks that are running or armed, by id; `[]` for a key the fleet owns no
    /// supervisor for. §7.4's "busy" — a turn running, or local shells still working — is the fleet's own fact, and
    /// this is the half of it a surface cannot see for itself: a surface reads `presence` and this, never a count
    /// it kept locally, so a channel that was spawned but never viewed is judged the same as one on screen.
    func liveTaskIDs(of key: ChannelKey) async -> [String]
    /// The §6.12 write.
    func declineProjectServers(_ names: [String], project: URL) async throws
    /// Store only.
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async
    /// A fresh unbounded fan-out per call for any channel this fleet owns a supervisor for, and nil for a key it
    /// does not know. Deliberately *not* gated on the channel being owned: subscribing before `perform(.open)` is
    /// what lets a consumer see the handshake rather than join after it. The stream is finished when the channel
    /// archives, so a consumer's `for await` ends rather than waiting on frames that can never come.
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>?
    /// Every transition, coalesced per channel.
    var updates: AsyncStream<ChannelState> { get }
    /// The roster, republished in full whenever it changes. `updates` cannot carry this: it is keyed by channel and
    /// an exec job has no channel, so a surface listening to it alone never learns that a job appeared outside
    /// afleet or that one changed state. Published from the observer's own watch and poll cycle, so a consumer that
    /// listens rather than polls costs no extra `agents --json` run.
    var jobUpdates: AsyncStream<[JobEntry]> { get }
}
