import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// The committed corpus, projected the two ways the app can see it: from the transcript files C3's
/// `RecordReducer` folds, and from the recorded frames its `WireReducer` folds.
///
/// **Read-only, and never under a config home.** Every path here is a fixture path opened for
/// reading; the recorded config home is a *value* the fixtures' own paths resolve against and
/// nothing writes to it (X9). Nothing in this file asserts over an `ItemID` or a `RecordKey`: both
/// carry a `LogicalStream`, which carries the config-home path (§11), so identity leaves here as a
/// key string.
enum TimelineCorpus {

    /// `AppTests/Support/` → the repository root → `Fixtures`.
    static var root: URL { FixtureRunner.repositoryRoot.appending(path: "Fixtures") }

    /// The config home the recordings were made under. A value, not a directory this suite touches.
    static let recordedConfigHome = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")

    /// Every fixture directory name, sorted.
    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// One fixture's durable projection, folded from its transcript files exactly as an archived
    /// channel's is: every `.jsonl` under `transcript/` resolved onto the recorded config home's
    /// `projects/` layout, reduced per stream and merged on the main one.
    static func durable(_ fixture: String) throws -> DurableProjection {
        let base = root.appending(path: fixture).appending(path: "transcript")
        guard FileManager.default.fileExists(atPath: base.path) else { return .empty }
        var projections: [StreamProjection] = []
        var main: LogicalStream?
        for (stream, kind, url) in try streams(under: base) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let records = text.split(separator: "\n").map { RecordDecoder.decode(line: Data($0.utf8)) }
            projections.append(RecordReducer.reduce(records, stream: stream, sourceFile: url))
            if case .mainTranscript = kind { main = stream }
        }
        guard let main else { return .empty }
        return RecordReducer.merge(projections, main: main)
    }

    /// One fixture's wire fold: the recorded frames through the reducer a live channel runs.
    static func wire(_ fixture: String) throws -> WireReducer {
        let session = try sessionID(of: fixture)
        let stream = LogicalStream(configHome: recordedConfigHome, sessionID: session, name: .main)
        var reducer = WireReducer(stream: stream, slug: "_slug_")
        for event in try FixtureRunner.events(fixture) { _ = reducer.apply(event) }
        return reducer
    }

    /// A hidden record's identity as a string, which is what a comparison against a row's `.key` can
    /// be made of without printing a stream (§11).
    static func key(of record: HiddenRecord) -> String {
        switch record.key.identity {
        case .uuid(let uuid): uuid
        case .hash(let hash, let ordinal): "\(hash)#\(ordinal)"
        }
    }

    // MARK: - Layout

    /// `transcript/<slug>/…` is the config home's `projects/<slug>/…`, so a file resolves by
    /// rewriting its fixture-relative path onto that layout — the same rewrite C3's own corpus
    /// loader performs.
    private static func streams(under base: URL) throws -> [(LogicalStream, TranscriptPath, URL)] {
        let basePath = base.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var out: [(LogicalStream, TranscriptPath, URL)] = []
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasSuffix(".jsonl"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(path.dropFirst(basePath.count + 1))
            let aliased = recordedConfigHome.appending(path: "projects").appending(path: relative)
            guard let (stream, kind) = TranscriptPath.resolve(aliased, under: recordedConfigHome) else { continue }
            out.append((stream, kind, url))
        }
        return out.sorted { $0.2.path < $1.2.path }
    }

    private static func sessionID(of fixture: String) throws -> SessionID {
        let data = try Data(contentsOf: root.appending(path: fixture).appending(path: "fixture.json"))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let raw = value["session_id"]?.stringValue, let session = SessionID(raw) else {
            throw CorpusError.noSession(fixture: fixture)
        }
        return session
    }

    enum CorpusError: Error, CustomStringConvertible {
        case noSession(fixture: String)
        var description: String {
            switch self {
            case .noSession(let fixture): "fixture \(fixture) carries no usable session id"
            }
        }
    }
}

// MARK: - Invented items

/// The items the row tests are built from. Every identifier is invented — a word and a repeated
/// nibble — so nothing here can be mistaken for an engine byte or for anybody's own session (§11).
enum InventedItems {

    static let stream = LogicalStream(configHome: URL(fileURLWithPath: "/tmp/invented-config-home"),
                                      sessionID: SidebarFixtures.session("a"),
                                      name: .main)

    static func id(_ key: String) -> ItemID { ItemID(stream: stream, key: key) }

    static var provenance: Provenance { Provenance(stream: stream, origin: .wire) }

    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func toolCall(_ name: String,
                         id key: String = "toolu_invented0000",
                         input: JSONValue = .object([:]),
                         result: JSONValue? = nil,
                         structured: JSONValue? = nil,
                         isError: Bool? = nil,
                         status: ToolCallItem.Status = .completed,
                         messageID: String? = nil,
                         at offset: TimeInterval = 0) -> ToolCallItem {
        ToolCallItem(id: id(key),
                     timestamp: epoch.addingTimeInterval(offset),
                     provenance: provenance,
                     toolUseID: key,
                     name: name,
                     rawInput: input,
                     result: result,
                     isError: isError,
                     structuredResult: structured,
                     messageID: messageID,
                     status: status)
    }

    static func assistant(_ blocks: [ContentBlock], key: String = "a-invented-1",
                          model: String? = "invented-model", at offset: TimeInterval = 0) -> AssistantMessageItem {
        AssistantMessageItem(id: id(key), timestamp: epoch.addingTimeInterval(offset), provenance: provenance,
                             messageID: "msg_invented0000", model: model, blocks: blocks)
    }

    static func text(_ value: String) -> ContentBlock {
        block(["type": .string("text"), "text": .string(value)])
    }

    static func thinking(_ value: String) -> ContentBlock {
        block(["type": .string("thinking"), "thinking": .string(value)])
    }

    /// A content block built the way the engine's own bytes become one: through the decoder.
    /// ClaudeWire's field structs synthesise an *internal* memberwise initialiser, so a block is
    /// constructed from JSON here rather than from fields — which also keeps the invented shapes in
    /// the shape the wire uses.
    static func block(_ object: [String: JSONValue]) -> ContentBlock {
        guard let data = try? JSONValue.object(object).canonicalData(),
              let block = try? JSONDecoder().decode(ContentBlock.self, from: data) else {
            preconditionFailure("an invented content block did not decode as one")
        }
        return block
    }

    /// A `task_started` frame, decoded for the same reason.
    static func taskStarted(taskID: String, toolUseID: String, agentType: String) -> TaskStarted {
        let object: [String: JSONValue] = ["type": .string("system"), "subtype": .string("task_started"),
                                           "task_id": .string(taskID), "tool_use_id": .string(toolUseID),
                                           "description": .string("an invented errand"),
                                           "subagent_type": .string(agentType),
                                           "spawn_depth": .integer(1), "task_type": .string("local_agent"),
                                           "uuid": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                                           "session_id": .string(stream.sessionID.description)]
        guard let data = try? JSONValue.object(object).canonicalData(),
              let frame = try? JSONDecoder().decode(TaskStarted.self, from: data) else {
            preconditionFailure("an invented task_started did not decode as one")
        }
        return frame
    }

    /// A `task_progress` heartbeat for a run already started: the frame that arrives repeatedly while a
    /// run is live and moves nothing a card reads.
    static func taskProgress(taskID: String) -> TaskProgress {
        let object: [String: JSONValue] = ["type": .string("system"), "subtype": .string("task_progress"),
                                           "task_id": .string(taskID),
                                           "description": .string("an invented errand"),
                                           "usage": .object([:]),
                                           "uuid": .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                                           "session_id": .string(stream.sessionID.description)]
        guard let data = try? JSONValue.object(object).canonicalData(),
              let frame = try? JSONDecoder().decode(TaskProgress.self, from: data) else {
            preconditionFailure("an invented task_progress did not decode as one")
        }
        return frame
    }


    /// A render context whose capabilities are the doubles a test hands it.
    ///
    /// `isOwned` defaults to true because a test that says nothing about it is drawing the ordinary
    /// case, a channel of this app's own. The gate itself is asserted against the real construction
    /// site, which is the only place the listing policy can be read.
    @MainActor
    static func context(links: any LinkRouterCapability = RecordingLinkRouter(),
                        agents: any AgentNavigating = NoAgentNavigation(),
                        neighbourhood: TimelineNeighbourhood = TimelineNeighbourhood(),
                        collapse: TimelineCollapseState = TimelineCollapseState(),
                        composer: (any ComposerSite)? = nil,
                        editing: TimelineEditState = TimelineEditState(),
                        signal: @escaping @Sendable (HostSignal) async -> Void = { _ in },
                        decisions: DecisionReservations = DecisionReservations(),
                        lifecycle: (any LifecycleAPI)? = nil,
                        isOwned: Bool = true,
                        retraction: RetractionRegistry = RetractionRegistry(),
                        cwd: URL? = nil,
                        key: ChannelKey? = nil) -> TimelineRenderContext {
        TimelineRenderContext(key: key ?? ChannelKey(configHome: stream.configHome, session: stream.sessionID),
                              links: links,
                              signal: signal,
                              decisions: decisions,
                              lifecycle: lifecycle,
                              isOwned: isOwned,
                              retraction: retraction,
                              cwd: cwd,
                              agents: agents,
                              collapse: collapse,
                              composer: composer,
                              editing: editing,
                              neighbourhood: neighbourhood)
    }
}
