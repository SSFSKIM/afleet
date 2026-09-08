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
    private func card(_ fixture: String) throws -> DecisionCard {
        let request = try FixtureRunner.request(fixture, subtype: "can_use_tool",
                                                id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
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
        XCTAssertEqual(ViewTree.values(of: PlaceholderTabSession.self, in: host.view(for: .thread, context: context)).count, 1,
                       "the placeholder is not drawing before the handover")

        await host.unregister(.thread)
        try host.register(ThreadTab(lifecycle: ThreadDouble()))

        XCTAssertEqual(host.available(for: context), [.thread], "the successor is not the tab the host presents")
        XCTAssertEqual(host.title(for: .thread), PanelTabID.thread.defaultTitle,
                       "the tab bar does not read this child's title")
        let view = host.view(for: .thread, context: context)
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
                                       in: model.panels.view(for: .thread, context: context)).count, 0,
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

    private nonisolated func unreachable(_ member: String) -> Never {
        fatalError("ThreadDouble.\(member) is not part of the Thread tab's surface")
    }
}

/// The in-flight state a posted reply holds, as a probe: a test that has pressed a button
/// waits for the round trip rather than for a duration.
extension ThreadModel {
    func whenIdle() async {
        while isPosting { await Task.yield() }
    }
}
