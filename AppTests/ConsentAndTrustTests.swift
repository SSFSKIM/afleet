import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// A probe on the one piece of in-flight state `PrecommitModel` holds. Every action claims the slot
/// before it returns, so a test that has pressed a button can wait for the round trip without
/// waiting on a duration.
extension PrecommitModel {
    func whenIdle() async {
        while isAnswering { await Task.yield() }
    }
}

/// The §6.12 consent sheet and the §6.11 trust banner (acceptance G4).
///
/// **Every clause asserts the call that left the surface**, never that a sheet closed or a banner
/// appeared: a sheet closes for many reasons and only one of them is the right consent having been
/// recorded. The accept clause asserts the emitted call *and* that nothing else was called; the
/// decline clause asserts the names and the project it was given.
///
/// **X9 and §11.** Nothing here writes anywhere: the decline goes through `LifecycleAPI`, which the
/// double answers in memory, and no test builds a real project or a real config home. Every
/// identifier is invented — servers named after nobody, a project under `/invented`, a config home
/// under the temporary directory that is never created. The untrusted clause asserts the *absence*
/// of the root's path component in the banner, so a banner that leaked the path fails.
@MainActor
final class ConsentAndTrustTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("e", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-consent-unwritten"))
    }

    /// The project a decline is recorded against, and the one whose trust is missing. Invented, and
    /// its last component is the string the trust banner must not contain.
    private static let project = URL(fileURLWithPath: "/invented/consent-project-e7")

    /// The second channel and project a selection moves to, so an evaluation can be superseded by
    /// one for somewhere else. Invented, and different from the first in both halves.
    private static var otherChannel: ChannelKey {
        ActivityFixtures.key("f", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-consent-unwritten"))
    }

    private static let otherProject = URL(fileURLWithPath: "/invented/consent-project-f8")

    /// The second project's own pending server, named after nobody and shared with neither list.
    private static let otherServers = [
        ProjectMCPServer(name: "invented-ledger",
                         transport: .http(url: "https://invented.example/ledger"),
                         entryHash: String(repeating: "c", count: 64))
    ]

    /// Two pending servers: one stdio, one http. Both invented.
    private static let servers = [
        ProjectMCPServer(name: "invented-notes",
                         transport: .stdio(command: "/invented/bin/notes-server", arguments: ["--port", "0"]),
                         entryHash: String(repeating: "a", count: 64)),
        ProjectMCPServer(name: "invented-search",
                         transport: .http(url: "https://invented.example/mcp"),
                         entryHash: String(repeating: "b", count: 64))
    ]

    /// A model over a double staged with one verdict, already evaluated.
    private func evaluated(_ verdicts: [SpawnPrecondition],
                           panels: any PanelHost = PanelHostModel())
        async -> (ConsentDouble, PrecommitModel) {
        let lifecycle = ConsentDouble()
        await lifecycle.stage(verdicts)
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels)
        await model.evaluate(channel: Self.channel, project: Self.project)
        return (lifecycle, model)
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the surface offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    /// The sheet the mount builds, over one `ConsentRequest`: servers and evaluation together, and
    /// both answers carrying that one value — which is exactly what `ChannelDecorations` does.
    private func sheet(for request: PrecommitModel.ConsentRequest, on model: PrecommitModel) -> ConsentSheet {
        ConsentSheet(servers: request.servers, isAnswering: model.isAnswering,
                     accept: { model.accept(request) }, decline: { model.decline(request) })
    }

    private func texts(in body: Any) -> [String] {
        ViewTree.values(of: Text.self, in: body).flatMap { ViewTree.values(of: String.self, in: $0) }
    }

    // MARK: - G4a: the sheet

    /// The sheet lists each pending server's name and the summary of its transport. A consent
    /// dialog that hides what it is consenting to is not consent, so both halves are asserted for
    /// both transports.
    func testTheSheetListsEveryServerWithItsNameAndTransportSummary() async throws {
        let (_, model) = await evaluated([.consentNeeded(Self.servers)])
        let servers = try XCTUnwrap(model.consentRequest?.servers, "the consentNeeded verdict raised no sheet")
        XCTAssertEqual(servers.count, 2, "the sheet lists a different number of servers than the verdict named")

        let sheet = ConsentSheet(servers: servers, isAnswering: false, accept: {}, decline: {})
        for server in servers {
            let drawn = texts(in: sheet.row(server))
            XCTAssertTrue(drawn.contains(server.name), "the sheet drew no row naming one of the servers")
            XCTAssertTrue(drawn.contains(ConsentSheet.summary(of: server.transport)),
                          "the sheet drew a server without its transport summary")
        }
        XCTAssertTrue(ConsentSheet.summary(of: servers[0].transport).contains("/invented/bin/notes-server"),
                      "a stdio server's summary did not carry the command it would run")
        XCTAssertTrue(ConsentSheet.summary(of: servers[1].transport).contains("https://invented.example/mcp"),
                      "an http server's summary did not carry the URL it would reach")
    }

    /// *Accept* is `acceptProjectServers` and **nothing else**: no decline, no spawn, no other
    /// lifecycle action. Asserted as the emitted call and its arguments.
    func testAcceptCallsAcceptProjectServersAndNothingElse() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(Self.servers), .ready])
        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")
        let servers = request.servers

        try press("Accept", in: sheet(for: request, on: model).body)
        await model.whenIdle()

        let accepted = await lifecycle.accepted
        XCTAssertEqual(accepted.count, 1, "accept did not emit exactly one acceptProjectServers call")
        XCTAssertEqual(accepted.first?.servers.map(\.name), servers.map(\.name),
                       "accept named different servers than the sheet listed")
        XCTAssertTrue(accepted.first?.project == Self.project,
                      "accept recorded the acceptance against a different project directory")

        let declined = await lifecycle.declined
        let actions = await lifecycle.actions
        XCTAssertEqual(declined.count, 0, "accept also declined \(declined.count) server set(s)")
        XCTAssertEqual(actions.count, 0, "accept also performed \(actions.count) lifecycle action(s)")
        XCTAssertTrue(model.consentRequest == nil, "the re-read verdict still asks for consent")
    }

    /// *Decline* is `declineProjectServers` with **exactly the declined names** and the project
    /// root. Asserted as the emitted call's arguments; a decline that sent hashes, a subset or the
    /// wrong directory fails here and nowhere else.
    func testDeclineCallsDeclineProjectServersWithExactlyTheDeclinedNames() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(Self.servers), .ready])
        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")

        try press("Decline", in: sheet(for: request, on: model).body)
        await model.whenIdle()

        let declined = await lifecycle.declined
        XCTAssertEqual(declined.count, 1, "decline did not emit exactly one declineProjectServers call")
        XCTAssertEqual(declined.first?.names, ["invented-notes", "invented-search"],
                       "decline named a different set of servers than the sheet declined")
        XCTAssertTrue(declined.first?.project == Self.project,
                      "decline recorded the names against a different project directory")

        let accepted = await lifecycle.accepted
        XCTAssertEqual(accepted.count, 0, "decline also accepted \(accepted.count) server set(s)")
    }

    /// The trace §6.12 turns on: consent is taken **before the child exists**, so no spawn may
    /// happen while the sheet is up. The spawn seam is installed and asserted never entered — the
    /// break cannot be executed from the surface, so the substitute is this trace.
    func testNothingSpawnedWhileTheConsentSheetWasUp() async throws {
        let counter = SpawnCounter()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.consentNeeded(Self.servers), .ready])
        await lifecycle.setSpawn(counter.factory)
        let model = PrecommitModel(lifecycle: lifecycle, panels: PanelHostModel())
        await model.evaluate(channel: Self.channel, project: Self.project)

        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")
        XCTAssertEqual(counter.count, 0, "a process was built while the consent sheet was up")
        try press("Accept", in: sheet(for: request, on: model).body)
        await model.whenIdle()

        XCTAssertEqual(counter.count, 0, "accepting the sheet spawned \(counter.count) process(es) itself")
        let opens = await lifecycle.actions.filter { if case .open = $0.action { true } else { false } }
        XCTAssertEqual(opens.count, 0, "the consent path performed \(opens.count) open action(s) of its own")
    }

    // MARK: - Two evaluations, one surface

    /// A verdict read for an evaluation the user has already navigated past **never reaches the
    /// surface**.
    ///
    /// `preconditions(for:)` is a call to the fleet and nothing orders two of them: the column
    /// re-evaluates whenever the selection moves, so A's read can complete after B's. A model that
    /// published whatever came back last would put A's `consentNeeded` on screen beside B's
    /// project — and the sheet's two answers act on exactly that pair, so the acceptance would be
    /// recorded for a project the user never saw.
    ///
    /// The out-of-order completion is constructed rather than hoped for: A's read is held inside the
    /// double until B's has settled.
    func testASupersededEvaluationsVerdictNeverReachesTheSurface() async throws {
        let lifecycle = ConsentDouble()
        // A reads `consentNeeded`; B reads `ready`. A is held, so it returns second.
        await lifecycle.stage([.consentNeeded(Self.servers), .ready])
        await lifecycle.gateNextPreconditions()
        let model = PrecommitModel(lifecycle: lifecycle, panels: PanelHostModel())

        let first = Task { await model.evaluate(channel: Self.channel, project: Self.project) }
        while await lifecycle.gated == 0 { await Task.yield() }

        await model.evaluate(channel: Self.otherChannel, project: Self.otherProject)
        XCTAssertTrue(model.consentRequest == nil, "the second channel's ready verdict raised a sheet of its own")

        await lifecycle.releaseGate()
        await first.value

        XCTAssertTrue(model.consentRequest == nil,
                      "a superseded evaluation's consent sheet reached the surface after a later one settled")
        let evaluation = try XCTUnwrap(model.evaluation, "no evaluation is on screen at all")
        XCTAssertTrue(evaluation.project == Self.otherProject,
                      "the surface holds a project the last evaluation did not read")
        XCTAssertTrue(evaluation.channel == Self.otherChannel,
                      "the surface holds a channel the last evaluation did not read")
    }

    /// The sheet's two answers act on **the project and the servers the sheet was shown with**, and
    /// a sheet whose evaluation has been superseded answers nothing.
    ///
    /// This needs no out-of-order completion at all: starting B's evaluation changes what the model
    /// holds while A's sheet is still on screen and still pressable. Both directions, because an
    /// accept that recorded nothing at all would pass the first clause alone.
    func testASupersededSheetRecordsNothingAndTheCurrentOneRecordsItsOwnProject() async throws {
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.consentNeeded(Self.servers), .consentNeeded(Self.otherServers)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: PanelHostModel())

        await model.evaluate(channel: Self.channel, project: Self.project)
        let stale = try XCTUnwrap(model.consentRequest, "the first channel raised no sheet")

        await model.evaluate(channel: Self.otherChannel, project: Self.otherProject)
        let current = try XCTUnwrap(model.consentRequest, "the second channel raised no sheet")
        XCTAssertNotEqual(stale.id, current.id, "the second evaluation reused the first one's sheet")

        try press("Accept", in: sheet(for: stale, on: model).body)
        await model.whenIdle()
        let afterStale = await lifecycle.accepted
        XCTAssertEqual(afterStale.count, 0,
                       "a sheet the selection has moved past recorded \(afterStale.count) acceptance(s)")

        try press("Accept", in: sheet(for: current, on: model).body)
        await model.whenIdle()
        let accepted = await lifecycle.accepted
        XCTAssertEqual(accepted.count, 1, "the current sheet emitted \(accepted.count) acceptProjectServers call(s)")
        XCTAssertTrue(accepted.first?.project == Self.otherProject,
                      "the acceptance was recorded against a project the sheet did not show")
        XCTAssertEqual(accepted.first?.servers.map(\.name), Self.otherServers.map(\.name),
                       "the acceptance named servers the sheet did not list")
    }

    // MARK: - G4b: a refused decline

    /// §6.12's fail-closed path — unparseable JSON, a symlink, a foreign uid, a write error — reads
    /// as nothing written and nothing spawned, and points at the terminal's own `/mcp` flow. It is
    /// not a retryable hiccup, so the banner must not read like one.
    func testARefusedDeclineRendersTheBannerPointingAtTheTerminal() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(Self.servers)])
        await lifecycle.refuseDecline(reason: "symlink")

        model.decline(try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet"))
        await model.whenIdle()

        let banner = try XCTUnwrap(model.banner, "a refused decline raised no banner")
        XCTAssertTrue(banner.text.contains("/mcp"),
                      "the refusal banner does not point at the terminal's /mcp flow")
        XCTAssertTrue(banner.text.contains("Nothing was written"),
                      "the refusal banner does not say that nothing was written")
        XCTAssertTrue(banner.text.contains("nothing spawned"),
                      "the refusal banner does not say that nothing spawned")
        XCTAssertTrue(banner.text.contains("symlink"),
                      "the refusal banner does not name the store's own reason")
        XCTAssertTrue(model.consentRequest != nil, "a refused decline let the consent sheet close")
    }

    // MARK: - G4c: the trust banner

    /// §6.11: an untrusted project opens history-only, and the banner names the project in words.
    /// The path clause is the discriminating one — `untrusted` carries a root, and a banner built
    /// from it would read the project's directory name out loud (§11).
    func testAnUntrustedChannelIsHistoryOnlyAndItsBannerNamesNoPath() async throws {
        let (_, model) = await evaluated([.untrusted(root: Self.project)])
        XCTAssertTrue(model.isHistoryOnly, "an untrusted verdict did not make the channel history-only")

        let banner = TrustBanner(isAnswering: false, review: {})
        let drawn = texts(in: banner.body)
        XCTAssertTrue(drawn.contains(PrecommitModel.untrustedSentence),
                      "the trust banner does not say the project has not been trusted in Claude Code")
        for line in drawn {
            XCTAssertFalse(line.contains(Self.project.lastPathComponent),
                           "the trust banner leaked the project's own directory name")
            XCTAssertFalse(line.contains(Self.project.path),
                           "the trust banner leaked the project's path")
        }
        // The floor: a banner that drew nothing at all would pass every clause above.
        XCTAssertGreaterThanOrEqual(drawn.count, 2, "the trust banner drew \(drawn.count) line(s)")

        // A trusted channel draws neither: the negative half, so the assertions above discriminate.
        let (_, ready) = await evaluated([.ready])
        XCTAssertFalse(ready.isHistoryOnly, "a ready channel was made history-only")
    }

    /// *Review trust in terminal* hands the host the `PaneRequest` C4 built, **unchanged, `id`
    /// included**: C4 accepts a `PaneExit` only when `exit.request.id` is the id it is waiting on,
    /// so a host handed a freshly minted request would have every exit discarded in silence.
    func testReviewTrustHandsTheHostTheSamePaneRequest() async throws {
        let panels = PanelHostModel()
        let runner = ConsentPaneRunner()
        panels.registerPaneRunner(runner, for: .terminal)
        let (lifecycle, model) = await evaluated([.untrusted(root: Self.project)], panels: panels)
        let expected = lifecycle.paneRequest

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        let received = await runner.received
        XCTAssertEqual(received.count, 1, "the registered runner received \(received.count) pane request(s)")
        XCTAssertEqual(received.first?.id, expected.id,
                       "the host was handed a different pane request id than the lifecycle minted")
        XCTAssertTrue(received.first == expected, "the pane request reached the runner edited")
        XCTAssertNil(model.banner, "a successful handoff raised a banner")
    }

    /// Item 47 degraded exactly as far as C7.4's absence forces: with no pane runner registered the
    /// host refuses, and the refusal is a banner naming the terminal rather than silence.
    func testWithNoRunnerRegisteredTheRefusalBecomesABannerNamingTheTerminal() async throws {
        let (_, model) = await evaluated([.untrusted(root: Self.project)], panels: PanelHostModel())

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        let raised = try XCTUnwrap(model.banner, "the host's refusal was swallowed and raised no banner")
        XCTAssertTrue(raised.text.contains("Terminal"), "the refusal banner does not name the terminal")
        XCTAssertTrue(raised.text.contains("claude"),
                      "the refusal banner does not say what to run in your own terminal")
        XCTAssertTrue(model.isHistoryOnly, "the refused handoff left the channel out of history-only")
    }
}

// MARK: - The doubles

/// A lifecycle that answers the four members this surface calls — `preconditions`, `accept`,
/// `decline` and `openInTerminal` — and records every one of them.
///
/// `LifecycleDouble` traps on all four, which is right for the surfaces it was built for and wrong
/// here. This one also carries the spawn seam, wired where `Fleet` wires it, so a test can assert
/// that consent was taken before any child existed.
actor ConsentDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    /// The verdicts, in order. The last one staged is repeated once the queue drains, so a re-read
    /// after an accept answers whatever the test said the fleet would then say.
    private var verdicts: [SpawnPrecondition] = [.ready]
    private var declineRefusal: LifecycleError?
    private(set) var accepted: [(servers: [ProjectMCPServer], project: URL)] = []
    private(set) var declined: [(names: [String], project: URL)] = []
    private(set) var actions: [(key: ChannelKey, action: LifecycleAction)] = []
    private var spawn: ProcessFactory?

    /// The request `openInTerminal` answers with. Built once, so a test can compare the id the host
    /// was handed against the id C4 minted.
    let paneRequest = PaneRequest(executable: URL(fileURLWithPath: "/invented/bin/claude"),
                                  arguments: ["--resume"],
                                  cwd: URL(fileURLWithPath: "/invented/consent-project-e7"),
                                  environment: [:],
                                  purpose: .hatch(SidebarFixtures.session("e")))

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Holds the next `preconditions` read inside the double until `releaseGate()`, so a test can
    /// construct the completion order two concurrent evaluations do not otherwise have. The verdict
    /// is drawn from the queue *before* the hold, so which read gets which verdict is settled by
    /// call order and not by completion order.
    private var gateNext = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// How many reads the gate has caught. A test waits on this rather than on a duration.
    private(set) var gated = 0

    func gateNextPreconditions() { gateNext = true }
    func releaseGate() {
        for continuation in held { continuation.resume() }
        held = []
    }

    func stage(_ verdicts: [SpawnPrecondition]) { self.verdicts = verdicts }
    func refuseDecline(reason: String) { declineRefusal = .declineRefused(reason: reason) }
    func setSpawn(_ factory: @escaping ProcessFactory) { spawn = factory }

    func preconditions(for key: ChannelKey) async -> SpawnPrecondition {
        var verdict = SpawnPrecondition.ready
        if let next = verdicts.first {
            verdict = next
            if verdicts.count > 1 { verdicts.removeFirst() }
        }
        if gateNext {
            gateNext = false
            gated += 1
            await withCheckedContinuation { held.append($0) }
        }
        return verdict
    }

    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {
        accepted.append((servers, project))
    }

    func declineProjectServers(_ names: [String], project: URL) async throws {
        declined.append((names, project))
        if let declineRefusal { throw declineRefusal }
    }

    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { paneRequest }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        actions.append((key, action))
        if case .open = action, let spawn {
            _ = spawn(.first, LaunchConfiguration(binary: URL(fileURLWithPath: "/invented/bin/claude"),
                                                  cwd: URL(fileURLWithPath: "/invented/consent-project-e7"),
                                                  session: .resume(key.session, fork: false)))
        }
        return ActivityFixtures.state(key)
    }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue { unreachable("send") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }

    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID { unreachable("sendPrompt") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { unreachable("liveTaskIDs") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ConsentDouble.\(member) is not part of the consent and trust surface")
    }
}

/// A `PaneRunning` that records the requests it was handed, unedited.
private actor ConsentPaneRunner: PaneRunning {
    private(set) var received: [PaneRequest] = []
    func bind(_ report: @escaping @Sendable (PaneExit) async -> Void) {}
    func run(_ request: PaneRequest) async { received.append(request) }
}
