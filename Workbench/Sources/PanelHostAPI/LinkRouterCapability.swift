import Foundation
import AfleetCore

/// Where an opened link should be delivered. A handler that receives only the link cannot
/// tell an in-panel open from a popped-out one, so every target is given this too.
public enum LinkDestination: Hashable, Sendable { case currentPanel, newWindow }

/// One panel's claim on a class of links.
public struct LinkTarget: Sendable {
    public let tab: PanelTabID
    /// Higher wins when two targets both handle a link; the host picks the most specific.
    public let specificity: Int
    /// Whether the host pops this target's tab out before delivering `.newWindow`.
    ///
    /// A target that answers `.newWindow` by **leaving the app** has no window to be popped out
    /// into, and a host that popped one anyway would present two: an afleet window holding the tab
    /// *and* the system browser. C7.6's Browser is that target — Cmd-click on a `.url` or a
    /// `.pullRequest` is the escape hatch to the user's real browser, with its profiles, its
    /// extensions and its password manager (ruled at C7.6's gate, 2026-09-09).
    ///
    /// It defaults to `true`, so every registrant written before this field keeps the pop-out it
    /// was written against. A target that declines is routed with **no** `prepare` at all rather
    /// than with one that does nothing: `prepare` is what makes the registry suspend between
    /// resolving a target and delivering to it, and a withdrawal landing in a suspension that
    /// exists for nothing costs an unrelated surviving target its delivery.
    public let popsOutForNewWindow: Bool
    public let handles: @Sendable (WorkspaceLink) -> Bool
    /// Receives the destination as well as the link, because C7's W5 is binding and says so:
    /// "a handler that receives the link and a `LinkDestination`". A handler given only the link
    /// cannot tell an in-panel open from a popped-out one, and destination-dependent delivery
    /// would be lost at integration even though C7's own pure tests passed.
    public let open: @MainActor @Sendable (WorkspaceLink, LinkDestination) async -> Void

    public init(tab: PanelTabID, specificity: Int, popsOutForNewWindow: Bool = true,
                handles: @escaping @Sendable (WorkspaceLink) -> Bool,
                open: @escaping @MainActor @Sendable (WorkspaceLink, LinkDestination) async -> Void) {
        self.tab = tab
        self.specificity = specificity
        self.popsOutForNewWindow = popsOutForNewWindow
        self.handles = handles
        self.open = open
    }
}

/// The one routing seam a panel holds. The host conforms to it and hands itself into every
/// `ChannelContext`; link opening is deliberately not a `PanelHost` member so a tab sees one
/// registry rather than two. The protocol is named `LinkRouterCapability` and not `LinkRouting`
/// because C7.2 owns a Workbench module called `LinkRouting`, and a panel target importing both
/// would see a module and a protocol competing for one name.
public protocol LinkRouterCapability: Sendable {
    func register(_ target: LinkTarget) async
    /// Drops every target registered for this tab. `PanelHost.unregister(_:)` calls it, so a
    /// target never outlives the tab that registered it and cannot deliver into one that is gone.
    func unregister(tab: PanelTabID) async
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async
}
