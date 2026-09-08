import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The two reports the engine makes once per process, and the surfaces that mount after them.
///
/// `events(of:)` is a future-only fan-out: a composer that subscribes late sees neither the handshake
/// nor `system/init`, and a picker drawn against a channel with no process asked two questions nobody
/// answered. Both are about a surface holding stale or empty state while the channel is perfectly
/// live, which nothing else in the leaf's gates can see.
@MainActor
final class LateMountMetadataTests: XCTestCase {

    private func key(_ nibble: String = "b") -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session(nibble))
    }

    /// An invented handshake naming the engine's own commands and a mode.
    private func handshakeEvent(commands: [String], mode: PermissionMode) -> WireEvent {
        let raw = JSONValue.object([
            "commands": .array(commands.map { .object(["name": .string($0)]) }),
            "current_permission_mode": .string(mode.rawValue),
        ])
        return .handshakeCompleted(Handshake(initialize: InitializeResponse(raw: raw), pending: []), .first)
    }

    /// An invented `system/init`, decoded the way the stream decodes one.
    private func systemInitEvent(slashCommands: [String]) throws -> WireEvent {
        let payload: [String: Any] = [
            "type": "system", "subtype": "init",
            "cwd": "/invented/project", "session_id": SidebarFixtures.session("b").description,
            "tools": [], "mcp_servers": [], "model": "invented-model", "permissionMode": "default",
            "slash_commands": slashCommands, "terminal_slash_commands": [],
            "apiKeySource": "none", "claude_code_version": "0.0.0", "output_style": "default",
            "skills": [], "plugins": [], "uuid": "invented-init-uuid",
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        let frame = FrameDecoder.decode(line: line)
        guard case .system(.initialize) = frame else {
            throw XCTSkip("the invented system/init line decoded as \(frame.typeName)")
        }
        return .frame(frame, .first)
    }

    /// A composer mounted onto a channel that handshook before it existed reads the two reports back
    /// rather than waiting for a stream that will not repeat them.
    ///
    /// Failed before the fix: `handshake` and `systemInit` were both nil, the mode picker had nothing
    /// to display, and autocomplete offered only the local table.
    func testALateComposerSeedsTheReportsTheStreamWillNotRepeat() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let engineCommand = "invented-engine-command"
        await double.openEvents(of: key)
        await double.stageEngineReport(handshake: handshakeEvent(commands: [engineCommand], mode: .plan),
                                       systemInitFrom: try systemInitEvent(slashCommands: [engineCommand]))
        let model = ComposerModel(key: key, lifecycle: double, surface: ChannelSurfaceState())

        model.start()
        try await waitFor("the retained reports to be seeded") { model.handshake != nil }

        XCTAssertNotNil(model.systemInit, "the composer read back no system/init")
        XCTAssertEqual(model.pickers.displayedMode, .plan,
                       "the mode picker displayed nothing for a channel that has already reported one")
        XCTAssertTrue(model.completions.contains("/" + engineCommand),
                      "autocomplete offered \(model.completions.count) name(s) and none of them was the engine's")
        model.stop()
    }

    /// **A cancelled subscription's seeding does not land on the one that replaced it.**
    ///
    /// `start()` checked its generation only where it clears the task handle. Acquiring the subscription is one
    /// suspension and `seedEngineReports` several more, and a `stop()` with a fresh `start()` behind it can land in
    /// any of them — a channel switch and back does exactly that. The old call then committed the handshake, the
    /// picker's mode readback and `system/init` over the values the *new* subscription had already applied, from a
    /// stream nobody is reading, so nothing downstream could notice.
    ///
    /// The two reports differ only in their permission mode, which is the value the picker displays: the assertion
    /// is on the mode and never on a report (§11).
    ///
    /// Deliberate break: drop the generation guards from `seedEngineReports(ifGenerationIs:)`.
    func testACancelledSubscriptionsSeedingDoesNotOverwriteTheCurrentOne() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.openEvents(of: key)
        await double.stageEngineReport(handshake: handshakeEvent(commands: [], mode: .plan), systemInitFrom: nil)
        await double.holdEngineReports()
        let model = ComposerModel(key: key, lifecycle: double, surface: ChannelSurfaceState())

        // The first subscription reaches the seeding and parks inside it, holding the older report.
        model.start()
        try await waitFor("the first subscription to reach its seeding") {
            await double.memberSequence.contains("engineReports")
        }

        // The channel is left and returned to: the first loop is cancelled and a second one seeds the newer report.
        model.stop()
        await double.stopHoldingEngineReports()
        await double.stageEngineReport(handshake: handshakeEvent(commands: [], mode: .acceptEdits),
                                       systemInitFrom: nil)
        model.start()
        try await waitFor("the second subscription to seed") { model.pickers.displayedMode == .acceptEdits }

        // And only now does the first one come back.
        await double.releaseEngineReports()
        for _ in 0..<64 { await Task.yield() }

        XCTAssertEqual(model.pickers.displayedMode, .acceptEdits,
                       "the cancelled subscription's readback landed over the current one's")
        model.stop()
    }

    /// A channel with no process refuses the picker's two questions. Its next handshake is the first
    /// moment there is anything to ask, so that is when the picker asks again — and only then: a
    /// refresh that already came back complete is not repeated.
    ///
    /// Failed before the fix: `noteHandshake` asked nothing, so the model menu of a channel opened
    /// from the archive stayed empty for the life of the channel.
    func testAHandshakeAfterARefusedRefreshReloadsThePickers() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let refusal = Result<JSONValue, WireError>.failure(.controlError("an invented refusal"))
        await double.stageSendSequence("list_models",
                                       [refusal, .success(try PickerReadbackTests.recordedBody("list_models"))])
        await double.stageSendSequence("get_settings",
                                       [refusal, .success(try PickerReadbackTests.recordedBody("get_settings"))])
        let pickers = SettingPickersModel(key: key, lifecycle: double, surface: ChannelSurfaceState())

        await pickers.refresh()
        XCTAssertTrue(pickers.modelOptions.isEmpty,
                      "a processless channel answered \(pickers.modelOptions.count) model row(s)")

        await pickers.noteHandshake(InitializeResponse(raw: .object([:])))

        XCTAssertGreaterThan(pickers.modelOptions.count, 0,
                             "the handshake left the menu with \(pickers.modelOptions.count) row(s)")

        // And the arm that must stay silent: a refresh that succeeded is not re-taken on every
        // handshake, which is what would spend two control requests per restart on every channel.
        let settled = await double.sentSubtypes.count
        await pickers.noteHandshake(InitializeResponse(raw: .object([:])))
        let after = await double.sentSubtypes.count
        XCTAssertEqual(after, settled,
                       "a handshake after a complete refresh made \(after - settled) more request(s)")
    }

    /// A bounded wait on a condition the model reaches on its own task.
    private func waitFor(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
