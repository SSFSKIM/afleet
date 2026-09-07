import Foundation
import FleetKit
import PanelHostAPI

/// X6's store, bound to the `workbench` namespace and handed to a panel through its
/// `ChannelContext` (spec §7).
///
/// **A panel cannot name a namespace at all.** The host binds the scope here, once, and a tab sees
/// only keys; nothing a panel can say reaches `fleetKit`'s documents or `afleet`'s. That is the
/// whole reason `ScopedStore` is its own protocol rather than `StateStore` passed through.
///
/// Keys pass through unchanged. C7's W6 has the Browser share one window-wide document
/// (`workbench.browser`) and each panel keep one per channel
/// (`workbench.panel.<configHomeHash>.<sessionId>`); both are the panel's own to name, and a host
/// that rewrote keys would make the second of those unreachable from the first.
struct WorkbenchScopedStore: ScopedStore {

    /// The namespace every read and write below is pinned to.
    static let namespace: StoreNamespace = .workbench

    let store: any StateStore

    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
        try await store.read(type, namespace: Self.namespace, key: key)
    }

    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
        try await store.write(value, namespace: Self.namespace, key: key)
    }

    func remove(key: String) async throws {
        try await store.remove(namespace: Self.namespace, key: key)
    }

    func keys() async throws -> [String] {
        try await store.keys(in: Self.namespace)
    }
}
