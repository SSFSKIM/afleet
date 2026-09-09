import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// The Thread tab: contract Y3's handover, §7.5's five kinds, and the two things a reply can be
/// (acceptance G2, spec D10).
///
/// **Every reply clause asserts what left the host** — the `InboundAnswer` handed to the lifecycle,
/// or the `UserInput` it was asked to send — and never that a thread changed. A thread changes for
/// many reasons and only one of them is the right thing having gone on the wire.
///
/// Item 10's clause is the inverse and is a **count**: the durable items C3's reducer folds are
/// counted before and after, in both directions, so an *Ask on the side* implemented as a composer
/// line — which would add a user record — cannot pass. The counter is shown able to move in the same
/// test, because a counter that never moves proves nothing about the case where it must not.
///
/// A `ChannelKey` carries a config home and an `ItemID` carries a session, and `XCTAssertEqual`
/// prints both operands (§6.3, §11), so comparisons over those are spelled as booleans with a
/// written message. Every identifier invented here is visibly nobody's.
@MainActor
final class ThreadTabTests: XCTestCase {

    // MARK: - Support

    /// A config home that is never written to and never resolves under a real one (X9).
    private static var channel: ChannelKey {
        ActivityFixtures.key("c", configHome: FileManager.default.temporaryDirectory
            .appending(path: "afleet-c6-3-threads-unwritten"))
    }

    private static var stream: LogicalStream {
        LogicalStream(configHome: channel.configHome, sessionID: channel.session, name: .main)
    }

    /// A model over a double that accepts everything, which is what the reply clauses drive.
    private func hosted() async -> (ThreadDouble, ThreadModel) {
        let lifecycle = ThreadDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        return (lifecycle, ThreadModel(channel: Self.channel, lifecycle: lifecycle))
    }

    /// Every item C3's reducer folds out of a fixture, and the reducer itself, so a test can keep
    /// folding into the same one.
    private func reduced(_ fixture: String) throws -> WireReducer {
        var reducer = WireReducer(stream: Self.stream, slug: "invented-slug")
        for event in try FixtureRunner.events(fixture) { _ = reducer.apply(event) }
        return reducer
    }

    /// A recorded tool call and the recorded sent file from the same fixture: §7.5's two posting
    /// anchors, taken from the recording rather than invented.
    private func postingAnchors() throws -> (ToolCallItem, SentFileItem) {
        let items = try reduced("send-user-file").durable.items
        var call: ToolCallItem?
        var sent: SentFileItem?
        for item in items {
            if case .toolCall(let c) = item, call == nil { call = c }
            if case .sentFile(let s) = item { sent = s }
        }
        return (try XCTUnwrap(call, "the recording folded no tool call"),
                try XCTUnwrap(sent, "the recording folded no sent file"))
    }

    /// A pending card over a recorded request.
    private func card(_ fixture: String, id: String = "cccccccc-cccc-4ccc-8ccc-cccccccccccc") throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: "can_use_tool", id: id)
        let item = try XCTUnwrap(DecisionItem(surfacing: request, in: Self.channel),
                                 "the surfacing initialiser opened no item for a recorded ask")
        return DecisionCard(item)
    }

    /// A task anchor over `background-shell`'s own recorded task frames.
    private func taskAnchor(_ lifecycle: any LifecycleAPI) throws -> TaskCardModel {
        var registry = RegistryMirror()
        var taskID: String?
        for frame in try FixtureRunner.frames("background-shell") {
            guard case .system(let system) = frame else { continue }
            let touched = registry.apply(system, at: Date(), epoch: .first)
            taskID = taskID ?? touched.first
        }
        let recorded = try XCTUnwrap(taskID, "the recording carries no task frames")
        let entry = try XCTUnwrap(registry.entries[recorded], "the mirror folded no entry for the recorded task")
        let item = TaskRunItem(id: ItemID(stream: Self.stream, key: recorded),
                               timestamp: Date(),
                               provenance: Provenance(stream: Self.stream, epoch: .first, origin: .synthesised),
                               taskID: recorded, kind: entry.kind, description: "An invented task",
                               status: entry.status, toolUseID: entry.toolUseID)
        return TaskCardModel(item: item, registry: registry, lifecycle: lifecycle, channel: Self.channel)
    }

    private func press(_ label: String, in body: Any) throws {
        let button = try XCTUnwrap(ViewTree.button(label, in: body), "the thread offered no \(label) button")
        XCTAssertTrue(ViewTree.press(button), "the \(label) button carried no action")
    }

    /// The `InboundAnswer` of the one answer this double was handed, or nil.
    private func answer(in actions: [(key: ChannelKey, action: LifecycleAction)]) -> InboundAnswer? {
        for (_, action) in actions {
            if case .answer(_, let answer) = action { return answer }
        }
        return nil
    }

    private func sentInput(in actions: [(key: ChannelKey, action: LifecycleAction)]) -> UserInput? {
        for (_, action) in actions {
            if case .send(let input) = action { return input }
        }
        return nil
    }

    // MARK: - G2: the handover

    /// Contract Y3, on the host: `.thread` passes from C5's placeholder to this child's tab, the tab
    /// bar reads this tab's title, and **the placeholder is no longer drawing**.
    ///
    /// The second half is the discriminating one. `register` refuses a duplicate, so a handover whose
    /// `unregister` never ran leaves the placeholder registered and the host still presenting a tab
    /// for `.thread` — every assertion about the id alone would pass against it.
    func testTheThreadTabTakesThreadFromThePlaceholderAndThePlaceholderStopsDrawing() async throws {
        let host = PanelHostModel()
        let context = ThreadFixtures.context(Self.channel)
        try host.register(PlaceholderTab())
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self, in: host.view(for: .thread, context: context, surface: .panel)).count, 1,
                       "the placeholder is not drawing before the handover")

        await host.unregister(.thread)
        try host.register(ThreadTab(lifecycle: ThreadDouble()))

        XCTAssertEqual(host.available(for: context), [.thread], "the successor is not the tab the host presents")
        XCTAssertEqual(host.title(for: .thread), PanelTabID.thread.defaultTitle,
                       "the tab bar does not read this child's title")
        let view = host.view(for: .thread, context: context, surface: .panel)
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self, in: view).count, 0,
                       "C5's placeholder is still drawing after the handover")
        XCTAssertEqual(ViewTree.values(of: ThreadModel.self, in: view).count, 1,
                       "the Thread tab drew no thread model")
        XCTAssertTrue(host.session(for: .thread, context: context) is ThreadModel,
                      "the host retains something other than a thread model for the channel")
    }

    /// And the same handover on the path the app really takes: a launch that reaches a workspace
    /// hands `.thread` over. Asserted through the composition root because contract Y3 names
    /// `AppModel` as where the pair lives — a handover only a test performs would leave the shipped
    /// app drawing C5's placeholder for ever.
    func testALaunchHandsThreadOverToThisChildsTab() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        try LaunchFixtures.transcript(in: configHome, slug: "invented-project", session: LaunchFixtures.sessionA)
        let fleet = LifecycleDouble()
        let binary = try temp.file("bin/claude", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            makeStore: { base, homes in try FileStateStore(baseDirectory: base, configHomes: homes) },
            makeDiagnostics: { DiagnosticsComposer(directory: $0) },
            makeIndex: { _, _, _ in StubIndex(persisted: nil,
                                              built: LaunchFixtures.snapshot(configHome: configHome,
                                                                             ids: [LaunchFixtures.sessionA]),
                                              delta: IndexDelta(added: [LaunchFixtures.sessionA])) },
            fleetFactory: { _, _, _, _, _, _ in fleet },
            makeWatcher: { _ in StubWatcher() },
            readClaudeJSON: { _ in true })

        let model = AppModel(sequence: sequence)
        let context = ThreadFixtures.context(ChannelKey(configHome: LaunchFixtures.directoryURL(configHome),
                                                        session: LaunchFixtures.sessionA))
        XCTAssertTrue(model.panels.session(for: .thread, context: context) is PlaceholderTabSession,
                      "the app does not start on C5's placeholder")

        await model.launch()

        XCTAssertTrue(model.panels.session(for: .thread, context: context) is ThreadModel,
                      "the launch left C5's placeholder holding .thread")
        XCTAssertEqual(model.panels.selected, .thread, "the handover lost the selection it started with")
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self,
                                       in: model.panels.view(for: .thread, context: context, surface: .panel)).count, 0,
                       "C5's placeholder is still drawing after the launch")
        model.activity?.stop()
        fleet.finish()
    }

    // MARK: - G2: the five kinds, one at a time

    /// §7.5's five kinds all open, and opening a second replaces the first — Slack-style, which is
    /// what "one thread at a time" means. Both halves: a tab that appended would keep the first.
    func testEachOfTheFiveKindsOpensAndASecondReplacesTheFirst() async throws {
        let (lifecycle, model) = await hosted()
        let (call, sent) = try postingAnchors()
        let anchors: [ThreadAnchor] = [
            .toolDetail(call),
            .task(try taskAnchor(lifecycle)),
            .decision(try card("permission-allow")),
            .sideQuestion(SideQuestionThread(anchorText: "An invented message.")),
            .sentFile(sent),
        ]
        XCTAssertEqual(Set(anchors.map(\.kind)).count, ThreadKind.allCases.count,
                       "the test drives \(Set(anchors.map(\.kind)).count) of \(ThreadKind.allCases.count) kinds")

        XCTAssertNil(model.anchor, "a fresh thread tab has a thread open")
        var previous: ThreadKind?
        for anchor in anchors {
            model.open(anchor)
            let open = try XCTUnwrap(model.anchor, "opening a \(anchor.kind.rawValue) thread opened nothing")
            XCTAssertEqual(open.kind, anchor.kind, "the tab holds a different kind from the one opened")
            if let previous {
                XCTAssertNotEqual(open.kind, previous, "the second thread did not replace the first")
            }
            previous = anchor.kind
            let drawn = CardTree.texts(in: ThreadView(model: model).body)
            XCTAssertTrue(drawn.contains(ThreadView.name(of: anchor.kind)),
                          "the \(anchor.kind.rawValue) thread does not name its kind")
        }

        // §7.5's Reply column: a task takes stop only.
        model.open(.task(try taskAnchor(lifecycle)))
        XCTAssertFalse(model.offersReply, "the task thread offered a reply")
        model.open(.toolDetail(call))
        XCTAssertTrue(model.offersReply, "the tool-detail thread offered no reply")
    }

    // MARK: - G2: the thread and the channel's fold

    /// The ruling that closes tracker 157's `raise` clause for this host: **a card answered from
    /// the Thread tab leaves nothing pending.**
    ///
    /// The engine sends no frame back for an answer, so the only thing that can move a
    /// `DecisionItem` out of `.pending` is the host saying it answered —
    /// `HostSignal.decisionAnswered` through `ChannelTimelineModel.signal(_:)`. Nothing assigned
    /// `DecisionAnswering.raise`, so the loop was complete and not closed: the answer went to the
    /// engine and the card stayed pending on screen for ever. The tab is handed the app's one
    /// registry at its construction, and this drives the whole path — a real fold over a recorded
    /// channel, the tab's own session, and a press on the card's own button.
    ///
    /// **The ask is pushed rather than replayed.** `permission-allow` opens `mcp_message` requests
    /// the inbound policy answers itself, so a wait on "a decision exists" would return while every
    /// decision present is one the host never has to answer. Pushing the one request under test
    /// makes both the wait and the count exact.
    func testAnsweringADecisionFromTheThreadTabLeavesNothingPending() async throws {
        let rig = try await ThreadFoldRig(fixture: "permission-allow")
        await rig.open()
        let ask = try rig.pushPendingAsk()
        let raised = await rig.settle { $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(raised, "the pushed ask never became a pending decision the host has to answer")

        let model = try rig.thread()
        model.open(.decision(DecisionCard(try rig.pending(ask))))
        try press("Allow once", in: try XCTUnwrap(CardTree.permissionBody(in: ThreadView(model: model).body),
                                                  "the decision thread drew no permission card"))
        await model.answering.whenIdle()

        let answered = await rig.settle { ThreadFoldRig.pendingCount(in: $0) == 0 }
        XCTAssertTrue(answered,
                      "answering from the Thread tab left \(ThreadFoldRig.pendingCount(in: rig.model)) pending decision(s)")
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "one press produced \(actions.count) lifecycle action(s)")
        XCTAssertTrue(answer(in: actions) != nil, "the press sent no answer")
    }

    /// And the anchor is a *view* of the fold, not a snapshot of it: a decision settled by any
    /// surface reads as settled in the open thread, and a reply to it is refused.
    ///
    /// `ThreadAnchor.decision` carries a `DecisionCard`, which is a value: it was pending when the
    /// thread opened and would stay pending however the request ended. The timeline row and Activity
    /// answer requests for channels whose thread is open beside them, and nothing tells the thread —
    /// so the card would go on offering a reply, and the reply would be a second `perform(.answer)`
    /// the supervisor rejects.
    ///
    /// The settlement is raised on the fold directly, which is what another surface's answer does,
    /// and the snapshot is re-asserted afterwards so the clause cannot pass by the anchor having
    /// been mutated.
    func testTheDecisionThreadReadsTheFoldRatherThanTheCardItOpenedOn() async throws {
        let rig = try await ThreadFoldRig(fixture: "permission-allow")
        await rig.open()
        let ask = try rig.pushPendingAsk()
        let raised = await rig.settle { $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(raised, "the pushed ask never became a pending decision the host has to answer")

        let model = try rig.thread()
        let opened = DecisionCard(try rig.pending(ask))
        model.open(.decision(opened))
        XCTAssertEqual(model.openDecision?.state, .pending, "the thread opened on a card that is not pending")

        // Another surface answers it — the timeline row, or Activity, both of which raise here.
        await rig.model.signal(.decisionAnswered(ask.id, outcome: .allowed))

        XCTAssertEqual(opened.state, .pending, "the anchor's own snapshot moved, so this clause proves nothing")
        XCTAssertEqual(model.openDecision?.state, .answered(outcome: "allowed"),
                       "the open thread still reads the card it was opened on")

        model.draft = "An invented second thought."
        try press("Send", in: ThreadView(model: model).body)
        await model.answering.whenIdle()
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 0, "a settled decision took \(actions.count) further answer(s)")
    }

    // MARK: - G2: replying to a card is answering it

    /// Item 37: a reply to a pending permission card sends `.deny` with the typed text as the
    /// `message` — **the emitted answer**, not the card's state, and `interrupt: false` with it
    /// (spec D6, D16).
    func testAReplyToAPendingPermissionCardEmitsDenyCarryingTheTypedText() async throws {
        let (lifecycle, model) = await hosted()
        let card = try card("permission-allow")
        XCTAssertTrue(card.state == .pending, "the recorded ask did not open pending")
        model.open(.decision(card))

        model.draft = "An invented reason not to."
        try press("Send", in: ThreadView(model: model).body)
        await model.answering.whenIdle()

        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 1, "one reply produced \(actions.count) actions")
        let answer = try XCTUnwrap(self.answer(in: actions), "the reply sent no answer")
        guard case .permission(.deny(let message, let interrupt, let classification)) = answer else {
            return XCTFail("a reply to a permission card did not send a denial")
        }
        XCTAssertEqual(message, "An invented reason not to.", "the denial does not carry the typed text")
        XCTAssertFalse(interrupt, "the denial interrupts the turn")
        XCTAssertEqual(classification, .userReject, "the denial carries the wrong classification")
    }

    /// §7.5: a plan card's reply is the rejection with the text as feedback, and a question card's
    /// reply is *Other* with the text, keyed by the raw question the engine asked (anchor 9).
    func testAReplyToAPlanCardRejectsAndAReplyToAQuestionCardAnswersOther() async throws {
        let (planLifecycle, planModel) = await hosted()
        planModel.open(.decision(try card("exit-plan-mode")))
        planModel.draft = "An invented objection."
        try press("Send", in: ThreadView(model: planModel).body)
        await planModel.answering.whenIdle()

        let planActions = await planLifecycle.actions
        let planAnswer = try XCTUnwrap(answer(in: planActions), "the plan reply sent no answer")
        guard case .permission(.deny(let feedback, _, let planClass)) = planAnswer else {
            return XCTFail("a reply to a plan card did not send a rejection")
        }
        XCTAssertEqual(feedback, "An invented objection.", "the rejection does not carry the typed feedback")
        XCTAssertEqual(planClass, .userReject, "the rejection carries the wrong classification")

        let (questionLifecycle, questionModel) = await hosted()
        let question = try card("ask-user-question")
        guard case .question(let tool) = question.payload else {
            return XCTFail("the recorded ask no longer decodes as a question")
        }
        let asked = try XCTUnwrap(QuestionPrompt.list(in: tool.fields.inputObject).first,
                                  "the recorded ask carries no question")
        questionModel.open(.decision(question))
        questionModel.draft = "An invented answer of my own."
        try press("Send", in: ThreadView(model: questionModel).body)
        await questionModel.answering.whenIdle()

        let questionActions = await questionLifecycle.actions
        let questionAnswer = try XCTUnwrap(answer(in: questionActions), "the question reply sent no answer")
        guard case .permission(.allow(let updatedInput, _, let questionClass)) = questionAnswer else {
            return XCTFail("a reply to a question card did not answer it")
        }
        XCTAssertEqual(questionClass, .userTemporary, "the question answer carries the wrong classification")
        let echoed = try XCTUnwrap(updatedInput, "the question answer echoed no input")
        let answers = try XCTUnwrap(echoed["answers"], "the answer echoed no answers object")
        XCTAssertTrue(answers[asked.question] == .string("An invented answer of my own."),
                      "*Other* was not answered with the typed text under the engine's own question key")
    }

    // MARK: - G2: the two posting kinds

    /// §7.5: the tool-detail and sent-file threads post to the main session with `Re: <tool>
    /// <short id>:`, through `perform(.send(UserInput))` — a plain text send, with no router, no
    /// attachments and no composer of any kind (D10).
    func testToolDetailAndSentFileRepliesCarryTheReplyPrefix() async throws {
        let (call, sent) = try postingAnchors()

        let (toolLifecycle, toolModel) = await hosted()
        toolModel.open(.toolDetail(call))
        toolModel.draft = "An invented follow-up."
        try press("Send", in: ThreadView(model: toolModel).body)
        await toolModel.whenIdle()

        let toolActions = await toolLifecycle.actions
        XCTAssertEqual(toolActions.count, 1, "one reply produced \(toolActions.count) actions")
        let toolInput = try XCTUnwrap(sentInput(in: toolActions), "the tool-detail reply sent no user input")
        XCTAssertEqual(toolInput.text,
                       "Re: \(call.name) \(ThreadReply.shortID(call.toolUseID)): An invented follow-up.",
                       "the tool-detail reply does not carry §7.5's prefix")
        XCTAssertTrue(toolInput.images.isEmpty, "a plain text send carried \(toolInput.images.count) attachment(s)")

        let (fileLifecycle, fileModel) = await hosted()
        fileModel.open(.sentFile(sent))
        fileModel.draft = "An invented note about the file."
        try press("Send", in: ThreadView(model: fileModel).body)
        await fileModel.whenIdle()

        let fileActions = await fileLifecycle.actions
        let fileInput = try XCTUnwrap(sentInput(in: fileActions), "the sent-file reply sent no user input")
        XCTAssertEqual(fileInput.text,
                       "Re: \(ThreadReply.sentFileTool) \(ThreadReply.shortID(sent.toolUseID)): An invented note about the file.",
                       "the sent-file reply does not carry §7.5's prefix")
        let requests = await fileLifecycle.sent
        XCTAssertEqual(requests.count, 0, "a posting reply sent \(requests.count) control request(s)")
    }

    // MARK: - G2: Ask on the side

    /// §7.5 and item 10, first half: `side_question` carries **no `history` key** on the first ask
    /// and the accumulated array on the second, in ask order.
    ///
    /// The engine spreads `history` only when it is non-empty (`askSideQuestion`,
    /// `cli.pretty.js:289480` in 2.1.263) and `SideQuestion` omits it the same way, so an empty array
    /// on the wire is a different request from the one the engine reads.
    func testAskingOnTheSideOmitsHistoryFirstAndAccumulatesAfterwards() async throws {
        let (lifecycle, model) = await hosted()
        await lifecycle.stageReply(.success(.object(["response": .string("An invented side answer."),
                                                     "synthetic": .bool(false)])))
        let thread = SideQuestionThread(anchorText: "An invented message.")
        model.open(.sideQuestion(thread))

        model.draft = "An invented first question?"
        try press("Ask", in: ThreadView(model: model).body)
        await thread.settled(1)

        var requests = await lifecycle.sent
        XCTAssertEqual(requests.count, 1, "one ask sent \(requests.count) control request(s)")
        XCTAssertEqual(requests.first?.subtype, "side_question", "*Ask on the side* sent another request")
        XCTAssertNil(requests.first?.payload["history"],
                     "the first ask carried a history key the engine reads as absent")

        await lifecycle.stageReply(.success(.object(["response": .string("An invented second answer."),
                                                     "synthetic": .bool(false)])))
        model.draft = "An invented second question?"
        try press("Ask", in: ThreadView(model: model).body)
        await thread.settled(2)

        requests = await lifecycle.sent
        XCTAssertEqual(requests.count, 2, "two asks sent \(requests.count) control request(s)")
        let history = try XCTUnwrap(requests.last?.payload["history"]?.arrayValue,
                                    "the second ask carried no history")
        XCTAssertEqual(history.count, 1, "the second ask carried \(history.count) history entries")
        XCTAssertTrue(history.first?["question"] == .string("An invented first question?"),
                      "the history's question is not the one that was asked")
        XCTAssertTrue(history.first?["response"] == .string("An invented side answer."),
                      "the history's response is not the one that came back")
        XCTAssertEqual(thread.exchanges.count, 2, "the thread holds \(thread.exchanges.count) exchanges")
    }

    /// A second question typed while the first ask is still on the wire **is not lost**.
    ///
    /// Only one ask goes at a time — `side_question` is a control request with a reply, and the
    /// thread accumulates its history in ask order — so the second press has to be refused. What it
    /// must not do is clear the field on the way to refusing it: the model holds the only copy of
    /// what the user typed, and *Ask* is the one control this thread has.
    ///
    /// The overlap is constructed rather than hoped for: the first ask is held inside the double
    /// until the second press has happened.
    func testASecondSideQuestionTypedWhileOneIsPendingKeepsItsDraft() async throws {
        let (lifecycle, model) = await hosted()
        await lifecycle.stageReply(.success(.object(["response": .string("An invented side answer."),
                                                     "synthetic": .bool(false)])))
        await lifecycle.gateNextSend()
        let thread = SideQuestionThread(anchorText: "An invented message.")
        model.open(.sideQuestion(thread))

        model.draft = "An invented first question?"
        try press("Ask", in: ThreadView(model: model).body)
        while await lifecycle.gated == 0 { await Task.yield() }
        XCTAssertEqual(model.draft, "", "the accepted ask left its own text in the field")
        XCTAssertTrue(ThreadView.isBlocked(try XCTUnwrap(model.anchor, "the thread closed itself"), model: model),
                      "Ask stayed enabled while an ask was on the wire")

        model.draft = "An invented second question?"
        try press("Ask", in: ThreadView(model: model).body)
        XCTAssertEqual(model.draft, "An invented second question?",
                       "the refused ask cleared the field and the second question was lost")

        await lifecycle.releaseGate()
        await thread.settled(1)
        var requests = await lifecycle.sent
        XCTAssertEqual(requests.count, 1, "two presses sent \(requests.count) control request(s)")

        // And the draft that survived is still askable, which is the whole point of keeping it.
        await lifecycle.stageReply(.success(.object(["response": .string("An invented second answer."),
                                                     "synthetic": .bool(false)])))
        try press("Ask", in: ThreadView(model: model).body)
        await thread.settled(2)
        requests = await lifecycle.sent
        XCTAssertEqual(requests.count, 2, "the preserved draft sent \(requests.count) control request(s) in total")
        XCTAssertTrue(requests.last?.payload["question"] == .string("An invented second question?"),
                      "the second ask carried a question the user did not type")
    }

    /// Item 10's negative, and the clause the item exists for: **the main transcript gains no
    /// records**. Counted as durable items before and after, in both directions.
    ///
    /// The instrument is C3's own reducer, folded over a committed recording. An ask on the side is a
    /// control request and produces no record, so the count cannot move; a posted reply is a user
    /// message and the engine echoes it, so the count moves by one. Both are folded through the same
    /// reducer in the same test, because a counter that is never shown moving proves nothing about
    /// the case where it must not move.
    func testAskingOnTheSideAddsNoRecordToTheMainTranscriptAndAReplyDoes() async throws {
        var reducer = try reduced("send-user-file")
        let before = reducer.durable.items.count
        XCTAssertGreaterThan(before, 0, "the recording folded no durable items to count")

        let (lifecycle, model) = await hosted()
        await lifecycle.stageReply(.success(.object(["response": .string("An invented side answer."),
                                                     "synthetic": .bool(false)])))
        let thread = SideQuestionThread(anchorText: "An invented message.")
        model.open(.sideQuestion(thread))
        model.draft = "An invented question?"
        try press("Ask", in: ThreadView(model: model).body)
        await thread.settled(1)

        // A control request produces no frame at all: there is nothing to fold, and nothing that
        // could have been folded — the double recorded no `perform` of any kind.
        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 0, "*Ask on the side* performed \(actions.count) lifecycle action(s)")
        XCTAssertEqual(reducer.durable.items.count, before,
                       "the transcript gained \(reducer.durable.items.count - before) item(s) from an ask on the side")

        // The other direction, through the same reducer: a posted reply is a user record, and the
        // engine echoes the line it was sent.
        let (call, _) = try postingAnchors()
        model.open(.toolDetail(call))
        model.draft = "An invented follow-up."
        try press("Send", in: ThreadView(model: model).body)
        await model.whenIdle()
        let postedActions = await lifecycle.actions
        let posted = try XCTUnwrap(sentInput(in: postedActions), "the reply sent no user input")
        _ = reducer.apply(.frame(FrameDecoder.decode(line: try posted.frame(uuid: UUID()).canonicalData()), .first))

        XCTAssertEqual(reducer.durable.items.count, before + 1,
                       "a posted reply moved the count by \(reducer.durable.items.count - before), not by one")
    }

    // MARK: - G2: the thread is reachable

    /// A thread's content scrolls, and the reply control stays outside the scroll container.
    ///
    /// §7.5's tool-detail thread draws a call's whole input and whole output, and the panel column
    /// this tab is drawn in adds no scroll container of its own: an oversized output in a plain
    /// stack pushes everything below it out of the tab, and what is below it is the one control the
    /// thread has. Both halves are asserted — the content inside, the reply outside — because a
    /// scroll view wrapped around *everything* would answer the first and re-create the second.
    func testTheThreadsContentScrollsAndTheReplyControlStaysReachable() async throws {
        let (_, model) = await hosted()
        let (call, _) = try postingAnchors()
        model.open(.toolDetail(call))

        let body = ThreadView(model: model).body
        let scrolled = try XCTUnwrap(ViewTree.scrollViewContent(in: body),
                                     "the thread draws its content in no scroll container")
        XCTAssertTrue(CardTree.texts(in: scrolled).contains("Input"),
                      "the tool detail's own content is outside the scroll container")
        XCTAssertTrue(ViewTree.button("Send", in: scrolled) == nil,
                      "the reply control scrolls away with the content it replies to")
        XCTAssertTrue(ViewTree.button("Send", in: body) != nil, "the thread offers no reply control at all")
    }

    // MARK: - G2: what the thread hosts is the thread it is open on

    /// The hosted content is keyed by **what the thread is open on**, not by its kind.
    ///
    /// `open(_:)` replaces the anchor in place, and SwiftUI keeps a subtree's `@State` across a body
    /// evaluation whose structure did not change. A second thread of the same kind therefore
    /// inherited the first one's view state: `TaskCardView` holds its `TaskCardModel` in `@State`,
    /// so a Task thread opened on B went on holding A and *Stop* would have stopped A; a permission
    /// card's denial text, a question's draft and an elicitation's form are the same shape.
    ///
    /// Two clauses, because either alone passes against the bug: the identity has to distinguish two
    /// subjects of one kind, and the view has to pin it.
    func testTheHostedContentIsKeyedByWhatTheThreadIsOpenOn() async throws {
        let (lifecycle, model) = await hosted()
        let first = ThreadAnchor.decision(try card("permission-allow", id: "dddddddd-dddd-4ddd-8ddd-ddddddddd001"))
        let second = ThreadAnchor.decision(try card("permission-allow", id: "dddddddd-dddd-4ddd-8ddd-ddddddddd002"))
        XCTAssertNotEqual(first.identity, second.identity,
                          "two threads of one kind on different subjects share an identity")

        model.open(first)
        let drawn = ViewTree.identities(in: ThreadView(model: model).body)
        XCTAssertTrue(drawn.contains(first.identity), "the thread pins no identity on the content it hosts")

        model.open(second)
        let replaced = ViewTree.identities(in: ThreadView(model: model).body)
        XCTAssertTrue(replaced.contains(second.identity),
                      "the replacement thread hosts content identified as the thread it replaced")

        // And across the five kinds, so a same-kind identity cannot be the only thing that moves.
        let (call, sent) = try postingAnchors()
        let anchors: [ThreadAnchor] = [
            .toolDetail(call),
            .task(try taskAnchor(lifecycle)),
            first,
            .sideQuestion(SideQuestionThread(anchorText: "An invented message.")),
            .sentFile(sent),
        ]
        XCTAssertEqual(Set(anchors.map(\.identity)).count, anchors.count,
                       "\(anchors.count) anchors share \(Set(anchors.map(\.identity)).count) identities")
    }

    /// Tracker 168: **this tab is the first host to mark a card active**, so Return approves it.
    ///
    /// The shortcut is `isActive && !default_to_no`, default false, because both list hosts draw
    /// many cards and the keyboard default action is singular. A Thread tab draws exactly one card
    /// and the user opened it, so there is no other card for Return to reach.
    func testTheOpenDecisionThreadsCardOwnsReturn() async throws {
        let (_, model) = await hosted()
        model.open(.decision(try card("permission-allow")))

        let hostedCard = try XCTUnwrap(ViewTree.values(of: DecisionCardView.self,
                                                       in: ThreadView(model: model).body).first,
                                       "the decision thread hosts no card component")
        let permission = try XCTUnwrap(ViewTree.values(of: PermissionCardView.self, in: hostedCard.body).first,
                                       "the hosted card drew no permission card")
        XCTAssertEqual(permission.approveShortcut, .defaultAction,
                       "the one card the open thread draws does not own Return")
    }

    // MARK: - G2: one request, one answer, whichever surface sends it

    /// A request already being answered **somewhere else** refuses the reply and keeps its draft.
    ///
    /// The same request is drawn by Activity's row and by the timeline's card at the same time as by
    /// this tab, and each host holds its own `DecisionAnswering`. A per-host in-flight set disables
    /// only the host that clicked: the second answer reaches the supervisor, which has already
    /// dropped the pending id, and comes back `decisionGone` — while this tab has erased the reply
    /// the user typed. Both clauses, because the refusal is only right if the text survives it.
    func testARequestBeingAnsweredElsewhereRefusesTheReplyAndKeepsItsDraft() async throws {
        let reservations = DecisionReservations()
        let lifecycle = ThreadDouble()
        await lifecycle.always(.success(ActivityFixtures.state(Self.channel)))
        let model = ThreadModel(channel: Self.channel, lifecycle: lifecycle, reservations: reservations)
        let card = try card("permission-allow")
        model.open(.decision(card))

        // Another surface answers first, in this same turn of the main actor: the claim is taken
        // before `send` returns, which is what the second press has to find.
        let elsewhere = DecisionAnswering(lifecycle: lifecycle, reservations: reservations)
        elsewhere.send(.allowOnce, on: card, in: Self.channel)

        model.draft = "An invented second thought."
        try press("Send", in: ThreadView(model: model).body)
        XCTAssertEqual(model.draft, "An invented second thought.",
                       "the refused reply cleared the field and the text was lost")

        await elsewhere.whenIdle()
        await model.answering.whenIdle()
        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 1, "one request was answered \(actions.count) times")
    }

    /// An answer the wire refused **leaves the reply in the field**.
    ///
    /// The card is still pending — `perform` threw, so the engine was never told — and it is still
    /// answerable. The model holds the only copy of what the user typed, and clearing the draft on
    /// the way out loses it to the one failure it was written for. The draft is therefore cleared by
    /// the answer succeeding rather than by it being sent.
    func testAReplyTheWireRefusedKeepsItsDraft() async throws {
        let lifecycle = ThreadDouble()
        let card = try card("permission-allow")
        await lifecycle.always(.failure(.decisionGone(card.requestID)))
        let model = ThreadModel(channel: Self.channel, lifecycle: lifecycle)
        model.open(.decision(card))

        model.draft = "An invented reason not to."
        try press("Send", in: ThreadView(model: model).body)
        await model.answering.whenIdle()

        let actions = await lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the reply produced \(actions.count) actions")
        XCTAssertEqual(model.draft, "An invented reason not to.",
                       "a refused answer erased the reply the user typed")
        XCTAssertNotNil(model.answering.banner, "a refused answer raised no banner")
    }
}


// MARK: - Support

private enum ThreadFixtures {

    /// A context over the same null capabilities the host's own tests use: these clauses are about
    /// the tab, not about what a capability does.
    static func context(_ key: ChannelKey) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: URL(fileURLWithPath: "/invented/project"),
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh", capturedAt: Date(), mode: .login),
                       store: NullThreadStore(),
                       links: NullThreadLinks(),
                       recentURLs: NullThreadURLs(),
                       reportPaneExit: { _ in })
    }
}

private struct NullThreadStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

private struct NullThreadLinks: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

private struct NullThreadURLs: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}

/// A lifecycle that records both halves of Y5 — `perform` and `send` — because the Thread tab's five
/// kinds split across them and item 10 is exactly the assertion that one kind took the other route.
///
/// `LifecycleDouble` traps on `send`, which is right for the surfaces it was built for and wrong
/// here; this double is the narrow one that answers both and records both.
actor ThreadDouble: LifecycleAPI {

    nonisolated let updates: AsyncStream<ChannelState>
    private nonisolated let continuation: AsyncStream<ChannelState>.Continuation
    nonisolated let jobUpdates: AsyncStream<[JobEntry]>
    private nonisolated let jobContinuation: AsyncStream<[JobEntry]>.Continuation

    private(set) var actions: [(key: ChannelKey, action: LifecycleAction)] = []
    private(set) var sent: [AnyControlRequest] = []
    private var outcome: Result<ChannelState, LifecycleError>?
    private var replies: [Result<JSONValue, WireError>] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (jobUpdates, jobContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Holds the next `send` inside the double until `releaseGate()`, so a test can press *Ask* a
    /// second time while the first ask is genuinely still on the wire.
    private var gateNext = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// How many sends the gate has caught. A test waits on this rather than on a duration.
    private(set) var gated = 0

    func gateNextSend() { gateNext = true }
    func releaseGate() {
        for continuation in held { continuation.resume() }
        held = []
    }

    func always(_ outcome: Result<ChannelState, LifecycleError>) { self.outcome = outcome }
    /// What the next `send` answers. A queue, so two asks are answered differently.
    func stageReply(_ reply: Result<JSONValue, WireError>) { replies.append(reply) }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        actions.append((key, action))
        guard let outcome else { unreachable("perform with no staged outcome") }
        return try outcome.get()
    }

    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        sent.append(request)
        if gateNext {
            gateNext = false
            gated += 1
            await withCheckedContinuation { held.append($0) }
        }
        guard !replies.isEmpty else { return .object([:]) }
        return try replies.removeFirst().get()
    }

    func state(of key: ChannelKey) async -> ChannelState? { nil }
    func states() async -> [ChannelState] { [] }
    func jobs() async -> [JobEntry] { [] }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { nil }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { unreachable("preconditions") }
    func route(_ text: String, on key: ChannelKey) async -> Routed { unreachable("route") }
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome { unreachable("run") }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { unreachable("openInTerminal") }
    func attach(_ job: JobShort) async throws -> PaneRequest { unreachable("attach") }
    func logs(_ job: JobShort) async throws -> PaneRequest { unreachable("logs") }
    func paneExited(_ exit: PaneExit) async { unreachable("paneExited") }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { unreachable("performJob") }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { unreachable("isDormantEligible") }
    func declineProjectServers(_ names: [String], project: URL) async throws { unreachable("declineProjectServers") }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async { unreachable("acceptProjectServers") }

    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID { unreachable("sendPrompt") }
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey { unreachable("fork") }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey { unreachable("resolvedForkKey") }
    func engineReports(of key: ChannelKey) async -> EngineReports? { unreachable("engineReports") }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        unreachable("resolveSetting")
    }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { unreachable("liveTaskIDs") }

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ThreadDouble.\(member) is not part of the Thread tab's surface")
    }
}

/// The two pieces of in-flight state the tab holds, as probes: a test that has pressed a button
/// waits for the round trip rather than for a duration.
extension ThreadModel {
    func whenIdle() async {
        while isPosting { await Task.yield() }
    }
}

extension SideQuestionThread {
    /// Waits for the ask that produces the `count`-th exchange. Counted rather than flagged because
    /// the ask starts inside a `Task`: a flag read before it has begun would report idle.
    func settled(_ count: Int) async {
        while exchanges.count < count { await Task.yield() }
        while isAsking { await Task.yield() }
    }
}

/// A channel with a real fold: a scratch config home, one committed recording placed in it, the app's
/// one `ChannelTimelineRegistry` over it, and the Thread tab built the way `performLaunch` builds it.
///
/// The two clauses that need one are about the seam between this tab and the channel's fold, and a
/// double in place of the fold would assert that a closure ran rather than that a decision left
/// `.pending`. `TempTree` refuses to build inside any config home, the recording is copied in at run
/// time, and nothing is written under a config home the app did not create (X9, §11).
@MainActor
private struct ThreadFoldRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey

    var model: ChannelTimelineModel { registry.model(for: key) }

    /// The tab's access to this rig's fold, through the same initialiser the composition root uses.
    var fold: ChannelFold { ChannelFold(timelines: registry) }

    init(fixture: String) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        let transcripts = Self.fixtures.appending(path: fixture).appending(path: "transcript")
        let slugs = try FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        var found: (session: SessionID, slug: URL)?
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                found = (session, slug)
            }
        }
        guard let found else { throw ThreadRigError.noTranscript(fixture) }
        key = ChannelKey(configHome: home.configHome.root, session: found.session)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: found.slug,
                                         to: projects.appending(path: found.slug.lastPathComponent,
                                                                directoryHint: .isDirectory))

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: home.configHome,
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
        // An owned channel, so the model's `events(of:)` really answers and a pushed request lands.
        await lifecycle.openEvents(of: key)
        // Every answer this rig drives is accepted, so what is asserted is what the tab did with it.
        await lifecycle.always(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
    }

    func open() async {
        await model.open(ChannelRow(key: key,
                                    title: "a recorded channel",
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
                                    state: SidebarFixtures.state(key, origin: .owned(.ready))))
    }

    /// The tab as `performLaunch` builds it, and the session it makes for this channel.
    func thread() throws -> ThreadModel {
        let tab = ThreadTab(lifecycle: lifecycle, fold: fold)
        let session = tab.makeSession(for: ThreadFixtures.context(key))
        guard let model = session as? ThreadModel else { throw ThreadRigError.noSession }
        return model
    }

    /// Pushes the one `can_use_tool` ask under test, re-keyed to an invented request id.
    func pushPendingAsk() throws -> InboundRequest {
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "req_invented_c63_thread_0001")
        guard case .request = FixtureRunner.event(for: ask) else { throw ThreadRigError.notSurfaced }
        lifecycle.enqueue(.request(ask), to: key)
        return ask
    }

    /// The fold's item for a pushed ask.
    func pending(_ ask: InboundRequest) throws -> DecisionItem {
        guard let item = model.timeline.overlay.decisions[ask.id] else { throw ThreadRigError.noDecision }
        return item
    }

    static func pendingCount(in model: ChannelTimelineModel) -> Int {
        model.timeline.overlay.decisions.values.filter { $0.state == .pending }.count
    }

    /// Waits, bounded, for the model to satisfy `predicate`, and returns whether it did, so the
    /// caller asserts the outcome rather than discarding the wait.
    func settle(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate(model) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(model)
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }
}

private enum ThreadRigError: Error, CustomStringConvertible {
    case noTranscript(String)
    case noSession
    case notSurfaced
    case noDecision

    var description: String {
        switch self {
        case .noTranscript(let fixture): "fixture \(fixture) carries no main transcript"
        case .noSession: "the Thread tab made a session that is not a thread model"
        case .notSurfaced: "the inbound policy does not surface a can_use_tool ask, so nothing would be pending"
        case .noDecision: "the fold holds no decision for the pushed ask"
        }
    }
}
