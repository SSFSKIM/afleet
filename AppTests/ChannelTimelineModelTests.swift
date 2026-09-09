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

    /// A config home reached through a symlink opens.
    ///
    /// `TranscriptIndex` canonicalises the root it was given and every path it discovers, so an
    /// entry's path is spelled through the resolved directory. Ingestion constructed with the
    /// workspace's own — unresolved — root then meets `TranscriptPath.resolve`, which is a lexical
    /// prefix check: the two spellings share no prefix, the path names no stream, and
    /// `StreamIngestion.open` reaches its `preconditionFailure` and takes the process down. Not a
    /// contrived home: a linked `TMPDIR` or a linked home is the ordinary case (tracker entry 54).
    ///
    /// What it asserts is that the channel is *readable*, not merely that nothing trapped, so a
    /// version that resolved the path and then read nothing fails too.
    func testAConfigHomeReachedThroughASymlinkOpens() async throws {
        let rig = try await Rig(inventedChannels: 1, throughSymlink: true)
        let model = rig.registry.model(for: rig.keys[0])

        await model.open(rig.row(0))

        XCTAssertNil(model.failure, "a symlinked config home reported a failure")
        XCTAssertGreaterThan(model.items.count, 0,
                             "a channel under a symlinked config home rendered \(model.items.count) items")
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
        // discriminates. A filter added inside `ChannelTimelineColumn` or a row builder registered
        // with `RowRegistry` would not be seen here; today the view is an unfiltered
        // `List(model.rows)` whose every row resolves through that registry.
    }

    /// Every row carries the item it was built from, and the three derived fields agree with it.
    ///
    /// Contract Y1's builder receives a `TimelineRow` and nothing else, so this is the assertion
    /// that the row is a *view of the item* rather than a summary of it (C6.1's amendment). Both
    /// directions and a floor: a corpus that failed to ingest leaves nothing to disagree, and the
    /// item count is checked against the model's own before anything is compared.
    func testARowCarriesTheItemItWasBuiltFrom() async throws {
        let names = try Corpus.namesWithAMainTranscript()
        let rig = try await Rig(fixtures: names)
        var rows = 0
        var mismatched = 0

        for (index, _) in names.enumerated() {
            let model = rig.registry.model(for: rig.keys[index])
            await model.open(rig.row(index))
            XCTAssertEqual(model.rows.count, model.items.count,
                           "\(model.items.count) items rendered \(model.rows.count) rows")
            for (row, item) in zip(model.rows, model.items) {
                rows += 1
                // `.key` and not the whole `ItemID`: the id carries the config-home path (§11).
                if row.item.id.key != row.id.key { mismatched += 1 }
                if row.item.category != row.category { mismatched += 1 }
                if row.item.id.key != item.id.key { mismatched += 1 }
            }
        }

        XCTAssertGreaterThan(rows, Corpus.rowFloor,
                             "the corpus rendered \(rows) rows, below the floor of \(Corpus.rowFloor)")
        XCTAssertEqual(mismatched, 0, "\(mismatched) row/item disagreement(s) across \(rows) rows")
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

    // MARK: - The settle

    /// `ChannelTimelineModel.open` settles once the ingestion's event stream is over.
    ///
    /// An archived channel has no supervisor, so the model hands `StreamIngestion.open` an
    /// already-finished stream; this is the app-side assertion that the whole pipeline behind that
    /// call returns and publishes rather than hanging on a tap that will never speak.
    ///
    /// **The wait is fulfilled by the settle, not by a clock.** The earlier version of this test
    /// measured the elapsed time of the `open` and compared it against a few hundred milliseconds,
    /// which made a busy machine — a parallel build alongside the bundle — indistinguishable from a
    /// pipeline that never settled, and it failed twice on exactly that. The timeout below is
    /// `LaunchFixtures.hangGuard` and exists only to turn a hang into a failure. How *fast* the
    /// ingestion gives up on a quiet tap is a separate claim and is guarded separately, in
    /// `IngestionTests.testOpenGivesUpOnAQuietTapAfterOneRound`, where `tapSettle` is injectable and
    /// the bound can be set where load cannot reach it.
    func testOpenSettlesOnAFinishedEventStream() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let model = rig.registry.model(for: rig.keys[0])
        let row = rig.row(0)

        let settled = XCTestExpectation(description: "open returned on a finished event stream")
        let opener = Task { @MainActor in
            await model.open(row)
            settled.fulfill()
        }

        // Asserted, not merely awaited: on a timeout the run would otherwise fall through to the
        // item clause, which reads the model directly and could pass on a half-built open.
        let outcome = await XCTWaiter().fulfillment(of: [settled], timeout: LaunchFixtures.hangGuard)
        opener.cancel()
        XCTAssertEqual(outcome, .completed,
                       "open did not settle on a finished event stream inside the hang guard")
        XCTAssertFalse(model.items.isEmpty, "the settled open read 0 items")
    }

    // MARK: - D11's retraction, from the state the fold publishes

    /// §8.4: the refusal dialog's `retractedMessageUuids` are evicted "on resolution, whatever the
    /// choice, **or when a `control_cancel_request` retires the dialog**".
    ///
    /// The binary retiring a dialog is a resolution nobody pressed, so a registry fed only by a
    /// card's success callback never hears about it — and the messages the refusal took back stay
    /// on screen for the life of the channel. This drives the whole thing through the running
    /// channel: recorded frames and the recorded refusal go in on the wire, the binary's
    /// cancellation follows, and **no card is ever built and no answer is ever sent**, which is what
    /// separates a registry fed from the published overlay from one fed by a view.
    ///
    /// Both directions, and both readers of the registry: C6.1's list filter drops the retracted
    /// rows and keeps every other row, and a host reaching the channel's fold the way the Thread tab
    /// does — through the app's one `ChannelTimelineRegistry` — reads the same eviction.
    func testACancelledRefusalRetractsItsMessagesWithNoCardEverDrawn() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let key = rig.keys[0]
        await rig.lifecycle.openEvents(of: key)
        let model = rig.registry.model(for: key)
        await model.open(rig.row(0, origin: .owned(.ready)))

        let streamed = await Self.settle(until: { Self.messageKeys(of: model).count > 1 })
        XCTAssertTrue(streamed, "the channel holds \(Self.messageKeys(of: model).count) message(s), fewer than 2")
        let retracted = Array(Self.messageKeys(of: model).prefix(2))

        // A refusal naming those two, which is the shape §8.4 describes and the shape no recording
        // carries: the recorded refusals each name one. It is the recorded request with its
        // `retractedMessageUuids` replaced, so everything but the list under test is the engine's.
        let request = try FixtureRunner.request("dialog-refusal-fallback", subtype: "request_user_dialog",
                                                id: "invented-refusal-1",
                                                overrides: ["payload": ["originalModel": "invented-original",
                                                                        "fallbackModel": "invented-fallback",
                                                                        "retractedMessageUuids": retracted]])
        rig.lifecycle.enqueue(.request(request), to: key)
        let raised = await Self.settle(until: { model.timeline.overlay.decisions[request.id] != nil })
        XCTAssertTrue(raised, "the refusal never reached the channel's fold")

        // The messages are on screen while the dialog is open — a registry that evicted on receipt
        // would already have taken them, and the clause below could not tell it from a working one.
        XCTAssertTrue(retracted.allSatisfy { uuid in
            TimelineListView.retained(model.rows, by: model.retraction).contains { $0.item.id.key == uuid }
        }, "a message was evicted while its dialog was still open")

        // The binary retires the dialog. Nothing is pressed and no card exists.
        rig.lifecycle.enqueue(.requestCancelled(request.id, .first), to: key)

        let evicted = await Self.settle(until: {
            let drawn = TimelineListView.retained(model.rows, by: model.retraction)
            return retracted.allSatisfy { uuid in !drawn.contains { $0.item.id.key == uuid } }
        })
        XCTAssertTrue(evicted, "the retired dialog left \(retracted.count) retracted message(s) on screen")

        let survivors = model.rows.filter { row in !retracted.contains(row.item.id.key) }
        XCTAssertGreaterThan(survivors.count, 0, "the channel holds nothing but the retracted messages")
        let drawn = TimelineListView.retained(model.rows, by: model.retraction)
        XCTAssertEqual(drawn.count, survivors.count,
                       "the filter drew \(drawn.count) of \(survivors.count) unretracted row(s)")

        // The second reader: the same fold reached the way the Thread tab reaches it.
        let elsewhere = rig.registry.model(for: key).retraction
        let doomed = model.rows.filter { retracted.contains($0.item.id.key) }
        XCTAssertEqual(doomed.count, retracted.count,
                       "the channel holds \(doomed.count) of the \(retracted.count) retracted messages")
        XCTAssertTrue(doomed.allSatisfy { !elsewhere.retains($0.item) },
                      "a host reaching the channel's fold does not see the eviction")

        // And nothing was answered: this whole eviction happened with no card and no wire traffic.
        let actions = await rig.lifecycle.actions.filter { if case .answer = $0.action { return true } else { return false } }
        XCTAssertEqual(actions.count, 0, "the retired dialog put \(actions.count) answer(s) on the wire")
    }

    /// The keys of the message rows this channel holds, in the fold's order.
    private static func messageKeys(of model: ChannelTimelineModel) -> [String] {
        model.rows.compactMap { row in
            switch row.item {
            case .assistantMessage, .userMessage: row.item.id.key
            default: nil
            }
        }
    }

    /// A bounded wait on a condition the ingestion fulfils asynchronously. It is a hang guard and
    /// not a measurement: the publish is coalesced at thirty hertz and the fold runs on an actor,
    /// so there is no synchronous point to read.
    private static func settle(until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(LaunchFixtures.hangGuard)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

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

        // The outcome is asserted, not just awaited. A dropped result makes the wait look like the
        // assertion when it is not one: on a timeout the run would fall through to the clauses
        // below, and the second of them reads the model directly rather than the published feed.
        let outcome = await XCTWaiter().fulfillment(of: [grew], timeout: LaunchFixtures.hangGuard)
        reader.cancel()
        XCTAssertEqual(outcome, .completed, "the model published no timeline holding the appended items")
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
        // The outcome is asserted, not just awaited. On a timeout the model never entered
        // `subscribe()`, nothing had happened yet, and both clauses below would pass on an open
        // that had not started — the two things they exist to separate would be untested.
        let reached = await XCTWaiter().fulfillment(of: [gate.reached], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(reached, .completed, "the model never reached its change-feed subscription")

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
        // The other writer of the header. The column no longer opens the channel to refresh it: it
        // watches `ChannelHeader(row:)` and calls `adopt` on every change, so `adopt` has to move
        // all four fields on its own and has to leave the ingestion alone.
        model.adopt(ChannelHeader(row: quiet))
        XCTAssertEqual(model.header.origin, .owned(.ready), "adopt did not move the header's origin")
        XCTAssertEqual(model.header.presence, .unknown, "adopt did not move the header's presence")
        XCTAssertNil(model.header.banner, "adopt did not clear the header's banner")
        XCTAssertNil(model.header.systemItem, "adopt did not clear the header's system item")
        XCTAssertEqual(model.items.count, opened,
                       "adopt left \(model.items.count) items against \(opened)")

        // **What is not asserted, and the substitute.** That the column carries the `onChange` at
        // all is a one-line binding inside a `body`, and a window cannot open in this runner. The
        // previous revision asserted on a bespoke identity type the view had to construct, which the
        // review had that view drop; inventing another such type so a test could see it would be an
        // artefact built for the test rather than for the app. So the wiring itself rests on review
        // and on the manual witness, and what is executable — that both writers of the header move
        // all four fields, and that neither restarts the read — is asserted above.
    }

    // MARK: - A cancelled open

    /// Cancelling an in-flight open leaves the channel readable.
    ///
    /// **The path is ordinary, not exotic.** `.task(id:)` cancels its body when the id changes, a
    /// channel switch changes it, and cancellation propagates into `StreamIngestion.open`'s settle
    /// sleep — whose own `catch` cancels the tap, finishes `effects` and marks the actor closed
    /// before rethrowing. With the read done inline and `hasOpened` already set, the replacement
    /// task's `open` was a no-op and the channel showed "could not be read" with zero items for the
    /// life of the app, because the registry retains the model.
    ///
    /// What is asserted is that the channel is **readable afterwards** — items present, no failure —
    /// and not merely that nothing crashed. The gate is the same suspension the ordering test uses,
    /// so the cancellation lands inside the open rather than near it.
    func testACancelledOpenLeavesTheChannelReadable() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let gate = SubscribeGate(feed: rig.feed)
        rig.registry.changeFeed = gate.subscribe
        let model = rig.registry.model(for: rig.keys[0])

        let opening = Task { await model.open(rig.row(0)) }
        // The outcome is asserted, not just awaited. The discriminating property of this test is
        // that the cancellation lands *inside* the open; on a timeout it would land on one that had
        // already finished, and the closing assertions would pass off the second `open` instead.
        let reached = await XCTWaiter().fulfillment(of: [gate.reached], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(reached, .completed, "the open never reached the gate, so nothing was cancelled inside it")

        // Exactly what `.task(id:)` does to its body when the selection moves.
        opening.cancel()
        gate.release()
        await opening.value

        // The replacement task the column makes for the same channel.
        await model.open(rig.row(0))

        XCTAssertNil(model.failure, "a cancelled open left the channel reporting a failure")
        XCTAssertFalse(model.items.isEmpty,
                       "a cancelled open left the channel holding \(model.items.count) items")
        XCTAssertTrue(model.hasOpened, "the channel does not report itself open")
    }

    /// Closing a model while its open is still in flight leaves nothing behind it.
    ///
    /// `close()` cancels the opening task and drops the ingestion, but the open is a sequence of
    /// awaits and cancellation only takes effect where the code looks for it. Parked inside
    /// `subscribe()` — the same gate the ordering test uses, so the close lands *inside* the open
    /// rather than near it — a resumption that checked neither cancellation nor the closed flag
    /// went on to install a change-feed loop, take an event subscription and read the file into a
    /// model the registry no longer holds.
    ///
    /// The witnesses are the two things such a resumption does that a closed model must not: the
    /// lifecycle's `events(of:)` log, taken between the subscribe and the read, and the items the
    /// read would have published.
    func testClosingDuringAnOpenLeavesNothingSubscribed() async throws {
        let rig = try await Rig(fixtures: ["plain-two-turn"])
        let key = rig.keys[0]
        await rig.lifecycle.openEvents(of: key)
        let gate = SubscribeGate(feed: rig.feed)
        rig.registry.changeFeed = gate.subscribe
        let model = rig.registry.model(for: key)

        let opening = Task { await model.open(rig.row(0, origin: .owned(.ready))) }
        let reached = await XCTWaiter().fulfillment(of: [gate.reached], timeout: LaunchFixtures.hangGuard)
        XCTAssertEqual(reached, .completed, "the open never reached the gate, so nothing was closed inside it")

        // The production seam: the channel left the index while its first open was in flight.
        rig.registry.release(key)
        gate.release()
        await opening.value

        let calls = await rig.lifecycle.eventSubscriptions
        XCTAssertTrue(calls.isEmpty,
                      "a closed model went on to take \(calls.count) event subscription(s)")
        XCTAssertTrue(model.items.isEmpty,
                      "a closed model went on to read \(model.items.count) items")
        await rig.lifecycle.finishEvents(of: key)
    }

    // MARK: - The coordinator's release and relocation seams

    /// A transcript that moves between slugs is read from its new path.
    ///
    /// The move is the ordinary one: the engine renames a project's slug directory, the index
    /// arbitrates the survivor and reports the session as updated, and the composition root hands
    /// that delta to `FleetCoordinator`. `StreamIngestion.fileChanged` resolves the *logical*
    /// stream from the path it is given and then reads the path its own `StreamState` holds, so
    /// without a `relocated` call every later change keeps reading a file that is no longer there
    /// and a file-only channel goes silently stale.
    ///
    /// Driven through `indexChanged` rather than through the model, because `relocated` existed and
    /// nothing in the app called it — the same defect class §8's release path was found by. The
    /// append lands on the new path only; the wait is fulfilled by the delivery itself.
    func testATranscriptThatMovesIsReadFromItsNewPath() async throws {
        let rig = try await Rig(inventedChannels: 1)
        let key = rig.keys[0]
        let model = rig.registry.model(for: key)
        await model.open(rig.row(0))
        let opened = model.items.count
        XCTAssertGreaterThan(opened, 0, "the invented transcript opened with 0 items")

        let old = rig.paths[0]
        let projects = rig.home.root.appending(path: "projects", directoryHint: .isDirectory)
        let moved = projects.appending(path: "invented-moved", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: old.deletingLastPathComponent(), to: moved)
        let new = moved.appending(path: old.lastPathComponent)

        let delta = await rig.workspace.index.update(changed: [old, new])
        XCTAssertTrue(delta.updated.contains(key.session) || delta.added.contains(key.session),
                      "the index reported \(delta.updated.count) updated and \(delta.added.count) added session(s) for the move")
        let coordinator = rig.coordinator()
        await coordinator.indexChanged(delta)
        coordinator.stop()

        let updates = model.timelineUpdates
        let grew = XCTestExpectation(description: "a timeline with more than \(opened) items")
        let seen = CountBox()
        let reader = Task {
            for await timeline in updates where timeline.items.count > opened {
                seen.set(timeline.items.count)
                grew.fulfill()
                return
            }
        }

        try rig.appendRecords(at: new, session: key.session, count: 2)
        rig.watcher.emit([new])

        let outcome = await XCTWaiter().fulfillment(of: [grew], timeout: LaunchFixtures.hangGuard)
        reader.cancel()
        XCTAssertEqual(outcome, .completed,
                       "the change to the moved transcript published no timeline holding the appended items")
        XCTAssertGreaterThan(model.items.count, opened,
                             "the moved channel holds \(model.items.count) items against \(opened) before the move")
    }

    /// A channel absent from a replacement snapshot is released.
    ///
    /// A warm launch paints the restored snapshot and then the freshly built one on top of it. A
    /// channel opened from the restored one and missing from the fresh build never generates a
    /// removal delta — the rebuilt index has no entry to remove — so the timeline model and the
    /// panel sessions it holds would live until the next launch replaced the workspace.
    ///
    /// The floor is the survivor: a coordinator that released everything on every snapshot would
    /// pass an assertion that only counted what disappeared.
    func testAChannelAbsentFromAReplacementSnapshotIsReleased() async throws {
        let rig = try await Rig(inventedChannels: 2)
        let host = PanelHostModel()
        host.attach(to: rig.workspace, timelines: rig.registry, lifecycle: rig.lifecycle)
        try host.register(PlaceholderTab())
        let coordinator = rig.coordinator(panels: host)

        let home = rig.workspace.configHome.root
        let restored = LaunchFixtures.snapshot(configHome: home, ids: rig.keys.map(\.session))
        let built = LaunchFixtures.snapshot(configHome: home, ids: [rig.keys[1].session])
        await coordinator.snapshotAvailable(restored, origin: .restored)

        for key in rig.keys {
            let context = try XCTUnwrap(host.context(for: key, cwd: URL(fileURLWithPath: "/invented/project")),
                                        "the host built no context for a restored channel")
            _ = host.session(for: .thread, context: context)
        }
        XCTAssertEqual(rig.registry.openChannels.count, 2,
                       "the registry holds \(rig.registry.openChannels.count) models for the 2 restored channels")
        XCTAssertEqual(host.liveChannelCount, 2,
                       "the host holds \(host.liveChannelCount) channels for the 2 restored channels")

        // The fresh build lands on top, and one of the two channels is not in it.
        await coordinator.snapshotAvailable(built, origin: .built)
        coordinator.stop()

        XCTAssertEqual(rig.registry.openChannels, [rig.keys[1]],
                       "the replacement snapshot left \(rig.registry.openChannels.count) timeline model(s) behind, not the 1 it still lists")
        XCTAssertEqual(host.liveChannelCount, 1,
                       "the replacement snapshot left \(host.liveChannelCount) channel(s) in the panel host, not 1")
    }

    // MARK: - The registry

    /// One model per channel, retained across a switch away and back, and one registry per app.
    ///
    /// The shared-registry assertion the brief pairs with Task 8 — a URL ingested through the model
    /// `ChannelColumnView` draws arriving through the exact `RecentURLFeed` handed to that
    /// channel's `ChannelContext` — is
    /// `testTheChannelColumnAndThePanelContextShareOneRegistry` below, which Task 8 wrote once the
    /// feed and the context existed. This test holds the half that does not need them: a channel's
    /// model survives a switch, and there is one model per channel.
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
    /// defect this instance exists to make unrepresentable; that one object is reachable from
    /// `AppModel` is this test, and that ingestion through it reaches the panel's feed is the
    /// end-to-end test below.
    func testAppModelExposesOneRegistry() async throws {
        let app = AppModel(registry: RowRegistry())
        XCTAssertNil(app.timelines.workspace, "an unlaunched registry is already bound to a workspace")
        XCTAssertEqual(app.timelines.openChannels.count, 0,
                       "an unlaunched registry already holds \(app.timelines.openChannels.count) model(s)")
        // Not `app.timelines === app.timelines`, which compares a `let` to itself and cannot fail in
        // any implementation. What can fail is that one channel resolves to one model through the
        // registry the app hands every consumer — the property a second registry breaks. Asserted
        // last, because resolving a model is what puts the first one in the registry.
        let key = ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                             session: SidebarFixtures.session("a"))
        XCTAssertTrue(app.timelines.model(for: key) === app.timelines.model(for: key),
                      "the registry handed back two models for one channel")
        XCTAssertEqual(app.timelines.openChannels.count, 1,
                       "one channel left \(app.timelines.openChannels.count) models in the registry")
    }

    /// A URL ingested through the model the channel column draws arrives through the **exact**
    /// `RecentURLFeed` instance handed to that channel's panel context.
    ///
    /// **Both sides are resolved from one `AppModel`** — `app.timelines` for the model, `app.panels`
    /// for the context — and neither is constructed here, because constructing either is precisely
    /// the mistake this assertion exists to catch. A second registry in the panel host would pass
    /// every unit test over either half and hand the Browser a feed watching a timeline that
    /// ingestion never touches.
    ///
    /// The subscription is taken before the file changes, and the wait is fulfilled by the delivery
    /// itself; the timeout is a hang guard. The floor is that the feed is empty before the change
    /// and holds the new URL after it, so a feed that answered the same list either way fails.
    func testTheChannelColumnAndThePanelContextShareOneRegistry() async throws {
        let rig = try await Rig(inventedChannels: 1)
        let app = AppModel(registry: RowRegistry())
        // The one production seam that binds both owners to a workspace.
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let key = rig.keys[0]

        // The model `ChannelColumnView` draws, and the context `PanelColumnView` draws.
        let model = app.timelines.model(for: key)
        await model.open(rig.row(0))
        let context = try XCTUnwrap(app.panels.context(for: key,
                                                       cwd: URL(fileURLWithPath: "/invented/project")),
                                    "the panel host built no context for the channel")
        let feed = context.recentURLs

        let before = await feed.current(limit: 10)
        XCTAssertTrue(before.isEmpty, "the channel began with \(before.count) URLs, so the change proves nothing")

        let expected = URL(string: "https://invented.example/shared-registry")!
        let updates = feed.updates
        let arrived = XCTestExpectation(description: "the ingested URL reaches the panel's feed")
        let reader = Task {
            for await urls in updates where urls.contains(where: { $0.url == expected }) {
                arrived.fulfill()
                return
            }
        }

        try rig.appendAssistantURL(to: 0, url: expected)
        rig.watcher.emit([rig.paths[0]])

        // The outcome is asserted, not just awaited. Without this clause a feed that never
        // published would wait out the hang guard and then pass on `current(limit:)` alone, which
        // reads the model directly — the publishing half would be untested. Found by mutation.
        let outcome = await XCTWaiter().fulfillment(of: [arrived], timeout: LaunchFixtures.hangGuard)
        reader.cancel()
        XCTAssertEqual(outcome, .completed,
                       "the ingested URL never arrived through the panel context's feed")
        let after = await feed.current(limit: 10)
        XCTAssertEqual(after.count, 1, "the feed holds \(after.count) URLs after the change, not 1")
        XCTAssertTrue(after.contains { $0.url == expected },
                      "the URL the column's model ingested did not reach the panel context's feed")
        XCTAssertEqual(model.timeline.recentURLs(limit: 10).count, after.count,
                       "the feed and the model the column draws disagree on how many URLs the channel has")
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
    /// A floor on how many rows the whole corpus renders, so a run that ingested almost nothing
    /// cannot pass a comparison that had nothing to compare. Well under what the corpus actually
    /// produces; it fails an empty or near-empty ingestion, not a corpus that grew or shrank by one.
    static let rowFloor = 50

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
    ///
    /// `throughSymlink` names the config home through a symlink pointing at it, rather than by the
    /// directory's own resolved path. One directory, two spellings — the disagreement tracker entry
    /// 54 records between the index and the fleet, and the shape of any config home reached through
    /// a linked `TMPDIR` or a linked home in the running app.
    init(fixtures: [String] = [], inventedChannels: Int = 0, throughSymlink: Bool = false) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        var keys: [ChannelKey] = []
        var paths: [URL] = []
        var titles: [String] = []
        let configHome: ConfigHome
        if throughSymlink {
            let link = temp.root.appending(path: "config-home-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.root)
            configHome = ConfigHome(root: URL(fileURLWithPath: link.path), source: .environment)
        } else {
            configHome = home.configHome
        }

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
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)

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

    /// The coordinator the composition root builds over this workspace, holding this rig's one
    /// timeline registry.
    ///
    /// Built here rather than in each test because what the two tests below are about is the
    /// production seam: a registry told to release or to relocate only by a test leaves the running
    /// app holding what it should have let go, which is the defect class §8's release path exists
    /// for.
    func coordinator(panels: PanelHostModel? = nil) -> FleetCoordinator {
        FleetCoordinator(configHome: workspace.configHome.root,
                         registrar: RegistrarDouble(),
                         index: workspace.index,
                         model: FleetBrowserModel(lifecycle: lifecycle,
                                                  configHome: workspace.configHome.root),
                         panels: panels,
                         timelines: registry)
    }

    /// Appends one assistant record naming `url`, and moves the projected leaf onto it.
    ///
    /// An assistant record rather than a user one because `URLSources.contributing` excludes user
    /// messages — the person typed those — so a URL appended as a user record would ingest cleanly
    /// and never reach `recentURLs`, and the test would fail for a reason that is not the defect.
    func appendAssistantURL(to index: Int, url: URL) throws {
        let handle = try FileHandle(forWritingTo: paths[index])
        defer { try? handle.close() }
        try handle.seekToEnd()
        let session = keys[index].session
        let me = "00000000-0000-4000-8000-000000000003"
        // Chained onto the assistant record `LaunchFixtures.transcript` wrote, so the leaf named
        // below carries the whole chain rather than starting a second root.
        let parent = "00000000-0000-4000-8000-000000000002"
        let text = "invented reply naming \(url.absoluteString)"
        let record = #"{"type":"assistant","sessionId":"\#(session)","uuid":"\#(me)","parentUuid":"\#(parent)","isSidechain":false,"cwd":"/invented/project","timestamp":"2026-01-01T00:00:03.000Z","message":{"id":"msg_invented3","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
        let leaf = #"{"type":"last-prompt","sessionId":"\#(session)","leafUuid":"\#(me)","lastPrompt":"invented prompt"}"# + "\n"
        try handle.write(contentsOf: Data((record + leaf).utf8))
    }

    /// Appends `count` further records to a channel's transcript, each with its own invented uuid.
    func appendRecords(to index: Int, count: Int) throws {
        try appendRecords(at: paths[index], session: keys[index].session, count: count)
    }

    /// The same append against a named file, for a channel whose transcript has moved out from
    /// under `paths[i]`.
    func appendRecords(at url: URL, session: SessionID, count: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
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
