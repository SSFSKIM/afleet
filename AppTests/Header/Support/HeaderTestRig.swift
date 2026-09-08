import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// What C6.2's header tests build their channels out of. Every identifier here is invented; no
/// engine byte and no real home appears in this file (§11).
@MainActor
enum HeaderRig {

    static func key(_ nibble: String = "a") -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session(nibble))
    }

    /// One row of the fleet browser, in the listing mode the test is about. `mode` is the whole
    /// point: `offersOwnedActions` and `readOnlyReason` are both read off it, and tracker 74 is the
    /// claim that this header consumes them.
    static func row(_ key: ChannelKey, mode: ListingPolicy.Mode) -> ChannelRow {
        ChannelRow(key: key,
                   title: "invented title",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: URL(fileURLWithPath: "/invented/project"),
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(timeIntervalSince1970: 0),
                   isRecent: true,
                   mode: mode,
                   decidingRule: "invented-rule",
                   isProvisional: false)
    }

    /// A header over the double, with the row adopted. `store` is nil for every test that is not
    /// about the bypass acceptance, which is the only value this leaf writes.
    static func header(_ double: ComposerLifecycleDouble,
                       key: ChannelKey,
                       mode: ListingPolicy.Mode = .ownedCandidate,
                       store: (any StateStore)? = nil) -> ChannelHeaderActionsModel {
        let composer = ComposerModel(key: key, lifecycle: double, surface: ChannelSurfaceState())
        let header = ChannelHeaderActionsModel(composer: composer, store: store)
        header.adopt(row: row(key, mode: mode))
        return header
    }

    /// The state a `perform(.quiescentRestart)` answers with when the process really was replaced.
    ///
    /// **By epoch.** A channel that is busy records the change for its dormant timer and answers
    /// success straight away, and so does one whose change merged into a restart already in flight;
    /// in both the process on the other end is still the old one. The epoch is the only thing that
    /// separates them, so a header test that stages a state without one is staging the restart that
    /// did not happen.
    static func replaced(_ key: ChannelKey, epoch: ProcessEpoch = .first) -> ChannelState {
        var state = SidebarFixtures.state(key, origin: .owned(.ready))
        state.epoch = epoch
        return state
    }

    /// The same answer for a restart that was only **queued**: no new process, and the request still
    /// pending for when the channel is next eligible.
    static func queued(_ key: ChannelKey, epoch: ProcessEpoch = .first) -> ChannelState {
        var state = SidebarFixtures.state(key, origin: .owned(.ready))
        state.epoch = epoch
        state.pendingChange = RestartRequest(allowBypass: true)
        return state
    }

    /// One running or finished background task, as the channel's fold carries it.
    static func task(_ id: String, status: TaskStatus) -> TimelineItem {
        let stream = LogicalStream(configHome: URL(fileURLWithPath: "/invented/config-home"),
                                   sessionID: SidebarFixtures.session("a"), name: .main)
        return .taskRun(TaskRunItem(id: ItemID(stream: stream, key: id),
                                    timestamp: Date(timeIntervalSince1970: 0),
                                    provenance: Provenance(stream: stream, origin: .wire),
                                    taskID: id,
                                    kind: .localBash,
                                    description: "an invented task",
                                    status: status))
    }
}

/// afleet's own store, recorded into the **same ordered log** as the lifecycle calls.
///
/// It wraps a real `FileStateStore` rather than standing in for one, so G5's X9 arm watches the
/// bytes that a production write would actually put on disk, through C5's `AppFileWrites` seam.
final class RecordingBypassStore: StateStore {

    private let inner: any StateStore
    private let double: ComposerLifecycleDouble

    init(inner: any StateStore, double: ComposerLifecycleDouble) {
        self.inner = inner
        self.double = double
    }

    func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T? {
        try await inner.read(type, namespace: namespace, key: key)
    }

    func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws {
        await double.noteStoreWrite(namespace: namespace, key: key)
        try await inner.write(value, namespace: namespace, key: key)
    }

    func remove(namespace: StoreNamespace, key: String) async throws {
        await double.noteStoreWrite(namespace: namespace, key: key)
        try await inner.remove(namespace: namespace, key: key)
    }

    func keys(in namespace: StoreNamespace) async throws -> [String] { try await inner.keys(in: namespace) }

    func appendUnique(_ element: String, namespace: StoreNamespace, key: String) async throws {
        await double.noteStoreWrite(namespace: namespace, key: key)
        try await inner.appendUnique(element, namespace: namespace, key: key)
    }
}

/// Every path C5's `AppFileWrites` seam was handed, in order.
///
/// `@unchecked Sendable` is sound because the one mutable field is read and written only inside
/// `lock`, this instance's private `NSLock`.
final class AppWriteRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var seen: [URL] = []

    func note(_ url: URL) { lock.lock(); seen.append(url); lock.unlock() }
    var paths: [URL] { lock.lock(); defer { lock.unlock() }; return seen }

    /// The seam, wired to this recorder.
    var seam: AppFileWrites {
        AppFileWrites(willWrite: { [self] in note($0) }, willDelegate: { [self] in note($0) })
    }

    /// Every recorded path that lies at or under a config home, canonicalised on both sides.
    ///
    /// The homes are `TempTree`'s three — the real user home's, the scratch fixtures' and whatever
    /// `CLAUDE_CONFIG_DIR` names — so "no write under any config home" is the claim, and not "no
    /// write under the one this test happened to think of".
    func pathsUnderAConfigHome(_ homes: [URL] = TempTree.configHomes()) -> [String] {
        let resolved = homes.map { CanonicalPath.string($0) }
        return paths.map { CanonicalPath.string($0) }.filter { path in
            resolved.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    /// Whether anything named the CLI's own settings document, which afleet never touches, on any arm.
    var namedTheCLIsSettings: [String] {
        paths.map { $0.lastPathComponent }.filter { $0 == "settings.json" }
    }
}
