import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// One channel of the app over a committed recording, in the shape `TimelineFixtureGateTests`'
/// `GateRig` takes — that one is `private` to its file, so this is its shape and not a second route
/// to it.
///
/// **It is this leaf's one replay rig and lives in a file of its own** so both gates drive the same
/// ingestion. G1 asks what the tree reads and G2 asks what one run's transcript draws, and the two
/// answers have to come from the same open of the same recording or the second is a claim about a
/// corpus rather than about the app.
///
/// It drives `ChannelTimelineModel`, not `StreamIngestion`: what this gate is about is what the
/// panel draws, and the panel reads the model's published timeline.
@MainActor
struct AgentGateRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey
    let fixture: String

    var model: ChannelTimelineModel { registry.model(for: key) }

    /// The tool-use id the replay's barrier names. Invented, so the cluster it opens is one no
    /// recorded frame can open and its arrival means the replay before it was consumed.
    static let barrierLead = "toolu_invented_agent_barrier"

    static func rowKey(of lead: String) -> String { "cluster:\(lead)" }

    /// `owned: false` opens the channel from its transcript files alone and never opens an event
    /// stream — every archived and every foreign session.
    ///
    /// `sidecars: false` copies the recording's transcripts **without** their `.meta.json` files, so
    /// the channel opens on a session whose sidecars the engine has not flushed yet — §7.3's ordinary
    /// case, and G1's "before the `.meta.json` is written". Nothing else about the open changes: the
    /// same frames are replayed into the same fold, and the only source withheld is the file one.
    init(fixture: String, owned: Bool = true, sidecars: Bool = true) async throws {
        self.fixture = fixture
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        guard let main = try Self.mainTranscript(of: fixture) else {
            throw AgentGateBail("fixture carries no main transcript")
        }
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let copied = projects.appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: main.slugDirectory, to: copied)
        if !sidecars { try Self.removeSidecars(under: copied) }
        key = ChannelKey(configHome: home.configHome.root, session: main.session)

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: home.configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs",
                                                                                              directoryHint: .isDirectory)),
                              rawCapture: nil)
        registry = ChannelTimelineRegistry()
        registry.attach(to: workspace, lifecycle: lifecycle)
        if owned { await lifecycle.openEvents(of: key) }
        await model.open(row())
    }

    func finish() async {
        await lifecycle.finishEvents(of: key)
        registry.release(key)
    }

    // MARK: - What the panel reads

    /// The read the panel derives, through the same expression the pane uses.
    func read() -> AgentRunRead { AgentRunRead(timeline: model.timeline) }

    /// The pane's session over this channel, reaching the one registry through a closure.
    func pane() -> AgentsModel {
        AgentsModel(channel: key, timelines: { [registry] key in registry.model(for: key).timeline },
                    store: AgentSelectionStore())
    }

    // MARK: - The replay

    @discardableResult
    func replay() async throws -> Int {
        let events = try FixtureRunner.events(fixture)
        for event in events { await push(event) }
        try await pushBarrier(Self.barrierLead)
        return events.count
    }

    func push(_ event: WireEvent) async { await lifecycle.push(event, to: key) }

    func pushBarrier(_ lead: String) async throws {
        await lifecycle.push(try Self.summaryFrame(lead: lead), to: key)
    }

    func settleOnBarrier() async -> Bool { await settle(on: Self.barrierLead) }

    /// Waits for the row a barrier's cluster makes. `ItemID.cluster(stream:leadToolUseID:)` prefixes
    /// the lead id, so a wait keyed on the bare id waits for a row the fold never makes.
    func settle(on lead: String) async -> Bool {
        await settle { model in model.rows.contains { $0.id.key == Self.rowKey(of: lead) } }
    }

    func settleOnRuns(_ count: Int) async -> Bool {
        await settle { $0.timeline.agents?.nodes.count == count }
    }

    /// A file-only channel pushes nothing, so its wait is on the open having produced items.
    func settleOnOpen() async -> Bool {
        await settle { $0.hasOpened && !$0.timeline.items.isEmpty }
    }

    /// Waits, bounded, for the model to satisfy `predicate`, and **answers whether it did**, so
    /// every caller asserts the outcome of its own wait.
    func settle(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<600 {
            if predicate(model) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(model)
    }

    // MARK: - Injected frames

    /// A `tool_use_summary`, built by hand because no committed fixture carries one. Every
    /// identifier in it is invented — a word and a repeated nibble (§11).
    static func summaryFrame(lead: String) throws -> WireEvent {
        try frame(["type": .string("tool_use_summary"),
                   "summary": .string("an invented replay barrier"),
                   "preceding_tool_use_ids": .array([.string(lead)]),
                   "uuid": .string("bbbbbbbb-3333-4333-8333-bbbbbbbbbbbb"),
                   "session_id": .string("cccccccc-4444-4444-8444-cccccccccccc")])
    }

    /// A second `task_started` for an id the tree already holds — the re-engagement
    /// `nested-depth-2`'s README says a host must expect. The task id and the tool-use id are the
    /// recording's own, read back out of the tree rather than written down here.
    static func taskStartedFrame(taskID: String, toolUseID: String) throws -> WireEvent {
        try frame(["type": .string("system"), "subtype": .string("task_started"),
                   "task_id": .string(taskID), "tool_use_id": .string(toolUseID),
                   "description": .string("an invented re-engagement"),
                   "task_type": .string("local_agent"),
                   "uuid": .string("bbbbbbbb-5555-4555-8555-bbbbbbbbbbbb"),
                   "session_id": .string("cccccccc-4444-4444-8444-cccccccccccc")])
    }

    /// Every `.meta.json` under a copied transcript tree, removed before the channel is opened.
    /// Counted and asserted: a copy that held none would make the withholding a no-op and the arm
    /// above would be measuring nothing.
    private static func removeSidecars(under directory: URL) throws {
        var removed = 0
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        for case let url as URL in files ?? .init() where url.lastPathComponent.hasSuffix(".meta.json") {
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        guard removed > 0 else { throw AgentGateBail("the copied transcripts carry no sidecar to withhold") }
    }

    /// An invented `agent-<taskId>.meta.json` naming an invented parent: a second source that
    /// **disagrees** with what the tree already holds. Every value in it is this test's own — the
    /// task id is the one the tree is keyed on and is written into the file name, never printed.
    func disagreeingSidecar(taskID: String) throws -> URL {
        try temp.file("sidecars/agent-\(taskID).meta.json",
                      #"{"agentType": "an-invented-type", "description": "an invented disagreement", "#
                      + #""toolUseId": "toolu_invented_conflict", "parentAgentId": "a0000000invented0", "#
                      + #""spawnDepth": 2}"#)
    }

    private static func frame(_ object: [String: JSONValue]) throws -> WireEvent {
        .frame(FrameDecoder.decode(line: try JSONValue.object(object).canonicalData()), .first)
    }

    // MARK: - Layout

    func row() -> ChannelRow {
        ChannelRow(key: key,
                   title: "a recorded channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: URL(fileURLWithPath: "/invented/project"),
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: SidebarFixtures.state(key, origin: .owned(.ready)))
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = FixtureRunner.repositoryRoot.appending(path: "Fixtures")
            .appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, slug)
            }
        }
        return nil
    }
}

/// A bail with a fixed sentence: it names no fixture, no path and no session (§11).
struct AgentGateBail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
