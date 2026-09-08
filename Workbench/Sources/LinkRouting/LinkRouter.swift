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

    /// What a withdrawal found when its drain finished, and the only thing a host may act on.
    ///
    /// The host releases the tab's sessions and pane runners after `unregister(tab:)` returns, and
    /// by then the tab may belong to someone else: a second withdrawal of the same tab, or the
    /// replacement X7's handover registers *during* the drain. Both cases are `superseded`, and a
    /// host that released state on them would delete the successor's (spec §3, 2026-09-08).
    public enum Withdrawal: Sendable, Equatable {
        /// The tab is still on the epoch this withdrawal opened and nothing has registered for it
        /// since. The caller owns the tab's state and may release it.
        case complete
        /// A later withdrawal, or a registration made during the drain, owns the tab's state now.
        case superseded
    }

    /// A registered target plus the identity the router gives it. `LinkTarget` is not `Equatable`
    /// and carries closures, so "the target I resolved" is only expressible as a token the router
    /// mints: monotonic, never reused, and dropped with the registration.
    ///
    /// `epoch` is the tab's withdrawal epoch at the moment of registration, which is what makes
    /// "registered before this teardown" and "registered during it" two different things.
    private struct Registration {
        let token: Int
        let epoch: Int
        let target: LinkTarget
    }

    private var registrations: [Registration] = []

    /// How many times each tab has been withdrawn. Incremented at the *start* of every
    /// `unregister(tab:)`, so everything registered before that line belongs to the previous epoch
    /// and everything registered during the drain belongs to the new one.
    private var epochs: [PanelTabID: Int] = [:]

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

    /// The tokens a tab's withdrawals took away while a delivery was still running for them. A
    /// tab's drain is over when none of them is in flight any more, which is what makes two
    /// overlapping withdrawals of one tab join *one* drain rather than each waiting on its own
    /// tokens: the second finds the first's tokens here and waits for them too.
    private var withdrawnInFlight: [PanelTabID: Set<Int>] = [:]

    /// Withdrawals parked until their tab's drain is over, by tab. An array because two
    /// withdrawals of one tab may overlap.
    private var drainWaiters: [PanelTabID: [CheckedContinuation<Void, Never>]] = [:]

    /// How many times one `open` may re-resolve after a withdrawal landed during `prepare`.
    ///
    /// Bounded rather than "until the fixed set is exhausted", because re-resolution is against the
    /// *live* registry: a tab that withdraws and registers again on every attempt would otherwise
    /// keep the call alive for ever. Two attempts is what the handover needs — the withdrawal and
    /// its replacement — and the third exists so the bound is a bound and not the exact shape of
    /// one scenario.
    private static let maxResolutionAttempts = 3

    /// How many preparations one `open` may run.
    ///
    /// One per *live* preparation, and a preparation stops being live when its tab is torn down
    /// under it: the teardown may have taken the window that preparation opened with it, so the
    /// replacement registered in the new epoch is prepared for once more rather than delivered
    /// into a window that is no longer there. The second is the last: the bound is what stops a
    /// tab that hands itself over on every attempt from presenting windows for ever. The attempt
    /// that follows it delivers into the last preparation **only while that preparation is still
    /// live**; a tab torn down again under it leaves the call with no window to deliver into, and
    /// that is W5's fallback rather than an unprepared `.newWindow`.
    private static let maxPreparationsPerOpen = 2

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
        registrations.append(Registration(token: nextToken, epoch: epoch(of: target.tab),
                                          target: target))
        nextToken += 1
    }

    /// The tab's current withdrawal epoch. Zero for a tab nothing has ever withdrawn.
    private func epoch(of tab: PanelTabID) -> Int { epochs[tab] ?? 0 }

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
    ///
    /// **It opens a new epoch for the tab**, and that is what the returned `Withdrawal` reports on.
    /// Two withdrawals of one tab overlap whenever the second begins while the first is draining;
    /// they join one drain, and only the last of them may release the tab's state. A registration
    /// made during a drain belongs to the new epoch, survives the withdrawal that is draining —
    /// X7's handover — and takes the tab's state with it, so that withdrawal is `superseded` too.
    @discardableResult
    public func unregister(tab: PanelTabID) async -> Withdrawal {
        let epoch = self.epoch(of: tab) + 1
        epochs[tab] = epoch
        for registration in registrations
        where registration.target.tab == tab && deliveriesInFlight[registration.token] != nil {
            withdrawnInFlight[tab, default: []].insert(registration.token)
        }
        registrations.removeAll { $0.target.tab == tab }
        while (withdrawnInFlight[tab] ?? []).contains(where: { deliveriesInFlight[$0] != nil }) {
            await withCheckedContinuation { continuation in
                drainWaiters[tab, default: []].append(continuation)
            }
        }
        let superseded = self.epoch(of: tab) != epoch
            || registrations.contains { $0.target.tab == tab }
        return superseded ? .superseded : .complete
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
    /// - **One `prepare` per live preparation.** `prepare` presents a window, which is not
    ///   undoable, so preparing a second *target* would leave two windows or one window with
    ///   nothing in it: a resolution that names any other tab takes W5's fallback (tracker 98). A
    ///   preparation is live while its tab is still on the epoch it was prepared under; a teardown
    ///   that landed since may have taken the window with it, so the replacement registered in the
    ///   new epoch is prepared for once more — the host's pop-out is idempotent per (tab, channel),
    ///   so that second preparation brings the window back rather than opening another one.
    public func open(_ link: WorkspaceLink, from destination: LinkDestination,
                     prepare: (@MainActor @Sendable (LinkTarget, LinkDestination) async -> Void)? = nil) async {
        var prepared: (tab: PanelTabID, epoch: Int)?
        var preparations = 0
        for _ in 0..<Self.maxResolutionAttempts {
            guard let chosen = mostSpecific(for: link) else { break }
            if let prepared {
                // A window was opened for `prepared.tab`. Only that tab's own replacement may
                // deliver into it; a different target would need a second, irreversible
                // preparation for a window this call has no way to take back.
                guard chosen.target.tab == prepared.tab else { break }
                if prepared.epoch == epoch(of: chosen.target.tab) {
                    // The window this call opened is still the one the target will render into.
                    await deliver(chosen, link, destination)
                    return
                }
                // It is not: a teardown landed on the tab since, and may have taken that window
                // with it. Preparing once more is the answer while the bound allows one, and when
                // it does not the open **falls back** rather than telling a handler `.newWindow`
                // for a window nothing holds (spec §3, 2026-09-08 final wave).
                if preparations >= Self.maxPreparationsPerOpen { break }
            }
            guard let prepare else {
                // Nothing suspends between the resolution above and this commit.
                await deliver(chosen, link, destination)
                return
            }
            let epochAtPreparation = epoch(of: chosen.target.tab)
            await prepare(chosen.target, destination)
            preparations += 1
            prepared = (chosen.target.tab, epochAtPreparation)
            // Valid only if the tab was not torn down while `prepare` was suspended *and* the
            // registration this call resolved is still the one holding the tab.
            if epoch(of: chosen.target.tab) == epochAtPreparation,
               registrations.contains(where: { $0.token == chosen.token }) {
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
        let tab = registration.target.tab
        withdrawnInFlight[tab]?.remove(registration.token)
        if withdrawnInFlight[tab]?.isEmpty ?? false { withdrawnInFlight[tab] = nil }
        // Every withdrawal parked for this tab re-checks the drain and parks again if another of
        // its tokens is still running, so the wake-up needs no bookkeeping of its own.
        for waiter in drainWaiters.removeValue(forKey: tab) ?? [] {
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
