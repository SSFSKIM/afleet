// C7.5 spec Design §9 and §10: the tab X7's host registers, where the session is activated, and
// where the panel's two link targets live.
import Foundation
import SwiftUI
import AfleetCore
import LinkRouting
import PanelHostAPI

/// What the tab asks the app for when a link is delivered: the Files session the delivery belongs
/// in, and the selection that brings the panel forward.
///
/// It exists because X7 hands a tab a `ChannelContext` and no host, and both questions are the
/// host's to answer: which channel the window is on, and which session belongs to it. Resolving
/// them here rather than from whichever view rendered last is what makes a delivery land in the
/// channel the link names — see `linkTargets()`.
///
/// `AnyObject` so the tab can hold it weakly (the host owns the tab), `Sendable` so the target's
/// handler may carry it; a main-actor class satisfies both.
@MainActor
public protocol FilesTabHost: AnyObject, Sendable {
    /// The Files session the delivery belongs in, built if this is that channel's first visit.
    /// Nil when there is no such channel — the window is on none, or the window this delivery was
    /// prepared for is gone.
    ///
    /// **The destination is what names the channel**, which is why it is asked rather than
    /// assumed. `.currentPanel` belongs to the channel the window is showing; `.newWindow` belongs
    /// to the channel the host popped the tab out **for**, captured when the action was taken.
    /// Routing suspends twice between that pop-out and this call and the main actor is free
    /// throughout, so a resolution that re-read the current channel would open the file in one
    /// channel while the window it opened renders another.
    func filesSession(for destination: LinkDestination) -> FilesPanelSession?
    /// Brings the Files tab forward in the main panel.
    func selectFilesTab()
}

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

    /// The app, weakly. Bound at construction by whoever registers the tab; nil in a test that is
    /// about the tab alone, which is what the anchor below is still for.
    private let hosted = HostAnchor()
    /// The session the render path last drew — the fallback for a tab built with no host, and
    /// nothing a hosted delivery consults.
    private let presented = SessionAnchor()
    /// Whether the pair below has been registered. Once for the tab, not once per channel.
    private var hasRegistered = false

    /// `host` is what a delivered link is resolved through. A tab built without one falls back to
    /// the session the render path last drew, which is all a package test has.
    public init(host: (any FilesTabHost)? = nil) {
        if let host { hosted.bind(host) }
    }

    /// Available for every channel: a channel has a working directory, and that is the whole of
    /// what this tab needs.
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    /// Builds the session, records it as the one an unhosted delivery reaches, and **activates**
    /// it.
    ///
    /// `makeSession` is called once per (tab, channel) by the host, while `activate()` is `async`
    /// and `makeSession` is not, so the activation is spawned here. Doing it from the view instead
    /// would re-run it on every remount, because a channel switch unmounts and remounts the
    /// subtree while the host keeps this session.
    ///
    /// The link targets are registered here **only if nothing has registered them yet**, which for
    /// the app is never: `AppModel` registers them when it registers the tab, because a session is
    /// built lazily for rendering and a link raised before the first visit to Files must still
    /// resolve. This line is what a package test drives, and the flag is what keeps one pair.
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

    /// The surface is not read: this tab describes a view rather than owning one, so the same
    /// description is right in the panel and in a popped-out window (X7).
    public func makeView(session: any PanelTabSession, context: ChannelContext,
                         surface: PanelSurface) -> AnyView {
        guard let session = session as? FilesPanelSession else { return AnyView(EmptyView()) }
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
    /// nothing to pick wrongly between, and the delivery reaches the session the *host* resolves
    /// for the channel it is showing at the moment of delivery — which is right for the case links
    /// are actually created by, a click in the channel on screen. It is *wrong* for a link
    /// delivered on behalf of a channel that is not on screen: the link cannot name that channel,
    /// and the file opens in the one the window is on. Only the X7 amendment can fix that.
    ///
    /// **The resolution is the host's, not the render path's.** A view is made for the tab the
    /// column is drawing, so switching channels while another tab is selected renders no Files
    /// view at all and a pop-out renders one for its own channel: an anchor bound in `makeView`
    /// therefore names whichever channel was drawn last, which is not the channel a
    /// `.currentPanel` link belongs to. Asking the host is what removes the coupling, and the
    /// **destination goes with the question**, because a `.newWindow` delivery belongs to the
    /// channel its window was popped out for and not to the one the window has moved on to. The
    /// anchor stays as the answer for a tab built with no host, and for no other case: a host that
    /// answers nothing means nothing is opened.
    ///
    /// Both anchors are weak, for the reason the session anchor always was:
    /// `LinkRouterCapability` has no per-registration withdrawal, so a released session — or a
    /// released host — must leave an inert target rather than resurrect itself, and the router
    /// takes W5's fallback instead.
    func linkTargets() -> [LinkTarget] {
        let anchor = presented
        let host = hosted
        let handler: @MainActor @Sendable (WorkspaceLink, LinkDestination) async -> Void = {
            link, destination in
            // The destination decides two things: **which channel** this delivery belongs to,
            // which is the host's answer below, and whether the main panel's selection moves.
            // `.newWindow` has already had the tab popped out by the host before this runs, and
            // that window draws the very session resolved here, because the host retains one per
            // (tab, channel) — so the *open* is the same work either way, and moving the main
            // window's selection for a link that asked for a window of its own would be wrong (§9).
            // **With a host, the host's answer is the whole answer.** Nil means this delivery
            // has no channel to land in, and the session the render path drew last is a
            // *different* channel's — a pop-out's, or whichever channel Files was drawn for last —
            // so falling back to it would open the file somewhere the link never named and write
            // it there on the next save. The anchor answers only for a tab built with no host,
            // which is what a package test has.
            let resolved: FilesPanelSession?
            if let live = host.host() {
                resolved = live.filesSession(for: destination)
            } else {
                resolved = anchor.session()
            }
            guard let session = resolved else { return }
            if destination == .currentPanel { host.host()?.selectFilesTab() }
            await session.open(link, from: destination)
        }
        return [
            LinkTarget(tab: .files, specificity: FilesPanelSession.linkSpecificity,
                       handles: { link in
                           guard case .file = link else { return false }
                           return host.isAlive || anchor.isAlive
                       },
                       open: handler),
            LinkTarget(tab: .files, specificity: FilesPanelSession.linkSpecificity,
                       handles: { link in
                           guard case .diff = link else { return false }
                           return host.isAlive || anchor.isAlive
                       },
                       open: handler),
        ]
    }

    /// Registers the pair through `links`, once. What the app calls when it registers the tab, so
    /// the targets exist before anything renders Files.
    public func registerLinkTargets(through links: any LinkRouterCapability) async {
        guard !hasRegistered else { return }
        hasRegistered = true
        for target in linkTargets() { await links.register(target) }
    }

    /// The same registration for a tab with no host, naming the session an unhosted delivery
    /// reaches. The seam the package's own tests drive.
    func registerLinkTargets(through links: any LinkRouterCapability,
                             presenting session: FilesPanelSession) async {
        presented.bind(session)
        await registerLinkTargets(through: links)
    }

    /// Makes `session`'s channel the one an unhosted delivery opens in.
    func present(_ session: FilesPanelSession) {
        presented.bind(session)
    }
}

/// A weak, `Sendable` hold on the app, so a target's handler can ask it something without the tab
/// — which the app owns, through the host — keeping it alive. The session anchor's shape, for the
/// same reason.
final class HostAnchor: Sendable {
    private nonisolated(unsafe) weak var held: (any FilesTabHost)?
    private let lock = NSLock()

    func bind(_ host: any FilesTabHost) {
        lock.lock()
        defer { lock.unlock() }
        held = host
    }

    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held != nil
    }

    @MainActor func host() -> (any FilesTabHost)? {
        lock.lock()
        defer { lock.unlock() }
        return held
    }
}
