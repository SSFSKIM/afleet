import AppKit
import SwiftUI

/// What a Return keystroke means in the composer (spec §8.5, §8.7): Shift+Enter inserts a newline,
/// Enter sends, Cmd+Enter sends.
///
/// A value rather than a branch inside `keyDown`, so the table can be read — and asserted — without
/// an event loop. Anything that is not Return, and any Return carrying a modifier the table does not
/// name (Option, Control), passes through to AppKit untouched: this leaf declares four keys and no
/// others, and swallowing a fifth is how a field loses a system binding.
enum ComposerKeyAction: Hashable, Sendable {
    case newline
    case send
    case pass

    /// Return is 36, the keypad's Enter is 76.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    static func forReturn(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ComposerKeyAction {
        guard returnKeyCodes.contains(keyCode) else { return .pass }
        // Caps Lock, Fn and the numeric-pad bit ride along on keystrokes nobody pressed them for;
        // the keypad's Enter always carries `.numericPad`.
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if flags.contains(.shift) { return .newline }
        if flags.isSubset(of: .command) { return .send }
        return .pass
    }
}

/// The field itself: an `NSTextView` behind SwiftUI, because a composer needs multi-line editing,
/// the system's own text behaviour and a Return key that means three different things — none of
/// which `TextEditor` gives up.
struct ComposerField: NSViewRepresentable {

    @Binding var text: String
    var isEnabled: Bool
    /// Enter and Cmd+Enter. The model decides whether that is a send, a route or nothing at all.
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let view = SendingTextView()
        view.delegate = context.coordinator
        view.onSend = { context.coordinator.parent.onSend() }
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? SendingTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.isEditable = isEnabled
        view.isSelectable = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    /// The one behaviour the delegate cannot express: `NSTextViewDelegate` sees Return only as
    /// `insertNewline(_:)`, which cannot tell Enter from Cmd+Enter, so the modifiers are read where
    /// they still exist.
    final class SendingTextView: NSTextView {
        var onSend: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch ComposerKeyAction.forReturn(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            case .newline: insertNewlineIgnoringFieldEditor(nil)
            case .send: onSend?()
            case .pass: super.keyDown(with: event)
            }
        }
    }
}
