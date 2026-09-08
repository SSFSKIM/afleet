import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 0: the two seams a channel's timeline model owns, and tracker 66.
///
/// **The channel's wire fold is not here.** An earlier revision of this suite drove a `WireReducer`
/// of the app's own over a second `events(of:)` subscription; the architect moved that fold into
/// `StreamIngestion`, where one channel has one of them, so what the app owns is the raise site for
/// host signals and nothing else. The assertions below are therefore about *subscription count*,
/// *forwarding* and *retry* — the three things observable from this side — and the behaviour a
/// signal produces is asserted against the ingestion, in C3's own suite, once its corrective lands.
///
/// Every config home here is a scratch tree under `TempTree`, which refuses to build inside any
/// config home; the fixture transcript is copied into it at run time. No assertion prints a path, a
/// session id or an engine byte (§11).
@MainActor
final class ChannelTimelineSeamTests: XCTestCase {

    // MARK: - One subscription

    /// The model takes **exactly one** `events(of:)` subscription for a channel, and it is not the
    /// Activity pump's.
    ///
    /// One channel, one wire fold, and it is `StreamIngestion`'s: the ingestion consumes the raw
    /// stream and holds the reducer. `LifecycleAPI.events(of:)` hands back a fresh unbounded fan-out
    /// per call, so a second consumer is *legal* — which is exactly why the count has to be asserted
    /// rather than assumed. A second subscription would be a second fold's worth of every frame in
    /// the channel, for a fold that no longer exists on this side.
    func testTheModelTakesOneEventSubscription() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        let key = rig.key

        // Task 6's pump, taking the app's one folded subscription, exactly as it does at launch.
        let pump = ChannelEventPump(key: key) { _, _ in }
        let taken = await rig.lifecycle.events(of: key)
        pump.start(try XCTUnwrap(taken, "the double answered no event stream for an owned channel"))
        let before = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(before.count, 1, "the pump's own subscription was not recorded: \(before.count) call(s)")

        await rig.open()

        let after = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(after.count - before.count, 1,
                       "the model took \(after.count - before.count) event subscription(s), not 1")
        XCTAssertEqual(after.filter { $0 == key }.count, after.count,
                       "\(after.filter { $0 != key }.count) subscription(s) named another channel")
        let fanOuts = await rig.lifecycle.fanOutCount(of: key)
        XCTAssertEqual(fanOuts, 2, "\(fanOuts) fan-out(s) are live on the channel, not 2")

        pump.stop()
        await rig.finish()
    }

    // MARK: - The host-signal seam

    /// A host signal raised on the model reaches the ingestion seam, once per call.
    ///
    /// `HostSignal` is modelled by C3 and was constructed nowhere in the tree: the fold has always
    /// known how to move a decision out of `.pending` and to give a turn its `.prompted`
    /// attribution, and nothing ever raised one. `ChannelTimelineModel.signal(_:)` is the raise
    /// site, and C6.2 and C6.3 call it by that name — after `.send` and an honoured rewind, and
    /// after a successful `perform(.answer)`.
    ///
    /// What is asserted is the only half the app can observe: the seam was called, exactly once,
    /// with the signal it was handed. **What the signal then does to the overlay is the ingestion's
    /// behaviour and is asserted there**, against C3's corrective, not here against a double.
    /// Without the count clause this would pass against a forwarder that forwards nowhere.
    func testSignalReachesTheIngestionSeam() async throws {
        let rig = try await SeamRig(fixture: "permission-allow")
        await rig.open()

        let seen = SignalLog()
        rig.model.ingestionSignal = { await seen.record($0) }

        let empty = await seen.count
        XCTAssertEqual(empty, 0, "the seam recorded \(empty) signal(s) before one was raised")

        await rig.model.signal(.promptSent(uuid: "00000000-0000-4000-8000-0000000000a1", at: Date()))
        let one = await seen.count
        XCTAssertEqual(one, 1, "one raised signal reached the seam \(one) time(s)")

        await rig.model.signal(.rewound(toUUID: "00000000-0000-4000-8000-0000000000a2"))
        let two = await seen.count
        XCTAssertEqual(two, 2, "two raised signals reached the seam \(two) time(s)")

        let kinds = await seen.kinds
        XCTAssertEqual(kinds, ["promptSent", "rewound"],
                       "the seam received \(kinds.count) signal(s) in an order or shape it was not handed")
        await rig.finish()
    }

    /// A relocation reaches both halves of the move: the ingestion's own rebind, and the seam.
    ///
    /// `relocated` is the one signal C6.1 raises itself, because it owns the path the index reports.
    /// The two are separate calls on purpose — `StreamIngestion.relocated(mainPath:)` rebinds the
    /// stream it reads, and the signal is what the fold hears — so a version that dropped either is
    /// a version that keeps reading the old path or keeps the old slug on the agent tree.
    func testARelocationRaisesTheSignalToo() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        await rig.open()

        let seen = SignalLog()
        rig.model.ingestionSignal = { await seen.record($0) }

        // A different path under the same scratch home; the model compares before it acts, so a
        // path equal to the one it holds would raise nothing and prove nothing.
        let moved = rig.transcriptDestination
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "invented-moved", directoryHint: .isDirectory)
            .appending(path: rig.transcriptDestination.lastPathComponent)
        await rig.model.transcriptMoved(to: moved)

        let kinds = await seen.kinds
        XCTAssertEqual(kinds, ["relocated"], "a relocation raised \(kinds.count) signal(s), not 1")

        // Idempotent: the coordinator forwards the entry's path on every index update, and only a
        // path that actually moved is worth raising.
        await rig.model.transcriptMoved(to: moved)
        let again = await seen.count
        XCTAssertEqual(again, 1, "a repeated relocation to the same path raised \(again) signal(s)")
        await rig.finish()
    }

}

// MARK: - Support

/// Records what `ChannelTimelineModel.ingestionSignal` was handed.
///
/// `kinds` names the case and never its payload: a `relocated` carries a path and a `promptSent` a
/// uuid, and neither belongs in an assertion message (§11).
private actor SignalLog {
    private(set) var signals: [HostSignal] = []
    var count: Int { signals.count }
    var kinds: [String] {
        signals.map { signal in
            switch signal {
            case .promptSent: "promptSent"
            case .decisionAnswered: "decisionAnswered"
            case .rewound: "rewound"
            case .processReplaced: "processReplaced"
            case .relocated: "relocated"
            }
        }
    }
    func record(_ signal: HostSignal) { signals.append(signal) }
}

/// One channel over a scratch config home, with a committed fixture's transcript on disk.
///
/// Built by hand rather than through `LaunchSequence`, like `ChannelTimelineModelTests`' own rig: a
/// launch adds a binary probe, a version gate and a sign-in gate, each of which can fail for reasons
/// that say nothing about these seams.
@MainActor
private struct SeamRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey
    let transcriptSource: URL
    let transcriptDestination: URL

    var model: ChannelTimelineModel { registry.model(for: key) }

    init(fixture: String, placeTranscript: Bool = true) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        guard let main = try Self.mainTranscript(of: fixture) else {
            throw Bail("fixture \(fixture) carries no main transcript")
        }
        transcriptSource = main.slugDirectory
        transcriptDestination = projects
            .appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
            .appending(path: "\(main.session).jsonl")
        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        if placeTranscript { try Self.place(source: transcriptSource, at: transcriptDestination) }

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
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)
        registry = ChannelTimelineRegistry()
        registry.attach(to: workspace, lifecycle: lifecycle)
        // An owned channel, so `events(of:)` really answers and the subscription count is real.
        await lifecycle.openEvents(of: key)
    }

    /// Puts the fixture's transcript on disk after the fact, for the retry test.
    func placeTranscript() throws {
        try Self.place(source: transcriptSource, at: transcriptDestination)
    }

    private static func place(source: URL, at destination: URL) throws {
        let slug = destination.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: slug.path) else { return }
        try FileManager.default.createDirectory(at: slug.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: slug)
    }

    func open() async { await model.open(row()) }
    func finish() async { await lifecycle.finishEvents(of: key) }

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

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = fixtures.appending(path: name).appending(path: "transcript")
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

private struct Bail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
