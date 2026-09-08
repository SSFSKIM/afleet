import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Gate **G7**, contract Y7: the rows that consume the render context, mounted (child spec §15).
///
/// Y1's skeleton promised a per-row capability carrier and no leaf built one, so five mounts waited
/// on it and each of them is a thing that can be wired to nothing while every gate on both leaves
/// stays green. These four tests are about the wiring and nothing else — the cards, the answer
/// mappings and the retraction bookkeeping are another leaf's and are asserted there.
///
/// Nothing here spawns a process, opens a transcript outside a scratch tree, or writes under any
/// config home (X9). Every identifier the tests invent is visibly nobody's; the recorded bytes are a
/// committed fixture's, replayed in process. No assertion prints a path, a title or a session id
/// (§11): a `ChannelKey` and an `ItemID` both carry a config home, so the comparisons over them are
/// booleans and counts with messages written for them.
@MainActor
final class RenderContextMountTests: XCTestCase {

    // MARK: - The raise, closed by the mount

    /// A decision card answered **from the list** leaves `pending` on screen.
    ///
    /// The whole loop, in the order the app runs it: the row builds its answering object through
    /// the context, a press on the mounted card sends `LifecycleAction.answer` through X5, the
    /// successful answer raises `HostSignal.decisionAnswered` through the context's `signal`, and
    /// C3's reducer moves the item. **The engine sends no frame back for an answer**, so the raise
    /// is the only thing that can move it.
    ///
    /// Discriminating: against a context whose raise is wired to nothing — a `makeAnswering` that
    /// builds the object and does not assign `raise` — the answer still reaches the wire and the
    /// card still disables, and the item reads `.pending` for ever. That is the defect contract Y7
    /// exists to prevent, and no gate on either leaf catches it.
    func testACardAnsweredFromTheListLeavesPending() async throws {
        let rig = try await MountRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.pushPermissionAsk(id: "req_invented_c61_mount_0001")
        let opened = await rig.settle { await $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(opened, "the pushed ask never became a pending decision, so nothing here could move it")

        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(rig.key)))
        let context = rig.context(lifecycle: lifecycle)
        // The row's own construction, and the thing under test: everything below goes through what
        // it returns.
        let answering = try XCTUnwrap(context.makeAnswering(),
                                      "the render context built no answering object for a live channel")

        let item = try XCTUnwrap(DecisionItem(surfacing: ask, in: rig.key),
                                 "the surfacing initialiser opened no item for the pushed ask")
        let content = DecisionRowContent(row: TimelineRow(.decision(item)), context: context, answering: answering)
        let card = try XCTUnwrap(CardTree.permissionBody(in: content.body),
                                 "the mounted decision row drew no permission card to answer")
        try Self.press("Allow once", in: card)
        await answering.whenIdle()

        let sent = await lifecycle.actions.filter { if case .answer = $0.action { true } else { false } }.count
        XCTAssertEqual(sent, 1, "the press put \(sent) answer(s) on the wire, not 1")
        let state = await rig.ingestion.timeline.overlay.decisions[ask.id]?.state
        XCTAssertEqual(state, .answered(outcome: "allowed"),
                       "the answered decision reads \(state.map(Self.reading) ?? "no state at all"), not answered")
    }

    // MARK: - The app's one reservation set

    /// The answering object the row builds holds **`AppModel.decisions`**, the app's one set.
    ///
    /// **Asserted by reserving the request from another surface and watching the row's answer be
    /// refused**, never by comparing object identity: two sets that merely happen to be equal —
    /// which is exactly what a row constructing its own would produce — pass an identity-free
    /// comparison and pass an equality one too, since a fresh `DecisionReservations` is empty and so
    /// is the app's. What separates them is whether a claim made on one is seen by the other.
    ///
    /// The floor is the second half: with the reservation released, the same press does reach the
    /// wire. Without it, a send broken for any other reason would pass the first half alone.
    func testTheRowSharesTheAppsOneReservationSet() async throws {
        let rig = try await MountRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.request(id: "req_invented_c61_mount_0002")
        let item = try XCTUnwrap(DecisionItem(surfacing: ask, in: rig.key),
                                 "the surfacing initialiser opened no item for a recorded ask")
        let card = DecisionCard(item)

        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(rig.key)))
        // The construction site, exercised as the column performs it — the app's `decisions` and the
        // app's lifecycle reach the context through this call and through no other.
        let app = AppModel(registry: RowRegistry())
        app.timelines.lifecycle = lifecycle
        let model = ChannelTimelineModel(key: rig.key, workspace: nil, lifecycle: lifecycle)
        let context = TimelineListView(model: model).context(in: app)
        let answering = try XCTUnwrap(context.makeAnswering(),
                                      "the render context built no answering object for a live channel")

        // Another surface takes the one slot this request has. `DecisionReservations.claim` is what
        // Activity's row and the Thread tab call through their own `DecisionAnswering`.
        XCTAssertTrue(app.decisions.claim(card.requestID),
                      "the app's reservation set refused a request nothing had claimed yet")

        answering.send(.allowOnce, on: card, in: rig.key)
        // **Not `whenIdle()` here.** That probe waits for the reservation set to empty, and the
        // point of this arm is that it does not: the other surface still holds the slot. Yielding
        // gives a send that *did* start its task room to reach the double before the count is read.
        for _ in 0..<20 { await Task.yield() }
        var sent = await lifecycle.actions.filter { if case .answer = $0.action { true } else { false } }.count
        XCTAssertEqual(sent, 0,
                       "\(sent) answer(s) reached the wire for a request another surface had already claimed")
        XCTAssertTrue(answering.isAnswering(card.requestID),
                      "the row's answering object cannot see the claim the other surface made, so the set is not shared")

        // The floor: released, the very same press goes out. A row whose send was broken for any
        // other reason would have passed the assertion above.
        app.decisions.release(card.requestID)
        answering.send(.allowOnce, on: card, in: rig.key)
        await answering.whenIdle()
        sent = await lifecycle.actions.filter { if case .answer = $0.action { true } else { false } }.count
        XCTAssertEqual(sent, 1, "\(sent) answer(s) reached the wire once the reservation was released, not 1")
    }

    // MARK: - The link capability

    /// A path in a permission card emits one `WorkspaceLink` through the context's `links`.
    ///
    /// The link is pressed on the label the **row itself drew** — found by reflecting over the
    /// mounted row's body — so what is asserted is the affordance the reader sees and not a helper
    /// a test called. The router is a double registered as the context's capability, so a card that
    /// reached a link registry of its own would deliver nowhere and record nothing.
    func testAPathInAPermissionCardEmitsALink() async throws {
        let rig = try await MountRig(fixture: "permission-allow")
        defer { rig.finish() }
        let ask = try rig.request(id: "req_invented_c61_mount_0003")
        let item = try XCTUnwrap(DecisionItem(surfacing: ask, in: rig.key),
                                 "the surfacing initialiser opened no item for a recorded ask")

        let router = RecordingLinkRouter()
        let lifecycle = LifecycleDouble()
        await lifecycle.always(.success(ActivityFixtures.state(rig.key)))
        let context = rig.context(lifecycle: lifecycle, links: router)
        let answering = try XCTUnwrap(context.makeAnswering(), "the context built no answering object")

        let content = DecisionRowContent(row: TimelineRow(.decision(item)), context: context, answering: answering)
        let labels = ViewTree.values(of: FileLinkLabel.self, in: content.body)
        XCTAssertEqual(labels.count, 1, "the mounted card drew \(labels.count) file link(s) for a card naming one path")
        let button = try XCTUnwrap(ViewTree.values(of: Button<Text>.self, in: labels[0].body).first,
                                   "the file link drew no button to press")
        XCTAssertTrue(ViewTree.press(button), "the file link's button carried no action")

        let delivered = await Self.settle(router, until: 1)
        let opened = await router.opened
        XCTAssertTrue(delivered, "the router received \(opened.count) link(s), waiting for 1")
        XCTAssertEqual(opened.count, 1, "the router received \(opened.count) link(s), not 1")
        XCTAssertTrue(opened.allSatisfy { if case .file = $0 { true } else { false } },
                      "the link the card emitted is not a file link")
    }

    // MARK: - D11's render-time filter

    /// A retracted frame is not drawn, and an unretracted one is — **both arms**.
    ///
    /// The negative alone passes against a list that draws nothing, and the positive alone passes
    /// against a list that filters nothing, so neither says anything by itself. Nothing is removed
    /// from C3's items: §7.3's differential invariant forbids this leaf reducing, so this is a
    /// render-time filter and the assertion is over what the table is handed.
    func testARetainedFrameIsNotDrawn() async throws {
        let card = try Self.refusalDialogCard()
        let retracted = try XCTUnwrap(card.refusalFallback?.retractedMessageUUIDs.first,
                                      "the recorded refusal dialog retracts nothing, so there is nothing to filter")

        let registry = RetractionRegistry()
        let doomed = TimelineRow(.assistantMessage(Self.assistant(key: retracted)))
        let kept = TimelineRow(.assistantMessage(Self.assistant(key: "invented-kept-message-1")))

        // Before the dialog settles, both are drawn: a registry that evicted on receipt would take
        // the message back while the reader was still deciding.
        let beforehand = TimelineListView.retained([doomed, kept], by: registry)
        XCTAssertEqual(beforehand.count, 2, "\(beforehand.count) row(s) drawn before the dialog settled, not 2")

        registry.resolved(card, in: Self.channel)
        let drawn = TimelineListView.retained([doomed, kept], by: registry)

        XCTAssertEqual(drawn.count, 1, "\(drawn.count) row(s) survived the retraction, not 1")
        XCTAssertFalse(drawn.contains { $0.id.key == doomed.id.key },
                       "the row the settled dialog took back is still drawn")
        XCTAssertTrue(drawn.contains { $0.id.key == kept.id.key },
                      "the row the dialog never named was dropped along with the one it did")
    }

    // MARK: - Support

    /// A config home this suite never writes to, for the items it invents. The rig below builds its
    /// scratch home under `TempTree`, which refuses to resolve inside a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("e", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c61-mounts-unwritten"))
    }

    private static var stream: LogicalStream {
        LogicalStream(configHome: channel.configHome, sessionID: channel.session, name: .main)
    }

    /// An invented assistant item under `channel`'s stream, keyed by whatever the caller names.
    /// `RetractionRegistry.retains(_:)` reads the channel out of the item's own stream, so the two
    /// have to agree or the filter would answer about a different channel.
    private static func assistant(key: String) -> AssistantMessageItem {
        AssistantMessageItem(id: ItemID(stream: stream, key: key),
                             timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                             provenance: Provenance(stream: stream, origin: .wire),
                             messageID: "msg_invented_c61_0001",
                             model: "invented-model",
                             blocks: [InventedItems.text("an invented reply")])
    }

    /// The first `request_user_dialog` the refusal-fallback recording carries, as a card.
    private static func refusalDialogCard() throws -> DecisionCard {
        let dialogs = try FixtureRunner.events("dialog-refusal-fallback").compactMap { event -> InboundRequest? in
            switch event {
            case .request(let request), .unansweredDialog(let request):
                return request.subtype == "request_user_dialog" ? request : nil
            default:
                return nil
            }
        }
        let withRetraction = dialogs.compactMap { DecisionItem(surfacing: $0, in: channel) }
            .map(DecisionCard.init)
            .first { !($0.refusalFallback?.retractedMessageUUIDs.isEmpty ?? true) }
        return try XCTUnwrap(withRetraction,
                             "the recording holds \(dialogs.count) dialog(s) and none of them retracts a message")
    }

    private static func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the card offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    /// Waits, bounded, for the router to have received a given number of links, and **answers
    /// whether it did**, so the caller asserts the outcome rather than discarding the wait.
    private static func settle(_ router: RecordingLinkRouter, until count: Int) async -> Bool {
        for _ in 0..<200 {
            if await router.opened.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await router.opened.count >= count
    }

    /// A decision's state as a word, so no assertion prints the engine's own.
    private static func reading(_ state: DecisionItem.State) -> String {
        switch state {
        case .pending: "pending"
        case .answered: "answered"
        case .cancelled: "cancelled"
        case .policyAnswered: "policy-answered"
        case .inert: "inert"
        }
    }
}

// MARK: - The rig

/// One channel's fold over a committed fixture's transcript in a scratch config home, and a render
/// context wired to it.
///
/// **`StreamIngestion` directly, rather than `ChannelTimelineModel`.** What G7's first clause is
/// about is that the raise reaches a fold at all; the channel model's own forwarding of `signal(_:)`
/// is asserted in `ChannelTimelineSeamTests` and is not restated here.
///
/// X9: `TempTree` canonicalises its root and skips before creating anything if it resolves inside
/// any config home, so nothing here can write into one.
@MainActor
private struct MountRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let ingestion: StreamIngestion
    let key: ChannelKey
    let fixture: String
    private let continuation: AsyncStream<WireEvent>.Continuation

    init(fixture: String) async throws {
        self.fixture = fixture
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        guard let main = try Self.mainTranscript(of: fixture) else {
            throw Bail("fixture carries no main transcript")
        }
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)
        let slug = projects.appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: main.slugDirectory, to: slug)
        let path = slug.appending(path: "\(main.session).jsonl")

        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        ingestion = StreamIngestion(session: main.session, configHome: home.configHome.root, mode: .filePrimary)
        let (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        _ = try await ingestion.open(file: path, events: events)
    }

    func finish() { continuation.finish() }

    /// The context the timeline injects, with this channel's fold behind its raise.
    ///
    /// It is built through `InventedItems.context`, which is the one place a test builds one, so a
    /// field added to the carrier reaches every test that takes one rather than only the ones that
    /// were updated.
    func context(lifecycle: any LifecycleAPI,
                 links: any LinkRouterCapability = RecordingLinkRouter()) -> TimelineRenderContext {
        InventedItems.context(links: links,
                              signal: { [ingestion] signal in _ = await ingestion.signal(signal) },
                              lifecycle: lifecycle,
                              key: key)
    }

    /// Pushes the fixture's recorded `can_use_tool` ask, re-keyed to an invented request id.
    ///
    /// **Pushed rather than replayed**: `permission-allow` opens `mcp_message` requests the inbound
    /// policy answers itself, so "a decision exists" can be true while every decision present is one
    /// no host has to answer. Pushing the one request under test makes the condition exact.
    func pushPermissionAsk(id: String) throws -> InboundRequest {
        let ask = try request(id: id)
        guard case .request = FixtureRunner.event(for: ask) else {
            throw Bail("the inbound policy does not surface this ask, so nothing would be pending")
        }
        continuation.yield(.request(ask))
        return ask
    }

    func request(id: String) throws -> InboundRequest {
        try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id)
    }

    /// Waits, bounded, for the fold to satisfy `predicate`, and **answers whether it did**, so the
    /// caller asserts the outcome rather than discarding a wedge.
    func settle(_ predicate: (StreamIngestion) async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate(ingestion) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate(ingestion)
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

    struct Bail: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
