import Foundation
import AfleetCore
import FleetKit
import PanelHostAPI
import Workbench

/// The host's own W6 document: which tab a channel was last showing (spec §7's selection
/// ownership; C7's W6 names `panel.host.<configHomeHash>.<sessionId>` and C5 as its writer).
///
/// A `schemaVersion` for the same reason every other panel document carries one: a build refuses a
/// document from a future schema into nothing rather than decoding a shape it does not know. Its
/// one field is a `PanelTabID`, and an id this build does not know decodes to nothing — the tab set
/// is closed at seven, so that can only mean a document from a build with more of them.
struct PanelHostDocument: Codable, Equatable, Sendable {

    /// What this build writes and the highest it will decode.
    static let currentSchemaVersion = 1

    var schemaVersion = PanelHostDocument.currentSchemaVersion
    var selectedTab: PanelTabID
}

/// The host's selection documents over the scoped store, one key per channel, with a coalescing
/// writer.
///
/// **One actor over every channel, not one per channel.** The panels' stores are built per channel
/// because a panel session *is* per channel; the host is one object over all of them, and a store
/// per channel would mean an actor and a writer task for every channel the window visits. So the
/// key is computed per call and the pending set is a map.
///
/// The coalescing is the panels' own: a selection is recorded, a single writer drains it on an
/// interval, and the last value for a key is the one that lands. Cmd+1…7 held down is a burst like
/// any other.
actor PanelHostStore {

    private let store: any ScopedStore
    private let coalescingInterval: Duration
    private var pending: [ChannelKey: PanelTabID] = [:]
    private var writer: Task<Void, Never>?

    init(store: any ScopedStore, coalescingInterval: Duration = .milliseconds(250)) {
        self.store = store
        self.coalescingInterval = coalescingInterval
    }

    /// W6's key for one channel: `panel.host.<configHomeHash>.<sessionId>`, in the `workbench`
    /// namespace the scoped store pins — so the full path reads
    /// `workbench.panel.host.<configHomeHash>.<sessionId>`.
    ///
    /// The hash is the twelve-lowercase-hex-character prefix of the SHA-256 of the config home's
    /// path — §11's spelling for capture directories, and the one the Files and Terminal documents
    /// key by — and it is **borrowed rather than recomputed**, so the three panel documents of one
    /// channel cannot come to disagree about which config home they belong to. `FilesPanelStore`'s
    /// is the published one that takes exactly the URL a `ChannelKey` carries; ClaudeWire's asks
    /// for a `ConfigHome`, which the key does not have. X1 leaves the app free to import either.
    nonisolated static func key(for channel: ChannelKey) -> String {
        let hash = FilesPanelStore.configHomeHash(channel.configHome)
        return "panel.host.\(hash).\(channel.session.description)"
    }

    /// The channel's remembered tab, or nil.
    ///
    /// Nothing here throws into the caller: an absent document, one this build cannot decode and
    /// one from a future schema are all the same answer to a window arriving at a channel — keep
    /// showing what it is showing. The version is read before the document, so a future one is
    /// never decoded.
    func load(_ channel: ChannelKey) async -> PanelTabID? {
        let key = Self.key(for: channel)
        guard let probe = try? await store.read(SchemaProbe.self, key: key) else { return nil }
        guard probe.schemaVersion <= PanelHostDocument.currentSchemaVersion else { return nil }
        guard let document = try? await store.read(PanelHostDocument.self, key: key) else { return nil }
        return document.selectedTab
    }

    /// Records the channel's tab to be written. Returns at once; the writer lands it.
    func save(_ tab: PanelTabID, for channel: ChannelKey) {
        pending[channel] = tab
        guard writer == nil else { return }
        writer = Task { [weak self] in await self?.drain() }
    }

    /// One writer at a time: it sleeps the interval, writes whatever the burst left, and exits when
    /// an interval passes with nothing pending.
    private func drain() async {
        while true {
            try? await Task.sleep(for: coalescingInterval)
            guard !pending.isEmpty else { break }
            let batch = pending
            pending = [:]
            for (channel, tab) in batch { await write(tab, for: channel) }
        }
        writer = nil
    }

    /// A refused write costs this run its document and nothing else. The selection is the user's
    /// and has already landed on the host; a store that cannot take it must not take that with it.
    private func write(_ tab: PanelTabID, for channel: ChannelKey) async {
        try? await store.write(PanelHostDocument(selectedTab: tab), key: Self.key(for: channel))
    }

    /// Just enough of the document to decide whether this build may decode the rest.
    private struct SchemaProbe: Codable, Sendable {
        let schemaVersion: Int
    }
}
