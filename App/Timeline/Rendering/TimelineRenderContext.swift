import SwiftUI
import FleetKit
import PanelHostAPI

// MARK: - Collapse state

/// Which clusters and thinking blocks a channel has folded shut.
///
/// A reference type, and shared by every row of one channel, because folding is a property of the
/// *channel's* view state and not of the row that happens to draw the disclosure: a cluster folded
/// while it is off screen has to still be folded when it scrolls back, and the row value that drew
/// it has been discarded twenty times over by then.
///
/// Keyed by `ItemID.key` and never by the `ItemID` itself: the id carries the config home (§11), and
/// a set of them is a set of paths waiting for the first diagnostic that prints it.
@MainActor
@Observable
final class TimelineCollapseState {

    private var collapsedKeys: Set<String> = []

    func isCollapsed(_ id: ItemID) -> Bool { collapsedKeys.contains(id.key) }

    func toggle(_ id: ItemID) {
        if collapsedKeys.remove(id.key) == nil { collapsedKeys.insert(id.key) }
    }
}

// MARK: - The context

/// Everything a row needs that is not its item (child spec §2, §3).
///
/// **It is an environment value and not a second builder parameter.** Contract Y1's builder is
/// `@MainActor (TimelineRow) -> AnyView`, four leaves build against that signature, and C6.3 is
/// writing two of the thirteen builders in a parallel worktree right now. A new parameter would be
/// a signature change in a file two leaves both compile; a new field on a value they already
/// receive is not.
struct TimelineRenderContext {

    /// The channel these rows belong to. Rows carry it into every capability call, so a link opened
    /// from a row is attributed to the channel it was opened from and not to whatever is selected.
    let key: ChannelKey

    /// Where a file link from a tool row goes.
    ///
    /// **`PanelHostModel.links`, which is a plain `let`, and never `context(for:cwd:)`.** That
    /// method mutates the host to make a channel context, and calling it from inside a SwiftUI
    /// `body` mutates observed state during evaluation — tracker 67, and a row evaluates its body
    /// thirty times a second while a message streams.
    let links: any LinkRouterCapability

    /// Where an `Agent` chip goes — contract Y4's seam, a no-op until C6.4 fills it.
    let agents: any AgentNavigating

    /// Which clusters and thinking blocks this channel has folded.
    let collapse: TimelineCollapseState

    /// `get_settings`' auto-scroll preference. Task 6 lands the readout that sets it; until then a
    /// channel follows its stream, which is what the engine's own renderer does.
    var autoScrollEnabled: Bool = true
}

// MARK: - The environment value

private struct TimelineRenderContextKey: EnvironmentKey {
    /// Computed rather than stored: a stored default would be a non-`Sendable` global, and the
    /// answer for a subtree nobody injected into is "no context" rather than an invented one.
    static var defaultValue: TimelineRenderContext? { nil }
}

extension EnvironmentValues {
    /// The render context on the timeline's subtree. Nil outside it — a row drawn by a preview or a
    /// test that injected nothing draws without capabilities rather than trapping.
    var timelineContext: TimelineRenderContext? {
        get { self[TimelineRenderContextKey.self] }
        set { self[TimelineRenderContextKey.self] = newValue }
    }
}
