import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// G5: the only place C6.3 speaks to the installed `claude`, and the whole of this child's live
/// budget — **six model turns, one channel, one run** (spec D13, the plan's *Live cost*).
///
/// The script is D13's table, in order, and each turn has the same three beats: a prompt, the card
/// the engine raises for it, and the answer a **press on that card's own button** puts on the wire.
/// Nothing here calls `answer(_:)` by hand: the point of the gate is that the surface a person
/// touches produces the bytes the engine acts on, so every clause below asserts the encoded
/// `InboundAnswer` that reached the lifecycle and then what the engine did about it on disk.
///
/// **Isolated settings are what make turns 3 and 4 mean anything.** The channel launches with
/// `--setting-sources ""` (plus `--strict-mcp-config` where the directory declares `.mcp.json`
/// servers, §6.12), so no rule in anybody's settings can pre-approve a `Write` or pre-deny one: a
/// card appearing at turn 1 and *not* appearing at turn 3 is the engine reacting to this run's own
/// answers and nothing else. `Fleet` composes every launch as `--resume` and carries the CLI's
/// default sources, which is right for the channels the app re-opens and wrong for a session that
/// does not exist yet, so the rewrite happens at the one seam that decides what a spawn is given —
/// the process factory (`isolatedFactory` below, in shape production's own `Fleet.liveFactory`).
///
/// **Nothing here writes under a config home (X9).** The scratch home is *read* — the trust
/// document through `ClaudeJSONReader`, the registry record the same way, the tree by the witness's
/// `lstat(2)` — and the only process that writes into it is the `claude` this gate started, which
/// is exactly what the witness's attribution is a claim about. afleet's own two write roots are
/// under a `TempTree`; the working directory is a disposable one under `/private/tmp/afleet-fixtures/`
/// that the scratch home already trusts, and the files this run creates there are removed after it.
///
/// **A failure names its turn and stops.** D13 allows one re-run of one failed item, so the
/// executor has to know which single turn to re-run; every step throws `TurnFailure`, and no
/// prompt is sent after one, so a broken run costs the turns it had already spent and no more.
@MainActor
final class LiveDecisionCardTests: XCTestCase {

    /// D13's script length. Named so the report and the assertions cannot drift apart.
    static let turns = scriptedTurns

    func testTheSixTurnScriptAnswersEveryCardKindAgainstTheInstalledEngine() async throws {
        try ScratchLiveGate.skipUnlessLive()

        let home = ScratchLiveGate.scratchHome
        let configHome = ConfigHome(root: home, source: .environment)
        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        let directory = try ScratchLiveGate.trustedDirectory()

        let resolved = await Self.appEnvironment(configHome: home)
        guard let binary = BinaryLocator.locate(in: resolved, override: nil) else {
            throw XCTSkip("no claude binary on the captured PATH")
        }

        // afleet's own two write roots, nowhere near a config home; `TempTree` refuses one that is.
        let tree = try TempTree()
        let store = try FileStateStore(baseDirectory: try tree.directory("store"), configHomes: [home])

        let session = SessionID()
        let key = ChannelKey(configHome: home, session: session)
        let declaresServers = FileManager.default.fileExists(
            atPath: directory.appending(path: ".mcp.json").path(percentEncoded: false))

        // The four files the script creates, gone before the run so an old one cannot pass for a new
        // one, and gone after it so the shared scratch directory is left as it was found.
        let files = Self.scriptFiles.map { directory.appending(path: $0) }
        for file in files { try? FileManager.default.removeItem(at: file) }
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let localSettings = directory.appending(path: ".claude/settings.local.json")
        let hadLocalSettings = FileManager.default.fileExists(atPath: localSettings.path(percentEncoded: false))
        defer { if !hadLocalSettings { try? FileManager.default.removeItem(at: localSettings) } }

        let fleet = Fleet(configHome: configHome, environment: resolved, binary: binary, store: store,
                          diagnosticsDirectory: try tree.directory("logs"),
                          factory: Self.isolatedFactory(environment: resolved, configHome: configHome,
                                                        fresh: session, strictMCPConfig: declaresServers))
        let lifecycle = RecordingLifecycle(fleet)
        await fleet.start()

        // The app's own subscription seam, not a second one: `ChannelEventPump` is what holds the
        // live `InboundRequest`s a card is built from, and taking it before the spawn is what lets
        // this see the handshake rather than join after it.
        let log = FrameLog()
        let pump = ChannelEventPump(key: key) { _, event in log.fold(event) }
        await fleet.register(key, cwd: directory, recent: true)
        guard let stream = await fleet.events(of: key) else {
            throw XCTSkip("the fleet built no channel for this session")
        }
        pump.start(stream)

        let answering = DecisionAnswering(lifecycle: lifecycle)
        // The seam moved to the shared reservation set, because any surface's answer closes the
        // request: this test has one surface, and registers on the set its answering object holds.
        answering.reservations.observe(pump) { id, _, _ in pump.forget(id) }

        var reachedTurn = 0
        var stopped = false
        defer {
            if !stopped {
                let live = fleet
                Task { _ = try? await live.perform(.reap, on: key); await live.shutdown() }
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let opened = try await fleet.perform(.open, on: key)
            guard opened.origin == .owned(.ready) else {
                throw TurnFailure(turn: 0, what: "the channel did not open ready")
            }

            // ── Turn 1, item 4. A Write ask, allowed once, and the file that follows.
            reachedTurn = 1
            let write = try await self.turn(1, prompt: "Create a file named ask.txt containing hello",
                                            kind: .permission, on: key, pump: pump, log: log, through: lifecycle)
            let tool = try Self.permission(write.card, turn: 1)
            XCTAssertTrue(tool.fields.toolName == "Write", "turn 1 raised a card for another tool")
            // The path is drawn as text; the content reaches the card as the typed input the diff
            // renderer draws from, and is read there rather than out of an attributed run.
            let drawn = CardTree.texts(in: try Self.permissionView(write.card, tool, key, answering).body)
            XCTAssertTrue(drawn.contains { $0.contains("ask.txt") }, "the Write card drew no path")
            guard case .write(let written) = tool.typedInput else {
                throw TurnFailure(turn: 1, what: "the Write ask did not carry a typed Write input")
            }
            XCTAssertTrue(written.content.contains("hello"), "the Write card carries no content")
            XCTAssertTrue(written.filePath.hasSuffix("ask.txt"), "the Write card names another file")
            try await self.press("Allow once", in: try Self.permissionView(write.card, tool, key, answering).body,
                                 answering: answering, turn: 1)
            var sent = try Self.answered(lifecycle, turn: 1, count: 1)
            XCTAssertTrue(sent["behavior"] == .string("allow"), "turn 1 did not answer allow")
            XCTAssertTrue(sent["decisionClassification"] == .string("user_temporary"),
                          "turn 1's allow-once is not user_temporary")
            XCTAssertNil(sent["updatedPermissions"], "turn 1's allow-once filed a rule")
            try await self.settle(log, turn: 1, after: write.results)
            XCTAssertTrue(Self.exists(files[0]), "turn 1's allowed file does not exist")

            // ── Turn 2, item 5. The same ask, allowed always: the suggestions the request carries,
            //    filed as the card's own picker preselected them.
            reachedTurn = 2
            let always = try await self.turn(2, prompt: "Create a file named ask2.txt containing hello",
                                             kind: .permission, on: key, pump: pump, log: log, through: lifecycle)
            let alwaysTool = try Self.permission(always.card, turn: 2)
            guard always.card.alwaysAllow != nil else {
                throw TurnFailure(turn: 2, what: "the ask carried no suggestion, so Always allow was not offered")
            }
            try await self.press("Always allow",
                                 in: try Self.permissionView(always.card, alwaysTool, key, answering).body,
                                 answering: answering, turn: 2)
            sent = try Self.answered(lifecycle, turn: 2, count: 2)
            XCTAssertTrue(sent["behavior"] == .string("allow"), "turn 2 did not answer allow")
            XCTAssertTrue(sent["decisionClassification"] == .string("user_permanent"),
                          "turn 2's always-allow is not user_permanent")
            XCTAssertTrue((sent["updatedPermissions"]?.arrayValue?.count ?? 0) > 0,
                          "turn 2's always-allow carried no updatedPermissions")
            try await self.settle(log, turn: 2, after: always.results)
            XCTAssertTrue(Self.exists(files[1]), "turn 2's allowed file does not exist")

            // ── Turn 3, item 5's other half. The rule turn 2 filed is what makes this ask never
            //    happen; an implementation that sent `updatedPermissions` the engine could not apply
            //    passes turn 2 and fails here.
            reachedTurn = 3
            let quiet = try await self.turnWithoutACard(3, prompt: "Create a file named ask3.txt containing hello",
                                                        on: key, pump: pump, log: log, through: lifecycle)
            XCTAssertEqual(quiet, 0, "turn 3 raised \(quiet) card(s) for an ask the rule already covers")
            XCTAssertTrue(Self.exists(files[2]), "turn 3's file does not exist")

            // ── Turn 4, item 41. A denial with the user's own words, sent from the Thread tab's
            //    reply — this child's other answering host (§7.5, item 37) — because the denial text
            //    is what the reply carries and the card's field is `@State` a test cannot type into.
            reachedTurn = 4
            let denied = try await self.turn(4, prompt: "Create a file named nope.txt containing hello",
                                             kind: .permission, on: key, pump: pump, log: log, through: lifecycle)
            let thread = ThreadModel(channel: key, lifecycle: lifecycle)
            thread.open(.decision(denied.card))
            thread.draft = "not now"
            try await self.press("Send", in: ThreadView(model: thread).body,
                                 answering: thread.answering, turn: 4)
            pump.forget(denied.card.requestID)
            sent = try Self.answered(lifecycle, turn: 4, count: 3)
            XCTAssertTrue(sent["behavior"] == .string("deny"), "turn 4 did not answer deny")
            XCTAssertTrue(sent["message"] == .string("not now"), "turn 4's denial does not carry the typed text")
            XCTAssertTrue(sent["interrupt"] == .bool(false), "turn 4's denial interrupts the turn (spec D6)")
            XCTAssertTrue(sent["decisionClassification"] == .string("user_reject"),
                          "turn 4's denial is not user_reject")
            try await self.settle(log, turn: 4, after: denied.results)
            XCTAssertFalse(Self.exists(files[3]), "turn 4's denied file exists")

            // ── Turn 5, item 6. The question card: an option chosen, sent, and the turn carrying on.
            reachedTurn = 5
            let asked = try await self.turn(5, prompt: "Use AskUserQuestion to ask me whether I prefer tabs or spaces",
                                            kind: .question, on: key, pump: pump, log: log, through: lifecycle)
            guard case .question(let questionTool) = asked.card.payload else {
                throw TurnFailure(turn: 5, what: "the ask did not decode as a question card")
            }
            let draft = QuestionCardView.Draft()
            let questionView = QuestionCardView(card: asked.card, tool: questionTool, presentation: .full,
                                                channel: key, answering: answering, draft: draft)
            guard let prompt = questionView.questions.first, let option = prompt.options.first else {
                throw TurnFailure(turn: 5, what: "the question card drew no option to choose")
            }
            guard let choice = ViewTree.button(option.label, in: questionView.option(option, of: prompt)),
                  ViewTree.press(choice) else {
                throw TurnFailure(turn: 5, what: "the option could not be chosen")
            }
            try await self.press("Send", in: questionView.body, answering: answering, turn: 5)
            sent = try Self.answered(lifecycle, turn: 5, count: 4)
            XCTAssertTrue(sent["behavior"] == .string("allow"), "turn 5's question answer is not an allow")
            XCTAssertTrue((sent["updatedInput"]?["answers"]?.objectValue?.count ?? 0) > 0,
                          "turn 5's answer echoed no answers object")
            XCTAssertTrue(sent["decisionClassification"] == .string("user_temporary"),
                          "turn 5's question answer is not user_temporary (spec D16)")
            try await self.settle(log, turn: 5, after: asked.results)

            // ── Turn 6, item 7. Plan mode, set through the control request rather than through a
            //    picker: the picker is C6.2's, and building one to reach this card would be its work
            //    done twice (spec D13).
            reachedTurn = 6
            _ = try await lifecycle.send(AnyControlRequest(SetPermissionMode(mode: .plan)), on: key)
            let plan = try await self.turn(6, prompt: "Plan a hello-world script",
                                           kind: .plan, on: key, pump: pump, log: log, through: lifecycle)
            guard case .plan(let planTool) = plan.card.payload else {
                throw TurnFailure(turn: 6, what: "the ask did not decode as a plan card")
            }
            let planView = PlanCardView(card: plan.card, tool: planTool, presentation: .full,
                                        channel: key, answering: answering)
            try await self.press("Approve", in: planView.body, answering: answering, turn: 6)
            sent = try Self.answered(lifecycle, turn: 6, count: 5)
            XCTAssertTrue(sent["behavior"] == .string("allow"), "turn 6's approval is not an allow")
            XCTAssertTrue(sent["decisionClassification"] == .string("user_temporary"),
                          "turn 6's approval is not user_temporary (spec D16)")
            let updates = sent["updatedPermissions"]?.arrayValue ?? []
            XCTAssertEqual(updates.count, 1, "turn 6's approval carried \(updates.count) permission updates")
            XCTAssertTrue(updates.first?["type"] == .string("setMode"),
                          "turn 6's approval does not carry a setMode update")
            try await self.settle(log, turn: 6, after: plan.results)

            // The engine's own account of the six turns. Every result is checked as it arrives; this
            // is the total, so a turn that quietly ran twice is visible as a count.
            XCTAssertTrue(log.results.count >= Self.turns,
                          "the six prompts produced \(log.results.count) result frame(s)")
        } catch let failure as TurnFailure {
            XCTFail(failure.description)
        }

        // This gate's own child, ended by this gate. Nothing else is signalled: `.reap` acts on the
        // channel this test opened, and the fleet holds no other.
        _ = try? await fleet.perform(.reap, on: key)
        pump.stop()
        await fleet.shutdown()
        stopped = true
        let elapsed = start.duration(to: clock.now)

        // The witness. **Not an empty diff**: a live session legitimately writes its own transcript,
        // its registry record and its history, and demanding emptiness would fail the gate on the
        // engine doing what the script needs. Zero *unattributed* changes is the bar — every changed
        // path explained by the allowlist, and the two families that carry an identity carrying this
        // gate's own child's.
        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        let attribution = ConfigHomeWitness.Attribution(childPID: Self.recordedPID(home: home, session: session) ?? 0,
                                                        session: session.description)
        let unattributed = ConfigHomeWitness.unattributed(difference, attribution: attribution)
        XCTAssertTrue(unattributed.isEmpty,
                      "\(unattributed.count) changed path(s) under the config home are unattributed")
        XCTAssertFalse(difference.isEmpty, "the config home did not change at all, so the witness watched nothing")
        // The proof the comparison discriminates, taken from the same reading rather than from a
        // second live run: a deliberately narrowed allowlist reports what the full one explains.
        XCTAssertTrue(ConfigHomeWitness.unattributed(difference, against: ["projects/"]).count > 0,
                      "a narrowed allowlist explained every path, so the check is vacuous")

        print("""
        G5 items 4, 5, 6, 7 and 41, live
          turns scripted ............... \(Self.turns)
          turns reached ................ \(reachedTurn)
          result frames ................ \(log.results.count)
          answers on the wire .......... \(lifecycle.answers.count)
          cost, this session ........... \(String(format: "%.4f", log.cost)) USD
          duration ..................... \(Self.ms(elapsed)) ms
          config home .................. \(difference.summary), unattributed \(unattributed.count)
        """)
    }

    // MARK: - One turn

    /// A prompt, and the card the engine raised for it.
    private struct Turn {
        var card: DecisionCard
        /// How many results the channel had produced before the prompt was sent.
        var results: Int
    }

    /// Sends `prompt` and waits for a card of `kind`.
    ///
    /// The result count is taken **before** the prompt so `settle` measures this turn's own result
    /// and not one the previous turn had already produced.
    private func turn(_ number: Int, prompt: String, kind: DecisionItem.Kind, on key: ChannelKey,
                      pump: ChannelEventPump, log: FrameLog,
                      through lifecycle: any LifecycleAPI) async throws -> Turn {
        let results = log.results.count
        _ = try await lifecycle.perform(.send(UserInput(text: prompt)), on: key)
        guard let card = await Self.poll(upTo: .seconds(240), { Self.card(ofKind: kind, in: pump, on: key) }) else {
            throw TurnFailure(turn: number, what: "no \(kind.rawValue) card within four minutes")
        }
        return Turn(card: card, results: results)
    }

    /// Sends `prompt` and asserts the engine asked nothing: the turn runs to its result with no card
    /// of any kind opening. Returns how many cards it saw, so the assertion is a count.
    private func turnWithoutACard(_ number: Int, prompt: String, on key: ChannelKey,
                                  pump: ChannelEventPump, log: FrameLog,
                                  through lifecycle: any LifecycleAPI) async throws -> Int {
        let results = log.results.count
        var seen = 0
        _ = try await lifecycle.perform(.send(UserInput(text: prompt)), on: key)
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < .seconds(240) {
            if !pump.requests.isEmpty { seen = max(seen, pump.requests.count) }
            if log.results.count > results { return seen }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw TurnFailure(turn: number, what: "the prompt produced no result within four minutes")
    }

    /// Waits for this turn's own result frame and refuses one the engine called an error.
    @discardableResult
    private func settle(_ log: FrameLog, turn: Int, after results: Int) async throws -> ResultFrame {
        guard let result = await Self.poll(upTo: .seconds(240), { log.results.count > results ? log.results.last : nil })
        else {
            throw TurnFailure(turn: turn, what: "no result frame within four minutes of the answer")
        }
        if result.isError || result.subtype != "success" {
            throw TurnFailure(turn: turn, what: "the turn ended with result subtype \(result.subtype)")
        }
        return result
    }

    /// Presses a button by its label and waits for the answer's round trip. `DecisionAnswering`
    /// claims the request id before `send` returns, so this waits on the wire and not on a duration.
    private func press(_ label: String, in body: Any, answering: DecisionAnswering, turn: Int) async throws {
        guard let button = ViewTree.button(label, in: body), ViewTree.press(button) else {
            throw TurnFailure(turn: turn, what: "the card drew no \(label) button")
        }
        await answering.whenIdle()
        if let banner = answering.banner {
            throw TurnFailure(turn: turn, what: "the answer was refused: \(banner.text)")
        }
    }

    // MARK: - Reading the surface

    private static let scriptFiles = ["ask.txt", "ask2.txt", "ask3.txt", "nope.txt"]

    /// The first open request of `kind`, as the card both hosts draw.
    private static func card(ofKind kind: DecisionItem.Kind, in pump: ChannelEventPump,
                             on key: ChannelKey) -> DecisionCard? {
        for request in pump.requests.values {
            guard let item = DecisionItem(surfacing: request, in: key), item.kind == kind else { continue }
            return DecisionCard(item)
        }
        return nil
    }

    private static func permission(_ card: DecisionCard, turn: Int) throws -> CanUseToolRequest {
        guard case .permission(let tool) = card.payload else {
            throw TurnFailure(turn: turn, what: "the ask did not decode as a permission card")
        }
        return tool
    }

    private static func permissionView(_ card: DecisionCard, _ tool: CanUseToolRequest, _ key: ChannelKey,
                                       _ answering: DecisionAnswering) throws -> PermissionCardView {
        PermissionCardView(card: card, tool: tool, presentation: .full, channel: key, answering: answering)
    }

    /// The body of the answer this turn put on the wire, with the count of answers so far asserted
    /// first: a press that sent two answers, or none, is caught here rather than by the clause below.
    private static func answered(_ lifecycle: RecordingLifecycle, turn: Int, count: Int) throws -> JSONValue {
        let answers = lifecycle.answers
        guard answers.count == count else {
            throw TurnFailure(turn: turn, what: "the run has put \(answers.count) answers on the wire, expected \(count)")
        }
        guard let last = answers.last,
              case .success(let success) = last.controlResponse(for: RequestID(rawValue: "gate")).body,
              let response = success.response else {
            throw TurnFailure(turn: turn, what: "the answer did not encode as a success body")
        }
        return response
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - The environment, the factory and the child's pid

    /// The login shell's environment with `CLAUDE_CONFIG_DIR` pointed at the scratch home.
    private static func appEnvironment(configHome: URL) async -> ResolvedEnvironment {
        let resolved = await LaunchSequence.resolveLoginShellEnvironment()
        var variables = resolved.variables
        variables["CLAUDE_CONFIG_DIR"] = configHome.path(percentEncoded: false)
        return ResolvedEnvironment(variables: variables, shell: resolved.shell,
                                   capturedAt: resolved.capturedAt, mode: resolved.mode)
    }

    /// Production's `Fleet.liveFactory` in shape, with the one launch this gate needs rewritten.
    ///
    /// Three edits, and each is D13's. `.resume` becomes `.new` for the one session this gate
    /// minted, because a session that does not exist yet cannot be resumed and `Fleet` composes
    /// every launch as a resume. `settingSources` becomes `[]` — `--setting-sources ""` — so no
    /// user, project or local rule can pre-answer a `Write`. `strictMCPConfig` follows §6.12's rule
    /// for a launch whose sources exclude `local`: a directory that declares servers gets none.
    private static func isolatedFactory(environment: ResolvedEnvironment, configHome: ConfigHome,
                                        fresh: SessionID, strictMCPConfig: Bool) -> ProcessFactory {
        { epoch, launch in
            var isolated = launch
            if case .resume(let id, false) = isolated.session, id == fresh { isolated.session = .new(id) }
            isolated.settingSources = []
            isolated.strictMCPConfig = strictMCPConfig
            let capturing = CapturingDiagnostics(forwardingTo: NullDiagnostics())
            let process = ClaudeProcess(epoch: epoch, launch: isolated, environment: environment,
                                        configHome: configHome,
                                        mcpServer: AfleetMCPServer(serverVersion: ProtocolBaseline.afleetVersion,
                                                                   cwd: isolated.cwd, tools: [SendUserFileTool()]),
                                        diagnostics: capturing, capture: nil)
            return LiveProcessHandle(process, epoch: epoch, diagnostics: capturing)
        }
    }

    /// The pid of the `claude` this gate started, read (never written) from the scratch home's own
    /// registry. The witness needs it to tell this child's `sessions/<pid>.*` from anybody else's.
    private static func recordedPID(home: URL, session: SessionID) -> pid_t? {
        let directory = home.appending(path: "sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = ClaudeJSONReader.read(directory.appending(path: name)),
                  let record = RegistryRecord.decode(data),
                  record.sessionId == session.description else { continue }
            return record.pid
        }
        return nil
    }

    private static func poll<T>(upTo deadline: Duration, _ body: @MainActor () -> T?) async -> T? {
        let clock = ContinuousClock()
        let start = clock.now
        while start.duration(to: clock.now) < deadline {
            if let value = body() { return value }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return body()
    }

    private static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
}

// MARK: - A failure that names its turn

/// D13 allows **one** re-run of **one** failed item, so a failure that did not say which turn it was
/// would cost the whole six-turn script to find out. Every step throws this, and the run stops at
/// the first one rather than sending the next prompt.
private struct TurnFailure: Error, CustomStringConvertible {
    let turn: Int
    let what: String
    var description: String { "turn \(turn) of \(scriptedTurns): \(what)" }
}

/// D13's script length, at file scope so a failure raised off the main actor can name it.
private let scriptedTurns = 6

// MARK: - What the channel said

/// The result frames this channel produced, and their cost. Counts and numbers only (§11).
///
/// `@unchecked Sendable` is sound because both fields are read and written only inside `lock`, this
/// instance's own `NSLock`; that lock is the serialising mechanism.
private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ResultFrame] = []
    private var total: Double = 0

    func fold(_ event: WireEvent) {
        guard case .frame(.result(let result), _) = event else { return }
        lock.lock()
        frames.append(result)
        total += result.totalCostUSD
        lock.unlock()
    }

    var results: [ResultFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    var cost: Double { lock.lock(); defer { lock.unlock() }; return total }
}

// MARK: - The answers, as they left the host

/// Every `InboundAnswer` the surface handed the lifecycle, forwarded to the real fleet unchanged.
///
/// The gate's assertions are about the **bytes an answer encodes to**, which is what the engine
/// acts on; `InboundAnswer` is not `Equatable` and a card's own state changes for many reasons, so
/// this — the value on its way through the one seam every answer passes — is what each clause reads.
private final class RecordingLifecycle: LifecycleAPI, @unchecked Sendable {   // `lock` serialises `recorded`
    private let inner: any LifecycleAPI
    private let lock = NSLock()
    private var recorded: [InboundAnswer] = []

    init(_ inner: any LifecycleAPI) { self.inner = inner }

    var answers: [InboundAnswer] { lock.lock(); defer { lock.unlock() }; return recorded }

    func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState {
        if case .answer(_, let answer) = action { record(answer) }
        return try await inner.perform(action, on: key)
    }

    /// Synchronous, because taking a lock inside an `async` body is not allowed and this one is held
    /// for an array append.
    private func record(_ answer: InboundAnswer) {
        lock.lock(); recorded.append(answer); lock.unlock()
    }

    func state(of key: ChannelKey) async -> ChannelState? { await inner.state(of: key) }
    func states() async -> [ChannelState] { await inner.states() }
    func preconditions(for key: ChannelKey) async -> SpawnPrecondition { await inner.preconditions(for: key) }
    func route(_ text: String, on key: ChannelKey) async -> Routed { await inner.route(text, on: key) }
    @discardableResult
    func send(_ request: AnyControlRequest, on key: ChannelKey) async throws -> JSONValue {
        try await inner.send(request, on: key)
    }
    @discardableResult
    func run(_ strategy: RouteStrategy, arguments: [String], on key: ChannelKey,
             ui: any StrategyUI) async throws -> StrategyOutcome {
        try await inner.run(strategy, arguments: arguments, on: key, ui: ui)
    }
    func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest { try await inner.openInTerminal(key) }
    func reviewTrustInTerminal(_ key: ChannelKey) async throws -> PaneRequest { try await inner.reviewTrustInTerminal(key) }
    func attach(_ job: JobShort) async throws -> PaneRequest { try await inner.attach(job) }
    func logs(_ job: JobShort) async throws -> PaneRequest { try await inner.logs(job) }
    func paneExited(_ exit: PaneExit) async { await inner.paneExited(exit) }
    func jobs() async -> [JobEntry] { await inner.jobs() }
    func performJob(_ verb: JobVerb, _ short: JobShort) async throws { try await inner.performJob(verb, short) }
    func isDormantEligible(_ key: ChannelKey) async -> Bool { await inner.isDormantEligible(key) }
    func declineProjectServers(_ names: [String], project: URL) async throws {
        try await inner.declineProjectServers(names, project: project)
    }
    func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async {
        await inner.acceptProjectServers(servers, project: project)
    }
    func events(of key: ChannelKey) async -> AsyncStream<WireEvent>? { await inner.events(of: key) }
    @discardableResult
    func sendPrompt(_ input: UserInput, on key: ChannelKey) async throws -> UUID {
        try await inner.sendPrompt(input, on: key)
    }
    @discardableResult
    func fork(at point: ForkPoint?, on key: ChannelKey) async throws -> ChannelKey {
        try await inner.fork(at: point, on: key)
    }
    func resolvedForkKey(of provisional: ChannelKey) async -> ChannelKey {
        await inner.resolvedForkKey(of: provisional)
    }
    func engineReports(of key: ChannelKey) async -> EngineReports? { await inner.engineReports(of: key) }
    func resolveSetting(_ name: String, to value: JSONValue, on key: ChannelKey) async throws {
        try await inner.resolveSetting(name, to: value, on: key)
    }
    func liveTaskIDs(of key: ChannelKey) async -> [String] { await inner.liveTaskIDs(of: key) }
    nonisolated var updates: AsyncStream<ChannelState> { inner.updates }
    nonisolated var jobUpdates: AsyncStream<[JobEntry]> { inner.jobUpdates }
}
