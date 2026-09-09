import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import XCTest

/// A `ChannelContext` a session test can own end to end: an in-memory store it can read back, a
/// recorder for `reportPaneExit`, and stubs for the two capabilities a Terminal session never
/// touches. Every identifier here is invented (§11); nothing is read from or written to a real
/// config home.
enum PaneTestContext {

    /// The invented config home the store-key vector in `TerminalPanelStateTests` is pinned to.
    /// Changing this path changes that vector, which is the point of pinning it.
    static let configHome = URL(filePath: "/invented/config-home")

    struct Fixture {
        let context: ChannelContext
        let key: ChannelKey
        let cwd: URL
        let store: RecordingStore
        let exits: ExitRecorder
    }

    /// `shell` is `/bin/sh` rather than the author's own login shell: a shell pane really spawns
    /// it, and §11 keeps the author's environment out of a committed file either way.
    static func environment(variables: [String: String]) -> ResolvedEnvironment {
        ResolvedEnvironment(
            variables: variables,
            shell: "/bin/sh",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .processFallback
        )
    }

    static func fixture(
        session: SessionID = SessionID(uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!),
        cwd: URL,
        variables: [String: String] = ["PATH": "/usr/bin:/bin", "AFLEET_PANE_MARK": "jade"],
        store: RecordingStore = RecordingStore()
    ) -> Fixture {
        let key = ChannelKey(configHome: configHome, session: session)
        let exits = ExitRecorder()
        let context = ChannelContext(
            key: key,
            session: key.session,
            cwd: cwd,
            environment: environment(variables: variables),
            store: store,
            links: SilentRouter(),
            recentURLs: EmptyFeed(),
            reportPaneExit: { await exits.record($0) }
        )
        return Fixture(context: context, key: key, cwd: cwd, store: store, exits: exits)
    }

    // MARK: Stubs

    /// Keyed JSON, boxed in a one-element array the way `PanelHostAPITests`' stub does, because a
    /// bare `String` is not a JSON document.
    actor RecordingStore: ScopedStore {
        private var storage: [String: Data] = [:]
        private(set) var writtenKeys: [String] = []
        /// A read held open, and whoever asked to be told one had begun. The pair exists because
        /// standing a mutation *inside* the read a restore is waiting on is the one interleaving
        /// that cannot be produced by ordering calls.
        private var isHoldingReads = false
        private var heldRead: CheckedContinuation<Void, Never>?
        private var announcement: CheckedContinuation<Void, Never>?
        private var hasBegunHeldRead = false

        /// Every read from here on blocks until ``releaseHeldRead()``.
        func holdReads() { isHoldingReads = true }

        func releaseHeldRead() {
            isHoldingReads = false
            heldRead?.resume()
            heldRead = nil
        }

        /// Returns once a held read has begun, so the caller knows it is standing inside one.
        func awaitHeldRead() async {
            guard !hasBegunHeldRead else { return }
            await withCheckedContinuation { announcement = $0 }
        }

        func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
            if isHoldingReads {
                hasBegunHeldRead = true
                announcement?.resume()
                announcement = nil
                await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
                    heldRead = held
                }
            }
            guard let data = storage[key] else { return nil }
            return try JSONDecoder().decode([T].self, from: data).first
        }

        func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
            storage[key] = try JSONEncoder().encode([value])
            writtenKeys.append(key)
        }

        func remove(key: String) async throws { storage[key] = nil }
        func keys() async throws -> [String] { storage.keys.sorted() }
    }

    actor ExitRecorder {
        private(set) var recorded: [PaneExit] = []
        func record(_ exit: PaneExit) { recorded.append(exit) }
    }

    struct SilentRouter: LinkRouterCapability {
        func register(_ target: LinkTarget) async {}
        func unregister(tab: PanelTabID) async {}
        func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
    }

    struct EmptyFeed: RecentURLFeed {
        func current(limit: Int) async -> [SeenURL] { [] }
        var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
    }
}
