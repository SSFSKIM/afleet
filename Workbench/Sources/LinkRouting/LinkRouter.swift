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

    private var targets: [LinkTarget] = []

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
    public var targetCount: Int { targets.count }

    // MARK: - The registry

    public func register(_ target: LinkTarget) {
        targets.append(target)
    }

    /// Drops every target this tab registered, so a target never outlives the tab that registered it.
    public func unregister(tab: PanelTabID) {
        targets.removeAll { $0.tab == tab }
    }

    /// Resolves the most specific registered target, runs `prepare` for it, and only then delivers
    /// both the link and the destination.
    ///
    /// `prepare` is where the host pops a tab out for `.newWindow`; it runs *after* resolution and
    /// *before* delivery, which is the ordering that rule is about. With no `prepare` this is the
    /// pure registry W5 describes.
    public func open(_ link: WorkspaceLink, from destination: LinkDestination,
                     prepare: (@MainActor @Sendable (LinkTarget, LinkDestination) async -> Void)? = nil) async {
        guard let target = mostSpecific(for: link) else {
            fallback(link)
            return
        }
        await prepare?(target, destination)
        await target.open(link, destination)
    }

    // MARK: - Picking

    /// Highest `specificity` wins; ties break by `PanelTabID`'s canonical order, so the choice is
    /// total and does not depend on registration order.
    private func mostSpecific(for link: WorkspaceLink) -> LinkTarget? {
        let handling = targets.filter { $0.handles(link) }
        return handling.min { left, right in
            if left.specificity != right.specificity { return left.specificity > right.specificity }
            return Self.order(left.tab) < Self.order(right.tab)
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
