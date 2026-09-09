import Foundation
import CryptoKit
import AfleetCore
import PanelHostAPI

/// The Files tab's per-channel document (spec Design §6).
///
/// The filter is a stored property and is deliberately **not** a coded one: a filter restored
/// from a previous launch hides files for a reason the user cannot see. Keeping it on the state
/// rather than off it puts that decision where a reader of the type finds it, and
/// `FilesPanelStateTests` asserts it does not survive the round trip.
public struct FilesPanelState: Codable, Equatable, Sendable {

    /// What this build writes and the highest it will decode. A document above it is refused
    /// into the empty state rather than read, which is the one thing the version exists for.
    public static let currentSchemaVersion = 1

    public var schemaVersion = FilesPanelState.currentSchemaVersion
    /// In tab order, each with its own cursor and markdown toggle.
    public var openFiles: [OpenFile] = []
    /// The absolute path of the selected file, if one of `openFiles` is selected.
    public var selectedPath: String?
    public var showsHiddenFiles = false
    public var showsGitIgnored = false
    /// Not persisted. See the type's note.
    public var filter = ""

    public struct OpenFile: Codable, Equatable, Sendable {
        /// Absolute; the model URI the bridge keys the buffer by is built from it.
        public var path: String
        public var line: Int
        public var column: Int
        /// Markdown is rendered by default and the toggle opens the source in Monaco, which is
        /// per open file and part of the persisted state (Design §4).
        public var rendersMarkdown: Bool

        public init(path: String, line: Int, column: Int, rendersMarkdown: Bool) {
            self.path = path
            self.line = line
            self.column = column
            self.rendersMarkdown = rendersMarkdown
        }
    }

    public static let empty = FilesPanelState()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, openFiles, selectedPath, showsHiddenFiles, showsGitIgnored
    }
}

/// `FilesPanelState` over the scoped store the host hands the panel, under the W6 key for this
/// panel and channel, with a coalescing writer.
///
/// The store is one document rewritten whole and a cursor moves on every keystroke, so a save is
/// recorded and a single writer drains it on an interval; a burst of N cursor moves is fewer than
/// N writes and the last value is the one that lands.
public actor FilesPanelStore {

    /// `panel.files.<configHomeHash>.<sessionId>`, in the `workbench` namespace the host binds —
    /// so the full path reads `workbench.panel.files.<configHomeHash>.<sessionId>`. The key is
    /// per *panel* as well as per channel, which is one of the two `[parent-impact]` deviations
    /// from W6 the spec files.
    public nonisolated let key: String

    private let store: any ScopedStore
    private let coalescingInterval: Duration
    private var pending: FilesPanelState?
    private var writer: Task<Void, Never>?

    /// The twelve-lowercase-hex-character prefix of the SHA-256 of the config home's path.
    ///
    /// The same spelling §11 uses for capture directories, recomputed here rather than imported:
    /// `RawCapture.configHomeHash` lives in ClaudeWire and contract X1 forbids Workbench from
    /// depending on it.
    public static func configHomeHash(_ configHome: URL) -> String {
        let digest = SHA256.hash(data: Data(configHome.path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    public init(store: any ScopedStore, configHome: URL, session: SessionID,
                coalescingInterval: Duration = .milliseconds(250)) {
        self.store = store
        self.coalescingInterval = coalescingInterval
        self.key = "panel.files.\(Self.configHomeHash(configHome)).\(session.description)"
    }

    /// The restored state, or the empty state.
    ///
    /// Nothing here throws into the caller: an absent document, a document this build cannot
    /// decode and a document from a future schema are all the same answer to a panel opening a
    /// channel, and the version is read before the state so a future document is never decoded.
    public func load() async -> FilesPanelState {
        guard let probe = try? await store.read(SchemaProbe.self, key: key) else { return .empty }
        guard probe.schemaVersion <= FilesPanelState.currentSchemaVersion else { return .empty }
        guard let state = try? await store.read(FilesPanelState.self, key: key) else { return .empty }
        return state
    }

    /// Records the state to be written. Returns at once; the writer lands it.
    public func save(_ state: FilesPanelState) {
        pending = state
        guard writer == nil else { return }
        writer = Task { [weak self] in await self?.drain() }
    }

    /// Writes whatever is pending now, without waiting for the interval.
    public func flush() async {
        guard let state = pending else { return }
        pending = nil
        try? await store.write(state, key: key)
    }

    /// One writer at a time: it sleeps the interval, writes whatever the burst left, and exits
    /// when an interval passes with nothing pending.
    private func drain() async {
        while true {
            try? await Task.sleep(for: coalescingInterval)
            guard let state = pending else { break }
            pending = nil
            try? await store.write(state, key: key)
        }
        writer = nil
    }

    /// Just enough of the document to decide whether this build may decode the rest.
    private struct SchemaProbe: Codable, Sendable {
        let schemaVersion: Int
    }
}
