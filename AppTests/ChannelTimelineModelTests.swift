import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Task 7: the per-channel timeline owner and the placeholder timeline (spec §8).
///
/// Every scratch tree here is a `TempTree`, which refuses to build inside any config home, and
/// every identifier the tests invent is a repeated hex nibble. Where a test needs a real transcript
/// it copies one of the twenty committed fixtures into that scratch tree at run time; nothing a
/// fixture holds is written into a committed file and no assertion below compares an engine byte
/// (§11).
@MainActor
final class ChannelTimelineModelTests: XCTestCase {

    // MARK: - Item 1's UI half

    /// Opening an archived channel renders its history from disk and reaches no process.
    ///
    /// **The trace clause names the two seams that would actually spawn.** The first is
    /// `LifecycleAPI` itself: `perform(_:on:)` is the app's only route to a child, so an empty
    /// action log is the app-side half. The second is the `ProcessFactory`, the seam the fleet
    /// builds a process through, installed here where `Fleet` installs it — on `perform(.open)` —
    /// so a run that reached it is a run that spawned. `LaunchSequence.fleetFactory` is deliberately
    /// *not* asserted on: it constructs a `Fleet`, and a `Fleet` exists before any workspace does,
    /// so an assertion on it could never fail.
    func testAnArchivedChannelRendersFromDiskWithNoProcess() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let spawns = SpawnCounter()
        await rig.lifecycle.setSpawn(spawns.factory)
        // So a `perform` that did happen is recorded rather than trapping, which would take the
        // bundle down instead of failing this test.
        await rig.lifecycle.always(.success(SidebarFixtures.state(rig.keys[0], origin: .archived)))

        let model = rig.registry.model(for: rig.keys[0])
        await model.open(rig.row(0))

        XCTAssertFalse(model.items.isEmpty,
                       "an archived channel rendered \(model.items.count) items from disk")
        XCTAssertEqual(model.rows.count, model.items.count,
                       "\(model.items.count) items rendered \(model.rows.count) rows")
        let actions = await rig.lifecycle.actions
        XCTAssertTrue(actions.isEmpty,
                      "opening an archived channel performed \(actions.count) lifecycle action(s)")
        XCTAssertEqual(spawns.count, 0,
                       "opening an archived channel invoked the process factory \(spawns.count) time(s)")
    }

    // MARK: - Every category reaches a row

    /// Over the corpus, the categories the view renders and the categories the projection holds are
    /// the same set, in both directions, and the set is not empty.
    ///
    /// The floor is what makes the comparison mean anything: a corpus that failed to ingest leaves
    /// two empty sets, which are equal, and the test would pass green on a model that read nothing.
    func testEveryTimelineCategoryRendersARow() async throws {
        let names = try Corpus.namesWithAMainTranscript()
        XCTAssertEqual(names.count, Corpus.expectedWithATranscript,
                       "\(names.count) of the committed fixtures carry a main transcript")

        let rig = try await Rig(fixtures: names)
        var projected: Set<TimelineCategory> = []
        var rendered: Set<TimelineCategory> = []
        var ingested = 0

        for (index, _) in names.enumerated() {
            let model = rig.registry.model(for: rig.keys[index])
            await model.open(rig.row(index))
            if !model.items.isEmpty { ingested += 1 }
            projected.formUnion(model.items.map(\.category))
            rendered.formUnion(model.rows.map(\.category))
        }

        XCTAssertEqual(ingested, names.count,
                       "\(ingested) of \(names.count) fixtures produced a non-empty projection")
        XCTAssertFalse(projected.isEmpty, "the corpus projected 0 categories")
        XCTAssertTrue(projected.count >= Corpus.categoryFloor,
                      "the corpus projected \(projected.count) categories, below the floor of \(Corpus.categoryFloor)")
        XCTAssertTrue(projected.isSubset(of: rendered),
                      "\(projected.subtracting(rendered).count) projected categories render no row")
        XCTAssertTrue(rendered.isSubset(of: projected),
                      "\(rendered.subtracting(projected).count) rendered categories are in no projection")
        // What `rendered` reaches, exactly: `ChannelTimelineModel.rows`, the row builder the column
        // draws — not the column. `TimelineRow.init` copies `item.category`, so the two sets are
        // equal by construction unless the builder drops a kind, which is the regression this
        // discriminates. A filter added inside `ChannelTimelineColumn` or `TimelineRowView` would
        // not be seen here; today the view is an unfiltered `List(model.rows)`.
    }

    // MARK: - C3's tap contract

    /// An owned channel's ingestion takes its own `events(of:)` subscription rather than reusing the
    /// Activity pump's.
    ///
    /// The pump subscribes first, exactly as Task 6's does at launch. The model's own call is the
    /// second entry in the double's log and the second live fan-out on the channel, which is what
    /// C3's tap contract asks for: `StreamIngestion` consumes the raw stream where the pump keeps
    /// three folded summaries, and one `AsyncStream` read twice splits its elements rather than
    /// duplicating them.
    func testAnOwnedChannelTakesItsOwnEventSubscription() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let key = rig.keys[0]
        await rig.lifecycle.openEvents(of: key)

        // Task 6's pump, taking the app's one folded subscription for this channel.
        let pump = ChannelEventPump(key: key) { _, _ in }
        let taken = await rig.lifecycle.events(of: key)
        let pumpStream = try XCTUnwrap(taken)
        pump.start(pumpStream)
        let before = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(before.count, 1, "the pump's own subscription was not recorded: \(before.count) call(s)")

        let model = rig.registry.model(for: key)
        await model.open(rig.row(0, origin: .owned(.ready)))

        let after = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(after.count - before.count, 1,
                       "the model took \(after.count - before.count) event subscription(s), not 1")
        XCTAssertEqual(after.filter { $0 == key }.count, after.count,
                       "\(after.filter { $0 != key }.count) subscription(s) named another channel")
        let fanOuts = await rig.lifecycle.fanOutCount(of: key)
        XCTAssertEqual(fanOuts, 2, "\(fanOuts) fan-out(s) are live on the channel, not 2")

        pump.stop()
        await rig.lifecycle.finishEvents(of: key)
    }

    // MARK: - The bounded settle

    /// `StreamIngestion.open` returns on a finished event stream instead of burning its fifty settle
    /// rounds.
    ///
    /// The measured property *is* the elapsed time, so this is a timing assertion and not a wait on
    /// a wall clock. The budget is the ingestion's own: fifty rounds of the twenty-millisecond
    /// default `tapSettle`, one second in total, which the archived path only reaches if the tap it
    /// was given keeps producing.
    func testOpenSettlesOnAFinishedEventStream() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let model = rig.registry.model(for: rig.keys[0])

        let started = ContinuousClock.now
        await model.open(rig.row(0))
        let elapsed = started.duration(to: .now)

        XCTAssertFalse(model.items.isEmpty, "the open that was timed read 0 items")
        XCTAssertLessThan(elapsed, Self.settleBudget,
                          "open took \(elapsed.milliseconds) ms against a \(Self.settleBudget.milliseconds) ms budget")
    }

    /// Twenty-five settle rounds of the twenty-millisecond default `tapSettle`. `StreamIngestion`
    /// keeps both numbers internal to its own module, so they are restated here with their source
    /// named.
    ///
    /// **Half the fifty-round ceiling, and deliberately.** A correct archived open exits after one
    /// round and measures about 45 ms, so the full 1000 ms ceiling left a broken run only 1.46x
    /// above the bound — a chatty tap that fell quiet after half a second would have passed it. This
    /// bound is still comfortably inside the fifty rounds the brief names, keeps 11x of headroom over
    /// the passing path, and fails a tap that burns more than half the rounds instead of all of them.
    private static let settleBudget: Duration = .milliseconds(25 * 20)

    // MARK: - The change feed

    /// A subscriber attached before the file changes sees the change.
    ///
    /// Subscribing first is the whole point: a feed that only ever republished its initial value
    /// would pass a test that read the stream after the change had already been applied. Nothing
    /// here polls — the wait is fulfilled by the delivery itself, and the timeout is a hang guard.
    func testTimelineUpdatesEmitOnIngestion() async throws {
        let rig = try await Rig(inventedChannels: 1)
        let key = rig.keys[0]
        let model = rig.registry.model(for: key)
        await model.open(rig.row(0))

        let first = model.items.count
        XCTAssertGreaterThan(first, 0, "the invented transcript opened with 0 items")

        // Before the change, and before anything is written.
        let updates = model.timelineUpdates
        let grew = XCTestExpectation(description: "a timeline with more than \(first) items")
        let seen = CountBox()
        let reader = Task {
            for await timeline in updates where timeline.items.count > first {
                seen.set(timeline.items.count)
                grew.fulfill()
                return
            }
        }

        try rig.appendRecords(to: 0, count: 2)
        rig.watcher.emit([rig.paths[0]])

        await XCTWaiter().fulfillment(of: [grew], timeout: LaunchFixtures.hangGuard)
        reader.cancel()
        XCTAssertGreaterThan(seen.value, first,
                             "the published timeline held \(seen.value) items against \(first) before the change")
        XCTAssertGreaterThan(model.items.count, first,
                             "the model holds \(model.items.count) items against \(first) before the change")
    }

    // MARK: - The ordering the change feed's window depends on

    /// The change subscription is taken before the transcript is read.
    ///
    /// **Why this is not a black-box assertion.** The design is loss-free by recovery —
    /// `StreamIngestion.fileChanged` reads from the stored offset to end of file, so a batch missed
    /// in the window is replayed by the next write — and both orders therefore converge on the same
    /// timeline. No observation of the *result* can separate them. The ordering itself can be
    /// observed, by parking the model inside `subscribe()` and asking what has happened by then.
    ///
    /// The witness for "the read has not run" is the lifecycle double's `events(of:)` log, because
    /// `open` calls `events(of:)` between the subscribe and the read; the item count is the second,
    /// covering a subscribe moved below the publish as well as one moved below the read. Nothing
    /// here races: the gate is a suspension the test releases.
    func testTheChangeSubscriptionIsTakenBeforeTheFileIsRead() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let key = rig.keys[0]
        // An owned channel, so `events(of:)` really answers and the log would really fill.
        await rig.lifecycle.openEvents(of: key)

        let gate = SubscribeGate(feed: rig.feed)
        rig.registry.changeFeed = gate.subscribe
        let model = rig.registry.model(for: key)

        let opening = Task { await model.open(rig.row(0, origin: .owned(.ready))) }
        await XCTWaiter().fulfillment(of: [gate.reached], timeout: LaunchFixtures.hangGuard)

        let calls = await rig.lifecycle.eventSubscriptions
        XCTAssertTrue(calls.isEmpty,
                      "\(calls.count) event subscription(s) were taken before the change subscription")
        XCTAssertTrue(model.items.isEmpty,
                      "\(model.items.count) items were read before the change subscription")

        gate.release()
        await opening.value
        XCTAssertFalse(model.items.isEmpty, "the released open read 0 items")
        let after = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(after.count, 1, "the released open took \(after.count) event subscription(s), not 1")
        await rig.lifecycle.finishEvents(of: key)
    }

    // MARK: - The header's live half

    /// The header follows a channel whose state changes while it stays selected.
    ///
    /// Two halves, because the defect spanned both. The model half is executable: a second `open`
    /// with a changed row moves all four of §8's live fields and restarts no ingestion. The view
    /// half is a **trace assertion** — a window cannot open in a headless runner, so what is
    /// asserted is the identity the column's opening task is keyed by, which is the thing that
    /// decides whether the second call happens at all. Keyed on the channel alone it never did.
    func testTheHeaderFollowsAChannelWhoseStateChangesWhileItStaysSelected() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"], inventedChannels: 1)
        let key = rig.keys[0]
        let model = rig.registry.model(for: key)

        let quiet = rig.row(0, state: SidebarFixtures.state(key, origin: .owned(.ready)))
        await model.open(quiet)
        let opened = model.items.count
        XCTAssertGreaterThan(opened, 0, "the channel opened with 0 items")
        XCTAssertEqual(model.header.origin, .owned(.ready), "the header did not take the row's origin")
        XCTAssertEqual(model.header.presence, .unknown, "the header did not take the row's presence")
        XCTAssertNil(model.header.banner, "a quiet channel's header carries a banner")
        XCTAssertNil(model.header.systemItem, "a quiet channel's header carries a system item")

        // The same channel, still selected, four live fields later.
        var state = SidebarFixtures.state(key, origin: .owned(.contended))
        state.presence = .busy
        state.banner = .untrusted
        state.systemItem = .crashed(exit: .code(1, stderrTail: ""), reopenOffered: true)
        let loud = rig.row(0, state: state)
        await model.open(loud)

        XCTAssertEqual(model.header.origin, .owned(.contended), "the header's origin did not follow")
        XCTAssertEqual(model.header.presence, .busy, "the header's presence did not follow")
        XCTAssertEqual(model.header.banner, .untrusted, "the header's banner did not follow")
        XCTAssertNotNil(model.header.systemItem, "the header's system item did not follow")
        // Header-only: the second call restarted nothing.
        XCTAssertEqual(model.items.count, opened,
                       "the second open left \(model.items.count) items against \(opened)")
        let subscriptions = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(subscriptions.count, 1,
                       "the second open took \(subscriptions.count) event subscription(s) in total, not 1")

        // The view half. The identity the column's task is keyed by has to separate these two rows,
        // or the second call above never happens in the running app.
        // Spelled as booleans rather than `XCTAssertNotEqual`, whose default message prints both
        // values: a `ChannelColumnOpenKey` carries a config-home path and a session id, and §11
        // keeps both out of a failure message.
        XCTAssertFalse(ChannelColumnOpenKey(quiet) == ChannelColumnOpenKey(loud),
                       "one channel's quiet and loud rows share an opening key")
        XCTAssertTrue(ChannelColumnOpenKey(quiet) == ChannelColumnOpenKey(quiet),
                      "one row does not equal itself, so the task would re-run on every body pass")
        // Two channels whose headers are equal — a restored row carries no origin, no presence and
        // no banner — still have to re-open on a switch.
        XCTAssertFalse(ChannelColumnOpenKey(rig.row(0)) == ChannelColumnOpenKey(rig.row(1)),
                       "two channels with equal headers share an opening key")
    }

    // MARK: - The registry

    /// One model per channel, retained across a switch away and back, and one registry per app.
    ///
    /// The shared-registry assertion the brief pairs with Task 8 —a URL ingested through the model
    /// `ChannelColumnView` draws arriving through the exact `RecentURLFeed` handed to that
    /// channel's `ChannelContext` — lands with Task 8, which is what builds the feed and the
    /// context. What is assertable now is the half that closes the same defect: `AppModel` exposes
    /// exactly one registry, and a channel's model survives a switch.
    func testOneModelPerChannelSurvivesASwitch() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"], inventedChannels: 1)
        let first = rig.registry.model(for: rig.keys[0])
        await first.open(rig.row(0))
        let ingested = first.items.count
        XCTAssertGreaterThan(ingested, 0, "the first channel opened with 0 items")

        // Switch away and back.
        let other = rig.registry.model(for: rig.keys[1])
        await other.open(rig.row(1))
        let again = rig.registry.model(for: rig.keys[0])

        XCTAssertTrue(again === first, "the registry handed back a second model for one channel")
        XCTAssertTrue(again.hasOpened, "the retained model reports itself unopened")
        XCTAssertEqual(again.items.count, ingested,
                       "the retained model holds \(again.items.count) items against \(ingested) before the switch")
        XCTAssertEqual(rig.registry.openChannels.count, 2,
                       "the registry holds \(rig.registry.openChannels.count) models for 2 channels")
    }

    /// `AppModel` carries the one app-scoped registry, and it is the same object across reads.
    ///
    /// Constructing a registry in the channel column and a second one in the panel host is the
    /// defect this instance exists to make unrepresentable; the assertion that `AppModel.timelines`
    /// is one object is the part of it a test can reach before Task 8 lands.
    func testAppModelExposesOneRegistry() async throws {
        let app = AppModel()
        XCTAssertTrue(app.timelines === app.timelines, "AppModel handed back two registries")
        XCTAssertNil(app.timelines.workspace, "an unlaunched registry is already bound to a workspace")
        XCTAssertEqual(app.timelines.openChannels.count, 0,
                       "an unlaunched registry already holds \(app.timelines.openChannels.count) model(s)")
    }
}

// MARK: - Support

/// Parks the model inside its change-feed subscribe call until the test releases it.
///
/// `@unchecked Sendable` is sound because every stored property is a `let` and each is itself
/// thread-safe: `XCTestExpectation` and an `AsyncStream.Continuation` are both safe to touch from
/// any thread, and the iterator is made and consumed on the one task that calls `subscribe`.
private final class SubscribeGate: @unchecked Sendable {
    let reached = XCTestExpectation(description: "the model is inside subscribe()")
    private let feed: TranscriptChangeFeed
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(feed: TranscriptChangeFeed) {
        self.feed = feed
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Lets the parked subscribe finish. Buffered, so a release issued before the gate is reached is
    /// not lost.
    func release() { continuation.yield(()) }

    var subscribe: ChannelTimelineModel.ChangeFeedSubscribing {
        { [self] in
            reached.fulfill()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return await feed.subscribe()
        }
    }
}

/// A `Int` box a detached reader writes and the test reads.
///
/// `@unchecked Sendable` is sound because the one mutable field is `stored`, read and written only
/// inside `lock`, this instance's private `NSLock`.
private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ next: Int) { lock.lock(); stored = next; lock.unlock() }
}

/// The committed corpus, read at run time. A loader of its own rather than C3's `FixtureCorpus`,
/// which lives in `FleetTimelineTests` and is not visible from the app's bundle.
private enum Corpus {
    /// `AppTests/` → the repository root.
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    /// Nineteen of the twenty committed fixtures carry a main transcript; `zero-cost` records a
    /// turn that wrote none. Pinned so a lost transcript fails rather than shrinking the corpus.
    static let expectedWithATranscript = 19
    /// The distinct categories the corpus is known to project. A floor, not an expectation: it
    /// fails a run that ingested a fraction of the corpus and still compared two equal sets.
    static let categoryFloor = 3

    static func namesWithAMainTranscript() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted()
        return try names.filter { try mainTranscript(of: $0) != nil }
    }

    /// `<fixture>/transcript/<slug>/<sessionID>.jsonl`, with the session the file name carries.
    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, url: URL)? {
        let transcripts = root.appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, file)
            }
        }
        return nil
    }

    /// The whole `transcript/` tree of a fixture, copied under a scratch home's `projects/`, so an
    /// agent stream lands where `StreamIngestion` looks for it.
    static func place(_ name: String, under projects: URL) throws {
        let transcripts = root.appending(path: name).appending(path: "transcript")
        let slugs = try FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        for slug in slugs {
            let destination = projects.appending(path: "\(name)-\(slug.lastPathComponent)", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: slug, to: destination)
        }
    }
}

/// A workspace over a scratch config home, with the channels a test opens already on disk.
///
/// Built by hand rather than through `LaunchSequence` because what is under test is the timeline
/// owner, and a launch would add a binary probe, a version gate and a sign-in gate, each of which
/// can fail for reasons that say nothing about §8.
@MainActor
private struct Rig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let watcher: StubWatcher
    /// The real feed behind `workspace.changes`, so the ordering test's gate can return a genuine
    /// subscription once it has been released.
    let feed: TranscriptChangeFeed
    let keys: [ChannelKey]
    let paths: [URL]
    let titles: [String]

    /// `fixtures` are copied out of the committed corpus; `inventedChannels` are transcripts this
    /// test wrote itself. The two lists concatenate in that order, and `keys[i]` names `paths[i]`.
    init(fixtures: [String] = [], inventedChannels: Int = 0) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        var keys: [ChannelKey] = []
        var paths: [URL] = []
        var titles: [String] = []
        let configHome = home.configHome

        for name in fixtures {
            guard let main = try Corpus.mainTranscript(of: name) else {
                throw Bail("fixture \(name) carries no main transcript")
            }
            try Corpus.place(name, under: projects)
            keys.append(ChannelKey(configHome: configHome.root, session: main.session))
            paths.append(projects.appending(path: "\(name)-\(main.slug)").appending(path: main.url.lastPathComponent))
            titles.append("a recorded channel")
        }
        for index in 0..<inventedChannels {
            let session = SidebarFixtures.session(String(index, radix: 16))
            let url = try LaunchFixtures.transcript(in: home.root, slug: "invented-\(index)", session: session)
            keys.append(ChannelKey(configHome: configHome.root, session: session))
            paths.append(url)
            titles.append("an invented channel")
        }
        self.keys = keys
        self.paths = paths
        self.titles = titles

        let index = TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()

        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        watcher = StubWatcher()
        feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)))

        registry = ChannelTimelineRegistry()
        registry.attach(to: workspace, lifecycle: lifecycle)
    }

    /// The row the channel column would hand the model. `state` overrides `origin` when both are
    /// given; the live half is what the header reads.
    func row(_ index: Int, origin: ChannelOrigin? = nil, state: ChannelState? = nil) -> ChannelRow {
        let key = keys[index]
        return ChannelRow(key: key,
                          title: titles[index],
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
                          state: state ?? origin.map { SidebarFixtures.state(key, origin: $0) })
    }

    /// Appends `count` further records to a channel's transcript, each with its own invented uuid.
    func appendRecords(to index: Int, count: Int) throws {
        let url = paths[index]
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let session = keys[index].session
        // Chained onto the assistant record `LaunchFixtures.transcript` wrote. A record with a nil
        // `parentUuid` starts a second root, and the reducer keeps one branch: two unparented
        // appends applied cleanly and changed no item at all, which is how this was found.
        var parent = "00000000-0000-4000-8000-000000000002"
        for step in 0..<count {
            let uuid = String(format: "00000000-0000-4000-8000-%012x", 0x100 + step)
            let line = #"{"type":"user","sessionId":"\#(session)","uuid":"\#(uuid)","parentUuid":"\#(parent)","isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:0\#(2 + step).000Z","message":{"role":"user","content":"invented follow-up"}}"# + "\n"
            try handle.write(contentsOf: Data(line.utf8))
            parent = uuid
        }
        // The leaf moves with the append. `LaunchFixtures.transcript` ends with a `last-prompt`
        // naming the first user record, and the reducer projects one branch: records past the named
        // leaf apply cleanly and appear in no projection, which is how this was found.
        let leaf = #"{"type":"last-prompt","sessionId":"\#(session)","leafUuid":"\#(parent)","lastPrompt":"invented follow-up"}"# + "\n"
        try handle.write(contentsOf: Data(leaf.utf8))
    }
}

private struct Bail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
