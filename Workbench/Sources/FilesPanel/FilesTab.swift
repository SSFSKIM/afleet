// C7.5 spec Design §9 and §10: the tab X7's host registers, where the session is activated, and
// where the panel's two link targets live.
import Foundation
import SwiftUI
import AfleetCore
import LinkRouting
import PanelHostAPI

/// The Files tab.
///
/// `.files` is held by nothing, so the app registers this with a plain `register` rather than
/// X7's unregister-then-register handover. Everything the panel remembers lives on the
/// `FilesPanelSession` the host retains per (tab, channel); the views below hold only what SwiftUI
/// may discard without loss — which row is expanded, and the `NSView` a representable made.
@MainActor
public final class FilesTab: PanelTab {

    public let id: PanelTabID = .files
    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    /// The session a delivered link is routed to: the one whose channel the panel is presenting.
    /// Weakly held, so a session the host's LRU released leaves the targets inert.
    private let presented = SessionAnchor()
    /// Whether the pair below has been registered. Once for the tab, not once per channel.
    private var hasRegistered = false

    public init() {}

    /// Available for every channel: a channel has a working directory, and that is the whole of
    /// what this tab needs.
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    /// Builds the session, makes it the one links are routed to, and **activates** it.
    ///
    /// `makeSession` is called once per (tab, channel) by the host, while `activate()` is `async`
    /// and `makeSession` is not, so the activation is spawned here. Doing it from the view instead
    /// would re-run it on every remount, because a channel switch unmounts and remounts the
    /// subtree while the host keeps this session.
    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        let session = FilesPanelSession(context: context)
        presented.bind(session)
        let links = context.links
        let targets = hasRegistered ? [] : linkTargets()
        hasRegistered = true
        Task {
            for target in targets { await links.register(target) }
            await session.activate()
        }
        return session
    }

    public func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let session = session as? FilesPanelSession else { return AnyView(EmptyView()) }
        // The host calls this for the channel it is about to draw, which is what "the channel the
        // panel is presenting" means for the routing below.
        presented.bind(session)
        return AnyView(FilesPanelView(session: session))
    }

    // MARK: - The link targets (Design §9)

    /// Registers `.file` and `.diff` for `tab: .files`, **once for the tab**.
    ///
    /// Design §9 put this on the session, one pair per channel. That is unroutable: every pair
    /// carries the same tab at the same specificity, and `LinkRouter.mostSpecific` compares
    /// specificity and canonical tab order and nothing else — so a link could be delivered to a
    /// retained session for a channel nobody was looking at, which then *wrote* that channel's
    /// file on the next save. The proper fix is X7 carrying the originating channel, filed as this
    /// leaf's Parent revision 4 and tracker 240.
    ///
    /// **What this mitigation covers, and what it does not.** One pair exists, so the router has
    /// nothing to pick wrongly between, and the delivery reaches the session for the channel the
    /// panel is presenting — which is right for the case links are actually created by, a click in
    /// the channel on screen. It is *wrong* for a link delivered on behalf of a channel that is
    /// not on screen: the panel has no way to name that channel, and the file opens in the one it
    /// is showing. Only the X7 amendment can fix that.
    ///
    /// The anchor holds the session weakly for the reason it always did: `LinkRouterCapability`
    /// has no per-registration withdrawal, so a released session must leave an inert target
    /// rather than resurrect itself, and the router takes W5's fallback instead.
    func linkTargets() -> [LinkTarget] {
        let anchor = presented
        let handler: @MainActor @Sendable (WorkspaceLink, LinkDestination) async -> Void = {
            link, destination in
            // The destination is received and deliberately not branched on: the host has already
            // popped the tab out for `.newWindow` before the handler runs, and a popped-out window
            // draws the same session, because the host retains one per (tab, channel). Recorded
            // here so a later reader does not read the absence of a branch as a dropped case (§9).
            await anchor.session()?.open(link, from: destination)
        }
        return [
            LinkTarget(tab: .files, specificity: FilesPanelSession.linkSpecificity,
                       handles: { link in
                           guard case .file = link else { return false }
                           return anchor.isAlive
                       },
                       open: handler),
            LinkTarget(tab: .files, specificity: FilesPanelSession.linkSpecificity,
                       handles: { link in
                           guard case .diff = link else { return false }
                           return anchor.isAlive
                       },
                       open: handler),
        ]
    }

    /// Registers the pair through `links` and routes deliveries to `session`. The seam the tests
    /// drive, and what `makeSession` does on the host's behalf.
    func registerLinkTargets(through links: any LinkRouterCapability,
                             presenting session: FilesPanelSession) async {
        presented.bind(session)
        guard !hasRegistered else { return }
        hasRegistered = true
        for target in linkTargets() { await links.register(target) }
    }

    /// Makes `session`'s channel the one a delivered link opens in.
    func present(_ session: FilesPanelSession) {
        presented.bind(session)
    }
}
