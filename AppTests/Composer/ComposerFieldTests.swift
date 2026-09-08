import AppKit
import XCTest
@testable import Afleet

/// The field's own reading of a keystroke, at the one place a table cannot answer it: while an input
/// method is composing.
///
/// `ComposerKeyAction` is a pure table over a key code and its modifiers, and it is asserted
/// elsewhere. What it cannot see is that the keystroke is not the composer's at all — AppKit hands a
/// key to the input context first, and while there is marked text a Return **confirms the candidate**
/// rather than sending anything. The product's first users type Korean, so this is the ordinary path
/// and not an edge: a field that sends on that Return submits an unfinished word on every phrase.
@MainActor
final class ComposerFieldTests: XCTestCase {

    /// A Return keystroke, as AppKit delivers one. Return is key code 36.
    private func returnKey() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\r",
                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                      "this machine would not synthesise a Return keystroke")
    }

    private func field(onSend: @escaping () -> Void) -> ComposerField.SendingTextView {
        let view = ComposerField.SendingTextView()
        view.onSend = onSend
        return view
    }

    /// Return while an input method is composing belongs to the candidate, not to the composer.
    ///
    /// Deliberate break: drop the `hasMarkedText()` arm from `keyDown` → the half-finished syllable is
    /// sent as a message.
    func testReturnWhileTheInputMethodIsComposingDoesNotSend() throws {
        var sends = 0
        let view = field { sends += 1 }
        // One syllable mid-composition — this suite's own text, in the script the case is about.
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "the field holds no marked text, so this arm proves nothing")

        view.keyDown(with: try returnKey())

        XCTAssertEqual(sends, 0,
                       "Return confirmed a composition and sent \(sends) message(s), so an unfinished word went to "
                       + "the engine")
    }

    /// The floor: the very same keystroke, with nothing being composed, still sends.
    func testTheSameReturnSendsWhenNothingIsBeingComposed() throws {
        var sends = 0
        let view = field { sends += 1 }
        view.string = "an invented line"
        XCTAssertFalse(view.hasMarkedText(), "the field holds marked text, so this floor proves nothing")

        view.keyDown(with: try returnKey())

        XCTAssertEqual(sends, 1, "an ordinary Return sent \(sends) message(s), not exactly 1")
    }
}
