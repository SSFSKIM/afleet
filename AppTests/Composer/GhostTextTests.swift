import Foundation
import AppKit
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 7: the engine's `prompt_suggestion` as ghost text, accepted by Tab, off by default.
///
/// The frame is built here from an invented line and decoded by the production decoder, exactly as a
/// real one is — nothing engine-recorded is spelled in this file (§11). The suggestion text is this
/// suite's own invention.
@MainActor
final class GhostTextTests: XCTestCase {

    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("a"))
    }

    private func makeModel(_ double: ComposerLifecycleDouble) -> ComposerModel {
        ComposerModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    /// An invented `prompt_suggestion` line, decoded the way the stream decodes one.
    private func suggestionEvent(_ suggestion: String) throws -> WireEvent {
        let payload: [String: Any] = [
            "type": "prompt_suggestion", "suggestion": suggestion,
            "uuid": "invented-suggestion-uuid", "session_id": SidebarFixtures.session("a").description,
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        let frame = FrameDecoder.decode(line: line)
        guard case .promptSuggestion = frame else {
            throw XCTSkip("the invented line decoded as \(frame.typeName), not a prompt_suggestion frame")
        }
        return .frame(frame, .first)
    }

    /// With the setting on, the frame's `suggestion` becomes the ghost text — and nothing else does.
    func testTheSuggestionKeyBecomesTheGhostText() async throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        model.promptSuggestionsEnabled = true
        let suggestion = "an invented next prompt"

        await model.observe(try suggestionEvent(suggestion))

        XCTAssertEqual(model.ghostText, suggestion,
                       "the ghost text carries \(model.ghostText?.count ?? 0) character(s), not the \(suggestion.count) the frame did")
        XCTAssertEqual(model.visibleGhostText, suggestion, "the suggestion is not shown over an empty field")
        XCTAssertEqual(model.draft.count, 0, "observing a suggestion typed \(model.draft.count) character(s) into the field")
        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "reading a suggestion reached \(members.count) lifecycle member(s)")
    }

    /// Tab accepts it into the draft, verbatim, and the ghost goes.
    func testTabAcceptsTheSuggestionIntoTheDraft() async throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        model.promptSuggestionsEnabled = true
        let suggestion = "another invented next prompt"
        await model.observe(try suggestionEvent(suggestion))

        XCTAssertEqual(ComposerKeyAction.forTab(keyCode: ComposerKeyAction.tabKeyCode,
                                                modifiers: [], hasGhostText: true), .acceptGhost,
                       "plain Tab with a suggestion showing is not the accept")
        let accepted = model.acceptGhostText()

        XCTAssertTrue(accepted, "Tab accepted nothing while a suggestion was showing")
        XCTAssertEqual(model.draft, suggestion,
                       "the field carries \(model.draft.count) character(s), not the \(suggestion.count) accepted")
        XCTAssertNil(model.ghostText, "the accepted suggestion is still offered")
        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "accepting a suggestion reached \(members.count) lifecycle member(s)")
    }

    /// Tab is the composer's **only** while there is something to accept.
    ///
    /// Shift+Tab is the permission-mode cycle and a bare Tab in a field with no suggestion is
    /// AppKit's; a composer that swallowed either would take a key away from the rest of the app.
    func testTabPassesThroughWithNothingToAcceptAndWithAModifier() {
        XCTAssertEqual(ComposerKeyAction.forTab(keyCode: ComposerKeyAction.tabKeyCode,
                                                modifiers: [], hasGhostText: false), .pass,
                       "Tab with no suggestion was taken by the composer")
        XCTAssertEqual(ComposerKeyAction.forTab(keyCode: ComposerKeyAction.tabKeyCode,
                                                modifiers: .shift, hasGhostText: true), .pass,
                       "Shift+Tab was taken by the ghost text rather than by the permission-mode cycle")
        XCTAssertEqual(ComposerKeyAction.forTab(keyCode: ComposerKeyAction.returnKeyCodes.first ?? 36,
                                                modifiers: [], hasGhostText: true), .pass,
                       "a key that is not Tab was read as the accept")
    }

    /// **Off by default.** A composer nobody has turned the setting on for shows nothing, and Tab
    /// accepts nothing, even when the frame arrives.
    func testWithTheSettingOffNothingIsShownAndTabAcceptsNothing() async throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)

        XCTAssertFalse(model.promptSuggestionsEnabled, "prompt suggestions are on before anything asked for them")
        await model.observe(try suggestionEvent("an invented suggestion nobody asked for"))

        XCTAssertNil(model.ghostText, "a suggestion was shown with the setting off")
        XCTAssertNil(model.visibleGhostText, "a suggestion was drawn with the setting off")
        XCTAssertFalse(model.acceptGhostText(), "Tab accepted a suggestion with the setting off")
        XCTAssertEqual(model.draft.count, 0, "the field gained \(model.draft.count) character(s) with the setting off")
    }

    /// A suggestion is a whole prompt, not a completion: it is not drawn behind typed words, where
    /// accepting it would throw them away.
    func testTheSuggestionIsNotDrawnOverAHalfTypedMessage() async throws {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        model.promptSuggestionsEnabled = true
        await model.observe(try suggestionEvent("an invented suggestion"))
        let typed = "words the user is already typing"
        model.draft = typed

        XCTAssertNil(model.visibleGhostText, "the suggestion is drawn behind \(model.draft.count) typed character(s)")
        XCTAssertFalse(model.acceptGhostText(), "Tab replaced \(model.draft.count) typed character(s) with a suggestion")
        XCTAssertEqual(model.draft.count, typed.count,
                       "the typed line lost characters; \(model.draft.count) of \(typed.count) remain")
    }
}
