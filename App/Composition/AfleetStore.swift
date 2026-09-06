import Foundation
import FleetKit

/// The `afleet` namespace of the X6 store (parent §7.8). It holds only what no other namespace
/// does: window and selection state, the Developer settings, notification preferences and the
/// unknown-frame tally.
///
/// Pinning, section order, collapse and the unread cursors are **not** duplicated here. They are
/// `FleetKitKeys.grouping` and `FleetKitKeys.unreadCursors` and are read and written where they
/// already live; a second copy of either is a second answer to the same question.
enum AfleetStoreKeys {
    /// `AfleetWindowState`
    static let window = "window.state"
    /// `AfleetSelectionState`
    static let selection = "selection.state"
    /// `AfleetSettings`
    static let settings = "settings"
    /// `UnknownFrameTally`
    static let unknownFrames = "frames.unknown"
}

/// The window's last frame on screen, so a relaunch reopens where the user left it.
struct AfleetWindowState: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Which channel the sidebar had selected.
struct AfleetSelectionState: Codable, Hashable, Sendable {
    var selectedSession: SessionID?

    init(selectedSession: SessionID? = nil) { self.selectedSession = selectedSession }
}

/// Settings' Developer section (spec §9). `binaryPathOverride` is what item 33 points at a
/// `fake-claude`: it is read by `BinaryLocator.locate(in:override:)` at launch and so takes effect
/// on *Check again*, not live.
struct DeveloperSettings: Codable, Hashable, Sendable {
    var binaryPathOverride: String?
    var rawFrameCapture: Bool
    /// Item 56's switch: the composition root builds no `TranscriptWatcher` when this is true.
    var transcriptWatcherStopped: Bool
    var isolatedSettingsForNewChannels: Bool

    init(binaryPathOverride: String? = nil,
         rawFrameCapture: Bool = false,
         transcriptWatcherStopped: Bool = false,
         isolatedSettingsForNewChannels: Bool = false) {
        self.binaryPathOverride = binaryPathOverride
        self.rawFrameCapture = rawFrameCapture
        self.transcriptWatcherStopped = transcriptWatcherStopped
        self.isolatedSettingsForNewChannels = isolatedSettingsForNewChannels
    }

    /// The override as a URL, or nil when it is unset or blank.
    var overrideURL: URL? {
        guard let raw = binaryPathOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(filePath: raw)
    }
}

/// Which of the three notifications the user wants (spec §6).
struct NotificationPreferences: Codable, Hashable, Sendable {
    var permissionRequests: Bool
    var turnCompleted: Bool
    var channelFailed: Bool

    init(permissionRequests: Bool = true, turnCompleted: Bool = true, channelFailed: Bool = true) {
        self.permissionRequests = permissionRequests
        self.turnCompleted = turnCompleted
        self.channelFailed = channelFailed
    }
}

/// The one document under `AfleetStoreKeys.settings`.
struct AfleetSettings: Codable, Hashable, Sendable {
    var developer: DeveloperSettings
    var notifications: NotificationPreferences

    init(developer: DeveloperSettings = DeveloperSettings(),
         notifications: NotificationPreferences = NotificationPreferences()) {
        self.developer = developer
        self.notifications = notifications
    }
}

/// Frame types the corpus does not type, counted since install (spec §9's Engine section). Types
/// and counts only — never a frame's bytes.
struct UnknownFrameTally: Codable, Hashable, Sendable {
    var counts: [String: Int]

    init(counts: [String: Int] = [:]) { self.counts = counts }

    var total: Int { counts.values.reduce(0, +) }
}

/// The tally's one writer. An actor because frames arrive from every channel at once and the
/// read-modify-write below is two hops onto the store.
actor UnknownFrameCounter {
    private let store: any StateStore
    private var tally: UnknownFrameTally?

    init(store: any StateStore) { self.store = store }

    /// One frame of a type the corpus does not carry.
    func record(_ type: String) async {
        var current = await load()
        current.counts[type, default: 0] += 1
        tally = current
        try? await store.write(current, namespace: .afleet, key: AfleetStoreKeys.unknownFrames)
    }

    func snapshot() async -> UnknownFrameTally { await load() }

    private func load() async -> UnknownFrameTally {
        if let tally { return tally }
        let loaded = (try? await store.read(UnknownFrameTally.self, namespace: .afleet,
                                            key: AfleetStoreKeys.unknownFrames)) ?? nil
        let value = loaded ?? UnknownFrameTally()
        tally = value
        return value
    }
}

/// Reading and writing the `afleet` namespace's settings document, in one place so no view has to
/// know the key.
enum AfleetSettingsStore {
    static func read(from store: any StateStore) async -> AfleetSettings {
        let loaded = (try? await store.read(AfleetSettings.self, namespace: .afleet,
                                            key: AfleetStoreKeys.settings)) ?? nil
        return loaded ?? AfleetSettings()
    }

    static func write(_ settings: AfleetSettings, to store: any StateStore) async throws {
        try await store.write(settings, namespace: .afleet, key: AfleetStoreKeys.settings)
    }
}
