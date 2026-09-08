// C7.2's `LinkRouter`, tested without the app: spec Design §3, gate G1.2, plan T1's seven
// groups. Every identifier in a link here is invented (§11); nothing is read from this machine.
import Foundation
import XCTest
import AfleetCore
import PanelHostAPI
@testable import LinkRouting

final class LinkRouterTests: XCTestCase {

    // MARK: - 1. Every `WorkspaceLink` case reaches the registered target intact

    @MainActor func testFileLinkReachesTheTarget() async { await assertDelivered(Fixtures.file) }
    @MainActor func testDiffLinkReachesTheTarget() async { await assertDelivered(Fixtures.diff) }
    @MainActor func testURLLinkReachesTheTarget() async { await assertDelivered(Fixtures.url) }
    @MainActor func testCommitLinkReachesTheTarget() async { await assertDelivered(Fixtures.commit) }
    @MainActor func testPullRequestLinkReachesTheTarget() async { await assertDelivered(Fixtures.pullRequest) }
    @MainActor func testCommandLinkReachesTheTarget() async { await assertDelivered(Fixtures.command) }

    /// The link the handler receives is *equal to* the one opened, not merely of the same case.
    @MainActor
    private func assertDelivered(_ link: WorkspaceLink,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 1, into: recorder))

        await router.open(link, from: .currentPanel)

        XCTAssertEqual(recorder.links, [link], "the target received \(recorder.links.count) links",
                       file: file, line: line)
        XCTAssertEqual(sink.messages, [], "a handled link also produced \(sink.messages.count) diagnostics",
                       file: file, line: line)
        XCTAssertEqual(sink.urls, [], "a handled link also reached the external opener",
                       file: file, line: line)
    }

    // MARK: - 2. The destination reaches the handler

    /// The same target, opened twice, records two *different* destinations. A router that
    /// hard-coded `.currentPanel` passes every other test in this file and fails this one.
    @MainActor
    func testTheDestinationReachesTheHandler() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Fixtures.target(.files, specificity: 1, into: recorder))

        await router.open(Fixtures.file, from: .currentPanel)
        await router.open(Fixtures.file, from: .newWindow)

        XCTAssertEqual(recorder.destinations, [.currentPanel, .newWindow],
                       "the handler saw \(recorder.destinations.count) destinations, not both of them")
    }

    // MARK: - 3. The fallback

    /// A `.url` nobody claimed goes to the system opener, with the URL intact.
    @MainActor
    func testUnclaimedURLReachesTheExternalOpener() async {
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })

        await router.open(Fixtures.unclaimedURL, from: .currentPanel)

        XCTAssertEqual(sink.urls, [Fixtures.unmistakableURL], "the opener saw \(sink.urls.count) URLs")
        XCTAssertEqual(sink.messages, [], "an unclaimed .url also produced a diagnostic")
    }

    /// The other five kinds are a diagnostic line that **names the kind and carries no part of the
    /// payload** (§11). Each link below is built around a token that appears nowhere else, so the
    /// assertion is about the message and not about the fixture.
    @MainActor
    func testFallbackDiagnosticNamesTheKindAndNotThePayload() async {
        let cases: [(WorkspaceLink, String)] = [
            (Fixtures.unclaimedFile, "file"),
            (Fixtures.unclaimedDiff, "diff"),
            (Fixtures.unclaimedCommit, "commit"),
            (Fixtures.unclaimedPullRequest, "pull-request"),
            (Fixtures.unclaimedCommand, "command"),
        ]
        for (link, kind) in cases {
            let sink = Sink()
            let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })

            await router.open(link, from: .currentPanel)

            XCTAssertEqual(sink.messages.count, 1, "the \(kind) fallback produced \(sink.messages.count) diagnostics")
            let message = sink.messages.first ?? ""
            XCTAssertTrue(message.contains(kind), "the \(kind) fallback message does not name its kind")
            for token in Fixtures.payloadTokens {
                XCTAssertFalse(message.contains(token),
                               "the \(kind) fallback message carries a payload token")
            }
            XCTAssertEqual(sink.urls, [], "the \(kind) fallback reached the external opener")
        }
    }

    // MARK: - 4. Specificity

    /// Highest `specificity` wins. The registration order and the canonical tab order both point
    /// at the *loser* here, so only specificity can produce the expected answer.
    @MainActor
    func testHighestSpecificityWins() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Fixtures.target(.agents, specificity: 1, into: recorder))
        await router.register(Fixtures.target(.browser, specificity: 10, into: recorder))

        await router.open(Fixtures.file, from: .currentPanel)

        XCTAssertEqual(recorder.tabs, [.browser], "the less specific target was chosen")
    }

    // MARK: - 5. The tie-break, as its own test

    /// Equal specificity, registered in the order that would give the wrong answer: canonical
    /// `PanelTabID` order decides. Separate from test 4 because a comparator missing its
    /// tie-break passes test 4.
    @MainActor
    func testEqualSpecificityBreaksByCanonicalTabOrder() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        // `.terminal` comes after `.files` in `PanelTabID.allCases`, and is registered first.
        await router.register(Fixtures.target(.terminal, specificity: 5, into: recorder))
        await router.register(Fixtures.target(.files, specificity: 5, into: recorder))

        await router.open(Fixtures.file, from: .currentPanel)

        XCTAssertEqual(recorder.tabs, [.files], "the tie went to registration order, not canonical order")
    }

    // MARK: - 6. Withdrawal by tab

    /// `unregister(tab:)` drops exactly the targets that tab registered — the count falls by two
    /// and not to zero — and the link falls through to the next target, while the withdrawn tab
    /// receives nothing more.
    @MainActor
    func testUnregisterDropsOnlyThatTabsTargetsAndFallsThrough() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder))
        await router.register(Fixtures.target(.files, specificity: 8, into: recorder))
        await router.register(Fixtures.target(.terminal, specificity: 1, into: recorder))
        let before = await router.targetCount
        XCTAssertEqual(before, 3, "the registry holds \(before) targets before the withdrawal")

        await router.open(Fixtures.file, from: .currentPanel)
        XCTAssertEqual(recorder.tabs, [.files], "the most specific target did not win the first open")

        await router.unregister(tab: .files)
        let after = await router.targetCount
        XCTAssertEqual(after, 1, "the registry holds \(after) targets after one tab withdrew two")

        await router.open(Fixtures.file, from: .currentPanel)
        XCTAssertEqual(recorder.tabs, [.files, .terminal],
                       "after the withdrawal the link did not fall through to the next target")
        XCTAssertEqual(recorder.tabs.filter { $0 == .files }.count, 1,
                       "the withdrawn tab received a link after it was withdrawn")
    }

    // MARK: - 7. `prepare` ordering

    /// `prepare` runs after the target is resolved and **before** the handler. One recorder, so
    /// the assertion is on order rather than on two independent facts.
    @MainActor
    func testPrepareRunsBeforeTheHandler() async {
        let recorder = Recorder()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(Fixtures.target(.files, specificity: 1, into: recorder))

        await router.open(Fixtures.file, from: .newWindow) { target, destination in
            recorder.note("prepare:\(target.tab.rawValue):\(destination)")
        }

        XCTAssertEqual(recorder.events, ["prepare:files:newWindow", "open:files:newWindow"],
                       "the recorded order was \(recorder.events)")
    }

    /// With nothing to resolve there is no target to prepare for, so `prepare` does not run and
    /// the fallback still does.
    @MainActor
    func testPrepareDoesNotRunWhenNothingHandlesTheLink() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })

        await router.open(Fixtures.unclaimedFile, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
        }

        XCTAssertEqual(recorder.events, [], "prepare ran with no target resolved")
        XCTAssertEqual(sink.messages.count, 1, "the fallback produced \(sink.messages.count) diagnostics")
    }

    // MARK: - 8. Withdrawal *during* the `prepare` suspension

    /// X7's guarantee is that a target "cannot deliver into one that is gone". `prepare` is an
    /// `await` on the main actor, so the router suspends between resolving a target and delivering
    /// to it, and `unregister(tab:)` can land in that window — which is exactly what the host does
    /// when it tears a tab down while a link for it is in flight. The withdrawal here is driven
    /// from inside `prepare` and awaited, so the interleaving is deterministic rather than timed:
    /// when `prepare` returns, the withdrawal has already been applied on the router's executor.
    ///
    /// The resolved tab must receive nothing. **And no second target is prepared**: `prepare` is
    /// the host's pop-out, which presents a window, and a window presented for a tab that is not
    /// the one delivering is not undoable. So a withdrawal that leaves only an *unrelated* target
    /// takes W5's fallback rather than preparing a second window for it. `prepare` here counts its
    /// own runs, which is what a `presentWindow` count is at this layer.
    @MainActor
    func testWithdrawalDuringPrepareStopsDeliveryAndPreparesNoOneElse() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder))
        await router.register(Fixtures.target(.terminal, specificity: 1, into: recorder))

        await router.open(Fixtures.file, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            if target.tab == .files { await router.unregister(tab: .files) }
        }

        XCTAssertEqual(recorder.tabs, [],
                       "delivery went to \(recorder.tabs) after the prepared tab withdrew during prepare")
        XCTAssertEqual(recorder.events, ["prepare:files"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages.count, 1,
                       "the link produced \(sink.messages.count) diagnostics, not the one fallback")
    }

    /// The companion the fix has to keep passing: a withdrawal that lands during `prepare` but
    /// names a *different* tab is none of the resolved target's business. A router that simply
    /// refused to deliver after any withdrawal would pass the test above and fail this one.
    @MainActor
    func testWithdrawalOfAnotherTabDuringPrepareStillDelivers() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder))
        await router.register(Fixtures.target(.terminal, specificity: 1, into: recorder))

        await router.open(Fixtures.file, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            await router.unregister(tab: .terminal)
        }

        XCTAssertEqual(recorder.events, ["prepare:files", "open:files:newWindow"],
                       "the recorded order was \(recorder.events)")
        let remaining = await router.targetCount
        XCTAssertEqual(remaining, 1, "the registry holds \(remaining) targets after the other tab withdrew")
    }

    /// Two targets for one tab, withdrawn together during `prepare`, leave nothing to fall through
    /// to: the link takes W5's fallback rather than vanishing. The re-check is about the *resolved
    /// target's* identity, so a router that only asked "does some target for this tab remain"
    /// would deliver into the second one here.
    @MainActor
    func testWithdrawalDuringPrepareWithNoOtherTargetTakesTheFallback() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder))
        await router.register(Fixtures.target(.files, specificity: 8, into: recorder))

        await router.open(Fixtures.unclaimedFile, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            await router.unregister(tab: .files)
        }

        XCTAssertEqual(recorder.tabs, [], "a withdrawn tab received \(recorder.tabs.count) links")
        XCTAssertEqual(recorder.events, ["prepare:files"], "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages.count, 1,
                       "the withdrawn link produced \(sink.messages.count) diagnostics, not the one fallback")
        for token in Fixtures.payloadTokens {
            XCTAssertFalse(sink.messages.first?.contains(token) ?? false,
                           "the fallback message carries a payload token")
        }
    }

    // MARK: - 9. A delivery already in flight, and the withdrawal that must wait for it

    /// `unregister(tab:)` returns only after every delivery already in flight for that tab has
    /// completed.
    ///
    /// The handler is `@MainActor`, so the router *suspends* between committing to a delivery and
    /// the handler's first line, and a withdrawal that completed in that window would let the host
    /// which awaits it release the tab's sessions under a handler that is about to run. The gate
    /// holds one delivery open, and the assertion is that the withdrawal has not returned while it
    /// is held — an ordering, not a timing.
    @MainActor
    func testUnregisterWaitsForADeliveryAlreadyInFlight() async {
        let recorder = Recorder()
        let gate = Gate()
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        await router.register(LinkTarget(tab: .files, specificity: 1,
                                         handles: { _ in true },
                                         open: { _, _ in
                                             recorder.note("handler-start")
                                             await gate.arrive()
                                             recorder.note("handler-end")
                                         }))

        let routing = Task { await router.open(Fixtures.file, from: .currentPanel) }
        await gate.waitForArrival()
        XCTAssertEqual(recorder.events, ["handler-start"], "the recorded order was \(recorder.events)")

        let withdrawal = Task {
            await router.unregister(tab: .files)
            recorder.note("withdrawn")
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(recorder.events, ["handler-start"],
                       "the withdrawal returned while a delivery was in flight: \(recorder.events)")

        gate.open()
        await withdrawal.value
        await routing.value
        XCTAssertEqual(recorder.events, ["handler-start", "handler-end", "withdrawn"],
                       "the recorded order was \(recorder.events)")
    }

    // MARK: - 10. Re-resolution is against the live registry

    /// A tab that withdraws and registers again *during* `prepare` — X7's handover, which is the
    /// reason `unregister(tab:)` is `async` at all — is the live target for this open.
    ///
    /// Re-resolving against the registry as it stood when the call began would exclude the
    /// replacement and hand the link either to an unrelated registration or to the fallback, and
    /// no assertion about the withdrawn target could see it. The two `.files` registrations carry
    /// different labels, so the recorded event names which one received the link.
    @MainActor
    func testAReplacementRegisteredDuringPrepareReceivesTheLink() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder,
                                              label: "placeholder"))
        await router.register(Fixtures.target(.terminal, specificity: 1, into: recorder))

        await router.open(Fixtures.file, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            guard target.tab == .files else { return }
            await router.unregister(tab: .files)
            await router.register(Fixtures.target(.files, specificity: 10, into: recorder,
                                                  label: "successor"))
        }

        XCTAssertEqual(recorder.events, ["prepare:files", "open:successor:newWindow"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages, [], "a link that reached a target also produced a diagnostic")
    }

    /// The bound on re-resolution, and what makes it a bound rather than a hope.
    ///
    /// This `prepare` hands the tab over on **every** attempt, so a router that re-resolved against
    /// the live registry and prepared each time would never leave `open`. It leaves after one
    /// preparation and one outcome: the replacement for the tab already prepared for delivers into
    /// the window that preparation opened, and nothing is prepared twice.
    @MainActor
    func testAHandoverRepeatedOnEveryAttemptStillFinishesWithOnePreparation() async {
        let recorder = Recorder()
        let sink = Sink()
        let router = LinkRouter(externalOpener: { sink.opened($0) }, diagnostic: { sink.said($0) })
        await router.register(Fixtures.target(.files, specificity: 10, into: recorder))

        await router.open(Fixtures.unclaimedFile, from: .newWindow) { target, _ in
            recorder.note("prepare:\(target.tab.rawValue)")
            await router.unregister(tab: .files)
            await router.register(Fixtures.target(.files, specificity: 10, into: recorder))
        }

        XCTAssertEqual(recorder.tabs, [.files], "a target delivered \(recorder.tabs.count) times, not once")
        XCTAssertEqual(recorder.events, ["prepare:files", "open:files:newWindow"],
                       "the recorded order was \(recorder.events)")
        XCTAssertEqual(sink.messages, [], "a link that reached a target also produced a diagnostic")
    }
}

// MARK: - Rigs

/// A one-shot gate a `@MainActor` handler waits on, so a delivery can be held *open* while the
/// test drives a withdrawal against it. Continuation-based rather than timed, so the interleaving
/// is deterministic.
@MainActor
final class Gate {
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var hasArrived = false

    /// Called from inside the handler: announces that the delivery has begun and blocks until the
    /// test opens the gate.
    func arrive() async {
        hasArrived = true
        let waiting = watchers
        watchers = []
        for watcher in waiting { watcher.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    /// Called from the test: returns once the handler has begun.
    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = arrivals
        arrivals = []
        for arrival in waiting { arrival.resume() }
    }
}


/// What the handlers and the `prepare` hook write to. One object, so ordering is assertable.
@MainActor
final class Recorder {
    private(set) var tabs: [PanelTabID] = []
    private(set) var links: [WorkspaceLink] = []
    private(set) var destinations: [LinkDestination] = []
    private(set) var events: [String] = []

    func delivered(tab: PanelTabID, link: WorkspaceLink, destination: LinkDestination,
                   label: String) {
        tabs.append(tab)
        links.append(link)
        destinations.append(destination)
        events.append("open:\(label):\(destination)")
    }

    func note(_ event: String) { events.append(event) }
}

/// The two fallback seams, injected. They are called from the router's own executor rather than
/// the main actor, so this is lock-guarded rather than actor-isolated.
final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    private var _urls: [URL] = []

    func said(_ message: String) { lock.lock(); _messages.append(message); lock.unlock() }
    func opened(_ url: URL) { lock.lock(); _urls.append(url); lock.unlock() }

    var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
}

/// Invented identifiers only (§11). `zzunmistakablezz` and the two numbers below appear nowhere
/// else, which is what makes the "no payload in the diagnostic" assertion able to fail.
enum Fixtures {
    static let token = "zzunmistakablezz"
    static let commitToken = "zzunmistakablezzc0ffee"
    static let pullRequestNumber = 918273
    static let payloadTokens = [token, commitToken, String(pullRequestNumber)]

    static let file = WorkspaceLink.file(URL(fileURLWithPath: "/invented/project/main.swift"), line: 12)
    static let diff = WorkspaceLink.diff(DiffRef(repository: URL(fileURLWithPath: "/invented/project"),
                                                 path: "Sources/main.swift",
                                                 base: .workingTreeAgainstHEAD))
    static let url = WorkspaceLink.url(URL(string: "https://invented.example/page-1")!)
    static let commit = WorkspaceLink.commit("0123456789abcdef")
    static let pullRequest = WorkspaceLink.pullRequest(7)
    static let command = WorkspaceLink.command("invented-command")

    static let unmistakableURL = URL(string: "https://invented.example/\(token)")!
    static let unclaimedURL = WorkspaceLink.url(unmistakableURL)
    static let unclaimedFile = WorkspaceLink.file(URL(fileURLWithPath: "/invented/project/\(token)/main.swift"),
                                                  line: pullRequestNumber)
    static let unclaimedDiff = WorkspaceLink.diff(DiffRef(repository: URL(fileURLWithPath: "/invented/\(token)"),
                                                          path: "\(token)/main.swift",
                                                          base: .commit(commitToken)))
    static let unclaimedCommit = WorkspaceLink.commit(commitToken)
    static let unclaimedPullRequest = WorkspaceLink.pullRequest(pullRequestNumber)
    static let unclaimedCommand = WorkspaceLink.command("\(token) --run")

    /// A target that handles everything, so the resolution tests are about resolution and the
    /// delivery tests are about delivery.
    ///
    /// `label` names the *registration* rather than the tab, so a handover — one tab withdrawing
    /// and registering again under the same id — is assertable. It defaults to the tab, which is
    /// what every test that has one registration per tab reads.
    @MainActor
    static func target(_ tab: PanelTabID, specificity: Int, into recorder: Recorder,
                       label: String? = nil) -> LinkTarget {
        let label = label ?? tab.rawValue
        return LinkTarget(tab: tab, specificity: specificity,
                          handles: { _ in true },
                          open: { link, destination in
                              recorder.delivered(tab: tab, link: link, destination: destination,
                                                 label: label)
                          })
    }
}
