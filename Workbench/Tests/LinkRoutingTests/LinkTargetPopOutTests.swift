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

    /// A target for `tab` that records what it receives, declining the pop-out or not.
    ///
    /// Specificity 1 against the fixtures' 0, so the tests above are about the field and not about
    /// which of two targets won.
    @MainActor
    private static func target(_ tab: PanelTabID, declining: Bool,
                               into recorder: Recorder) -> LinkTarget {
        LinkTarget(tab: tab, specificity: 1, popsOutForNewWindow: !declining,
                   handles: { _ in true },
                   open: { link, destination in
                       recorder.delivered(tab: tab, link: link, destination: destination,
                                          label: tab.rawValue)
                   })
    }
}
