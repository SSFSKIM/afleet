// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §2, §7, §11: the tab X7's host registers, and where the panel's one link target lives.
import Foundation
import SwiftUI
import AfleetCore
import PanelHostAPI

/// What the tab asks the app for when a `.commit` link is delivered: the Source Control session
/// the delivery belongs in, and the selection that brings the panel forward.
///
/// It exists because X7 hands a tab a `ChannelContext` and no host, and both questions are the
/// host's to answer: which channel the window is on, and which session belongs to it. Resolving
/// them here rather than from whichever view rendered last is what makes a delivery land in the
/// channel the link names — see `linkTargets()`.
///
/// `AnyObject` so the tab can hold it weakly (the host owns the tab), `Sendable` so the target's
/// handler may carry it; a main-actor class satisfies both.
@MainActor public protocol SourceControlTabHost: AnyObject, Sendable {
    /// The session the delivery belongs in, built if this is that channel's first visit. Nil when
    /// there is no such channel — the window is on none, or the window this delivery was prepared
    /// for is gone.
    ///
    /// **The destination is what names the channel**, which is why it is asked rather than
    /// assumed. `.currentPanel` belongs to the channel the window is showing; `.newWindow` belongs
    /// to the channel the host popped the tab out **for**, captured when the action was taken.
    /// Routing suspends between that pop-out and this call and the main actor is free throughout,
    /// so a resolution that re-read the current channel would select a commit in one channel while
    /// the window it opened renders another.
    func sourceControlSession(for destination: LinkDestination) -> SourceControlModel?
    /// Brings the Source Control tab forward in the main panel.
    func selectSourceControlTab()
}

/// The Source Control tab (Design §2).
///
/// Everything the panel remembers lives on the `SourceControlModel` the host retains per
/// (tab, channel); the views T7 writes hold only what SwiftUI may discard without loss.
@MainActor
public final class SourceControlTab: PanelTab {

    /// W5's row for this leaf: `.commit` is claimed at 100, the specificity C7.5's Files targets
    /// take, because a panel that owns a kind outright claims it outright.
    public static let linkSpecificity = 100

    public let id: PanelTabID = .sourceControl
    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    /// The app, weakly. Bound at construction by whoever registers the tab; nil in a test that is
    /// about the tab alone, which is what the anchor below is still for.
    private let hosted = HostAnchor()
    /// The session the render path last drew — the fallback for a tab built with no host, and
    /// nothing a hosted delivery consults.
    private let presented = SessionAnchor()
    /// Whether the target below has been registered. Once for the tab, not once per channel.
    private var hasRegistered = false

    /// `host` is what a delivered link is resolved through. A tab built without one falls back to
    /// the session the render path last drew, which is all a package test has.
    public init(host: (any SourceControlTabHost)? = nil) {
        if let host { hosted.bind(host) }
    }

    /// Available for every channel, including one whose folder is in no repository — which renders
    /// the empty state. Availability is what X7's Cmd+1…7 indexes over, and a tab that came and
    /// went would renumber the shortcuts under the user (Design §11).
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    /// Builds the session, records it as the one an unhosted delivery reaches, and **activates**
    /// it.
    ///
    /// `makeSession` is called once per (tab, channel) by the host, while `activate()` is `async`
    /// and `makeSession` is not, so the read is spawned here. Doing it from the view instead would
    /// re-run it on every remount, because a channel switch unmounts and remounts the subtree
    /// while the host keeps this session.
    ///
    /// The target is registered here **only if nothing has registered it yet**, which for the app
    /// is never: T8 registers it when it registers the tab, because a session is built lazily for
    /// rendering and a `.commit` link raised before the first visit must still resolve. This line
    /// is what a package test drives, and the flag is what keeps one registration.
    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        let session = SourceControlModel(context: context)
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

    /// The surface is taken and named — X7 gives it no default — and not read: this tab describes
    /// a view rather than owning one, so the same description is right in the panel and in a
    /// popped-out window (Design §11).
    public func makeView(session: any PanelTabSession, context: ChannelContext,
                         surface: PanelSurface) -> AnyView {
        guard let view = panelView(session: session, surface: surface) else {
            return AnyView(EmptyView())
        }
        return AnyView(view)
    }

    /// The same view, before it is erased. `makeView` has to answer `AnyView`, and an `AnyView` is
    /// not a thing a test can ask what it was made of — which is the seam C7.6's `BrowserTab`
    /// established and the mistake it exists to prevent.
    func panelView(session: any PanelTabSession, surface: PanelSurface)
        -> SourceControlPanelView? {
        guard let session = session as? SourceControlModel else { return nil }
        presented.bind(session)
        return SourceControlPanelView(session: session)
    }

    // MARK: - the `.commit` target (Design §7)

    /// Registers `.commit` for `tab: .sourceControl`, **once for the tab**.
    ///
    /// Design §7 could have put this on the session, one per channel. That is unroutable: every
    /// registration would carry the same tab at the same specificity, and `LinkRouter.mostSpecific`
    /// compares specificity and canonical tab order and nothing else — so a link could be delivered
    /// to a retained session for a channel nobody was looking at, which would then select a commit
    /// and read a diff in it. The proper fix is X7 carrying the originating channel, filed as
    /// tracker 240 and recorded the same way by C7.5.
    ///
    /// **What this mitigation covers, and what it does not.** One registration exists, so the
    /// router has nothing to pick wrongly between, and the delivery reaches the session the *host*
    /// resolves for the channel it is showing at the moment of delivery — which is right for the
    /// case links are actually created by, a click in the channel on screen. It is *wrong* for a
    /// link delivered on behalf of a channel that is not on screen: the link cannot name that
    /// channel, and the commit is selected in the one the window is on. Only the X7 amendment can
    /// fix that; this is its mitigation and not its fix.
    ///
    /// **The resolution is the host's, not the render path's.** A view is made for the tab the
    /// column is drawing, so switching channels while another tab is selected renders no Source
    /// Control view at all and a pop-out renders one for its own channel: an anchor bound in
    /// `makeView` therefore names whichever channel was drawn last, which is not the channel a
    /// `.currentPanel` link belongs to. The **destination goes with the question**, because a
    /// `.newWindow` delivery belongs to the channel its window was popped out for. The anchor stays
    /// as the answer for a tab built with no host, and for no other case.
    ///
    /// Both anchors are weak, because `LinkRouterCapability` has no per-registration withdrawal:
    /// a released session — or a released host — must leave an **inert** target rather than
    /// resurrect itself, and the router takes W5's fallback instead.
    ///
    /// `popsOutForNewWindow` is X7's default. The Browser's declination is about *leaving the app*,
    /// and nothing here does: a `.commit` delivered `.newWindow` is this panel in a window of its
    /// own (Design §6, §7).
    func linkTargets() -> [LinkTarget] {
        let anchor = presented
        let host = hosted
        return [
            LinkTarget(tab: .sourceControl, specificity: Self.linkSpecificity,
                       handles: { link in
                           guard case .commit = link else { return false }
                           return host.isAlive || anchor.isAlive
                       },
                       open: { link, destination in
                           guard case .commit(let hash) = link else { return }
                           // **With a host, the host's answer is the whole answer.** Nil means this
                           // delivery has no channel to land in, and the session the render path
                           // drew last is a *different* channel's — a pop-out's, or whichever
                           // channel this tab was drawn for last — so falling back to it would
                           // select a commit somewhere the link never named.
                           let resolved: SourceControlModel?
                           if let live = host.host() {
                               resolved = live.sourceControlSession(for: destination)
                           } else {
                               resolved = anchor.session()
                           }
                           guard let session = resolved else { return }
                           // `.newWindow` has already had the tab popped out by the host before
                           // this runs, and that window draws the very session resolved here, so
                           // the selection is the same work either way; moving the main window's
                           // selection for a link that asked for a window of its own would be
                           // wrong.
                           if destination == .currentPanel { host.host()?.selectSourceControlTab() }
                           await session.select(commit: hash)
                       }),
        ]
    }

    /// Registers the target through `links`, once. What T8 calls when it registers the tab, so the
    /// target exists before anything renders this panel.
    public func registerLinkTargets(through links: any LinkRouterCapability) async {
        guard !hasRegistered else { return }
        hasRegistered = true
        for target in linkTargets() { await links.register(target) }
    }

    /// The same registration for a tab with no host, naming the session an unhosted delivery
    /// reaches. The seam this package's own tests drive.
    func registerLinkTargets(through links: any LinkRouterCapability,
                             presenting session: SourceControlModel) async {
        presented.bind(session)
        await registerLinkTargets(through: links)
    }

    /// Makes `session`'s channel the one an unhosted delivery selects in.
    func present(_ session: SourceControlModel) { presented.bind(session) }
}

/// A weak, `Sendable` hold on the app, so a target's handler can ask it something without the tab
/// — which the app owns, through the host — keeping it alive. The session anchor below has the
/// same shape for the same reason.
final class HostAnchor: Sendable {
    private nonisolated(unsafe) weak var held: (any SourceControlTabHost)?
    private let lock = NSLock()

    func bind(_ host: any SourceControlTabHost) {
        lock.lock(); defer { lock.unlock() }
        held = host
    }

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil
    }

    @MainActor func host() -> (any SourceControlTabHost)? {
        lock.lock(); defer { lock.unlock() }
        return held
    }
}

/// A weak hold on the session an unhosted delivery reaches. Weak because a released session must
/// leave an inert target rather than be resurrected by one (tracker 240's mitigation, not its fix).
final class SessionAnchor: Sendable {
    private nonisolated(unsafe) weak var held: SourceControlModel?
    private let lock = NSLock()

    func bind(_ session: SourceControlModel) {
        lock.lock(); defer { lock.unlock() }
        held = session
    }

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return held != nil
    }

    @MainActor func session() -> SourceControlModel? {
        lock.lock(); defer { lock.unlock() }
        return held
    }
}
