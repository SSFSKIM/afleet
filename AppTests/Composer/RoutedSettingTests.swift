import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// What a **routed** line does after the request goes out (spec C6.2 *The router UI*, §7.7's `/cd`
/// row, §8.6).
///
/// The dispatch table's rows are asserted by G1; these are the halves G1's member sequence cannot
/// see: that a routed setting change takes the same gate and the same readback a click does, that an
/// answer which changed nothing is not reported as a change, that what a strategy hands back reaches
/// the user, and that a slash command carries what is attached to it.
///
/// Every identifier is invented and every assertion is on member names, subtypes and counts (§11).
@MainActor
final class RoutedSettingTests: XCTestCase {

    // MARK: - Rig

    private func key(_ nibble: String = "c") -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session(nibble))
    }

    private func composer(_ double: ComposerLifecycleDouble, key: ChannelKey) -> ComposerModel {
        ComposerModel(key: key, lifecycle: double, surface: ChannelSurfaceState())
    }

    // MARK: - The settings the pickers own

    /// §8.6 binds **every** path to the gate. A typed `/permissions bypassPermissions` is a first
    /// selection like any other: the disclaimer comes first, and nothing reaches the wire until it is
    /// answered.
    ///
    /// Failed before the fix: the line sent `set_permission_mode` straight out, to a process that was
    /// never launched with the flag, with no disclaimer and no acceptance recorded.
    func testARoutedBypassModeTakesTheHeadersGate() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        let header = HeaderRig.header(double, key: key)
        await header.pickers.refresh()

        await header.composer.dispatch(.controlRequest(AnyControlRequest(SetPermissionMode(mode: .bypassPermissions))))

        XCTAssertTrue(header.isShowingBypassDisclaimer, "the routed line reached no disclaimer")
        let subtypes = await double.sentSubtypes
        XCTAssertFalse(subtypes.contains(SetPermissionMode.subtype),
                       "the mode was sent before the disclaimer was answered")
    }

    /// A routed `/model` re-reads what a click re-reads, so the header displays what the engine now
    /// holds and the next restart snapshot is taken from it.
    ///
    /// Failed before the fix: the request went out and nothing was re-read, so the picker still showed
    /// whatever it last knew — nothing, here.
    func testARoutedModelChangeRefreshesTheHeadersReadback() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let rows = ModelOption.options(in: try PickerReadbackTests.recordedBody("list_models"))
        let picked = try XCTUnwrap(rows.first, "the recording offers no model row")
        await double.stageSend("get_settings", .success(try PickerReadbackTests.settings(model: picked.canonical)))
        let model = composer(double, key: key)
        model.draft = "/model \(picked.value)"

        await model.send()

        XCTAssertEqual(model.pickers.appliedModel, picked.canonical,
                       "the routed change left the header's readback where it was")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, [SetModel.subtype, GetSettings.subtype],
                       "the routed change made \(subtypes.count) request(s): " + subtypes.joined(separator: ", "))
    }

    // MARK: - `/cd` and the trust handshake

    /// `{status: "needs_trust", directory}` is a **success envelope that changed nothing** (§7.7).
    /// afleet asks, and only then repeats the call with `trust_accepted` and `trusted_directory`
    /// echoing the directory the engine named.
    ///
    /// Failed before the fix: the answer was discarded, the line was cleared, and the channel's
    /// directory silently did not change.
    func testANeedsTrustAnswerAsksAndThenRepeatsTheCallWithTheEchoedDirectory() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let asked = "/invented/project"
        let resolved = "/invented/project-resolved"
        await double.stageSendSequence(SetCwd.subtype, [
            .success(.object(["status": .string("needs_trust"), "directory": .string(resolved)])),
            .success(.object(["status": .string("ok"), "cwd": .string(resolved),
                              "transcript_relocated": .bool(true)])),
        ])
        let model = composer(double, key: key)
        model.draft = "/cd \(asked)"

        await model.send()

        guard case .trustDirectory(let directory, let path)? = model.pendingConfirmation else {
            return XCTFail("a needs_trust answer raised no question")
        }
        XCTAssertEqual(directory, resolved, "the question is about a directory other than the one the engine named")
        XCTAssertEqual(path, asked, "the second call would ask for a path the line did not name")
        XCTAssertFalse(model.draft.isEmpty, "the line was cleared for a directory change that has not happened")
        let beforeAnswer = await double.sentSubtypes
        XCTAssertEqual(beforeAnswer, [SetCwd.subtype],
                       "\(beforeAnswer.count) request(s) went out before the question was answered")

        await model.confirmPending()

        let after = await double.sentSubtypes
        XCTAssertEqual(after, [SetCwd.subtype, SetCwd.subtype],
                       "the answered question made \(after.count) request(s) in all")
        let calls = await double.calls
        let payloads: [JSONValue] = calls.compactMap {
            if case .send(_, SetCwd.subtype, let payload) = $0 { payload } else { nil }
        }
        let second = try XCTUnwrap(payloads.last, "no second set_cwd reached the wire")
        XCTAssertEqual(second["trust_accepted"]?.boolValue, true, "the second call granted no trust")
        XCTAssertEqual(second["trusted_directory"]?.stringValue, resolved,
                       "the second call echoed something other than the directory the engine asked about")
        XCTAssertNotNil(model.editNote, "the directory change said nothing")
        XCTAssertTrue(model.draft.isEmpty, "the answered line stayed in the field")
    }

    // MARK: - What a strategy hands back

    /// `StrategyOutcome` carries everything the multi-step rows read off the engine, and a dispatch
    /// that dropped it left a cleared line and nothing on screen.
    ///
    /// Failed before the fix: both arms left the note nil.
    func testAStrategysOutcomeIsPutInFrontOfTheUser() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let servers = [MCPPopover.Server(name: "invented-one", status: "connected"),
                       MCPPopover.Server(name: "invented-two", status: "failed")]
        await double.stageRun(.success(.mcp(MCPPopover(servers: servers))))
        let model = composer(double, key: key)

        await model.dispatch(.strategy(.mcpPopover, arguments: []))

        let note = try XCTUnwrap(model.editNote, "the MCP outcome said nothing")
        XCTAssertTrue(note.contains("\(servers.count)"),
                      "the note of \(note.count) character(s) carries no count of what came back")

        // A refused rewind is never reported as done, and what is offered instead is named.
        let refused = ComposerLifecycleDouble()
        let reason = "an invented refusal"
        let preview = RewindPreview(canRewind: true, filesChanged: ["invented"], insertions: 1, deletions: 0)
        await refused.stageRun(.success(.rewind(preview,
                                                RewindOutcome(rewound: false, prefillText: nil, error: reason))))
        let refusedModel = composer(refused, key: key)

        await refusedModel.dispatch(.strategy(.rewind, arguments: ["invented-uuid"]))

        let refusal = try XCTUnwrap(refusedModel.editNote, "a refused rewind said nothing")
        XCTAssertTrue(refusal.contains(reason), "the note did not carry the engine's own reason")
        XCTAssertTrue(refusedModel.draft.isEmpty, "a refused rewind prefilled the field")
    }

    // MARK: - The native destinations

    /// A bare `/model` names a picker, and the picker it names opens.
    ///
    /// Failed before the fix: the destination was stored on a property nothing read, so the line was
    /// cleared and no surface appeared.
    func testABarePickerCommandOpensThatPicker() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let model = composer(double, key: key)
        model.draft = "/model"

        await model.send()

        XCTAssertEqual(model.pickers.presentedPicker, "modelPicker",
                       "the routed destination opened nothing")
        XCTAssertEqual(model.openSurface, "modelPicker", "the destination the table named was not recorded")
        let members = await double.memberSequence
        XCTAssertEqual(members, ["route"], "a native row reached \(members.count) member(s)")
    }

    // MARK: - Attachments

    /// A slash command that passes through to the engine is a message like any other, so it carries
    /// what is attached to it.
    ///
    /// Failed before the fix: the `.text` route built its `UserInput` with no images, and the
    /// attachment stayed in the tray to ride the next message instead.
    func testAPassThroughCommandCarriesTheAttachments() async throws {
        let double = ComposerLifecycleDouble()
        let key = key()
        let line = "/invented-passthrough with an image"
        await double.stageRoute(.text(line))
        await double.alwaysSendPrompt(.success(UUID()))
        let model = composer(double, key: key)
        model.attachments = [ImageAttachment(mediaType: "image/png", base64: "aW52ZW50ZWQ=")]
        model.draft = line

        await model.send()

        let prompts = await double.prompts
        XCTAssertEqual(prompts.count, 1, "the pass-through sent \(prompts.count) prompt(s)")
        XCTAssertEqual(prompts.first?.images.count, 1,
                       "the pass-through carried \(prompts.first?.images.count ?? 0) image(s)")
        XCTAssertTrue(model.attachments.isEmpty,
                      "\(model.attachments.count) attachment(s) were left to ride the next message")
    }
}
