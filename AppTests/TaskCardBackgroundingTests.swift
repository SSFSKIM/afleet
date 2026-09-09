import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// The `taskRun` row's task card over the channel's own registry mirror (spec §8.4, contract Y2).
///
/// `TimelineRenderContext.makeTaskCard(_:)` built its model over an empty `RegistryMirror()`, so the
/// row's card could never offer *Move to background* however live the run was — tracker 321. The
/// mirror now travels on `ChannelTimeline` and reaches the card through the neighbourhood, which is
/// the same read the agent tree and the cluster members take.
///
/// Every identifier here is invented (§11); nothing reads a recording.
@MainActor
final class TaskCardBackgroundingTests: XCTestCase {

    private static let runID = "task_invented_agent_01"
    private static let toolUseID = "toolu_invented0001"

    /// A mirror holding one running, foreground agent run — the shape §8.4 makes the action available
    /// for. Folded from a `task_started` frame rather than assembled by hand, so what the card reads is
    /// what the fold would have produced.
    private static func mirrorWithRunningAgent() -> RegistryMirror {
        var mirror = RegistryMirror()
        let started = InventedItems.taskStarted(taskID: runID, toolUseID: toolUseID, agentType: "InventedAgentType")
        mirror.apply(.taskStarted(started), at: InventedItems.epoch, epoch: .first)
        return mirror
    }

    private static func run(_ taskID: String) -> TaskRunItem {
        TaskRunItem(id: InventedItems.id("run-\(taskID)"),
                    timestamp: InventedItems.epoch,
                    provenance: InventedItems.provenance,
                    taskID: taskID,
                    kind: .localAgent,
                    description: "an invented errand",
                    status: .running,
                    toolUseID: toolUseID)
    }

    /// The neighbourhood built the way a publish builds it: from a `ChannelTimeline`, through the
    /// cache the model asks. Asserting through the cache rather than the initialiser is what makes this
    /// a test of the wiring and not of a value a test assembled.
    private static func neighbourhood(carrying mirror: RegistryMirror) -> TimelineNeighbourhood {
        TimelineNeighbourhoodCache().neighbourhood(for: ChannelTimeline(registry: mirror))
    }

    // MARK: - The rule

    /// **The action is offered for a run the mirror knows and for no other.**
    ///
    /// Two cards from one context and one mirror: the run the mirror holds, and a run it does not. A card
    /// built over an empty mirror answers `false` to both, so the *second* assertion alone would pass
    /// against the defect this closes; the pair is what discriminates.
    func testTheRowsCardOffersBackgroundingOnlyForARunTheMirrorKnows() throws {
        let mirror = Self.mirrorWithRunningAgent()
        let context = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: mirror),
                                            lifecycle: LifecycleDouble())

        let known = try XCTUnwrap(context.makeTaskCard(Self.run(Self.runID)), "an owned channel built no card")
        XCTAssertTrue(known.offersMoveToBackground,
                      "a running foreground agent run the mirror holds was offered no backgrounding")
        XCTAssertEqual(known.entry?.toolUseID, Self.toolUseID,
                       "the action names the tool-use id from the mirror's row, which is what the request carries")

        let unknown = try XCTUnwrap(context.makeTaskCard(Self.run("task_invented_absent_01")))
        XCTAssertFalse(unknown.offersMoveToBackground,
                       "a run the mirror never saw was offered an action the engine would refuse")
        XCTAssertNil(unknown.entry)
        XCTAssertTrue(unknown.offersStop, "the item's own status still drives Stop, which needs no mirror")
    }

    /// **The row's card is the model the mirror alone decides.** Two models over one mirror — the row's,
    /// built through the context, and one built directly — agree about every run, so nothing the context
    /// does on the way in changes the answer §8.4's clause gives.
    ///
    /// It is deliberately **not** named for contract Y2. No production site builds `ThreadAnchor.task`
    /// yet, so a `TaskCardModel` a test constructs is not "the Thread tab": the tab's own host path is
    /// asserted in the case below, which is the one that can catch that host drifting.
    func testTheRowsCardMatchesAModelBuiltDirectlyOverTheSameMirror() throws {
        let mirror = Self.mirrorWithRunningAgent()
        let lifecycle = LifecycleDouble()
        let key = ChannelKey(configHome: InventedItems.stream.configHome, session: InventedItems.stream.sessionID)
        let context = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: mirror),
                                            lifecycle: lifecycle,
                                            key: key)

        for taskID in [Self.runID, "task_invented_absent_01"] {
            let item = Self.run(taskID)
            let row = try XCTUnwrap(context.makeTaskCard(item))
            let direct = TaskCardModel(item: item, registry: mirror, lifecycle: lifecycle, channel: key)
            XCTAssertEqual(row.offersMoveToBackground, direct.offersMoveToBackground,
                           "two models over one mirror disagree about \(taskID)")
            XCTAssertEqual(row.entry?.id, direct.entry?.id)
        }
    }

    /// **Contract Y2 at the second host: the Thread tab draws the row's card, and the same action on it.**
    ///
    /// The tab's real path — `ThreadModel.open(.task(…))` and the `TaskCardView` `ThreadView` mounts for
    /// that anchor — is what this drives, with the model the *row* built. So the assertion is about two
    /// hosts of one card and not about a value this test assembled: if the tab ever drew its own reading
    /// of a task instead of hosting the card, or hosted it without its actions, this fails.
    func testTheThreadTabHostsTheRowsCardWithTheSameAction() throws {
        let mirror = Self.mirrorWithRunningAgent()
        let lifecycle = LifecycleDouble()
        let key = ChannelKey(configHome: InventedItems.stream.configHome, session: InventedItems.stream.sessionID)
        let context = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: mirror),
                                            lifecycle: lifecycle, key: key)
        let tab = ThreadModel(channel: key, lifecycle: lifecycle)

        for (taskID, expected) in [(Self.runID, true), ("task_invented_absent_01", false)] {
            let item = Self.run(taskID)
            let card = try XCTUnwrap(context.makeTaskCard(item), "the row built no card for \(taskID)")
            tab.open(.task(card))

            let hosted = try XCTUnwrap(ViewTree.values(of: TaskCardView.self, in: ThreadView(model: tab).body).first,
                                       "the task thread hosts no task card")
            let offered = ViewTree.button("Move to background", in: hosted.body) != nil
            XCTAssertEqual(offered, card.offersMoveToBackground,
                           "the Thread tab drew a different action from the card it was handed")
            XCTAssertEqual(offered, expected, "the mirror's own answer for \(taskID) is not what was drawn")
            XCTAssertNotNil(ViewTree.button("Stop", in: hosted.body), "a running task offered no Stop")
        }
    }

    /// **A channel with no fold carries an empty mirror, and the action is absent rather than wrong.**
    /// That is the reading an archived or foreign channel keeps, and the one the defect made universal.
    func testAChannelWithNoFoldOffersNoBackgrounding() throws {
        let context = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: RegistryMirror()),
                                            lifecycle: LifecycleDouble())
        let card = try XCTUnwrap(context.makeTaskCard(Self.run(Self.runID)))
        XCTAssertFalse(card.offersMoveToBackground)
        XCTAssertTrue(card.offersStop)
    }

    // MARK: - §8.4's `{backgrounded: false}` arm

    /// **A `{backgrounded: false}` answer refreshes the card from the timeline.**
    ///
    /// That body is the engine saying the entry the card was reading is stale or ineligible: the action
    /// goes and the card takes whatever the timeline now says the run is (§8.4, item 61's first arm).
    /// `TaskCardModel.refresh` is how it takes it, and the row's host left it at its default — a closure
    /// that answers nil — so the card kept the item it was built with and went on drawing a finished
    /// run's opening description.
    ///
    /// The row is built from a **stale** item on purpose: that is the gap the arm exists for, and the
    /// card holds its item by value (tracker 322), so the timeline can hold a newer one.
    func testABackgroundedFalseAnswerRefreshesTheRowsCardFromTheTimeline() async throws {
        let control = ControlDouble()
        await control.stage(.success(.object(["backgrounded": .bool(false)])))

        var settled = Self.run(Self.runID)
        settled.status = .completed
        settled.summary = "an invented outcome"
        let timeline = ChannelTimeline(durable: DurableProjection(items: [.taskRun(settled)]),
                                       registry: Self.mirrorWithRunningAgent())
        let context = InventedItems.context(neighbourhood: TimelineNeighbourhoodCache().neighbourhood(for: timeline),
                                            lifecycle: control)

        // What the row mounted with: the run as it read while it was still going.
        let card = try XCTUnwrap(context.makeTaskCard(Self.run(Self.runID)))
        XCTAssertTrue(card.offersMoveToBackground, "the arm under test is only reachable from the action")

        await card.moveToBackground()
        await card.whenIdle()

        XCTAssertEqual(card.item.status, .completed,
                       "the card kept the reading the engine had just contradicted")
        XCTAssertEqual(card.item.summary, "an invented outcome",
                       "the card drew the opening description of a run the timeline says is over")
        XCTAssertFalse(card.offersMoveToBackground, "the action survived the engine's refusal of it")
        XCTAssertNil(card.banner, "a success body raises no banner")
    }

    /// **The mirror travels on the published read model and not beside it.** The neighbourhood cache is the
    /// one place a `ChannelTimeline` becomes what a row reads, so a mirror that never got onto the timeline
    /// would arrive here empty however the card was built.
    func testTheNeighbourhoodCarriesThePublishedTimelinesMirror() {
        let mirror = Self.mirrorWithRunningAgent()
        let cache = TimelineNeighbourhoodCache()
        let carried = cache.neighbourhood(for: ChannelTimeline(registry: mirror))
        XCTAssertEqual(carried.registry, mirror, "the published mirror did not reach the row's neighbourhood")
        XCTAssertEqual(cache.builds, 1)

        // And a mirror that moved is a neighbourhood that is rebuilt: the cache's key is the timeline with
        // its preview taken off, so the registry is part of it.
        var moved = mirror
        moved.apply(.taskStarted(InventedItems.taskStarted(taskID: "task_invented_agent_02",
                                                           toolUseID: "toolu_invented0002",
                                                           agentType: "InventedAgentType")),
                    at: InventedItems.epoch, epoch: .first)
        let after = cache.neighbourhood(for: ChannelTimeline(registry: moved))
        XCTAssertEqual(cache.builds, 2, "a changed registry did not invalidate the cached neighbourhood")
        XCTAssertEqual(after.registry.entries.count, 2)
    }

    // MARK: - What the mirror costs, and what it re-keys

    /// **A heartbeat is not a new neighbourhood, and a run appearing is.**
    ///
    /// `RegistryMirror` stamps `lastFrameAt` on every task frame, so keying the cache on the whole
    /// mirror charged a chatty agent one O(items) rebuild per frame — the growth §8.3 forbids, arriving
    /// through a value a card reads four fields out of. The pair is the discrimination: a cache keyed
    /// on nothing would pass the first clause and fail the second.
    func testAHeartbeatReusesTheNeighbourhoodAndAMembershipChangeRebuildsIt() {
        var mirror = Self.mirrorWithRunningAgent()
        let cache = TimelineNeighbourhoodCache()
        _ = cache.neighbourhood(for: ChannelTimeline(registry: mirror))
        XCTAssertEqual(cache.builds, 1)

        // The same run, still running, one heartbeat later: only `lastFrameAt` moves.
        var beating = mirror
        beating.apply(.taskProgress(InventedItems.taskProgress(taskID: Self.runID)),
                      at: InventedItems.epoch.addingTimeInterval(1), epoch: .first)
        XCTAssertNotEqual(beating, mirror, "the heartbeat moved nothing, so reusing the neighbourhood proves nothing")
        let reused = cache.neighbourhood(for: ChannelTimeline(registry: beating))
        XCTAssertEqual(cache.builds, 1, "a heartbeat rebuilt the whole neighbourhood")
        XCTAssertTrue(reused.registry.entries[Self.runID].map(TaskCardModel.isEligible) ?? false,
                      "the reused neighbourhood no longer offers the action it was built offering")

        // A second run: the set of tasks the card can be built over has changed.
        mirror = beating
        mirror.apply(.taskStarted(InventedItems.taskStarted(taskID: "task_invented_agent_02",
                                                            toolUseID: "toolu_invented0002",
                                                            agentType: "InventedAgentType")),
                     at: InventedItems.epoch, epoch: .first)
        let rebuilt = cache.neighbourhood(for: ChannelTimeline(registry: mirror))
        XCTAssertEqual(cache.builds, 2, "a run the mirror had never held did not rebuild the neighbourhood")
        XCTAssertEqual(rebuilt.registry.entries.count, 2)
    }

    /// **A row mounted before its run reached the fold gains the action when a publish adds it.**
    ///
    /// The card is `@State` behind `TaskCardSeam.identity(of:in:)`, and that identity read the task, the
    /// status and the channel's capability — never the mirror. So a `taskRun` row drawn while the
    /// registry did not yet hold the run kept the card it built then, and *Move to background* was
    /// missing for the whole of that run's foreground life whatever the publish said (tracker 406).
    ///
    /// Both halves are asserted, because either alone leaves the gap open: the identity has to change,
    /// **and** the table has to consider the context changed, or the mounted row never re-keys at all.
    @MainActor
    func testARowMountedBeforeItsTaskStartedGainsTheAction() throws {
        let item = Self.run(Self.runID)
        var before = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: RegistryMirror()),
                                           lifecycle: LifecycleDouble())
        // The same context, one publish later: only the mirror has moved.
        var after = before
        after.neighbourhood = Self.neighbourhood(carrying: Self.mirrorWithRunningAgent())

        XCTAssertNotEqual(TaskCardSeam.identity(of: item, in: before),
                          TaskCardSeam.identity(of: item, in: after),
                          "the row would hold the card it built before the run was in the registry")
        XCTAssertTrue(TimelineTableController.differs(before, after),
                      "the mounted row is never handed the context that would re-key it")

        // And the card that identity now names really does offer the action, so the re-key is worth it.
        XCTAssertFalse(try XCTUnwrap(before.makeTaskCard(item)).offersMoveToBackground)
        XCTAssertTrue(try XCTUnwrap(after.makeTaskCard(item)).offersMoveToBackground)

        // A heartbeat is not a new card: the identity and the comparison both hold still for it.
        var beating = Self.mirrorWithRunningAgent()
        beating.apply(.taskProgress(InventedItems.taskProgress(taskID: Self.runID)),
                      at: InventedItems.epoch.addingTimeInterval(1), epoch: .first)
        var later = before
        later.neighbourhood = Self.neighbourhood(carrying: beating)
        XCTAssertEqual(TaskCardSeam.identity(of: item, in: after), TaskCardSeam.identity(of: item, in: later))
        XCTAssertFalse(TimelineTableController.differs(after, later),
                       "a heartbeat forced every mounted row's roots to be refreshed")
    }
}
