import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet


/// A workspace over a scratch config home, with the host and the timeline registry attached to it
/// exactly as `AppModel.bindWorkspace` attaches them.
///
/// Built by hand rather than through `LaunchSequence` because what is under test is the panel host,
/// and a launch would add a binary probe, a version gate and a sign-in gate, each of which can fail
/// for reasons that say nothing about §7.
@MainActor
struct PanelRig {

    /// The invented identifiers the rig itself needs, and the one place they are spelled (§11).
    /// `PanelFixtures` reads them from here so a suite and its rig cannot name two channels while
    /// meaning one.
    nonisolated static let cwd = URL(fileURLWithPath: "/invented/project")

    /// A v4-shaped session id from an index, so twenty distinct channels read as twenty numbers.
    nonisolated static func session(_ index: Int) -> SessionID {
        SessionID(String(format: "%08x-0000-4000-8000-%012x", index, index))!
    }

    nonisolated static func url(_ index: Int) -> URL {
        URL(string: "https://invented.example/page-\(index)")!
    }

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let host: PanelHostModel
    let timelines: ChannelTimelineRegistry
    let browser: FleetBrowserModel
    let shell: ShellModel
    let watcher: StubWatcher
    let keys: [ChannelKey]
    let paths: [URL]

    /// `urlsPerChannel` transcripts carry that many assistant messages naming an invented URL each;
    /// zero writes the plain two-record transcript.
    ///
    /// `shellPath` is what `ResolvedEnvironment.shell` resolves to for every channel this rig makes,
    /// and so what a shell pane in one of them actually spawns. Its default is the login shell
    /// `LaunchFixtures.environment` has always returned, so a caller that does not name one gets
    /// the environment this rig has always built.
    init(channels: Int, urlsPerChannel: Int = 0, shellPath: String = "/bin/zsh") async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let configHome = home.configHome

        var keys: [ChannelKey] = []
        var paths: [URL] = []
        for index in 0..<channels {
            let session = PanelRig.session(index)
            let url: URL
            if urlsPerChannel > 0 {
                url = try PanelRig.transcriptWithURLs(in: home.root, slug: "invented-\(index)",
                                                      session: session, urls: urlsPerChannel)
            } else {
                url = try LaunchFixtures.transcript(in: home.root, slug: "invented-\(index)", session: session)
            }
            keys.append(ChannelKey(configHome: configHome.root, session: session))
            paths.append(url)
        }
        self.keys = keys
        self.paths = paths

        let index = TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        let captured = LaunchFixtures.environment(home: temp.root, configHome: home.root)
        workspace = Workspace(configHome: configHome,
                              environment: ResolvedEnvironment(variables: captured.variables,
                                                               shell: shellPath,
                                                               capturedAt: captured.capturedAt,
                                                               mode: captured.mode),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)

        timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        host = PanelHostModel()
        shell = ShellModel(panels: host)
        host.attach(to: workspace, timelines: timelines, lifecycle: lifecycle)
        browser = FleetBrowserModel(lifecycle: lifecycle, configHome: configHome.root)
        browser.paint(LaunchFixtures.snapshot(configHome: configHome.root, ids: keys.map(\.session)),
                      listing: nil, origin: .built)
    }

    /// The row the channel column would hand the timeline model.
    func row(_ index: Int) -> ChannelRow {
        ChannelRow(key: keys[index],
                   title: "an invented channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: PanelRig.cwd,
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: nil)
    }

    /// Appends one assistant message naming `PanelRig.url(index)`, and moves the leaf onto it.
    ///
    /// The leaf has to move: `RecordReducer` projects the chain the closing `last-prompt` names, so
    /// a record appended past the named leaf applies cleanly and appears in no projection.
    func appendURL(to channel: Int, index: Int) throws {
        let handle = try FileHandle(forWritingTo: paths[channel])
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(PanelRig.assistantWithURL(session: keys[channel].session,
                                                                    index: index).utf8))
    }

    /// One user record and `count` assistant records, each naming its own invented URL, with the
    /// leaf on the last of them.
    private static func transcriptWithURLs(in configHome: URL, slug: String, session: SessionID,
                                           urls count: Int) throws -> URL {
        let directory = configHome.appending(path: "projects/\(slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var body = #"{"type":"user","sessionId":"\#(session)","uuid":"\#(uuid(0))","parentUuid":null,"isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"invented prompt"}}"# + "\n"
        for index in 0..<count { body += assistantWithURL(session: session, index: index) }
        let file = directory.appending(path: "\(session).jsonl")
        try Data(body.utf8).write(to: file)
        return file
    }

    /// An assistant record naming one invented URL, followed by the `last-prompt` that makes it the
    /// projected leaf. Its parent is the record before it, so the chain stays one branch.
    private static func assistantWithURL(session: SessionID, index: Int) -> String {
        let me = uuid(index + 1)
        let parent = uuid(index)
        let text = "invented reply naming \(PanelRig.url(index).absoluteString)"
        let record = #"{"type":"assistant","sessionId":"\#(session)","uuid":"\#(me)","parentUuid":"\#(parent)","isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:0\#(index + 1).000Z","message":{"id":"msg_invented\#(index)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        let leaf = #"{"type":"last-prompt","sessionId":"\#(session)","leafUuid":"\#(me)","lastPrompt":"invented prompt"}"# + "\n"
        return record + leaf
    }

    private static func uuid(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012x", index)
    }
}
