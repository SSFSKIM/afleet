import Foundation
import AfleetCore
import PanelHostAPI
import Workbench

/// The app's target for `WorkspaceLink.command` — C7's Parent-Level Acceptance item 3, "`.command`
/// to the composer through C6's registered target".
///
/// **A command link is a request to run a command in a channel, so it is delivered to that channel's
/// composer and to nothing else.** The composer is the one place a command is dispatched (contract
/// X10) and the one place that knows what a `.native` destination means; a target that opened a
/// surface itself would be a second answer to a question `RouterTable` already answers, and it would
/// answer it for whichever channel happened to be selected when the delivery landed.
///
/// **The channel is the link's origin and never the current selection.** `LinkOrigin.channel` is the
/// capture `HostLinkRouter` takes at entry, for exactly this: routing suspends twice on the way here,
/// and the window can move to another channel while one link is in flight. A delivery with no origin
/// is reported rather than run somewhere — running a command in a channel the user was not acting in
/// is worse than not running it.
///
/// Registered against `.thread`, which is the tab the conversation surface owns: a target is dropped
/// with the tab that registered it (X7's `unregister(tab:)`), and this one's lifetime is the Thread
/// tab's — the composer it delivers to is the one drawn beside that tab.
@MainActor
enum CommandLinkTarget {

    /// The registration. `composers` is the app's one registry and is captured weakly: the target
    /// lives on the link registry's actor, which outlives no window but is not the registry's owner.
    ///
    /// The specificity is the same 1 the panels' own targets use — nothing else claims `.command`, so
    /// there is no tie to break, and a higher number would be a claim about a competition that does
    /// not exist.
    static func target(composers: ComposerRegistry,
                       diagnostic: @escaping @Sendable (String) -> Void = LinkRouter.logDiagnostic) -> LinkTarget {
        LinkTarget(tab: .thread,
                   specificity: 1,
                   handles: { link in
                       if case .command = link { true } else { false }
                   },
                   open: { [weak composers] link, _ in
                       guard case .command(let surface) = link else { return }
                       // Named without the channel, the session or the command's own argument (§11):
                       // a `.native` destination is a table constant, but a command link is a string
                       // from wherever it was raised, and a log line is not the place to find out.
                       guard let channel = LinkOrigin.channel else {
                           return diagnostic("a command link had no channel to run in")
                       }
                       guard let composer = composers?.model(for: channel) else {
                           // Before a launch has reached a workspace there is no lifecycle to build a
                           // composer over, so there is nothing to run the command with. The
                           // diagnostic is what stood here before any target claimed the link at all,
                           // and it stays for that one case rather than the link disappearing.
                           return diagnostic("a command link reached a channel with no composer")
                       }
                       composer.present(native: surface)
                   })
    }
}
