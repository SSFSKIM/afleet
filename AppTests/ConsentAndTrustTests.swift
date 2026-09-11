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

    /// Waits for the work the **pane's exit** starts: the re-read, and the spawn a trust flip earns.
    ///
    /// `isAnswering` is released when the pane is handed over — see `reviewTrustInTerminal` — so it
    /// cannot be what this waits on. The verdict leaving `.untrusted` is what the re-read does, and
    /// it is the thing the caller is about to assert on, so it is what ends the wait.
    func settledAfterPane() async {
        while isHistoryOnly { await Task.yield() }
        await Task.yield()
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
                           panels: any PanelHost = ConsentPanelHost())
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
                     accept: { model.accept(request) }, decline: { model.decline(request) },
                     notNow: { model.notNow(request) })
    }

    private func texts(in body: Any) -> [String] {
        ViewTree.values(of: Text.self, in: body).flatMap { ViewTree.values(of: String.self, in: $0) }
    }

    // MARK: - G4a: the sheet

    /// The sheet lists each pending server's name and the summary of its transport. A consent
    /// dialog that hides what it is consenting to is not consent, so both halves are asserted for
    /// both transports.
    func testTheSheetListsEveryServerWithItsNameAndTransportSummary() async throws {
        let (_, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers)])
        let servers = try XCTUnwrap(model.consentRequest?.servers, "the consentNeeded verdict raised no sheet")
        XCTAssertEqual(servers.count, 2, "the sheet lists a different number of servers than the verdict named")

        let sheet = ConsentSheet(servers: servers, isAnswering: false, accept: {}, decline: {}, notNow: {})
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
        let (lifecycle, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers), .ready])
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
        let (lifecycle, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers), .ready])
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
        await lifecycle.stage([.consentNeeded(project: Self.project, servers: Self.servers), .ready])
        await lifecycle.setSpawn(counter.factory)
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())
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
        await lifecycle.stage([.consentNeeded(project: Self.project, servers: Self.servers), .ready])
        await lifecycle.gateNextPreconditions()
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())

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
        await lifecycle.stage([.consentNeeded(project: Self.project, servers: Self.servers),
                               .consentNeeded(project: Self.otherProject, servers: Self.otherServers)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())

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

    /// The two answers name **the project the fleet evaluated**, not the directory the row happened
    /// to be showing when the button was pressed.
    ///
    /// `Fleet.preconditions(for:)` reads the launch's own `cwd`; the mount supplies the row's
    /// directory independently, and the two part company the moment a channel is relocated — a
    /// `set_cwd`, a re-registration, an index update that arrives after the verdict. A decline is
    /// the one §6.12 write, into the project's `.claude/settings.local.json`, so a verdict computed
    /// for A that is declined against B writes a refusal into a project nobody was asked about. The
    /// project therefore travels *with* the verdict, and the sheet's answers take it from there.
    func testTheAnswersNameTheEvaluatedProjectAfterTheRowsDirectoryMoves() async throws {
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.consentNeeded(project: Self.project, servers: Self.servers)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())
        await model.evaluate(channel: Self.channel, project: Self.project)

        // The row moves. The fleet still evaluates the launch it holds, so the verdict is the same
        // one and names the same project; only the directory the mount supplies has changed.
        await model.evaluate(channel: Self.channel, project: Self.otherProject)
        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")

        try press("Decline", in: sheet(for: request, on: model).body)
        await model.whenIdle()
        let declined = await lifecycle.declined
        XCTAssertEqual(declined.count, 1, "decline did not emit exactly one declineProjectServers call")
        XCTAssertTrue(declined.first?.project == Self.project,
                      "the decline would have written into a project the verdict was not computed for")

        try press("Accept", in: sheet(for: request, on: model).body)
        await model.whenIdle()
        let accepted = await lifecycle.accepted
        XCTAssertEqual(accepted.count, 1, "accept did not emit exactly one acceptProjectServers call")
        XCTAssertTrue(accepted.first?.project == Self.project,
                      "the acceptance was recorded against a project the verdict was not computed for")
    }

    // MARK: - G4b: a refused decline

    /// §6.12's fail-closed path — unparseable JSON, a symlink, a foreign uid, a write error — reads
    /// as nothing written and nothing spawned, and points at the terminal's own `/mcp` flow. It is
    /// not a retryable hiccup, so the banner must not read like one.
    func testARefusedDeclineRendersTheBannerPointingAtTheTerminal() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers)])
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
        let panels = ConsentPanelHost()
        let (lifecycle, model) = await evaluated([.untrusted(root: Self.project)], panels: panels)
        let expected = lifecycle.paneRequest

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        let received = panels.runs.map(\.request)
        XCTAssertEqual(received.count, 1, "the registered runner received \(received.count) pane request(s)")
        XCTAssertEqual(received.first?.id, expected.id,
                       "the host was handed a different pane request id than the lifecycle minted")
        XCTAssertTrue(received.first == expected, "the pane request reached the runner edited")
        // The channel the action named, not the one the window happens to be showing (X7 as amended
        // 2026-09-09): the pane belongs to the evaluation this banner was drawn for, and opening it
        // anywhere else would put somebody else's project on screen under this project's trust.
        XCTAssertTrue(panels.runs.first?.channel == Self.channel,
                      "the action named a different channel than the evaluation it was drawn for")
        XCTAssertNil(model.banner, "a successful handoff raised a banner")
    }

    /// Item 47 degraded as far as a build with no Terminal pane forces: the host refuses, and the
    /// refusal is a banner naming the terminal rather than silence.
    ///
    /// The refusal is asked for rather than arranged by omission, since C7.4 landed: the app now
    /// registers a pane runner at launch, so `noPaneRunner` is a defence rather than a state a real
    /// host falls into, and a test that produced it by leaving a runner unregistered would be
    /// asserting on a configuration the app no longer has.
    func testWithNoRunnerRegisteredTheRefusalBecomesABannerNamingTheTerminal() async throws {
        let panels = ConsentPanelHost()
        panels.refusal = .noPaneRunner(.terminal)
        let (_, model) = await evaluated([.untrusted(root: Self.project)], panels: panels)

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        let raised = try XCTUnwrap(model.banner, "the host's refusal was swallowed and raised no banner")
        XCTAssertTrue(raised.text.contains("Terminal"), "the refusal banner does not name the terminal")
        XCTAssertTrue(raised.text.contains("claude"),
                      "the refusal banner does not say what to run in your own terminal")
        XCTAssertTrue(model.isHistoryOnly, "the refused handoff left the channel out of history-only")
    }

    // MARK: - Item 47's second half: the trust flip spawns

    /// §14 item 47, end to end on this side: the dialog was accepted in the pane the banner handed
    /// over, the re-read finds `.ready`, and the channel spawns **owned**.
    ///
    /// Nothing else would spawn it. Trust is granted outside afleet, no state afleet holds changes
    /// when it is, and the channel is history-only precisely because the user cannot send — so a
    /// re-read that only cleared the banner would leave a trusted project sitting behind an empty
    /// column until the selection moved.
    func testTrustGrantedInTheTerminalSpawnsTheChannelExactlyOnce() async throws {
        let panels = ConsentPanelHost()
        let (lifecycle, model) = await evaluated([.untrusted(root: Self.project), .ready], panels: panels)
        let spawns = SpawnCounter()
        await lifecycle.setSpawn(spawns.factory)

        XCTAssertTrue(model.isHistoryOnly, "an untrusted project was not opened history-only")
        let actionsBefore = await lifecycle.actions.count
        XCTAssertEqual(actionsBefore, 0, "the untrusted channel acted before trust was granted")
        XCTAssertEqual(spawns.count, 0, "the untrusted channel built a process")

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.settledAfterPane()

        XCTAssertFalse(model.isHistoryOnly, "the channel stayed history-only after trust was granted")
        let opens = await lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(opens.count, 1, "the trust flip issued \(opens.count) open(s), not one")
        XCTAssertTrue(opens.first?.key == Self.channel,
                      "the spawn named a channel other than the evaluation's own")
        XCTAssertEqual(spawns.count, 1, "the trust flip did not reach a process")
        XCTAssertNil(model.banner, "a successful spawn after trust raised a banner")
    }

    /// **Item 47, end to end on the timing that matters: the re-read happens after the pane
    /// *exits*, not after the request is handed over.**
    ///
    /// `PanelHost.run(_:for:)` returns when the pane **starts** — the runner spawns and returns —
    /// and the exit travels back later through `reportPaneExit`. Trust is granted in the engine's
    /// own dialog *inside* that pane, so a re-read taken when `run` returned would read the verdict
    /// before the user had answered: the channel would stay history-only and the one thing that
    /// re-reads it, coming back to the front, no longer happens now that the pane is inside afleet.
    func testTheTrustRereadWaitsForThePaneToExit() async throws {
        let panels = ConsentPanelHost()
        let announcer = PaneExitAnnouncer()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project), .ready])
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels, paneExits: announcer)
        await model.evaluate(channel: Self.channel, project: Self.project)
        let spawns = SpawnCounter()
        await lifecycle.setSpawn(spawns.factory)

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)

        // The pane is running. Nothing has been re-read and nothing has spawned: the user is still
        // looking at the engine's dialog.
        await model.whenIdle()
        XCTAssertEqual(panels.runs.count, 1, "the pane was not handed over")
        XCTAssertTrue(model.isHistoryOnly, "the verdict was re-read before the pane had ended")
        let duringPane = await lifecycle.actions.count
        XCTAssertEqual(duringPane, 0, "the channel acted while the trust dialog was still open")
        XCTAssertEqual(spawns.count, 0, "the channel spawned while the trust dialog was still open")

        // The user answers the dialog and closes the pane. The panel reports the exit, and that is
        // what drives the re-read.
        let request = try XCTUnwrap(panels.runs.first?.request)
        await announcer.announce(PaneExit(request: request, code: 0, observedAt: Date()))
        await model.settledAfterPane()

        XCTAssertFalse(model.isHistoryOnly, "the channel stayed history-only after trust was granted")
        let opens = await lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(opens.count, 1, "the pane's exit issued \(opens.count) open(s), not one")
        XCTAssertTrue(opens.first?.key == Self.channel,
                      "the spawn named a channel other than the evaluation's own")
        XCTAssertEqual(spawns.count, 1, "the pane's exit did not reach a process")

        // **The id is forgotten, which is the bound.** A second announcement of a pane already
        // waited for must do nothing: an announcer that kept every id would keep every waiter's
        // entry too, and this one would re-read and spawn again.
        await announcer.announce(PaneExit(request: request, code: 0, observedAt: Date()))
        await Task.yield()
        let again = await lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(again.count, 1, "a second announcement of one pane issued \(again.count) opens")
    }

    /// **One press, one pane.** A second press while the review pane is open opens nothing.
    ///
    /// `isAnswering` is released at the handover, which is right — it protects a second *request*
    /// reaching the host and that is over. What protects the supervisor's single pending review is
    /// its own flag: a second request would overwrite that slot, so the first pane's exit would
    /// match nothing and the channel would wait for a pane nobody is going to close.
    func testASecondPressWhileTheReviewPaneIsOpenOpensNothing() async throws {
        let panels = ConsentPanelHost()
        let announcer = PaneExitAnnouncer()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project), .ready])
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels, paneExits: announcer)
        await model.evaluate(channel: Self.channel, project: Self.project)

        try press("Review trust in terminal", in: TrustBanner(isAnswering: !model.canReviewTrust) {
            model.reviewTrustInTerminal()
        }.body)
        await model.whenIdle()
        XCTAssertEqual(panels.runs.count, 1, "the first press opened no pane")
        XCTAssertFalse(model.canReviewTrust, "the banner is still offered with a review pane open")

        // The second press, taken exactly as the banner would take it.
        model.reviewTrustInTerminal()
        await model.whenIdle()
        XCTAssertEqual(panels.runs.count, 1, "a second press opened \(panels.runs.count) panes, not one")
        let asked = await lifecycle.openings
        XCTAssertEqual(asked, 1, "a second press asked X5 for \(asked) requests, not one")

        // The pane ends, and the action is offered again.
        let request = try XCTUnwrap(panels.runs.first?.request)
        await announcer.announce(PaneExit(request: request, code: 0, observedAt: Date()))
        await model.settledAfterPane()
        XCTAssertTrue(model.canReviewTrust, "the action was not offered again after the pane ended")
    }

    /// A refused handoff gives back everything it took, so the user can press again.
    ///
    /// The declared pane id and the one-press slot are both taken *before* `PanelHost.run`, and the
    /// host discharges a request it refuses — the exit it synthesises goes to X5, not here. Without
    /// the withdrawal the id stayed declared for the life of the app and the banner stayed disabled
    /// for ever.
    func testARefusedReviewGivesBackTheSlotAndTheDeclaration() async throws {
        let panels = ConsentPanelHost()
        panels.refusal = .noPaneRunner(.terminal)
        let announcer = PaneExitAnnouncer()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels, paneExits: announcer)
        await model.evaluate(channel: Self.channel, project: Self.project)

        model.reviewTrustInTerminal()
        await model.whenIdle()
        XCTAssertNotNil(model.banner, "the refusal raised no banner")
        XCTAssertTrue(model.canReviewTrust, "a refused review left the action disabled for ever")

        // And a second press really does reach the host, which is what the slot being back means.
        panels.refusal = nil
        model.reviewTrustInTerminal()
        await model.whenIdle()
        XCTAssertEqual(panels.runs.count, 1, "the retry after a refusal opened no pane")
    }

    /// Switching to another application while the trust dialog is open does not drop the spawn.
    ///
    /// The decoration's `.task(id:)` keys on `isApplicationActive`, so coming back to the front
    /// re-evaluates the **same** channel and bumps the generation. Fenced on the generation, the
    /// exit-driven re-read dropped item 47's spawn exactly when the user did the thing the dialog
    /// asks for; fenced on the channel, it does not.
    func testLeavingAndReturningToTheAppWhileThePaneIsOpenKeepsTheSpawn() async throws {
        let panels = ConsentPanelHost()
        let announcer = PaneExitAnnouncer()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project), .ready])
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels, paneExits: announcer)
        await model.evaluate(channel: Self.channel, project: Self.project)

        model.reviewTrustInTerminal()
        await model.whenIdle()
        let request = try XCTUnwrap(panels.runs.first?.request)

        // The user switches away and back while the dialog is up: the same channel, a new
        // evaluation, a bumped generation.
        await model.evaluate(channel: Self.channel, project: Self.project)

        await announcer.announce(PaneExit(request: request, code: 0, observedAt: Date()))
        await model.settledAfterPane()

        let opens = await lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(opens.count, 1, "a trip out of the app dropped the spawn (\(opens.count) opens)")
        XCTAssertTrue(opens.first?.key == Self.channel, "the spawn named another channel")
    }

    /// The banner is usable again as soon as the pane has been handed over, and not held for as
    /// long as the user keeps it open.
    ///
    /// `isAnswering` disables every affordance here. It protects a second request reaching the
    /// host, which is over once the request is handed over — holding it until the exit would leave
    /// the banner dead for as long as the trust dialog was on screen.
    func testTheBannerIsUsableAgainOnceThePaneIsHandedOver() async throws {
        let panels = ConsentPanelHost()
        let announcer = PaneExitAnnouncer()
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels, paneExits: announcer)
        await model.evaluate(channel: Self.channel, project: Self.project)

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        XCTAssertFalse(model.isAnswering, "the banner is still disabled with the pane already running")
        XCTAssertEqual(panels.runs.count, 1, "the pane was not handed over")
    }

    /// The negative half, and the one that makes the clause above discriminating: a `.ready` verdict
    /// arriving on a channel that was **not** untrusted spawns nothing.
    ///
    /// `evaluate` runs on every selection and on every return to the front, so a spawn hung on
    /// `.ready` alone would open a process in every channel the user clicks past — which is the
    /// general auto-spawn item 47 does not ask for and §6.11's two preconditions exist to keep out.
    func testAConsentAcceptanceThatBecomesReadyDoesNotSpawn() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers),
                                                  .ready])
        let request = try XCTUnwrap(model.consentRequest, "the consent verdict raised no sheet")

        model.accept(request)
        await model.whenIdle()

        let accepted = await lifecycle.accepted.count
        XCTAssertTrue(accepted == 1, "the acceptance did not reach the fleet")
        let opens = await lifecycle.actions.filter { if case .open = $0.action { return true }; return false }
        XCTAssertEqual(opens.count, 0, "a consent acceptance that cleared the verdict spawned a process")
    }

    // MARK: - G4a: what an acceptance actually grants

    /// The sheet says **how long an acceptance lasts**, because it outlives the sheet.
    ///
    /// `SpawnPreconditions.accept` records project root, server name and entry hash in afleet's own
    /// store and `evaluate` reads those records on every later spawn; the production store writes
    /// them to disk, so the grant survives a restart. Copy that said *this session* described a
    /// narrower permission than the one being taken — the one thing a consent dialog may not do.
    /// Asserted as the words the sheet draws, in both directions: the disclosure has to be there and
    /// the old, narrower sentence has to be gone.
    func testTheSheetSaysAnAcceptanceIsRememberedAcrossSessions() async throws {
        let (_, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers)])
        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")
        let drawn = texts(in: sheet(for: request, on: model).body).joined(separator: " ")

        XCTAssertTrue(drawn.contains("across sessions"),
                      "the sheet does not say the acceptance is remembered across sessions")
        XCTAssertTrue(drawn.contains("configuration changes"),
                      "the sheet does not say what ends the acceptance it is taking")
        XCTAssertFalse(drawn.contains("this session start"),
                       "the sheet still offers the acceptance as one session's")
        XCTAssertFalse(drawn.contains("for this session"),
                       "the sheet still scopes the acceptance to one session")
        // The count clause the copy has always had, so the disclosure did not replace it (§6.3).
        XCTAssertTrue(drawn.contains("2 MCP server(s)"), "the sheet no longer says how many servers it lists")
    }

    // MARK: - G4a: the third answer (tracker 170)

    /// *Not now* dismisses the sheet and **writes nothing anywhere**.
    ///
    /// §6.12 has exactly one write in it and it is the decline; dismissal is not a decline and may
    /// never be recorded as one. The clause is the X9 seam: the lifecycle received no acceptance, no
    /// decline and no action of any kind. The precondition is asserted afterwards because that is
    /// what makes the dismissal safe — the channel is still unspawned and still asking — and the
    /// banner clause is what keeps the unanswered decision reachable once its modal is gone.
    func testNotNowRecordsNothingAndLeavesTheChannelWaiting() async throws {
        let (lifecycle, model) = await evaluated([.consentNeeded(project: Self.project, servers: Self.servers)])
        let request = try XCTUnwrap(model.consentRequest, "the consentNeeded verdict raised no sheet")

        try press("Not now", in: sheet(for: request, on: model).body)

        XCTAssertTrue(model.consentRequest == nil, "*Not now* left the sheet up")
        let accepted = await lifecycle.accepted
        let declined = await lifecycle.declined
        let actions = await lifecycle.actions
        XCTAssertEqual(accepted.count, 0, "*Not now* recorded \(accepted.count) acceptance(s)")
        XCTAssertEqual(declined.count, 0, "*Not now* recorded \(declined.count) decline(s)")
        XCTAssertEqual(actions.count, 0, "*Not now* performed \(actions.count) lifecycle action(s)")
        guard case .consentNeeded = model.precondition else {
            return XCTFail("*Not now* changed the verdict the channel is held by")
        }
        XCTAssertFalse(model.isHistoryOnly, "*Not now* made the channel history-only")

        // The decision is still outstanding, so the column still has to offer it: the banner is the
        // way back, and the sheet it brings back is the same one.
        XCTAssertTrue(model.isConsentDeferred, "a dismissed sheet left the column with no way back to it")
        let banner = ConsentBanner(isAnswering: model.isAnswering) { model.resumeConsent() }
        try press("Review project servers", in: banner.body)
        let resumed = try XCTUnwrap(model.consentRequest, "the banner did not bring the sheet back")
        XCTAssertEqual(resumed.servers.map(\.name), Self.servers.map(\.name),
                       "the sheet came back listing servers the verdict did not name")
    }

    // MARK: - Two evaluations, one surface (continued)

    /// A read whose **task** was cancelled publishes nothing, even though nothing superseded it.
    ///
    /// The mount evaluates in a `.task(id:)`, and a selection that moves to a column with no channel
    /// cancels that task without starting another: the generation never moves, so the generation
    /// fence alone lets the old channel's verdict land on a surface that is showing nothing. The two
    /// fences catch different things and both are needed.
    func testACancelledEvaluationPublishesNothing() async throws {
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.consentNeeded(project: Self.project, servers: Self.servers)])
        await lifecycle.gateNextPreconditions()
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())

        let read = Task { await model.evaluate(channel: Self.channel, project: Self.project) }
        while await lifecycle.gated == 0 { await Task.yield() }
        read.cancel()
        await lifecycle.releaseGate()
        await read.value

        XCTAssertTrue(model.consentRequest == nil, "a cancelled read raised its consent sheet anyway")
        XCTAssertTrue(model.evaluation == nil, "a cancelled read published its evaluation")
    }

    /// The mount with no channel or no project **invalidates before it returns**.
    ///
    /// Nothing is evaluated for an empty column, so nothing may be left on screen for it either: the
    /// previous verdict would draw one channel's banner above a column showing nothing, and a read
    /// still suspended in `preconditions(for:)` would find its own generation unchanged and publish
    /// into that emptiness. Both halves, and the second is the discriminating one.
    func testInvalidatingDropsTheVerdictAndTheReadStillInFlight() async throws {
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project),
                               .consentNeeded(project: Self.project, servers: Self.servers)])
        let model = PrecommitModel(lifecycle: lifecycle, panels: ConsentPanelHost())
        await model.evaluate(channel: Self.channel, project: Self.project)
        XCTAssertTrue(model.isHistoryOnly, "the first verdict never reached the surface")

        await lifecycle.gateNextPreconditions()
        let read = Task { await model.evaluate(channel: Self.otherChannel, project: Self.otherProject) }
        while await lifecycle.gated == 0 { await Task.yield() }

        model.invalidate()
        XCTAssertFalse(model.isHistoryOnly, "the emptied column kept the last channel's trust banner")
        XCTAssertTrue(model.evaluation == nil, "the emptied column kept an evaluation")

        await lifecycle.releaseGate()
        await read.value
        XCTAssertTrue(model.consentRequest == nil, "a read in flight published into an emptied column")
        XCTAssertTrue(model.evaluation == nil, "a read in flight published its evaluation into an emptied column")
    }

    /// The verdict is a function of the channel **and** the project **and** whether afleet is at the
    /// front, so the mount's task is keyed by all three.
    ///
    /// A row's `cwd` arrives with an index update rather than with the row, so a channel evaluated
    /// while it had none must be evaluated again when it has one — a decline is recorded against the
    /// project, and a key that ignored it would leave the sheet unable to record anything. Coming
    /// back to the front is the third, because *Review trust in terminal* hands the decision to
    /// another application and nothing tells this side when it was made.
    func testTheEvaluationKeyCarriesTheProjectAndTheFrontmostState() {
        func key(channel: ChannelKey?, project: URL?, active: Bool) -> ChannelDecorations.EvaluationKey {
            ChannelDecorations(channel: channel, project: project, isApplicationActive: active,
                               lifecycle: ConsentDouble(), panels: ConsentPanelHost(),
                               paneExits: nil).evaluationKey
        }
        let base = key(channel: Self.channel, project: Self.project, active: true)

        XCTAssertEqual(base, key(channel: Self.channel, project: Self.project, active: true),
                       "the same inputs produced two different evaluation keys")
        XCTAssertNotEqual(base, key(channel: Self.channel, project: nil, active: true),
                          "a channel whose project has not arrived yet shares its key with one that has")
        XCTAssertNotEqual(base, key(channel: Self.channel, project: Self.otherProject, active: true),
                          "a channel whose project changed shares its key with the old one")
        XCTAssertNotEqual(base, key(channel: Self.otherChannel, project: Self.project, active: true),
                          "two channels share one evaluation key")
        XCTAssertNotEqual(base, key(channel: Self.channel, project: Self.project, active: false),
                          "coming back to the front does not re-key the evaluation")
    }

    // MARK: - G4c: the trust action, fenced

    /// The verdict is **re-read when the terminal handoff returns**.
    ///
    /// Trust is granted in Claude Code's own dialog, in the pane this just handed the project to,
    /// and nothing about that reaches afleet: no frame, no state, no file this side watches. Without
    /// the re-read the channel stays history-only on a project the user has since trusted, and the
    /// banner they just acted on is still there.
    func testTheVerdictIsRereadWhenTheTerminalHandoffReturns() async throws {
        let panels = ConsentPanelHost()
        let (_, model) = await evaluated([.untrusted(root: Self.project), .ready], panels: panels)
        XCTAssertTrue(model.isHistoryOnly, "the untrusted verdict never reached the surface")

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        // **The verdict and not the idle flag.** The re-read is no longer what the handoff returning
        // does: `PanelHost.run` returns when the pane *starts*, so the model waits for the pane's
        // exit and releases its in-flight slot at the handover. With no announcer — this model has
        // none — the wait returns at once and the re-read follows, which is what this waits for.
        await model.settledAfterPane()

        XCTAssertFalse(model.isHistoryOnly,
                       "the verdict was not re-read after the handoff, so the channel is still history-only")
        XCTAssertNil(model.banner, "a successful handoff left a banner behind")
    }

    /// A trust action taken from a banner the surface has moved past **opens nothing**.
    ///
    /// The banner on screen was drawn for the evaluation that produced it; an evaluation already in
    /// flight means that is no longer the one the model holds, so the press would hand the host a
    /// channel the user is not looking at and open a pane on somebody else's project. The same fence
    /// the sheet's two answers take, for the same reason.
    func testATrustActionFromASupersededBannerOpensNothing() async throws {
        let lifecycle = ConsentDouble()
        await lifecycle.stage([.untrusted(root: Self.project), .ready])
        let panels = ConsentPanelHost()
        let model = PrecommitModel(lifecycle: lifecycle, panels: panels)
        await model.evaluate(channel: Self.channel, project: Self.project)
        XCTAssertTrue(model.isHistoryOnly, "the untrusted verdict never reached the surface")

        // The selection moves; its read is held, so the banner above is still the one on screen.
        await lifecycle.gateNextPreconditions()
        let read = Task { await model.evaluate(channel: Self.otherChannel, project: Self.otherProject) }
        while await lifecycle.gated == 0 { await Task.yield() }

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()

        let openings = await lifecycle.openings
        XCTAssertEqual(openings, 0, "a superseded banner opened \(openings) terminal pane(s)")

        await lifecycle.releaseGate()
        await read.value
    }

    /// A refusal belongs to the evaluation it was raised under, and **a new evaluation clears it**.
    ///
    /// The three actions all fail asynchronously. A banner that outlived its evaluation would draw
    /// one channel's failure above another channel's conversation — the same wrong pairing
    /// `Evaluation` exists to prevent, one step further on — and nothing else ever cleared it.
    func testANewEvaluationClearsTheOldContextsRefusalBanner() async throws {
        let panels = ConsentPanelHost()
        panels.refusal = .noPaneRunner(.terminal)
        let (_, model) = await evaluated([.untrusted(root: Self.project)], panels: panels)

        let banner = TrustBanner(isAnswering: model.isAnswering) { model.reviewTrustInTerminal() }
        try press("Review trust in terminal", in: banner.body)
        await model.whenIdle()
        XCTAssertNotNil(model.banner, "the refused handoff raised no banner, so this clause proves nothing")

        await model.evaluate(channel: Self.otherChannel, project: Self.otherProject)
        XCTAssertNil(model.banner, "a new evaluation kept the previous context's refusal on screen")
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

    /// How many terminal handoffs were asked for. A count, so a superseded banner's press is
    /// asserted as *nothing left the surface* rather than as a flag (§11).
    private(set) var openings = 0

    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest {
        unreachable("openInTerminal")
    }

    /// §6.11's verb, which is the one the trust banner calls (tracker 314). Counted, so a superseded
    /// banner's press is asserted as *nothing left the surface* rather than as a flag (§11).
    func reviewTrustInTerminal(_ key: ChannelKey) async throws -> PaneRequest {
        openings += 1
        return paneRequest
    }

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

/// The host these tests hand `PrecommitModel`, recording what item 47's action asked of it.
///
/// A **double and not `PanelHostModel`**, since X7's amendment of 2026-09-09 (C7.4): the real host
/// resolves the named channel's `ChannelContext` and refuses with `noChannelContext` when it has
/// never rendered that channel, which a bare host in a unit test never has. Standing one up would
/// mean a config home, a store, a transcript index and a workspace — the whole `PanelRig` — to
/// assert something about `PrecommitModel`. That the real host hands the runner the caller's
/// channel unchanged is asserted where it belongs, in `PanelHostTests` and the Terminal panel's
/// own wiring suite.
@MainActor
private final class ConsentPanelHost: PanelHost {

    /// Every request item 47's action handed over, with the channel it named for each.
    private(set) var runs: [(request: PaneRequest, channel: ChannelKey)] = []

    /// What `run(_:for:)` throws instead of recording, so the refusal banners can be exercised.
    var refusal: PanelHostError?

    func run(_ request: PaneRequest, for channel: ChannelKey) async throws {
        if let refusal { throw refusal }
        runs.append((request, channel))
    }

    // The rest of X7. A trust action reaches none of it, and a double that quietly answered
    // would let a test pass on a path it never took.
    var selected: PanelTabID? { nil }
    func register(_ tab: any PanelTab) throws { unreachable("register") }
    func unregister(_ id: PanelTabID) async { unreachable("unregister") }
    func registerPaneRunner(_ runner: any PaneRunning, for tab: PanelTabID) { unreachable("registerPaneRunner") }
    func available(for context: ChannelContext) -> [PanelTabID] { unreachable("available") }
    func select(_ id: PanelTabID) { unreachable("select") }
    func selectIndex(_ index: Int, in context: ChannelContext) { unreachable("selectIndex") }
    func popOut(_ id: PanelTabID, channel: ChannelKey) { unreachable("popOut") }
    func session(for id: PanelTabID, context: ChannelContext) -> any PanelTabSession { unreachable("session") }
    func view(for id: PanelTabID, context: ChannelContext,
              surface: PanelSurface) -> AnyView { unreachable("view") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ConsentPanelHost.\(member) is not part of the consent and trust surface")
    }
}
