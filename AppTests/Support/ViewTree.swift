import SwiftUI

/// Inspects a constructed SwiftUI body without a second copy of its presentation logic.
/// Reflection is test-only; it never prints values (a view may retain runtime environment data).
enum ViewTree {
    static func values<T>(of type: T.Type, in value: Any) -> [T] {
        if let match = value as? T { return [match] }
        return Mirror(reflecting: value).children.flatMap { values(of: type, in: $0.value) }
    }

    /// The content of the first `ScrollView` in a body, or nil when the body holds none.
    ///
    /// `ScrollView`'s generic parameter is its content's type, so a caller cannot name the concrete
    /// type to `values(of:)`; the descent is by type name and then into the stored `content`, which
    /// is what lets a test assert that something is *inside* the scroll container rather than merely
    /// somewhere in the same body.
    static func scrollViewContent(in value: Any) -> Any? {
        if String(describing: type(of: value)).hasPrefix("ScrollView<") {
            return Mirror(reflecting: value).descendant("content")
        }
        for child in Mirror(reflecting: value).children {
            if let found = scrollViewContent(in: child.value) { return found }
        }
        return nil
    }

    static func button(_ label: String, in body: Any) -> Button<Text>? {
        values(of: Button<Text>.self, in: body).first {
            values(of: String.self, in: $0).contains(label)
        }
    }

    @MainActor
    static func press(_ button: Button<Text>) -> Bool {
        guard let action = Mirror(reflecting: button).descendant("action", "closure") else { return false }
        // Swift 6's dynamic cast from Any rejects this isolated closure. Open the existential
        // and require matching isolation/signature and size before recovering the callable value.
        func invoke<Action>(_ value: Action) -> Bool {
            typealias Callback = @MainActor () -> Void
            // SwiftUI's Swift-5 closure metadata lacks Swift-6's inferred Sendable marker.
            let source = String(reflecting: Action.self).replacingOccurrences(of: "@Sendable ", with: "")
            let target = String(reflecting: Callback.self).replacingOccurrences(of: "@Sendable ", with: "")
            guard source == target,
                  MemoryLayout<Action>.size == MemoryLayout<Callback>.size else { return false }
            unsafeBitCast(value, to: Callback.self)()
            return true
        }
        return _openExistential(action, do: invoke)
    }
}
