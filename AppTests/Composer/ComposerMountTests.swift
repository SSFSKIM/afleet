import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.2 Task 2: the two call sites, and the three keys C5 left undeclared for this leaf.
///
/// The mount assertions run over a **launched** `AppModel`, because the two edits are inside a view
/// `ChannelColumnView` builds only when the browser has a row and the shell is focused on it. A test
/// that constructed the inner view directly could not fail on a call site that was never added,
/// which is the whole question.
///
/// Nothing here compares an aggregate reaching a `ChannelKey`, a `ChannelContext` or an
/// `IndexEntry` (§11): the answers are type names, subtypes, counts and booleans.
@MainActor
final class ComposerMountTests: XCTestCase {

    // MARK: - The launch this leaf mounts into

    private struct Rig {
        let temp: TempTree
        let configHome: URL
        let fleet: LifecycleDouble
        let sequence: LaunchSequence
    }

    /// A launch that reaches a workspace with exactly one listed channel. Everything is invented and
    /// every path is under the process's temporary directory (X9).
    private func makeRig(sessions: [SessionID] = [LaunchFixtures.sessionA],
                         teammates: Set<SessionID> = []) throws -> Rig {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        for session in sessions {
            try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: session)
        }
        let fleet = LifecycleDouble()
        let index = StubIndex(persisted: nil,
                              built: LaunchFixtures.snapshot(configHome: configHome, ids: sessions,
                                                             teammates: teammates),
                              delta: IndexDelta(added: sessions))
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in index },
            fleetFactory: { _, _, _, _, _, _ in fleet },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })

        return Rig(temp: temp, configHome: configHome, fleet: fleet, sequence: sequence)
    }

    /// The column as the window draws it, with the one channel selected.
    private func makeColumn(_ rig: Rig,
                            selecting session: SessionID = LaunchFixtures.sessionA)
    async throws -> (app: AppModel, column: ChannelColumnView) {
        let app = AppModel(registry: RowRegistry(), sequence: rig.sequence)
        await app.launch()
        let workspace = try XCTUnwrap(app.route.workspace, "the launch reached no workspace to draw")
        app.shell.select(session)
        // A boolean, not the row: a `ChannelRow` reaches an `IndexEntry` and would print every
        // field of it on failure (§11).
        XCTAssertTrue(app.browser?.row(session) != nil,
                      "the launch painted no channel row, so the column would draw its placeholder")
        return (app, ChannelColumnView(app: app, shell: app.shell, workspace: workspace))
    }

    /// The inner per-channel view, which is `private` to `ChannelColumnView.swift` and so is reached
    /// by opening the body rather than by naming the type.
    private func channelBody(of column: ChannelColumnView) throws -> Any {
        let inner = try XCTUnwrap(ComposerViewTree.view(named: "ChannelTimelineColumn", in: column.body),
                                  "the column drew no per-channel view, so there is no call site to assert on")
        return ComposerViewTree.body(of: inner)
    }

    // MARK: - The mount (plan Task 2, deliverable 1)

    /// The header's action slot is **above** the list and the composer is **below** it.
    ///
    /// Order, not membership: a set assertion would pass on a composer mounted at the top of the
    /// column, which is the arrangement the two call sites exist to rule out.
    func testTheColumnMountsTheHeaderSlotAboveTheListAndTheComposerBelowIt() async throws {
        let rig = try makeRig()
        let (_, column) = try await makeColumn(rig)

        // The list is drawn as a `List` when the channel has rows and as `PlaceholderColumn` when it
        // has none; this launch reads a transcript with no rows yet, so either may be the landmark.
        let landmarks: Set<String> = ["ChannelHeaderActionsSlot", "List", "PlaceholderColumn",
                                      "ChannelComposerMount"]
        let order = ComposerViewTree.order(of: landmarks, in: try channelBody(of: column))

        guard let slot = order.firstIndex(of: "ChannelHeaderActionsSlot") else {
            return XCTFail("the column mounts no header action slot; it drew \(order.count) landmark(s)")
        }
        guard let composer = order.lastIndex(of: "ChannelComposerMount") else {
            return XCTFail("the column mounts no composer; it drew \(order.count) landmark(s)")
        }
        guard let list = order.firstIndex(where: { $0 == "List" || $0 == "PlaceholderColumn" }) else {
            return XCTFail("the column drew neither a list nor a placeholder to mount around")
        }
        XCTAssertTrue(slot < list, "the header's action slot is drawn after the list, not above it")
        XCTAssertTrue(list < composer, "the composer is drawn before the list, not below it")
    }

    /// The mounted field's send action reaches the lifecycle.
    ///
    /// The whole chain is walked — column, per-channel view, mount, `ComposerView`, `ComposerField` —
    /// and the closure fired is the one `ComposerField.SendingTextView.keyDown` calls on Return. The
    /// registry is seeded through its own production member, so nothing test-only is on the path.
    func testTheMountedFieldsSendActionReachesTheLifecycle() async throws {
        let rig = try makeRig()
        let key = ChannelKey(configHome: LaunchFixtures.directoryURL(rig.configHome),
                             session: LaunchFixtures.sessionA)
        let double = ComposerLifecycleDouble()
        await double.alwaysSendPrompt(.success(UUID()))

        let (app, column) = try await makeColumn(rig)
        // The registry is the app's own, bound by `bindWorkspace` during the launch above; the
        // double replaces the lifecycle it was bound to, which is the seam
        // `ChannelTimelineRegistry` already carries for the same reason.
        app.composers.lifecycle = double
        let model = try XCTUnwrap(app.composers.model(for: key),
                                  "the registry built no composer for a channel with a lifecycle")
        model.draft = "an invented line"
        let mount = try XCTUnwrap(ComposerViewTree.view(named: "ChannelComposerMount",
                                                        in: try channelBody(of: column)),
                                  "the column mounts no composer")
        let composer = try XCTUnwrap(ComposerViewTree.view(named: "ComposerView",
                                                           in: ComposerViewTree.body(of: mount)),
                                     "the mount drew no composer for a channel the registry holds one for")
        let field = try XCTUnwrap(ComposerViewTree.view(named: "ComposerField",
                                                        in: ComposerViewTree.body(of: composer)),
                                  "the composer drew no field")

        XCTAssertTrue(ComposerViewTree.fireSend(of: field), "the mounted field carried no send action")
        // Counted as prompts and not as calls: drawing the mount also subscribes this channel's
        // composer to `events(of:)`, which is a call on the same log and not a send.
        let sent = await settle(double) { $0 >= 1 }
        XCTAssertEqual(sent, 1, "the field's send action sent \(sent) prompt(s)")
        let prompts = await double.prompts
        guard let input = prompts.first else {
            return XCTFail("the field's send action reached a lifecycle member that is not `sendPrompt`")
        }
        XCTAssertEqual(input.text, "an invented line",
                       "the field sent \(input.text.count) character(s), not the 16 in the draft")
    }

    // MARK: - Esc (plan Task 2, deliverable 2)

    /// Esc is one interrupt control request and **no** lifecycle action.
    ///
    /// It goes out through `route`, so the mapping from `/stop` to `interrupt` stays C4's table's
    /// (X10). The `route` call is asserted for that reason: a composer that built an `Interrupt`
    /// itself would reach the same subtype with a shorter member sequence and would pass without it.
    func testEscapeIssuesOneInterruptRequestAndNoLifecycleAction() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)

        await model.interrupt()

        let members = await double.memberSequence
        XCTAssertEqual(members, ["route", "send"],
                       "Esc reached \(members.count) member(s): \(members.joined(separator: ", "))")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["interrupt"],
                       "Esc sent \(subtypes.count) request(s): \(subtypes.joined(separator: ", "))")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 0, "Esc performed \(actions.count) lifecycle action(s)")
        XCTAssertNil(model.refusal, "Esc raised an inline refusal")
    }

    // MARK: - Shift+Tab

    /// Shift+Tab sends `set_permission_mode` once per press and the cycle wraps.
    ///
    /// The expected sequence is derived from `ComposerModel.cyclablePermissionModes` rather than
    /// written out, so a mode added to `PermissionMode` cannot leave this asserting a stale list.
    /// `bypassPermissions` is asserted absent: §8.6 puts it behind a disclaimer and a quiescent
    /// restart, and a key that could land on it by being pressed once too often walks past the gate.
    func testShiftTabSendsEachPermissionModeInTurnAndWraps() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let modes = ComposerModel.cyclablePermissionModes
        XCTAssertGreaterThan(modes.count, 1, "the cycle offers \(modes.count) mode(s), so wrapping is not observable")
        XCTAssertFalse(modes.contains(.bypassPermissions), "the cycle offers the bypass mode")

        for _ in 0..<modes.count { await model.cyclePermissionMode() }

        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, Array(repeating: "set_permission_mode", count: modes.count),
                       "\(modes.count) press(es) sent \(subtypes.count) request(s)")
        let sent = await sentModes(double)
        let expected = Array(modes.dropFirst()) + [modes[0]]
        XCTAssertEqual(sent, expected.map(\.rawValue),
                       "\(modes.count) press(es) walked \(Set(sent).count) distinct mode(s) and did not wrap to the first")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 0, "Shift+Tab performed \(actions.count) lifecycle action(s)")
    }

    // MARK: - Cmd+Shift+Esc

    /// *Stop everything* issues **nothing** until the confirm is accepted, then exactly one action.
    ///
    /// The first arm is the one that matters and it is asserted on an empty call log: the action
    /// closes every background task's shell in the channel (§7.4), so a chord that reached it before
    /// the answer would be destructive with no way back.
    func testStopEverythingIssuesNothingBeforeTheConfirmIsAccepted() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)

        model.requestStopEverything()

        XCTAssertEqual(model.pendingConfirmation, .stopEverything, "the chord raised no confirm")
        let before = await double.memberSequence
        XCTAssertEqual(before.count, 0,
                       "the unanswered confirm reached \(before.count) member(s): \(before.joined(separator: ", "))")

        await model.confirmPending()

        XCTAssertNil(model.pendingConfirmation, "the accepted confirm stayed up")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "the accepted confirm performed \(actions.count) action(s)")
        guard case .stopEverything? = actions.first else {
            return XCTFail("the accepted confirm performed an action that is not `.stopEverything`")
        }
    }

    /// The cancelled confirm reaches nothing either, which is what makes the arm above about the
    /// answer rather than about the order of two calls.
    func testACancelledStopEverythingReachesNothing() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)

        model.requestStopEverything()
        model.cancelPending()

        XCTAssertNil(model.pendingConfirmation, "the cancelled confirm stayed up")
        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "a cancelled confirm reached \(members.count) member(s)")
    }

    /// **The affirmative takes the answer before the dialog's dismissal clears it.**
    ///
    /// SwiftUI answers a confirmation dialog with two calls: the button's action, and the presentation binding
    /// going false — which is `cancelPending()`. The dismissal is synchronous and the button's work is not, so an
    /// action that read `pendingConfirmation` when its task began read a value that had already been cleared and
    /// performed nothing at all: the user pressed *Stop Everything* and nothing stopped.
    ///
    /// The order here is the dialog's own: claim, then dismiss, then run.
    ///
    /// Deliberate break: run the claimed confirm by reading `pendingConfirmation` again instead of the claim.
    func testAClaimedConfirmSurvivesTheDialogsDismissal() async throws {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.stagePerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double)

        model.requestStopEverything()
        let claim = try XCTUnwrap(model.claimPending(), "the affirmative claimed nothing while a confirm was up")
        // The dismissal that follows the affirmative, which is what used to erase the pending action.
        model.cancelPending()
        await model.confirm(claim)

        let actions = await double.actions
        XCTAssertEqual(actions.count, 1,
                       "the claimed confirm performed \(actions.count) action(s) after the dialog dismissed itself")
        guard case .stopEverything? = actions.first else {
            return XCTFail("the claimed confirm performed an action that is not `.stopEverything`")
        }
        XCTAssertNil(model.pendingConfirmation, "the claim left a confirm standing")
    }

    // MARK: - The channel switch

    /// Switching to another channel **of the same mode** starts the new composer's subscription and
    /// gives the new header its row.
    ///
    /// The two channels are of the same listing mode on purpose. The subtree SwiftUI draws for a
    /// channel keeps its identity across a selection change, so nothing appears or disappears; a
    /// composer that only subscribed on appearance stays unsubscribed for the whole of the second
    /// channel's visit, and a header that only adopted on appearance or on a change of mode holds
    /// no row and offers nothing. Both are silent: the field draws, and neither the queue nor the
    /// menu ever says why it is empty.
    ///
    /// Asserted by drawing the two mounts, which is what the window does on every body evaluation,
    /// and reading the one ordered X5 log for the second channel's own `events(of:)`.
    func testSwitchingToAChannelOfTheSameModeStartsItsComposerAndAdoptsItsHeaderRow() async throws {
        let rig = try makeRig(sessions: [LaunchFixtures.sessionA, LaunchFixtures.sessionB])
        let home = LaunchFixtures.directoryURL(rig.configHome)
        let first = ChannelKey(configHome: home, session: LaunchFixtures.sessionA)
        let second = ChannelKey(configHome: home, session: LaunchFixtures.sessionB)
        let double = ComposerLifecycleDouble()
        await double.openEvents(of: first)
        await double.openEvents(of: second)

        let (app, column) = try await makeColumn(rig, selecting: LaunchFixtures.sessionA)
        app.composers.lifecycle = double
        // The modes are compared as a boolean: a `ChannelRow` reaches an `IndexEntry` (§11).
        XCTAssertTrue(app.browser?.row(LaunchFixtures.sessionA)?.mode == app.browser?.row(LaunchFixtures.sessionB)?.mode,
                      "the two channels are of different listing modes, so this proves nothing about a same-mode switch")
        try draw(column)
        let firstSubscribed = await subscriptions(double, of: first)
        XCTAssertEqual(firstSubscribed, 1,
                       "the first channel's composer took \(firstSubscribed) event subscription(s), not 1, so the "
                       + "arm below would prove nothing about the switch")

        app.shell.select(LaunchFixtures.sessionB)
        try draw(column)

        let subscribed = await subscriptions(double, of: second)
        XCTAssertEqual(subscribed, 1,
                       "the second channel's composer took \(subscribed) event subscription(s) after the switch, not 1")
        let header = try XCTUnwrap(app.composers.header(for: second),
                                   "the registry built no header actions for the second channel")
        XCTAssertTrue(header.row != nil,
                      "the second channel's header adopted no row, so it offers no action at all")
    }

    // MARK: - The read-only row (scalpel sweep #1)

    /// **A row C5 lists read-only gets no field at all.**
    ///
    /// The header's actions are already gated on the same policy, but nothing gated the composer — and every write
    /// this leaf makes leaves through it: a prompt resumes an archived session in `ChannelSupervisor.send`, and the
    /// `!` escape permits an archived origin outright. So a teammate's transcript, which afleet may show and may not
    /// write to, was fully actionable.
    ///
    /// Walked through the real mount, over a launch whose one channel is a teammate's, so the assertion is about the
    /// column's own call site and not about a view built by hand.
    ///
    /// Deliberate break: mount `ComposerView` regardless of `readOnly`.
    func testAReadOnlyRowMountsNoComposerAndSaysWhy() async throws {
        let rig = try makeRig(teammates: [LaunchFixtures.sessionA])
        let (app, column) = try await makeColumn(rig)
        app.composers.lifecycle = ComposerLifecycleDouble()
        // The premise: this row really is the read-only one. A boolean, never the row (§11).
        XCTAssertTrue(app.browser?.row(LaunchFixtures.sessionA)?.readOnlyReason != nil,
                      "the launch painted no read-only row, so this proves nothing about the policy")

        let mount = try XCTUnwrap(ComposerViewTree.view(named: "ChannelComposerMount", in: try channelBody(of: column)),
                                  "the column mounts no composer at all")
        let body = ComposerViewTree.body(of: mount)

        XCTAssertNil(ComposerViewTree.view(named: "ComposerView", in: body),
                     "the read-only row drew a composer, so its field can send")
        XCTAssertNotNil(ComposerViewTree.view(named: "ReadOnlyComposerNotice", in: body),
                        "the read-only row drew neither a field nor the sentence that says why")
        XCTAssertEqual(app.composers.openChannels.count, 0,
                       "\(app.composers.openChannels.count) composer(s) were built for a read-only channel")
    }

    /// The floor under the arm above: an ordinary row still gets the field, so the gate is about the policy and not
    /// about the mount having stopped drawing composers.
    func testAnOwnedCandidateRowStillMountsItsComposer() async throws {
        let rig = try makeRig()
        let (app, column) = try await makeColumn(rig)
        app.composers.lifecycle = ComposerLifecycleDouble()
        XCTAssertTrue(app.browser?.row(LaunchFixtures.sessionA)?.readOnlyReason == nil,
                      "the launch painted a read-only row, so this proves nothing about an owned candidate")

        let mount = try XCTUnwrap(ComposerViewTree.view(named: "ChannelComposerMount", in: try channelBody(of: column)),
                                  "the column mounts no composer")
        let body = ComposerViewTree.body(of: mount)

        XCTAssertNotNil(ComposerViewTree.view(named: "ComposerView", in: body),
                        "an ordinary row lost its field")
        XCTAssertNil(ComposerViewTree.view(named: "ReadOnlyComposerNotice", in: body),
                     "an ordinary row was told it is read-only")
    }

    // MARK: - The workspace generation (scalpel-4 #2, #3)

    /// **A fork handed off after the workspace was replaced is dropped.**
    ///
    /// `attach(to:)` releases the previous workspace's models and keeps the registry, which is app-scoped. The
    /// handoff closure captures the registry weakly and nothing else, so a fork that completed its `LifecycleAPI`
    /// call across a *Check again* would prefill this registry and move the window's selection onto a channel of a
    /// fleet nothing else refers to.
    ///
    /// Deliberate break: drop the generation guard from `ComposerRegistry.prefill(_:for:from:)`.
    func testAForkHandedOffAfterAWorkspaceRebindIsDropped() async throws {
        let rig = try makeRig()
        let app = AppModel(registry: RowRegistry(), sequence: rig.sequence)
        await app.launch()
        let workspace = try XCTUnwrap(app.route.workspace, "the launch reached no workspace")
        let key = ChannelKey(configHome: LaunchFixtures.directoryURL(rig.configHome), session: LaunchFixtures.sessionA)
        app.composers.lifecycle = ComposerLifecycleDouble()
        let model = try XCTUnwrap(app.composers.model(for: key), "the registry built no composer")
        let handOff = try XCTUnwrap(model.handOffToFork, "the registry installed no fork handoff")
        var selected: [SessionID] = []
        app.composers.selectChannel = { selected.append($0.session) }

        // The launch runs again: same registry, new workspace, every model released.
        app.bindWorkspace(workspace)
        app.composers.selectChannel = { selected.append($0.session) }
        let forked = ChannelKey(configHome: key.configHome, session: LaunchFixtures.sessionB)
        handOff(forked, "an invented edited message")

        XCTAssertEqual(selected.count, 0,
                       "\(selected.count) selection(s) were made by a handoff from a workspace that is gone")
        app.composers.lifecycle = ComposerLifecycleDouble()
        let after = try XCTUnwrap(app.composers.model(for: forked), "the registry built no composer for the fork")
        XCTAssertEqual(after.draft.count, 0,
                       "the stale handoff left \(after.draft.count) character(s) in a new workspace's composer")
    }

    /// The floor: within one workspace the same handoff prefills and selects, so the arm above is about the rebind
    /// and not about a handoff that stopped working.
    func testAForkHandedOffWithinTheSameWorkspacePrefillsAndSelects() async throws {
        let rig = try makeRig()
        let app = AppModel(registry: RowRegistry(), sequence: rig.sequence)
        await app.launch()
        let key = ChannelKey(configHome: LaunchFixtures.directoryURL(rig.configHome), session: LaunchFixtures.sessionA)
        app.composers.lifecycle = ComposerLifecycleDouble()
        let model = try XCTUnwrap(app.composers.model(for: key), "the registry built no composer")
        let handOff = try XCTUnwrap(model.handOffToFork, "the registry installed no fork handoff")
        var selected: [SessionID] = []
        app.composers.selectChannel = { selected.append($0.session) }

        let forked = ChannelKey(configHome: key.configHome, session: LaunchFixtures.sessionB)
        handOff(forked, "an invented edited message")

        XCTAssertEqual(selected.count, 1, "the handoff made \(selected.count) selection(s), not 1")
        let after = try XCTUnwrap(app.composers.model(for: forked), "the registry built no composer for the fork")
        XCTAssertEqual(after.draft, "an invented edited message", "the fork's composer opened with something else")
    }

    /// **A fork's prefill never overwrites words the user has already typed into that fork.**
    ///
    /// The handoff is asynchronous: `fork(at:on:)` answers, the identity resolves, and only then does the text of
    /// the edited message arrive. A user who reached the sibling in that window and started typing loses everything
    /// they wrote if the prefill is assigned unconditionally — the same defect the slash-rewind path was corrected
    /// for, and the same rule answers it here.
    ///
    /// Deliberate break: assign `existing.draft = text` with no check on what the draft holds.
    func testAForkPrefillKeepsWhatTheUserTypedIntoThatForksComposer() async throws {
        let rig = try makeRig()
        let app = AppModel(registry: RowRegistry(), sequence: rig.sequence)
        await app.launch()
        let key = ChannelKey(configHome: LaunchFixtures.directoryURL(rig.configHome), session: LaunchFixtures.sessionA)
        app.composers.lifecycle = ComposerLifecycleDouble()
        let model = try XCTUnwrap(app.composers.model(for: key), "the registry built no composer")
        let handOff = try XCTUnwrap(model.handOffToFork, "the registry installed no fork handoff")

        // The sibling's composer exists and the user has typed in it before the handoff resumed.
        let forked = ChannelKey(configHome: key.configHome, session: LaunchFixtures.sessionB)
        let sibling = try XCTUnwrap(app.composers.model(for: forked), "the registry built no composer for the fork")
        sibling.draft = "what the user typed into the fork"

        handOff(forked, "an invented edited message")

        XCTAssertEqual(sibling.draft, "what the user typed into the fork",
                       "the prefill overwrote a draft of \(sibling.draft.count) character(s) the user had typed")
        let note = try XCTUnwrap(sibling.editNote, "the dropped prefill said nothing about where the message went")
        XCTAssertEqual(note, ComposerRegistry.typedIntoForkNote, "the fork said something other than its own note")
    }

    // MARK: - The release (scalpel-4 #6)

    /// **A channel that leaves the index releases its composer.**
    ///
    /// `ComposerRegistry.release(_:)` existed, was tested, and had no production caller — the same defect the panel
    /// host's and the timeline registry's releases were both found with. A removed channel therefore kept its
    /// composer, its draft, its attachments and the surface state the header writes into, and where the view
    /// identity was retained it kept a live `events(of:)` subscription too.
    ///
    /// Deliberate break: remove the `composers?.release(key)` line from `FleetCoordinator.release(_:)`.
    func testAChannelThatLeavesTheIndexReleasesItsComposer() async throws {
        let temp = try TempTree()
        let home = LaunchFixtures.directoryURL(try temp.directory("home"))
        let session = LaunchFixtures.sessionA
        let key = ChannelKey(configHome: home, session: session)
        let registry = ComposerRegistry()
        registry.lifecycle = ComposerLifecycleDouble()
        XCTAssertNotNil(registry.model(for: key), "the registry built no composer to release")
        XCTAssertEqual(registry.openChannels.count, 1,
                       "the registry holds \(registry.openChannels.count) composer(s) before the removal, not 1")

        let coordinator = FleetCoordinator(configHome: home,
                                           registrar: RegistrarDouble(),
                                           index: StubIndex(persisted: nil,
                                                            built: LaunchFixtures.snapshot(configHome: home, ids: [])),
                                           model: FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home),
                                           composers: registry)
        await coordinator.indexChanged(IndexDelta(removed: [session]))

        XCTAssertEqual(registry.openChannels.count, 0,
                       "\(registry.openChannels.count) composer(s) survived the channel leaving the index")
    }

    // MARK: - Shift+Tab over the readback (sweep #5)

    /// **The cycle starts from the mode the channel is in.**
    ///
    /// The pickers hold the handshake's `permissionMode` readback, and the shortcut used to keep a second cursor
    /// that started at `.default` on every channel. A channel launched in `acceptEdits` therefore received
    /// `acceptEdits` again on its first Shift+Tab: one request, no change, and a key that looked broken.
    ///
    /// Deliberate break: cycle from a local `permissionMode` cursor again.
    func testShiftTabCyclesFromTheModeTheHandshakeReportedAndNotFromDefault() async throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let modes = ComposerModel.cyclablePermissionModes
        let reported = try XCTUnwrap(modes.dropFirst().first, "the cycle offers one mode, so a start point is moot")
        await model.pickers.noteHandshake(Self.handshake(reporting: reported))
        XCTAssertEqual(model.pickers.displayedMode, reported, "the handshake's mode did not reach the picker")

        await model.cyclePermissionMode()

        let sent = await sentModes(double)
        let expected = modes[(modes.firstIndex(of: reported)! + 1) % modes.count]
        XCTAssertEqual(sent, [expected.rawValue],
                       "the first press sent \(sent.count) mode(s) and did not start from the readback")
    }

    /// A handshake reporting one permission mode. `current_permission_mode` is the field the picker's readback
    /// reads; every value here is invented and no engine byte reaches this file (§11).
    private static func handshake(reporting mode: PermissionMode) -> InitializeResponse {
        InitializeResponse(raw: .object(["current_permission_mode": .string(mode.rawValue)]))
    }

    // MARK: - The composer's own lifecycle

    /// A composer released while a `/rewind` confirmation is up answers it with a decline, and a
    /// confirmation arriving after the release is declined at once.
    ///
    /// `StrategyExecutor` suspends inside `confirm(preview:)` until the sheet answers. Releasing the
    /// channel — or replacing the workspace — takes the sheet off the screen through `stop()`, and a
    /// `stop()` that did not answer would leave the strategy suspended for the life of the process
    /// with no control left that could ever resume it.
    func testStoppingDeclinesAPendingRewindConfirmationAndALateOne() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let preview = RewindPreview(canRewind: true, filesChanged: [], insertions: 0, deletions: 0)

        async let pending = model.confirm(preview: preview)
        for _ in 0..<64 where model.rewindPreview == nil { await Task.yield() }
        XCTAssertNotNil(model.rewindPreview, "the confirm never put a preview in front of the user")

        model.stop()
        let answer = await pending
        XCTAssertEqual(answer, .cancel, "the released composer answered the suspended strategy with something else")
        XCTAssertNil(model.rewindPreview, "the released composer left its confirmation on screen")

        // Late: the controls are gone, so the answer is the decline and it does not suspend.
        let late = await model.confirm(preview: preview)
        XCTAssertEqual(late, .cancel, "a confirmation raised after the release was not declined")
        XCTAssertNil(model.rewindPreview, "a confirmation raised after the release put a preview back on screen")
    }

    /// A composer whose event stream finished subscribes again on the next `start()`.
    ///
    /// `ChannelSupervisor` finishes every subscriber when a channel goes archived. The loop then
    /// ends on its own, and a composer that left its task handle in place refuses every later
    /// subscription — so a channel that is reopened receives no frames at all: no handshake, no
    /// slash commands, no ghost text, and a queue chip fed by nothing.
    func testAComposerWhoseStreamFinishedSubscribesAgain() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.openEvents(of: key)
        let model = ComposerModel(key: key, lifecycle: double, surface: ChannelSurfaceState())

        model.start()
        let first = await subscriptions(double, of: key, until: 1)
        XCTAssertEqual(first, 1, "the composer took \(first) subscription(s) on the first start, not 1")

        await double.finishEvents(of: key)
        // The mount resolves the composer on every body evaluation, so `start()` is offered again
        // and again; the loop is bounded so a composer that never frees its handle fails on a count.
        var second = 0
        for _ in 0..<2_000 {
            await Task.yield()
            model.start()
            second = await double.calls.filter { if case .events = $0 { true } else { false } }.count
            if second >= 2 { break }
        }
        XCTAssertEqual(second, 2,
                       "the composer took \(second) subscription(s) after its stream finished; the second start was refused")
    }

    // MARK: - The channel's context

    /// A composer's context is re-resolved when its channel's directory moves.
    ///
    /// The panel host answers `context(for:cwd:)` for the directory it is asked about, and the
    /// registry is where that question is asked. A registry that kept the first non-nil answer for
    /// the life of the composer leaves `!` running in the directory the channel was in before the
    /// relocation — a host command in the wrong tree, which is worse than one that says it cannot
    /// run.
    ///
    /// The paths are invented and the assertion is a boolean over them (§11).
    func testAComposersContextFollowsAChangeOfDirectory() async throws {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        let router = RecordingLinkRouter()
        let registry = ComposerRegistry()
        registry.lifecycle = double
        // The host's own question, answered for whichever directory it is asked about.
        registry.contextProvider = { key, cwd in ComposerMountTests.context(key, cwd: cwd, links: router) }

        let before = URL(fileURLWithPath: "/invented/project")
        let after = URL(fileURLWithPath: "/invented/relocated")
        let model = try XCTUnwrap(registry.model(for: key, cwd: before),
                                  "the registry built no composer for a channel with a lifecycle")
        XCTAssertTrue(model.context?.cwd == before, "the composer took no context for the directory it was built in")

        _ = registry.model(for: key, cwd: after)

        XCTAssertTrue(model.context?.cwd == after,
                      "the composer kept a context for the directory the channel has left")
    }

    // MARK: - The collision check (plan Task 2, deliverable 3)

    /// No key this leaf declares is a key C5 declared.
    ///
    /// C5's five are read from `App/AfleetApp.swift`: Cmd+K, Cmd+Shift+A, Cmd+1 through Cmd+7, and
    /// Cmd+, which SwiftUI binds to the `Settings` scene's own menu item. They are listed here rather
    /// than in `App/` because a list in the shipped target whose only reader is this test is exactly
    /// what `make check-wiring` exists to find.
    func testNoComposerShortcutCollidesWithOneTheShellDeclares() {
        let composer = ComposerShortcut.allCases.map { binding($0.key, $0.modifiers) }
        var shell = [binding(KeyEquivalent("k"), .command),
                     binding(KeyEquivalent("a"), [.command, .shift]),
                     binding(KeyEquivalent(","), .command)]
        shell += (1...7).map { binding(KeyEquivalent(Character("\($0)")), .command) }

        XCTAssertEqual(composer.count, 4, "this leaf declares \(composer.count) key(s), not the 4 it is allowed")
        XCTAssertEqual(Set(composer).count, 4, "two of this leaf's \(composer.count) keys are the same key")
        XCTAssertEqual(shell.count, 10, "the shell's list carries \(shell.count) key(s), not the 10 C5 declares")

        let collisions = Set(composer).intersection(shell)
        XCTAssertEqual(collisions.count, 0,
                       "\(collisions.count) of this leaf's \(composer.count) keys are already bound by the shell")
        // Two-directional, and a floor: a comparison that matched nothing because the spellings
        // differ would pass the clause above for the wrong reason.
        XCTAssertEqual(Set(shell).subtracting(composer).count, shell.count,
                       "the shell's keys and this leaf's compare unequal even where they should match")
        XCTAssertTrue(Set(composer).contains(binding(.return, .command)),
                      "Cmd+Return is not among the keys compared, so the comparison proves nothing about it")
    }

    // MARK: - Support

    private func binding(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> String {
        // A string rather than a tuple so a failure prints a key and a bitmask and nothing else.
        "\(key.character.unicodeScalars.map { String($0.value) }.joined())+\(modifiers.rawValue)"
    }

    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("d"))
    }

    private func makeModel(_ double: ComposerLifecycleDouble) -> ComposerModel {
        ComposerModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    /// Draws the column's two mounts, which is what the window does whenever the selection moves.
    /// Opening a body is how this suite asserts on views at all; nothing here renders a scene.
    private func draw(_ column: ChannelColumnView) throws {
        let body = try channelBody(of: column)
        for name in ["ChannelHeaderActionsSlot", "ChannelComposerMount"] {
            let mount = try XCTUnwrap(ComposerViewTree.view(named: name, in: body),
                                      "the column drew no \(name)")
            _ = ComposerViewTree.body(of: mount)
        }
    }

    /// How many `events(of:)` calls one channel has taken, waited for with the same bounded loop the
    /// send arms use so a composer that never subscribes fails on a count rather than hanging.
    private func subscriptions(_ double: ComposerLifecycleDouble,
                               of key: ChannelKey,
                               until expected: Int = 1) async -> Int {
        var count = 0
        for _ in 0..<2_000 {
            await Task.yield()
            count = await double.calls.filter { if case .events(let called) = $0 { called == key } else { false } }.count
            if count >= expected { return count }
        }
        return count
    }

    /// A `ChannelContext` for one directory, over the shared stubs. Built here rather than through
    /// `ComposerContextFixtures` because the directory is what this arm is about.
    private static func context(_ key: ChannelKey, cwd: URL, links: RecordingLinkRouter) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: cwd,
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh",
                                                        capturedAt: Date(timeIntervalSince1970: 0),
                                                        mode: .login),
                       store: NullComposerScopedStore(),
                       links: links,
                       recentURLs: NullComposerRecentURLFeed(),
                       reportPaneExit: { _ in })
    }

    /// Every `set_permission_mode` payload's mode, in order.
    private func sentModes(_ double: ComposerLifecycleDouble) async -> [String] {
        await double.calls.compactMap { call in
            guard case .send(_, "set_permission_mode", let payload) = call else { return nil }
            return payload.objectValue?["mode"]?.stringValue
        }
    }

    /// Waits for the detached `Task` a fired send action starts. Bounded so a composer that never
    /// reaches the lifecycle fails on a count instead of hanging the suite.
    private func settle(_ double: ComposerLifecycleDouble,
                        until reached: (Int) -> Bool) async -> Int {
        var count = 0
        for _ in 0..<2_000 {
            await Task.yield()
            count = await double.prompts.count
            if reached(count) { return count }
        }
        return count
    }
}
