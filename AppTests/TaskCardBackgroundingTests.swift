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

    /// **Contract Y2: the two hosts of this card offer the same action on the same run.** The Thread tab
    /// builds `TaskCardModel` with the pump's mirror; the row builds it through the context. Same
    /// component, same mirror, same answer — which is only assertable now that the row has a mirror at all.
    func testTheRowAndTheThreadTabAgree() throws {
        let mirror = Self.mirrorWithRunningAgent()
        let lifecycle = LifecycleDouble()
        let key = ChannelKey(configHome: InventedItems.stream.configHome, session: InventedItems.stream.sessionID)
        let context = InventedItems.context(neighbourhood: Self.neighbourhood(carrying: mirror),
                                            lifecycle: lifecycle,
                                            key: key)

        for taskID in [Self.runID, "task_invented_absent_01"] {
            let item = Self.run(taskID)
            let row = try XCTUnwrap(context.makeTaskCard(item))
            let thread = TaskCardModel(item: item, registry: mirror, lifecycle: lifecycle, channel: key)
            XCTAssertEqual(row.offersMoveToBackground, thread.offersMoveToBackground,
                           "the two hosts of one card disagree about \(taskID)")
            XCTAssertEqual(row.entry?.id, thread.entry?.id)
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
}
