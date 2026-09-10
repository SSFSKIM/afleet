import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// The *New channel* sheet's state and its one action (spec §8.2, §14 items 3 and 47).
///
/// It lives beside `FleetBrowserModel` rather than in `App/Views/` because everything it decides is
/// about the fleet — which directory the channel runs in, whether a worktree is asked for, whether
/// the launch may spawn at all — and none of it is about layout. The sheet reads it and decides
/// nothing.
///
/// **It creates through the composition root's seam and spawns through X5, never both at once.**
/// `Fleet.create` files a supervisor and no process; the spawn that follows is `perform(.open)` and
/// it happens **only** when the precondition verdict is `.ready`. An untrusted project or a pending
/// `.mcp.json` consent therefore leaves the channel created, selected and processless, with
/// `ChannelDecorations` drawing the banner or the sheet §6.11 and §6.12 call for — which is the
/// first half of item 47.
@MainActor
@Observable
final class NewChannelModel {

    /// The project directory the sheet was opened over, or nil for the global entry, where the user
    /// picks a directory that may never have been opened in Claude Code at all.
    let root: URL?

    /// The Developer setting *Isolated settings for new channels*, read from the store when this
    /// model was built. Displayed, and passed into the request: the sheet says whether the channel
    /// it is about to make will carry `--setting-sources ""`, because that changes which rules can
    /// pre-approve a tool and the user cannot see it anywhere else.
    let isolatedSettings: Bool

    /// The directory the global entry's chooser returned. Unused in the section case.
    var chosenDirectory: URL?

    var wantsWorktree = false
    var worktreeName = ""
    var model = ""
    var permissionMode: PermissionMode = .default
    var effort = ""
    var agent = ""
    var sessionName = ""

    /// True between *Create* and the answer. Every affordance disables on it, so one press is one
    /// channel — the same rule `PrecommitModel.isAnswering` holds for the consent sheet's answers.
    private(set) var isCreating = false

    /// Why the last press did not make a channel. A shape, never a path (§11).
    private(set) var failure: String?

    private let browser: FleetBrowserModel
    private let lifecycle: any LifecycleAPI
    private let shell: ShellModel
    private let create: (ChannelCreation) async -> ChannelKey?

    init(root: URL?, isolatedSettings: Bool, browser: FleetBrowserModel,
         lifecycle: any LifecycleAPI, shell: ShellModel,
         create: @escaping (ChannelCreation) async -> ChannelKey?) {
        self.root = root
        self.isolatedSettings = isolatedSettings
        self.browser = browser
        self.lifecycle = lifecycle
        self.shell = shell
        self.create = create
    }

    // MARK: - What the sheet offers

    /// The directory the channel will be created in: the section's root, or the one the chooser
    /// returned. Nil in the global case until the user has picked one.
    var cwd: URL? { root ?? chosenDirectory }

    /// Whether the sheet's own case needs a directory chooser. The section case does not: its root
    /// is the section the user pressed the item on, and offering to change it would let a channel
    /// be made in a project other than the one whose header was clicked.
    var offersDirectoryChooser: Bool { root == nil }

    /// The permission modes offered. `bypassPermissions` is absent for the reason §8.6 puts it
    /// behind a disclaimer and a quiescent restart, and this list is the composer's own
    /// (`ComposerModel.cyclablePermissionModes`) rather than a second copy of the rule.
    var permissionModes: [PermissionMode] { ComposerModel.cyclablePermissionModes }

    var canCreate: Bool {
        guard !isCreating, cwd != nil else { return false }
        return !wantsWorktree || !Self.trimmed(worktreeName).isEmpty
    }

    /// The request the sheet's fields describe, or nil when it does not yet describe one.
    ///
    /// Every optional field is nil when blank rather than an empty string: `LaunchConfiguration`
    /// emits `--model`, `--agent`, `--effort` and `-n` exactly when their value is non-nil, and an
    /// empty token would reach the CLI as an option with a missing value.
    var request: ChannelCreation? {
        guard let cwd else { return nil }
        let worktree = Self.trimmed(worktreeName)
        return ChannelCreation(cwd: cwd,
                               worktree: wantsWorktree && !worktree.isEmpty ? .named(worktree) : nil,
                               model: Self.value(model),
                               permissionMode: permissionMode,
                               effort: Self.value(effort),
                               agent: Self.value(agent),
                               name: Self.value(sessionName),
                               isolatedSettings: isolatedSettings)
    }

    // MARK: - Confirm

    /// *Create*: mint the channel, show it, and spawn only if nothing is in the way.
    ///
    /// Answers whether the sheet should close. It closes on a created channel whatever the verdict
    /// was — the channel exists, the window is on it, and the banner or the consent sheet the
    /// verdict calls for belongs to the column and not to this modal — and stays up on a refusal
    /// with the reason on it.
    ///
    /// The spawn goes through `FleetBrowserModel.perform`, which is the same call the sidebar's own
    /// actions take, so a refusal reads as a banner on the row that asked and never as an error
    /// travelling into a channel (§10).
    @discardableResult
    func confirm() async -> Bool {
        guard let request, !isCreating else { return false }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        guard let key = await create(request) else {
            failure = "afleet could not create a channel: the workspace has no fleet."
            return false
        }
        // Selected before the verdict is read, so the column is already mounted when the trust
        // banner or the consent sheet appears — both are drawn around the channel's own column.
        shell.select(key.session)
        let verdict = await lifecycle.preconditions(for: key)
        guard verdict == .ready, let row = browser.row(key.session) else { return true }
        await browser.perform(.open, on: row)
        return true
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(_ text: String) -> String? {
        let trimmed = Self.trimmed(text)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One press of a *New channel…* item, held above the window because the global entry is declared
/// in the scene's `commands` and cannot reach a view's `@State`.
///
/// `id` is a sequence number, for the reason `ShellModel.PendingPanelIndex` carries one: two presses
/// of one item are two events, and `.sheet(item:)` takes a superseded sheet down only when the new
/// item is a different value.
struct NewChannelRequest: Identifiable, Hashable, Sendable {
    let id: Int
    /// The project section's root, or nil for the global entry, which chooses its own directory.
    let root: URL?
}
