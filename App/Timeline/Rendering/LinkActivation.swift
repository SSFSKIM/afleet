import AppKit
import PanelHostAPI

// MARK: - What the modifier keys mean at the moment a link is activated

/// Which `LinkDestination` a click on a link in the timeline is (spec §9.6, contract X7): plain
/// opens in the channel's panel, Command opens a new window.
///
/// **It is read at activation and never carried on the link.** A row's tap gesture is not handed the
/// event that caused it, and the destination is a property of the *gesture* rather than of the item:
/// the same path clicked twice is two different requests. `NSApp.currentEvent` is the event being
/// dispatched at the moment the gesture's action runs, which is precisely the click, so the modifier
/// state read here is the one the user was holding — not the state whenever the row was built.
///
/// The rest of the rule is the router's and is not restated here: `.newWindow` pops the target's tab
/// out before delivery, except for a target that declines the pop-out because it answers by leaving
/// the app — the Browser's `.url` and `.pullRequest` (X7's `LinkTarget.popsOutForNewWindow`). So a
/// Cmd-clicked markdown URL reaches the user's own browser through the same one line below.
@MainActor
enum LinkActivation {

    /// Where the modifier state comes from. A seam, because the alternative is a test that posts a
    /// synthetic `NSEvent` into the dispatch queue and asserts the scheduler's habits rather than
    /// this rule; the production reading is the default and nothing in the app replaces it.
    static var modifiers: () -> NSEvent.ModifierFlags = { NSApp?.currentEvent?.modifierFlags ?? [] }

    /// The destination the click in flight asks for.
    ///
    /// Command alone and Command with anything else both mean a new window: the other modifiers
    /// carry no meaning for a link, and requiring Command *exactly* would drop the gesture for a
    /// user whose Caps Lock happens to be on.
    static var destination: LinkDestination {
        modifiers().contains(.command) ? .newWindow : .currentPanel
    }
}
