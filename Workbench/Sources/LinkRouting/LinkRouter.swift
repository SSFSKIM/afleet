// LinkRouting: owned by C7.2 (docs/doperpowers/specs/2026-09-07-c7.2-editor-core.md Design §3,
// under the composite's binding W5 and contract X7).
import Foundation
import AppKit
import OSLog
import AfleetCore
import PanelHostAPI

/// The one `WorkspaceLink` registry, reusable and testable without the app.
///
/// An `actor` rather than main-actor-isolated state: X7 kept `unregister(tab:)` `async` expressly
/// so this choice was open, and serialised execution is what makes withdrawal-before-registration
/// ordering structural rather than argued.
///
/// It owns registration, withdrawal by tab, resolution and the fallback. It does **not** own
/// pop-out: `.newWindow` has to pop the target's tab out before the target delivers, and that
/// needs the host. A stored host hook on an actor the host owns is a retain cycle, so the hook is
/// the per-call `prepare` parameter of ``open(_:from:prepare:)`` instead.
///
/// For the same reason it deliberately does **not** conform to `LinkRouterCapability`: a router
/// handed out as the capability directly would route `.newWindow` with nobody to pop the tab out.
/// The host conforms and delegates here, passing its pop-out as `prepare` (spec Design §4).
public actor LinkRouter {

    /// What an unhandled `.url` falls back to. Injected so a test does not open a browser window.
    private let externalOpener: @Sendable (URL) -> Void

    /// Where the fallback's diagnostic goes for every kind that is not a `.url`. The message names
    /// the kind and never the link, so no path, no commit hash and no PR number reaches a log (§11).
    private let diagnostic: @Sendable (String) -> Void

    /// A registered target plus the identity the router gives it. `LinkTarget` is not `Equatable`
    /// and carries closures, so "the target I resolved" is only expressible as a token the router
    /// mints: monotonic, never reused, and dropped with the registration.
    private struct Registration {
        let token: Int
        let target: LinkTarget
    }

    private var registrations: [Registration] = []

    /// Next token to hand out. Monotonic, so a withdrawn token can never be resurrected by a
    /// later registration — which is what makes the post-suspension re-check below sound.
    private var nextToken = 0

    /// How many deliveries are running for each token right now.
    ///
    /// A delivery is *committed* on this actor and only then hops to the handler's main actor, so
    /// there is a window in which a registration is live, a delivery is owed to it, and the handler
    /// has not run a line. `unregister(tab:)` must not return inside that window: the host awaits
    /// it and releases the tab's sessions the moment it does.
    private var deliveriesInFlight: [Int: Int] = [:]

    /// Withdrawals parked until the deliveries they found in flight have finished, by token. An
    /// array because two withdrawals of one tab may overlap.
    private var drainWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    /// How many times one `open` may re-resolve after a withdrawal landed during `prepare`.
    ///
    /// Bounded rather than "until the fixed set is exhausted", because re-resolution is against the
    /// *live* registry: a tab that withdraws and registers again on every attempt would otherwise
    /// keep the call alive for ever. Two attempts is what the handover needs — the withdrawal and
    /// its replacement — and the third exists so the bound is a bound and not the exact shape of
    /// one scenario.
    private static let maxResolutionAttempts = 3

    private static let log = Logger(subsystem: "com.afleet.app", category: "panel-links")

    /// The production fallbacks. Public because they are the `init` defaults, and a default
    /// argument expression is inlined into every caller, so it can only name public API.
    public static let systemOpener: @Sendable (URL) -> Void = { url in
        Task { @MainActor in NSWorkspace.shared.open(url) }
    }

    public static let logDiagnostic: @Sendable (String) -> Void = { message in
        log.notice("\(message, privacy: .public)")
    }

    public init(externalOpener: @escaping @Sendable (URL) -> Void = LinkRouter.systemOpener,
                diagnostic: @escaping @Sendable (String) -> Void = LinkRouter.logDiagnostic) {
        self.externalOpener = externalOpener
        self.diagnostic = diagnostic
    }

    /// How many targets are registered, for a diagnostic line. A count, never a tab set (§11).
    public var targetCount: Int { registrations.count }

    // MARK: - The registry

    public func register(_ target: LinkTarget) {
        registrations.append(Registration(token: nextToken, target: target))
        nextToken += 1
    }

    /// Drops every target this tab registered, so a target never outlives the tab that registered
    /// it, and **returns only once every delivery already in flight for those targets has
    /// finished**.
    ///
    /// The drop itself is synchronous on this actor, so no *new* delivery can be resolved against a
    /// withdrawn target from the moment the call begins. The wait is the other half: a delivery
    /// committed before the drop is already owed to a handler that has not run yet, because
    /// handlers are main-actor and the router suspends to reach them. `PanelHost.unregister(_:)`
    /// awaits this and then releases the tab's sessions, so without the wait that release lands
    /// under a handler about to start (contract X7's 2026-09-06 amendment; tracker 97).
    ///
    /// A handler that awaited a withdrawal of its *own* tab from inside its own delivery would
    /// wait on itself. Nothing does — withdrawal is the host's teardown path, not a panel's — and
    /// making it safe would mean a delivery could outlive the guarantee this method exists to give.
    public func unregister(tab: PanelTabID) async {
        let withdrawn = registrations.filter { $0.target.tab == tab }.map(\.token)
        registrations.removeAll { $0.target.tab == tab }
        for token in withdrawn where deliveriesInFlight[token] != nil {
            await withCheckedContinuation { continuation in
                drainWaiters[token, default: []].append(continuation)
            }
        }
    }

    /// Resolves the most specific registered target, runs `prepare` for it, and only then delivers
    /// both the link and the destination.
    ///
    /// `prepare` is where the host pops a tab out for `.newWindow`; it runs *after* resolution and
    /// *before* delivery, which is the ordering that rule is about. With no `prepare` this is the
    /// pure registry W5 describes, and nothing suspends between resolving and committing.
    ///
    /// `prepare` is a main-actor `await`, so the router *suspends* between resolving and
    /// delivering, and an `unregister(tab:)` can land in that window — the host's own teardown
    /// path does exactly this. Three things follow, and they are one design rather than three
    /// patches:
    ///
    /// - **The resolved registration is re-checked by token after the suspension.** X7 says a
    ///   target "cannot deliver into one that is gone", so a withdrawn one is not delivered to.
    /// - **Re-resolution is against the registry as it stands now**, not as it stood when the call
    ///   began. The handover X7 was amended for withdraws a tab and registers its replacement under
    ///   the same id, both inside this suspension; a replacement excluded because it is younger
    ///   than the call is a live target losing to a stale one or to the fallback.
    /// - **At most one `prepare` runs per call.** `prepare` presents a window, which is not
    ///   undoable, so preparing a second target would leave two windows or one window with nothing
    ///   in it. A replacement for the *same tab* delivers into the window already prepared for that
    ///   tab; anything else takes W5's fallback (tracker 98).
    public func open(_ link: WorkspaceLink, from destination: LinkDestination,
                     prepare: (@MainActor @Sendable (LinkTarget, LinkDestination) async -> Void)? = nil) async {
        var preparedTab: PanelTabID?
        for _ in 0..<Self.maxResolutionAttempts {
            guard let chosen = mostSpecific(for: link) else { break }
            if let preparedTab {
                // A window is already open for `preparedTab`. Only that tab's own replacement may
                // deliver into it; a different target would need a second, irreversible preparation.
                guard chosen.target.tab == preparedTab else { break }
                await deliver(chosen, link, destination)
                return
            }
            guard let prepare else {
                // Nothing suspends between the resolution above and this commit.
                await deliver(chosen, link, destination)
                return
            }
            await prepare(chosen.target, destination)
            preparedTab = chosen.target.tab
            if registrations.contains(where: { $0.token == chosen.token }) {
                await deliver(chosen, link, destination)
                return
            }
        }
        fallback(link)
    }

    /// Commits a delivery and runs it. The count is raised on this actor *before* the hop to the
    /// handler's main actor, which is what makes `unregister(tab:)`'s wait cover the whole of it.
    private func deliver(_ registration: Registration, _ link: WorkspaceLink,
                         _ destination: LinkDestination) async {
        deliveriesInFlight[registration.token, default: 0] += 1
        await registration.target.open(link, destination)
        let remaining = (deliveriesInFlight[registration.token] ?? 1) - 1
        if remaining > 0 {
            deliveriesInFlight[registration.token] = remaining
            return
        }
        deliveriesInFlight[registration.token] = nil
        for waiter in drainWaiters.removeValue(forKey: registration.token) ?? [] {
            waiter.resume()
        }
    }

    // MARK: - Picking

    /// Highest `specificity` wins; ties break by `PanelTabID`'s canonical order, so the choice is
    /// total and does not depend on registration order.
    private func mostSpecific(for link: WorkspaceLink) -> Registration? {
        let handling = registrations.filter { $0.target.handles(link) }
        return handling.min { left, right in
            if left.target.specificity != right.target.specificity {
                return left.target.specificity > right.target.specificity
            }
            return Self.order(left.target.tab) < Self.order(right.target.tab)
        }
    }

    private static func order(_ id: PanelTabID) -> Int {
        PanelTabID.allCases.firstIndex(of: id) ?? PanelTabID.allCases.count
    }

    /// W5's rule: a `.url` nobody claimed goes to the system, and every other kind is a diagnostic
    /// line that names the kind and carries no part of the payload.
    private func fallback(_ link: WorkspaceLink) {
        switch link {
        case .url(let url):
            externalOpener(url)
        case .file:
            diagnostic("no panel target for a file link")
        case .diff:
            diagnostic("no panel target for a diff link")
        case .commit:
            diagnostic("no panel target for a commit link")
        case .pullRequest:
            diagnostic("no panel target for a pull-request link")
        case .command:
            diagnostic("no panel target for a command link")
        }
    }
}
