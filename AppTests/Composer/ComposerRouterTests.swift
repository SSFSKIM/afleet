import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.2 Task 3, gate **G1**: the router UI over every row of X10.
///
/// The first test enumerates `RouterTable.local` **itself**. Nothing here lists a command name, and
/// the member each row is expected to reach is derived from the row's own `RouteStrategy` through an
/// exhaustive switch — so a strategy added to C4's enum stops this file compiling, and a row added to
/// C4's table fails the gate until the composer dispatches it.
///
/// Every user-visible sentence asserted below is read back out of `RouterTable` rather than written
/// here. A test that quoted the copy would pass on a composer that had forked its own (X10).
///
/// §11: no assertion compares an aggregate reaching a `ChannelKey`, a `ChannelContext` or a
/// `ResolvedEnvironment`; the answers are member names, counts, subtypes and invented strings.
@MainActor
final class ComposerRouterTests: XCTestCase {

    // MARK: - Rig

    private func makeKey(_ nibble: String = "e") -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session(nibble))
    }

    private func makeModel(_ double: ComposerLifecycleDouble, key: ChannelKey? = nil) -> ComposerModel {
        ComposerModel(key: key ?? makeKey(), lifecycle: double, surface: ChannelSurfaceState())
    }

    /// An invented `system/init` frame, decoded the way the stream decodes one. The fields are
    /// constructed rather than borrowed: `SystemInitFields`' memberwise initialiser is internal to
    /// ClaudeWire, and no engine byte reaches this file (§11).
    private func systemInitEvent(slashCommands: [String], terminalOnly: [String]) throws -> WireEvent {
        let payload: [String: Any] = [
            "type": "system", "subtype": "init",
            "cwd": "/invented/project", "session_id": SidebarFixtures.session("e").description,
            "tools": [], "mcp_servers": [], "model": "invented-model", "permissionMode": "default",
            "slash_commands": slashCommands, "terminal_slash_commands": terminalOnly,
            "apiKeySource": "none", "claude_code_version": "0.0.0", "output_style": "default",
            "skills": [], "plugins": [], "uuid": "invented-init-uuid",
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        let frame = FrameDecoder.decode(line: line)
        guard case .system(.initialize) = frame else {
            throw XCTSkip("the invented system/init line decoded as \(frame.typeName), not a system frame")
        }
        return .frame(frame, .first)
    }

    /// An invented handshake naming the engine's own commands.
    private func handshakeEvent(commands: [String]) -> WireEvent {
        let raw = JSONValue.object(["commands": .array(commands.map { .object(["name": .string($0)]) })])
        return .handshakeCompleted(Handshake(initialize: InitializeResponse(raw: raw), pending: []), .first)
    }

    /// An invented assistant frame whose one text block carries `text`.
    private func assistantEvent(text: String) throws -> WireEvent {
        let payload: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
            "uuid": "invented-assistant-uuid", "session_id": SidebarFixtures.session("e").description,
        ]
        let line = try JSONSerialization.data(withJSONObject: payload)
        let frame = FrameDecoder.decode(line: line)
        guard case .assistant = frame else {
            throw XCTSkip("the invented assistant line decoded as \(frame.typeName), not an assistant frame")
        }
        return .frame(frame, .first)
    }

    // MARK: - Every local row, by enumeration

    /// The line typed for one row, built from the row and not from a list.
    ///
    /// `/permissions` takes a mode out of `PermissionMode` itself, because a word the engine does not
    /// know is C4's unknown-mode refusal and would take the row somewhere its strategy does not name.
    /// Everything else that parses an argument gets an invented one.
    private func line(for command: LocalCommand) -> String {
        switch command.strategy {
        case .setPermissionMode:
            return "\(command.name) \(PermissionMode.allCases[0].rawValue)"
        case .setModel, .applyFlagSetting, .renameSession, .setCwd, .sideQuestion, .restart, .rewind:
            return "\(command.name) invented-argument"
        case .interrupt, .login, .permissionsView, .mcpPopover, .memoryFiles, .lifecycle, .text, .native:
            return command.name
        }
    }

    /// The X5 members the spec's dispatch table names for a strategy, in order.
    ///
    /// Exhaustive on purpose: a `RouteStrategy` case added by C4 fails to compile here rather than
    /// slipping through unasserted.
    private func expectedMembers(for strategy: RouteStrategy) -> [String] {
        switch strategy {
        case .setModel, .setPermissionMode, .applyFlagSetting, .renameSession, .setCwd, .interrupt, .sideQuestion:
            return ["route", "send"]
        case .rewind, .login, .permissionsView, .mcpPopover, .memoryFiles:
            return ["route", "run"]
        case .lifecycle, .restart:
            return ["route", "perform"]
        // `.text` is a prompt, not a lifecycle action: a pass-through causes a turn, so it goes out
        // as `sendPrompt` and raises `HostSignal.promptSent` with the minted uuid, exactly as a typed
        // message does. Task 7 moved it there; until then it was `perform(.send)` and raised nothing,
        // which left every pass-through turn reducing as `.unprompted`. The member is asserted **by
        // name**, so a composer back on `perform` fails here.
        case .text:
            return ["route", "sendPrompt"]
        case .native:
            return ["route"]
        }
    }

    /// Every row of `RouterTable.local` reaches the member its strategy names, and no other.
    ///
    /// Two-directional: the whole member sequence is compared, so an extra call fails as loudly as a
    /// missing one. A row behind a confirm reaches nothing until the confirm is answered, and that is
    /// asserted on the empty log before the answer.
    func testEveryLocalRowDispatchesToTheMemberItsStrategyNames() async throws {
        XCTAssertGreaterThanOrEqual(RouterTable.local.count, 27,
                                    "the table carries \(RouterTable.local.count) row(s); the gate is written over all of them")

        var confirmed: [String] = []
        var surfacesOpened = 0

        for command in RouterTable.local {
            let double = ComposerLifecycleDouble()
            let key = makeKey()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            await double.alwaysSendPrompt(.success(UUID()))
            let model = makeModel(double, key: key)
            model.draft = line(for: command)

            await model.send()

            if model.pendingConfirmation != nil {
                let before = await double.memberSequence
                XCTAssertEqual(before, ["route"],
                               "a row behind a confirm reached \(before.count) member(s) before it was answered: "
                                   + before.joined(separator: ", "))
                confirmed.append(command.name)
                await model.confirmPending()
            }

            let members = await double.memberSequence
            XCTAssertEqual(members, expectedMembers(for: command.strategy),
                           "row \(command.name) reached \(members.count) member(s): " + members.joined(separator: ", "))

            if case .native(let surface) = command.strategy {
                surfacesOpened += 1
                XCTAssertEqual(model.openSurface, surface,
                               "a native row opened \(model.openSurface ?? "no surface") rather than the one it names")
            } else {
                XCTAssertNil(model.openSurface, "row \(command.name) opened a surface it does not name")
            }
            XCTAssertNil(model.refusal, "row \(command.name) was refused inline")
        }

        XCTAssertGreaterThan(surfacesOpened, 0, "no row exercised the native arm, so it proves nothing")
        // Two-directional on the confirm: `/fork` and `/background` are lifecycle rows too, and a
        // composer that confirmed every lifecycle action would fail here rather than pass quietly.
        XCTAssertEqual(confirmed, ["/logout"],
                       "\(confirmed.count) row(s) were put behind a confirm: " + confirmed.joined(separator: ", "))
    }

    /// `.backgroundAll` and `.stopEverything` are confirmed too. They are not rows of the table — no
    /// typed line produces them — so they are staged as the `Routed` case the header will hand over.
    func testTheOtherTwoConfirmedLifecycleActionsIssueNothingUntilAnswered() async {
        for action in [LifecycleAction.backgroundAll, .stopEverything] {
            let double = ComposerLifecycleDouble()
            let key = makeKey()
            await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
            let model = makeModel(double, key: key)

            await model.dispatch(action: action)

            XCTAssertNotNil(model.pendingConfirmation, "a destructive action was issued with no confirm")
            let before = await double.actions
            XCTAssertEqual(before.count, 0, "the unanswered confirm performed \(before.count) action(s)")

            await model.confirmPending()
            let after = await double.actions
            XCTAssertEqual(after.count, 1, "the answered confirm performed \(after.count) action(s)")
            XCTAssertNil(model.pendingConfirmation, "the answered confirm stayed up")
        }
    }

    /// A plain fork is issued without a confirm, so the arm above is about the three actions and not
    /// about every lifecycle case.
    func testAPlainForkIsIssuedWithoutAConfirm() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        let model = makeModel(double, key: key)

        await model.dispatch(action: .fork(at: nil))

        XCTAssertNil(model.pendingConfirmation, "a plain fork was put behind a confirm")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 1, "a plain fork performed \(actions.count) action(s)")
    }

    // MARK: - Terminal-only

    /// A name the engine reports in `terminal_slash_commands` is hidden from autocomplete, refused
    /// with the table's own sentence, and reaches nothing.
    func testATerminalOnlyCommandIsHiddenRefusedVerbatimAndReachesNothing() async throws {
        let name = "/invented-terminal-only"
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let systemInit = try systemInitEvent(slashCommands: ["invented-terminal-only", "invented-offered"],
                                             terminalOnly: ["invented-terminal-only"])
        await double.stageEngineReport(handshake: nil, systemInitFrom: systemInit)
        await model.observe(systemInit)

        XCTAssertGreaterThan(model.completions.count, 0, "autocomplete offered nothing, so its exclusion proves nothing")
        XCTAssertFalse(model.completions.contains(name), "autocomplete offered the engine's terminal-only command")
        XCTAssertTrue(model.completions.contains("/invented-offered"),
                      "autocomplete dropped a command the engine offered, so the exclusion above is not selective")

        model.draft = name
        await model.send()

        XCTAssertEqual(model.refusal, RouterTable.explanation(forTerminalOnly: name),
                       "the composer rendered \(model.refusal?.count ?? 0) character(s) of copy of its own")
        let members = await double.memberSequence
        XCTAssertEqual(members, ["route"],
                       "a locally refused command reached \(members.count) member(s): " + members.joined(separator: ", "))
        XCTAssertEqual(model.draft, name, "the refused line was eaten; \(model.draft.count) character(s) remain")
    }

    // MARK: - Pass-through

    /// A command the engine offers that the local table does not know is sent as text, unmodified.
    func testAnEngineCommandOutsideTheTableIsSentAsTextUnmodified() async throws {
        let name = "/invented-passthrough"
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        await double.alwaysPerform(.success(SidebarFixtures.state(key, origin: .owned(.ready))))
        await double.alwaysSendPrompt(.success(UUID()))
        let model = makeModel(double, key: key)
        let handshake = handshakeEvent(commands: ["invented-passthrough"])
        let systemInit = try systemInitEvent(slashCommands: [], terminalOnly: [])
        await double.stageEngineReport(handshake: handshake, systemInitFrom: systemInit)
        await model.observe(handshake)
        await model.observe(systemInit)

        XCTAssertTrue(model.completions.contains(name), "autocomplete dropped a command the engine offers")

        model.draft = name
        await model.send()

        let members = await double.memberSequence
        XCTAssertEqual(members, ["route", "sendPrompt"],
                       "a pass-through reached \(members.count) member(s): " + members.joined(separator: ", "))
        let prompts = await double.prompts
        XCTAssertEqual(prompts.count, 1, "a pass-through sent \(prompts.count) prompt(s)")
        let actions = await double.actions
        XCTAssertEqual(actions.count, 0, "a pass-through performed \(actions.count) lifecycle action(s) as well")
        guard let input = prompts.first else {
            return XCTFail("a pass-through reached a lifecycle member that is not `sendPrompt`")
        }
        XCTAssertEqual(input.text, name, "the pass-through sent \(input.text.count) character(s), not the \(name.count) typed")
    }

    // MARK: - The drift interception

    /// The engine's own two refusal sentences, built from the patterns `RouterTable` publishes so no
    /// engine byte is quoted here (§11) and a widened pattern cannot leave this asserting a stale one.
    private func refusal(_ shape: RefusalShape, name: String) -> String {
        switch shape {
        case .bare: return "\(name) isn't available in this environment."
        case .interactivePanel:
            return "\(name) opens an interactive panel and isn't available in this environment. "
                + "Run it from the Claude Code terminal instead."
        }
    }

    /// Each shape is intercepted, replaced with the table's own sentence, and counted in its own
    /// bucket while the other stays at zero. A matcher that collapsed the two fails the second clause.
    func testEachRefusalShapeIsInterceptedReplacedAndCountedApart() async throws {
        for shape in RefusalShape.allCases {
            let name = "/invented-drifted"
            let double = ComposerLifecycleDouble()
            let model = makeModel(double)
            // The sentences must be the ones the patterns match, or this test would pass on a
            // composer that intercepted nothing because the input was wrong.
            XCTAssertNotNil(try? NSRegularExpression(pattern: pattern(of: shape)),
                            "the pattern for one shape does not compile, so the input below is unchecked")

            await model.observe(try assistantEvent(text: refusal(shape, name: name)))

            XCTAssertEqual(model.lastInterception?.replacement,
                           RouterTable.explanation(forDrift: name, shape: shape),
                           "the replacement is not the table's own sentence for this shape")
            XCTAssertEqual(model.lastInterception?.shape, shape, "the interception was filed under the other shape")
            let hits = await model.interceptor.driftCount(of: shape)
            XCTAssertEqual(hits, 1, "the intercepted shape counted \(hits) time(s)")
            for other in RefusalShape.allCases where other != shape {
                let spill = await model.interceptor.driftCount(of: other)
                XCTAssertEqual(spill, 0, "the other shape's bucket moved to \(spill)")
            }
            let total = await model.interceptor.driftCount
            XCTAssertEqual(total, 1, "the drift total reads \(total) after one interception")
            let members = await double.memberSequence
            XCTAssertEqual(members.count, 0, "an interception reached \(members.count) lifecycle member(s)")
        }
    }

    /// Either sentence inside a longer answer is intercepted by neither and moves no counter.
    ///
    /// Required: an interceptor firing on a substring rewrites an answer the engine meant.
    func testARefusalSentenceInsideALongerMessageIsInterceptedByNeither() async throws {
        for shape in RefusalShape.allCases {
            let double = ComposerLifecycleDouble()
            let model = makeModel(double)
            let embedded = "Here is what happens: " + refusal(shape, name: "/invented-drifted")
                + " That is why I did something else."

            await model.observe(try assistantEvent(text: embedded))

            XCTAssertNil(model.lastInterception, "a substring was intercepted")
            let total = await model.interceptor.driftCount
            XCTAssertEqual(total, 0, "a substring moved the drift total to \(total)")
            XCTAssertEqual(model.interceptedReplacements.count, 0,
                           "a substring produced \(model.interceptedReplacements.count) replacement(s)")
        }
    }

    private func pattern(of shape: RefusalShape) -> String {
        switch shape {
        case .bare: return RouterTable.bareRefusalPattern
        case .interactivePanel: return RouterTable.interactivePanelRefusalPattern
        }
    }

    // MARK: - Refusals from the lifecycle

    /// `busy` and `notEligible` each explain inline, keep the typed line, and do not retry.
    ///
    /// A success is staged behind each refusal through the fallback, so a composer that retried would
    /// clear the draft and the call count would read two.
    func testALifecycleRefusalOnARoutedLineKeepsTheLineAndDoesNotRetry() async {
        let refusals: [LifecycleError] = [.busy(.spawn), .notEligible(.turnRunning)]
        for error in refusals {
            let double = ComposerLifecycleDouble()
            let model = makeModel(double)
            await double.stageSendPrompt(.failure(error))
            await double.alwaysSendPrompt(.success(UUID()))
            // `/clear` is a `.text` row, so the refusal is raised by the one `sendPrompt` the row
            // names — a pass-through is a prompt and takes the send path (Task 7).
            model.draft = "/clear"

            await model.send()

            XCTAssertEqual(model.refusal, ComposerModel.explanation(of: error),
                           "the refusal rendered \(model.refusal?.count ?? 0) character(s) that are not the model's own explanation")
            XCTAssertEqual(model.draft, "/clear", "the refused line left \(model.draft.count) character(s) in the field")
            let prompts = await double.prompts
            XCTAssertEqual(prompts.count, 1,
                           "a refused routed line sent \(prompts.count) prompt(s); more than one is a retry")
        }
    }

    // MARK: - StrategyUI

    /// `open(url:)` reaches the channel's link-routing capability as a `WorkspaceLink.url`, and
    /// nothing else.
    func testOpenURLReachesTheChannelsLinkRouterAsAWorkspaceLinkURL() async {
        let double = ComposerLifecycleDouble()
        let key = makeKey()
        let links = RecordingLinkRouter()
        let model = makeModel(double, key: key)
        model.context = ComposerContextFixtures.context(key, links: links)

        await model.open(url: "https://invented.example/sign-in")

        let urls = await links.openedURLs
        XCTAssertEqual(urls, ["https://invented.example/sign-in"],
                       "the browser route received \(urls.count) URL(s)")
        let destinations = await links.destinations
        XCTAssertEqual(destinations.count, 1, "the route was asked \(destinations.count) time(s)")
        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "opening a URL reached \(members.count) lifecycle member(s)")
    }

    /// `confirm(preview:)` puts the dry run's counts in front of the user and answers with what they
    /// chose. The counts are asserted, because a sheet that showed none is the one thing `/rewind`'s
    /// confirmation exists to prevent.
    func testConfirmPresentsTheDryRunCountsAndReturnsTheChoice() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let preview = RewindPreview(canRewind: true, filesChanged: ["a", "b", "c"], insertions: 12, deletions: 4)

        async let choice = model.confirm(preview: preview)
        var presented: RewindPreview?
        for _ in 0..<2_000 {
            await Task.yield()
            if let seen = model.rewindPreview { presented = seen; break }
        }
        XCTAssertEqual(presented?.filesChanged.count, 3, "the sheet presented \(presented?.filesChanged.count ?? 0) changed file(s)")
        XCTAssertEqual(presented?.insertions, 12, "the sheet presented \(presented?.insertions ?? 0) insertion(s)")
        XCTAssertEqual(presented?.deletions, 4, "the sheet presented \(presented?.deletions ?? 0) deletion(s)")
        model.answerRewind(.conversationOnly)

        let answered = await choice
        XCTAssertEqual(answered, .conversationOnly, "the sheet answered with a choice the user did not make")
        XCTAssertNil(model.rewindPreview, "the answered sheet stayed up")
        let members = await double.memberSequence
        XCTAssertEqual(members.count, 0, "a confirmation reached \(members.count) lifecycle member(s)")
    }
}
