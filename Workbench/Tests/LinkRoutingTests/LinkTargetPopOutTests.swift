// X7's `popsOutForNewWindow`, at the registry. The amendment was ruled at C7.6's gate
// (2026-09-09) for the Browser, whose `.newWindow` is the *system* browser: a target that leaves
// the app has no window to be popped out into, and a host that popped one anyway would present
// two. Every identifier here is invented (§11).
import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
@testable import LinkRouting

final class LinkTargetPopOutTests: XCTestCase {

    /// A declining target is delivered to **without `prepare` running at all**.
    ///
    /// Not "prepare ran and did nothing": `prepare` is an `await` on the main actor, so calling it
    /// is what makes the router suspend between resolving a target and delivering to it, and a
    /// withdrawal landing in a suspension that exists for nothing makes the router refuse an
    /// unrelated surviving target (`LinkRouterTests` section 8). The declining target takes the
    /// path that documents itself as not suspending, and the recorder's order is the proof.
    @MainActor
    func testADecliningTargetIsDeliveredToWithoutPreparing() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Self.target(.browser, declining: true, into: recorder))

        await router.open(Fixtures.url, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
        }

        XCTAssertEqual(recorder.events, ["open:browser:newWindow"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(recorder.destinations, [.newWindow],
                       "the declining target received \(recorder.destinations) rather than .newWindow")
    }

    /// The companion, and the half that makes the field discriminate: a target that says nothing
    /// still has `prepare` run for it, in the order the pop-out rule is about.
    @MainActor
    func testATargetThatDoesNotDeclineIsStillPreparedFor() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Self.target(.files, declining: false, into: recorder))

        await router.open(Fixtures.url, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
        }

        XCTAssertEqual(recorder.events, ["prepare:files", "open:files:newWindow"],
                       "the recorded order was \(recorder.events)")
    }

    /// What the suspension costs, made observable: a withdrawal that lands *in* it.
    ///
    /// The `prepare` here withdraws the tab it was called for, which is the host's own teardown
    /// path landing inside the window `prepare` opens. A router that ran it for the declining
    /// target would then have nothing live to deliver to and would take W5's fallback — the
    /// injected external opener, not a browser. A router that never ran it delivers. The
    /// interleaving is deterministic rather than timed, because the withdrawal is awaited from
    /// inside the hook.
    @MainActor
    func testAWithdrawalCannotLandInASuspensionADecliningTargetNeverEnters() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Self.target(.browser, declining: true, into: recorder))

        await router.open(Fixtures.url, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            await router.unregister(tab: target.tab)
        }

        XCTAssertEqual(recorder.tabs, [.browser],
                       "the declining target was delivered to \(recorder.tabs.count) times, not once")
        XCTAssertEqual(sink.urls, [], "the open fell back to the external opener")
    }

    // MARK: - The budget is the preparing target's, not the resolution's

    /// Two handovers, and the target the third resolution finds **declines** the pop-out.
    ///
    /// The preparation bound has been spent by then, and it was spent on two targets that each
    /// wanted a window. The one that survives wants none: it answers `.newWindow` by leaving the
    /// app. A router that charged it for the budget those two ran through would fall back over a
    /// live target that needs nothing further from the host — and W5's fallback for a
    /// `.pullRequest` is a diagnostic, so the link is simply dropped.
    @MainActor
    func testADecliningReplacementIsDeliveredToAfterTheBudgetIsSpent() async {
        let recorder = Recorder()
        let sink = Sink()
        let handovers = Counter()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Self.target(.files, declining: false, into: recorder,
                                          specificity: 10, label: "first"))

        await router.open(Fixtures.pullRequest, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            switch handovers.next() {
            case 0:
                await router.unregister(tab: .files)
                await router.register(Self.target(.files, declining: false, into: recorder,
                                                  specificity: 10, label: "second"))
            case 1:
                await router.unregister(tab: .files)
                await router.register(Self.target(.files, declining: true, into: recorder,
                                                  specificity: 10, label: "decliner"))
            default:
                break
            }
        }

        XCTAssertEqual(recorder.events,
                       ["prepare:files", "prepare:files", "open:decliner:newWindow"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages, [],
                       "a link a live target could have taken produced a diagnostic instead")
    }

    /// The other half of the same rule: the prepared target is withdrawn, and re-resolution finds a
    /// **different** tab whose target declines.
    ///
    /// The prepared-tab guard exists so that a second, irreversible preparation is never run for a
    /// window this call cannot take back. A declining target asks for no preparation at all, so the
    /// guard has nothing to protect against and the surviving target delivers.
    @MainActor
    func testAWithdrawnPreparationReResolvesOntoADecliningTargetOnAnotherTab() async {
        let recorder = Recorder()
        let sink = Sink()
        let handover = Once()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Self.target(.files, declining: false, into: recorder,
                                          specificity: 10, label: "specific"))
        await router.register(Self.target(.browser, declining: true, into: recorder,
                                          specificity: 1, label: "browser"))

        await router.open(Fixtures.pullRequest, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            guard target.tab == .files, handover.firstTime() else { return }
            await router.unregister(tab: .files)
        }

        XCTAssertEqual(recorder.events, ["prepare:files", "open:browser:newWindow"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages, [],
                       "the surviving Browser target lost the link to a diagnostic")
    }

    /// A target for `tab` that records what it receives, declining the pop-out or not.
    ///
    /// Specificity defaults to 1 against the fixtures' 0, so the first tests here are about the
    /// field and not about which of two targets won; the budget cases above set it, because they
    /// are about two targets at once.
    @MainActor
    private static func target(_ tab: PanelTabID, declining: Bool,
                               into recorder: Recorder,
                               specificity: Int = 1,
                               label: String? = nil) -> LinkTarget {
        let label = label ?? tab.rawValue
        return LinkTarget(tab: tab, specificity: specificity, popsOutForNewWindow: !declining,
                          handles: { _ in true },
                          open: { link, destination in
                              recorder.delivered(tab: tab, link: link, destination: destination,
                                                 label: label)
                          })
    }
}

/// How many times a `prepare` has run, so a chain of handovers can act differently on each. `Once`
/// answers the one-handover cases; a two-handover chain needs to count.
@MainActor
final class Counter {
    private var count = 0
    func next() -> Int {
        defer { count += 1 }
        return count
    }
}
