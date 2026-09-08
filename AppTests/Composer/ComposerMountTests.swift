import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
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
    private func makeRig() throws -> Rig {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let fleet = LifecycleDouble()
        let index = StubIndex(persisted: nil,
                              built: LaunchFixtures.snapshot(configHome: configHome, ids: [LaunchFixtures.sessionA]),
                              delta: IndexDelta(added: [LaunchFixtures.sessionA]))
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
    private func makeColumn(_ rig: Rig) async throws -> (app: AppModel, column: ChannelColumnView) {
        let app = AppModel(sequence: rig.sequence)
        await app.launch()
        let workspace = try XCTUnwrap(app.route.workspace, "the launch reached no workspace to draw")
        app.shell.select(LaunchFixtures.sessionA)
        // A boolean, not the row: a `ChannelRow` reaches an `IndexEntry` and would print every
        // field of it on failure (§11).
        XCTAssertTrue(app.browser?.row(LaunchFixtures.sessionA) != nil,
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
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))

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
        let sent = await settle(double) { $0 >= 1 }
        XCTAssertEqual(sent, 1, "the field's send action reached the lifecycle \(sent) time(s)")
        let actions = await double.actions
        guard case .send(let input)? = actions.first else {
            return XCTFail("the field's send action performed an action that is not `.send`")
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
            count = await double.calls.count
            if reached(count) { return count }
        }
        return count
    }
}
