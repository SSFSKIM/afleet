import AppKit
import Foundation

@MainActor
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    func feed(_ output: Data)
    var onInput: (@Sendable (Data) -> Void)? { get set }
    var onResize: (@Sendable (TerminalSize) -> Void)? { get set }
    func processDidExit(code: Int32)
    func setAppearance(_ appearance: TerminalAppearance)
    var terminalDescription: TerminalDescription { get }
}
