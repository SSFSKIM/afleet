import SwiftUI
import XCTest
@testable import Afleet

/// C5's `ViewTree` reads one constructed body. C6.2's mount question is one level deeper: the two
/// call sites are inside `ChannelTimelineColumn`, which is `private` to `ChannelColumnView.swift`
/// and so cannot be named, constructed or cast to from a test.
///
/// So the body is opened rather than the type: a value recovered as `any View` is expanded through
/// `_openExistential`, which needs no name at all. Nothing here prints a value — a view retains
/// runtime environment data and a channel's own state (§11) — and every answer is a type name or a
/// count.
@MainActor
enum ComposerViewTree {

    /// One view's `body`, without naming its type.
    static func body(of view: any View) -> Any {
        func open<V: View>(_ view: V) -> Any { view.body }
        return _openExistential(view, do: open)
    }

    /// The first descendant whose type is spelled exactly `name`, depth-first in declaration order.
    static func view(named name: String, in value: Any) -> (any View)? {
        if typeName(of: value) == name, let view = value as? any View { return view }
        for child in Mirror(reflecting: value).children {
            if let found = view(named: name, in: child.value) { return found }
        }
        return nil
    }

    /// The names in `names` in the order a depth-first walk of `value` meets them. Order is the
    /// point: "the composer is below the list" is a claim about position, and a set could not fail
    /// on a composer mounted above the header.
    static func order(of names: Set<String>, in value: Any) -> [String] {
        var found: [String] = []
        walk(value, names: names, into: &found)
        return found
    }

    private static func walk(_ value: Any, names: Set<String>, into found: inout [String]) {
        let name = typeName(of: value)
        if names.contains(name) { found.append(name) }
        for child in Mirror(reflecting: value).children {
            walk(child.value, names: names, into: &found)
        }
    }

    /// The unqualified type name — `Afleet.ComposerView` reads as `ComposerView`, and a generic's
    /// parameters are dropped so `List<Never, TimelineRowSlot>` is not three names.
    static func typeName(of value: Any) -> String {
        let full = String(describing: type(of: value))
        let head = full.prefix { $0 != "<" }
        return String(head.split(separator: ".").last ?? head)
    }

    /// The `onSend` a `ComposerField` was built with, fired. This is what a Return in the field
    /// reaches: `ComposerField.SendingTextView.keyDown` calls exactly this closure.
    static func fireSend(of field: Any) -> Bool {
        guard let closure = Mirror(reflecting: field).descendant("onSend") else { return false }
        func invoke<Action>(_ value: Action) -> Bool {
            typealias Callback = () -> Void
            let source = String(reflecting: Action.self).replacingOccurrences(of: "@Sendable ", with: "")
            let target = String(reflecting: Callback.self).replacingOccurrences(of: "@Sendable ", with: "")
            guard source == target, MemoryLayout<Action>.size == MemoryLayout<Callback>.size else { return false }
            unsafeBitCast(value, to: Callback.self)()
            return true
        }
        return _openExistential(closure, do: invoke)
    }
}
