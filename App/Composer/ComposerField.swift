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
    case acceptGhost
    case pass

    /// Return is 36, the keypad's Enter is 76.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// Tab is 48.
    static let tabKeyCode: UInt16 = 48

    /// Plain Tab, with ghost text showing, accepts it (spec C6.2 *Ghost text*).
    ///
    /// Answered in the field rather than by a `.keyboardShortcut`, exactly as Return is and for the
    /// same reason: Tab already means something in a text view, and a command-table binding would
    /// take it away for the whole column whether or not there is a suggestion to accept. So this is
    /// not a fifth declared key — `ComposerShortcut` still names four — it is the field's own reading
    /// of a key it already receives, and Tab passes through untouched whenever there is nothing to
    /// accept or any modifier is held (Shift+Tab is the permission-mode cycle).
    static func forTab(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasGhostText: Bool) -> ComposerKeyAction {
        guard keyCode == tabKeyCode, hasGhostText else { return .pass }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        return flags.isEmpty ? .acceptGhost : .pass
    }

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
    /// Plain Tab, while a suggestion is showing. Answers whether it accepted one, so a Tab with
    /// nothing to accept still reaches AppKit.
    var onAcceptGhost: () -> Bool = { false }
    /// A paste or a drop. Answers how many images it took; zero lets AppKit have the keystroke, so
    /// pasting text is still pasting text.
    var onPasteboard: (NSPasteboard) -> Int = { _ in 0 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let view = SendingTextView()
        view.delegate = context.coordinator
        view.onSend = { context.coordinator.parent.onSend() }
        view.onAcceptGhost = { context.coordinator.parent.onAcceptGhost() }
        view.onPasteboard = { context.coordinator.parent.onPasteboard($0) }
        // A drop of an image arrives on a pasteboard of its own; without these the text view accepts
        // only what it can insert as characters.
        view.registerForDraggedTypes([.png, .tiff, .fileURL])
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
        /// Answers whether a suggestion was accepted; false means the keystroke was not the
        /// composer's and goes on to AppKit.
        var onAcceptGhost: (() -> Bool)?
        /// A paste or a drop, answering how many images the composer took off it.
        var onPasteboard: ((NSPasteboard) -> Int)?

        override func keyDown(with event: NSEvent) {
            // **An input method is composing, so this keystroke is the candidate's and not the composer's.** Return
            // confirms a candidate and Tab moves through them; a field that read the key code first would submit an
            // unfinished word on every phrase, which for a user typing Korean, Japanese or Chinese is every message.
            // AppKit's own path decides it: the key goes to the input context and nothing here is declared over it.
            if hasMarkedText() { super.keyDown(with: event); return }
            let tab = ComposerKeyAction.forTab(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                               hasGhostText: true)
            if tab == .acceptGhost, onAcceptGhost?() == true { return }
            switch ComposerKeyAction.forReturn(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            case .newline: insertNewlineIgnoringFieldEditor(nil)
            case .send: onSend?()
            case .acceptGhost, .pass: super.keyDown(with: event)
            }
        }

        /// Cmd+V. An image on the pasteboard is attached; anything else is pasted as text, which is
        /// what the field would have done anyway.
        override func paste(_ sender: Any?) {
            if (onPasteboard?(NSPasteboard.general) ?? 0) > 0 { return }
            super.paste(sender)
        }

        /// A drop. The same intake as a paste — the drag pasteboard is a pasteboard (§C6.2
        /// *Attachments*: both are user input and both are validated at this boundary).
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if (onPasteboard?(sender.draggingPasteboard) ?? 0) > 0 { return true }
            return super.performDragOperation(sender)
        }
    }
}
