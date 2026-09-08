import Foundation
import Observation
import AfleetCore
import FleetKit

/// What has to be settled before a channel may spawn, and the two things a user can do about it
/// (root spec §6.11 and §6.12, acceptance G4).
///
/// One object over `LifecycleAPI.preconditions(for:)`. It answers the two verdicts this child
/// renders — starting with `consentNeeded`, which raises the sheet — and it renders every refusal
/// as a `RowBanner`. Every other verdict is somebody else's surface and this model draws nothing
/// for it.
///
/// **It writes nothing.** *Accept* is `acceptProjectServers`, which only remembers the acceptance in
/// afleet's own store; *Decline* is `declineProjectServers`, the one Claude Code-owned file afleet
/// writes — and C4 is what writes it. No path under a config home is opened here.
///
/// The two actions are synchronous and claim `isAnswering` before they return, for the reason
/// `DecisionAnswering.send(_:on:in:)` claims its request id before it returns: the second of two
/// clicks in one run-loop turn must find the first already on the wire.
@MainActor
@Observable
final class PrecommitModel {

    private let lifecycle: any LifecycleAPI

    /// The channel this model was last evaluated for, and the project directory a decline is
    /// recorded against. Nil until `evaluate(channel:project:)` has run once.
    private(set) var channel: ChannelKey?
    private(set) var project: URL?

    /// The last verdict. `.ready` until one has been read, which is what a channel with no
    /// precondition looks like and is what draws nothing.
    private(set) var precondition: SpawnPrecondition = .ready

    /// Why the last action did not happen, or nil. Cleared by the next action that succeeds.
    private(set) var banner: RowBanner?

    /// True while an accept or a decline is on the wire. Every affordance disables on it, so
    /// nothing is sent twice.
    private(set) var isAnswering = false

    init(lifecycle: any LifecycleAPI) {
        self.lifecycle = lifecycle
    }

    // MARK: - The verdict

    /// The servers the sheet lists, or nil when no sheet is up.
    var consentServers: [ProjectMCPServer]? {
        if case .consentNeeded(let servers) = precondition { return servers }
        return nil
    }

    /// Reads the precondition for a channel. The only call that asks the fleet anything before a
    /// user has clicked.
    func evaluate(channel: ChannelKey, project: URL) async {
        self.channel = channel
        self.project = project
        precondition = await lifecycle.preconditions(for: channel)
    }

    // MARK: - §6.12, the consent sheet's two answers

    /// *Accept*: the store remembers the acceptance per project and server hash, and nothing is
    /// written to disk. The verdict is re-read afterwards, so the sheet closes because the fleet
    /// stopped asking rather than because the view decided it had.
    func accept(_ servers: [ProjectMCPServer]) {
        guard let project, claim() else { return }
        Task {
            defer { isAnswering = false }
            await lifecycle.acceptProjectServers(servers, project: project)
            banner = nil
            await reread()
        }
    }

    /// *Decline*: exactly the names the user declined, recorded through C4 in the project's
    /// `.claude/settings.local.json`. A refusal is fail-closed and says so.
    func decline(_ names: [String]) {
        guard let project, claim() else { return }
        Task {
            defer { isAnswering = false }
            do {
                try await lifecycle.declineProjectServers(names, project: project)
                banner = nil
                await reread()
            } catch let error as LifecycleError {
                banner = Self.banner(for: error)
            } catch {
                banner = RowBanner(text: "The project-server decline did not complete: \(type(of: error)).")
            }
        }
    }

    // MARK: - Refusals

    /// §6.12's fail-closed banner. `declineRefused` is the unparseable-JSON, symlink, foreign-uid
    /// and write-error path: nothing was written and nothing spawned, and the way forward is the
    /// terminal's own `/mcp` flow rather than another click here. The reason is the store's own
    /// kind word — never a path (§11).
    private static func banner(for error: LifecycleError) -> RowBanner {
        guard case .declineRefused(let reason) = error else { return RowBanner(error) }
        return RowBanner(text: "Nothing was written and nothing spawned: the decline was refused (\(reason)). "
                       + "Review this project's MCP servers in your terminal with /mcp.")
    }

    /// Takes the in-flight slot, or refuses because one is already taken.
    private func claim() -> Bool {
        guard !isAnswering else { return false }
        isAnswering = true
        return true
    }

    private func reread() async {
        guard let channel else { return }
        precondition = await lifecycle.preconditions(for: channel)
    }
}
