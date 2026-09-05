import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

// MARK: - The comparison

/// One place two projections of the same channel disagree. Prints identifiers, a category and a field path only —
/// never a path under a home directory, never a record's content (C3 constraint 12), which is why the stream is named
/// by `StreamName.label` and not by the `LogicalStream` that carries the config home.
struct Difference: CustomStringConvertible, Hashable {
    let itemID: ItemID
    let category: TimelineCategory
    let field: String
    var description: String { "\(category) \(itemID.stream.name.label)/\(itemID.key) at \(field)" }
}

/// Check two of the differential invariant: the durable projection the wire reducer builds from a recording's frames
/// against the one the record reducer builds from the same recording's transcript files.
///
/// Both sides are filtered to `ProjectionCategories.comparedWireToFile` and keyed by `ItemID`, so the comparison is
/// bound to the named constant and narrowing the constant narrows the comparison. Each pair is then compared on
/// `ProjectionCategories.comparedItemFields` and nowhere else; the shapes are diffed by `IdentityMask.differingPaths`
/// (Task 3's, already falsifiable under `IdentityMaskTests`) so a difference is reported at its own dotted path.
enum ProjectionComparison {
    /// Timestamps are excluded from the field set on purpose (`excludedItemFields`) and compared here instead: the
    /// wire stamps an item from the frame's own `timestamp` where it has one and from the arrival instant where it
    /// does not, so the two sides agree to within a frame's flight time, not to the millisecond.
    static let timestampTolerance: TimeInterval = 1

    /// The compared half of a projection, keyed by item id.
    ///
    /// A `.taskRun` with `synthesised == true` is left out, and that is a statement about the row rather than about
    /// the fixture: the record reducer's merge produces a run row for a *subagent*, from that stream's
    /// `agent_metadata` sidecar, and the wire reducer produces the same row through the same merge. A synthesised row
    /// is the other kind — a background shell's completion, which `system/task_notification` reports and the
    /// transcript never records anywhere. It exists only while a process runs, so there is no file half for it to
    /// equal. This is what the brief means by "subagent task runs keyed by agent id".
    static func compared(_ p: DurableProjection, fileOnly: Set<String> = []) -> [ItemID: TimelineItem] {
        var out: [ItemID: TimelineItem] = [:]
        for item in p.items(in: ProjectionCategories.comparedWireToFile) {
            if case .taskRun(let run) = item, run.synthesised { continue }
            if fileOnly.contains(item.id.key) { continue }
            out[item.id] = item
        }
        return out
    }

    static func itemsCompared(_ p: DurableProjection, fileOnly: Set<String> = []) -> Int {
        compared(p, fileOnly: fileOnly).count
    }

    /// The record uuids a `ProjectionCategories.fileOnlyRecordKinds` matcher selects. An item keyed by one of them
    /// exists on the file half by definition and can never exist on the wire half, so it is out of the comparison —
    /// and the exclusion is derived from the constant, so a matcher leaving that set puts the items straight back.
    static func fileOnlyRecordUUIDs(_ fx: FixtureCorpus.Fixture) throws -> Set<String> {
        var out: Set<String> = []
        for (_, _, url) in try fx.transcriptFiles() {
            for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                let record = RecordDecoder.decode(line: Data(line))
                guard let uuid = record.uuid,
                      ProjectionCategories.fileOnlyRecordKinds.contains(where: { $0.matches(record) }) else { continue }
                out.insert(uuid)
            }
        }
        return out
    }

    static func compare(wire: DurableProjection, file: DurableProjection, fileOnly: Set<String> = []) -> [Difference] {
        let left = compared(wire, fileOnly: fileOnly), right = compared(file, fileOnly: fileOnly)
        var out: [Difference] = []
        for id in Set(left.keys).union(right.keys).sorted(by: precedes) {
            switch (left[id], right[id]) {
            case (nil, nil):
                continue
            case (let only?, nil), (nil, let only?):
                out.append(Difference(itemID: id, category: only.category, field: "<presence>"))
            case (let a?, let b?):
                guard a.category == b.category else {
                    out.append(Difference(itemID: id, category: a.category, field: "category"))
                    continue
                }
                for path in IdentityMask.differingPaths(shape(a), shape(b)).sorted() {
                    out.append(Difference(itemID: id, category: a.category, field: path))
                }
                if let x = a.timestamp, let y = b.timestamp, abs(x.timeIntervalSince(y)) > timestampTolerance {
                    out.append(Difference(itemID: id, category: a.category, field: "timestamp"))
                }
            }
        }
        return out
    }

    private static func precedes(_ a: ItemID, _ b: ItemID) -> Bool {
        a.stream.name.label == b.stream.name.label ? a.key < b.key : a.stream.name.label < b.stream.name.label
    }

    // MARK: The compared shape

    /// The item reduced to exactly the fields `comparedItemFields` names. Every field is gated on the constant, so
    /// removing one from the set removes it from the comparison rather than leaving a second, silent copy here.
    static func shape(_ item: TimelineItem) -> JSONValue {
        let fields = ProjectionCategories.comparedItemFields.fields
        var out: [String: JSONValue] = [:]
        if fields.contains(.role) { out["role"] = .string(role(of: item)) }
        if fields.contains(.model) { out["model"] = model(of: item).map(JSONValue.string) ?? .null }
        if fields.contains(.origin) { out["origin"] = origin(of: item) }
        if fields.contains(.toolDenialKind) { out["toolDenialKind"] = denialKind(of: item).map(JSONValue.string) ?? .null }
        for field in fields {
            guard case .contentBlocks(let text, let thinking, let toolUseID, let toolUseName, let toolUseInput,
                                      let toolResultContent, let toolResultIsError, let image, let document) = field
            else { continue }
            out["contentBlocks"] = content(of: item, text: text, thinking: thinking, toolUseID: toolUseID,
                                           toolUseName: toolUseName, toolUseInput: toolUseInput,
                                           toolResultContent: toolResultContent, toolResultIsError: toolResultIsError,
                                           image: image, document: document)
        }
        return .object(out)
    }

    private static func role(of item: TimelineItem) -> String {
        switch item {
        case .userMessage: "user"
        case .assistantMessage: "assistant"
        case .peerMessage: "peer"
        case .toolCall: "tool_use"
        case .sentFile: "sent_file"
        case .taskRun: "task_run"
        default: item.category.rawValue
        }
    }

    private static func model(of item: TimelineItem) -> String? {
        if case .assistantMessage(let a) = item { return a.model }
        return nil
    }

    /// The `origin` a message carried. Only a peer message has one; the record reducer and the wire reducer both read
    /// it off `message.origin`, so a peer that arrived as an operator on one side differs here as well as at `role`.
    private static func origin(of item: TimelineItem) -> JSONValue {
        guard case .peerMessage(let p) = item else { return .null }
        return .object(["kind": .string(p.originKind),
                        "from": p.from.map(JSONValue.string) ?? .null,
                        "name": p.name.map(JSONValue.string) ?? .null])
    }

    private static func denialKind(of item: TimelineItem) -> String? {
        if case .toolCall(let c) = item { return c.denialKind }
        return nil
    }

    /// The item's content as blocks. A message contributes its own; a tool call and a `send_user_file` row contribute
    /// the one synthetic block that holds the same fields, so the `tool_use` half and the `tool_result` half of a call
    /// are compared under the same flags that govern them inside a message. A task run has no content: it is compared
    /// on presence and identity alone, which is all `comparedItemFields` names for it.
    private static func content(of item: TimelineItem, text: Bool, thinking: Bool, toolUseID: Bool, toolUseName: Bool,
                                toolUseInput: Bool, toolResultContent: Bool, toolResultIsError: Bool,
                                image: Bool, document: Bool) -> JSONValue {
        func block(_ b: ContentBlock) -> JSONValue {
            switch b {
            case .text(let t):
                return .object(["type": .string("text")].merging(text ? ["text": .string(t.fields.text)] : [:]) { a, _ in a })
            case .thinking(let t):
                // `signature` is in `excludedItemFields`: it is opaque and the wire's streamed copy need not carry it.
                return .object(["type": .string("thinking")].merging(thinking ? ["thinking": .string(t.fields.thinking)] : [:]) { a, _ in a })
            case .redactedThinking(let r):
                return .object(["type": .string("redacted_thinking")].merging(thinking ? ["data": .string(r.fields.data)] : [:]) { a, _ in a })
            case .toolUse(let u):
                var o: [String: JSONValue] = ["type": .string("tool_use")]
                if toolUseID { o["id"] = .string(u.fields.id) }
                if toolUseName { o["name"] = .string(u.fields.name) }
                if toolUseInput { o["input"] = u.fields.input }
                return .object(o)
            case .toolResult(let r):
                var o: [String: JSONValue] = ["type": .string("tool_result")]
                if toolUseID { o["tool_use_id"] = .string(r.fields.toolUseID) }
                if toolResultContent { o["content"] = r.fields.content ?? .null }
                if toolResultIsError { o["is_error"] = r.fields.isError.map(JSONValue.bool) ?? .null }
                return .object(o)
            case .image(let i):
                return .object(["type": .string("image")].merging(image ? ["source": i.fields.source] : [:]) { a, _ in a })
            case .document(let d):
                var o: [String: JSONValue] = ["type": .string("document")]
                if document { o["source"] = d.fields.source; o["title"] = d.fields.title.map(JSONValue.string) ?? .null }
                return .object(o)
            case .opaque(let v):
                return v
            }
        }
        switch item {
        case .userMessage(let u): return .array(u.blocks.map(block))
        case .assistantMessage(let a): return .array(a.blocks.map(block))
        case .peerMessage(let p): return .array(p.blocks.map(block))
        case .toolCall(let c):
            var o: [String: JSONValue] = ["type": .string("tool_use")]
            if toolUseID { o["id"] = .string(c.toolUseID) }
            if toolUseName { o["name"] = .string(c.name) }
            if toolUseInput { o["input"] = c.rawInput }
            if toolResultContent { o["result"] = c.result ?? .null }
            if toolResultIsError { o["is_error"] = c.isError.map(JSONValue.bool) ?? .null }
            return .array([.object(o)])
        case .sentFile(let s):
            var o: [String: JSONValue] = ["type": .string("send_user_file")]
            if toolUseID { o["id"] = .string(s.toolUseID) }
            if toolUseInput {
                o["files"] = .array(s.files.map(JSONValue.string))
                o["caption"] = s.caption.map(JSONValue.string) ?? .null
            }
            if toolResultIsError { o["delivered"] = s.delivered.map(JSONValue.bool) ?? .null }
            return .array([.object(o)])
        default:
            return .array([])
        }
    }
}

// MARK: - The independent floor

/// Counts and identifier sets derived from a fixture's raw bytes with `JSONValue` alone: no `TranscriptRecord`, no
/// `RecordReducer`, no `WireReducer`, no `ProjectionCategories`. It exists so that "the comparison saw every item"
/// is grounded in something that cannot fail in the same direction as the code under test — a comparison that
/// matched nothing, or a category constant that quietly lost a member, disagrees with this walk.
enum IndependentCount {

    // MARK: Items the file's records imply

    /// Every item the transcript files of `fx` must produce in the compared categories:
    /// one per `message.id` group of consecutive `assistant` records, one per `tool_use` block those records carry
    /// (a tool card, or the `send_user_file` row for the one MCP tool), one per `user` record that is neither `isMeta`
    /// nor nothing-but-`tool_result`, and one run row per agent transcript.
    static func comparedItems(_ fx: FixtureCorpus.Fixture) throws -> Int {
        var total = 0
        for (_, kind, url) in try fx.transcriptFiles() {
            total += try streamItems(url)
            if case .agentTranscript = kind { total += 1 }
        }
        return total
    }

    private static func streamItems(_ url: URL) throws -> Int {
        var count = 0
        var runMessageID: String?
        var runOpen = false
        for record in try lines(url) {
            switch record["type"]?.stringValue {
            case "assistant":
                let messageID = record["message"]?["id"]?.stringValue
                if !runOpen || messageID == nil || messageID != runMessageID { count += 1 }
                runOpen = true
                runMessageID = messageID
                for block in record["message"]?["content"]?.arrayValue ?? []
                where block["type"]?.stringValue == "tool_use" { count += 1 }
            case "user":
                runOpen = false; runMessageID = nil
                if record["isMeta"]?.boolValue == true { continue }
                // The two file-only user shapes, restated here rather than read off
                // `ProjectionCategories.fileOnlyRecordKinds`: an engine-injected task notification and a subagent's
                // opening prompt reach the host only through the transcript and the mirror, never as a `user` frame.
                // Restating them is the point — a floor that consulted the constant could not catch the constant.
                if record["origin"]?["kind"]?.stringValue == "task-notification" { continue }
                if record["isSidechain"]?.boolValue == true, record["parentUuid"] == nil || record["parentUuid"] == .null { continue }
                if let blocks = record["message"]?["content"]?.arrayValue, !blocks.isEmpty,
                   blocks.allSatisfy({ $0["type"]?.stringValue == "tool_result" }) { continue }
                count += 1
            case "system":
                runOpen = false; runMessageID = nil          // a boundary or a notification: renders, so it closes the run
            default:
                continue                                     // attachments, progress and every state kind render nothing
            }
        }
        return count
    }

    private static func lines(_ url: URL) throws -> [JSONValue] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        }
    }

    // MARK: What the recording's control traffic implies

    static let decisionSubtypes: Set<String> = ["can_use_tool", "request_user_dialog", "elicitation"]

    /// Request id → the state the recording implies, for every out-direction `control_request` of a decision subtype.
    /// A `control_cancel_request` naming the id cancels it; otherwise the host's own in-direction `control_response`
    /// says how it ended — `allow`/`deny` by name, any other behaviour by the request's subtype, an error body as a
    /// cancellation. Every decision request in the corpus is reached by one of those two, so nothing is left implicit.
    static func decisionStates(_ fx: FixtureCorpus.Fixture) throws -> [String: String] {
        var subtypes: [String: String] = [:]
        var cancelled: Set<String> = []
        var answers: [String: JSONValue] = [:]
        for frame in try fx.frames() {
            let value = frame.value
            let type = value["type"]?.stringValue
            if frame.direction == "out", type == "control_request",
               let id = value["request_id"]?.stringValue,
               let subtype = value["request"]?["subtype"]?.stringValue, decisionSubtypes.contains(subtype) {
                subtypes[id] = subtype
            }
            if frame.direction == "out", type == "control_cancel_request",
               let id = value["request_id"]?.stringValue { cancelled.insert(id) }
            if frame.direction == "in", type == "control_response",
               let id = value["response"]?["request_id"]?.stringValue { answers[id] = value["response"] ?? .null }
        }
        var out: [String: String] = [:]
        for (id, subtype) in subtypes {
            if cancelled.contains(id) { out[id] = "cancelled"; continue }
            guard let answer = answers[id] else { out[id] = "unanswered"; continue }
            if answer["subtype"]?.stringValue == "error" { out[id] = "cancelled"; continue }
            switch answer["response"]?["behavior"]?.stringValue {
            case "allow": out[id] = "allowed"
            case "deny": out[id] = "denied"
            default: out[id] = subtype
            }
        }
        return out
    }

    /// Out-direction `result` frames: uuid → (`duration_ms`, `total_cost_usd`) as the recording wrote them, or nil
    /// where the frame omits either — the two synthetic dialogs, whose constructor writes only what its branch knew.
    static func results(_ fx: FixtureCorpus.Fixture) throws -> [(uuid: String, durationMs: Int?, cost: Double?)] {
        try fx.frames().filter { $0.direction == "out" && $0.value["type"]?.stringValue == "result" }
            .map { (uuid: $0.value["uuid"]?.stringValue ?? "",
                    durationMs: $0.value["duration_ms"]?.intValue.map(Int.init),
                    cost: $0.value["total_cost_usd"].flatMap(double)) }
    }

    /// `total_cost_usd` is a JSON number, but a whole-dollar value decodes as `.integer`.
    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    static func toolUseSummaryFrames(_ fx: FixtureCorpus.Fixture) throws -> Int {
        try fx.frames().filter { $0.value["type"]?.stringValue == "tool_use_summary" }.count
    }
}

// MARK: - The tests

final class ProjectionEqualityTests: XCTestCase {

    /// The two synthetic fixtures are run through both checks like any other, and their outcome is pinned by name
    /// rather than asserted as a pass: a synthetic recording is authoritative about the shapes it was built to
    /// exercise and about nothing else, so a difference it shows is a fact about the constructor, not about the
    /// engine. Filled from the first run and frozen; loosening it needs a Decision Log entry.
    ///
    /// Both dialogs' constructors write the operator's prompts into the transcript but emit no out-direction `user`
    /// frame for them — the engine's `--replay-user-messages` echo, which every recorded fixture carries. So the wire
    /// half of each has no user message, and every prompt is a `<presence>` difference.
    private static let expectedSyntheticFindings: Set<String> = [
        // Every record in both synthetic transcripts carries `parentUuid: null`, so the conversation tree sees ten
        // (respectively twelve) roots rather than one chain, and the record reducer renders only the chain to the
        // leaf — one record. Every other message the constructor wrote is off-chain and produces no file item, while
        // the wire half produces one per out-direction frame. That is a fact about `Tools/probe/synthetic/dialogs.py`,
        // not about the engine, which is why it is pinned here and not asserted.
        "dialog-fable-overage assistantMessage main/a-0 at <presence>",
        "dialog-fable-overage assistantMessage main/a-1 at <presence>",
        "dialog-fable-overage assistantMessage main/a-2 at <presence>",
        "dialog-fable-overage assistantMessage main/a-3 at <presence>",
        "dialog-fable-overage compared 1 of 10 records-implied items",
        "dialog-refusal-fallback assistantMessage main/a-partial-1 at <presence>",
        "dialog-refusal-fallback assistantMessage main/a-partial-2 at <presence>",
        "dialog-refusal-fallback assistantMessage main/a-partial-3 at <presence>",
        "dialog-refusal-fallback assistantMessage main/a-refusal-2 at <presence>",
        "dialog-refusal-fallback assistantMessage main/a-refusal-3 at <presence>",
        "dialog-refusal-fallback assistantMessage main/a-retry-0 at <presence>",
        // The one difference that runs the other way: `u-undeclared` is the file's leaf and so its only rendered
        // item, and the host's own prompt never comes back as an out-direction `user` frame in either dialog.
        "dialog-refusal-fallback userMessage main/u-undeclared at <presence>",
        "dialog-refusal-fallback compared 1 of 12 records-implied items",
    ]

    /// Every fixture's compared-item count, pinned by name so each outcome is stated rather than summed. Filled from
    /// the first run, cross-checked item for item by `IndependentCount.comparedItems`, and re-pinned only after a
    /// confirmed re-recording.
    private static let expectedComparedItems: [String: Int] = [
        "ask-user-question": 4,          // one prompt, two assistant groups, one AskUserQuestion call
        "background-shell": 5,           // one prompt, three assistant groups, one Bash call; the task-notification peer is file-only, the shell's own run row wire-only
        "control-shapes": 2,             // one prompt and one assistant group; the fixture is about control traffic
        "dialog-fable-overage": 1,       // synthetic: a flat list of roots, so only the leaf `a-4` is rendered
        "dialog-refusal-fallback": 1,    // synthetic: the same, so only the leaf `u-undeclared` is rendered
        "exit-plan-mode": 11,            // one prompt, five assistant groups, five calls including ExitPlanMode
        "explore-depth-1": 20,           // main 5, the agent stream 14, and the agent's own run row
        "nested-depth-2": 19,            // main 6, the two agent streams 11 between them, and their two run rows
        "notification-hook": 4,          // one prompt, two assistant groups, one Write call
        "permission-allow": 4,           // one prompt, two assistant groups, the allowed Write
        "permission-deny": 4,            // one prompt, two assistant groups, the denied Write
        "plain-two-turn": 4,             // two prompts, two assistant groups, no tools
        "rate-limited-turn": 4,          // two prompts, two assistant groups
        "resume-no-replay": 4,           // entirely the initial/ snapshot: the engine replayed nothing
        "send-user-file": 6,             // one prompt, three assistant groups, one Bash call, one send_user_file row
        "session-mirror-relocation": 8,  // four prompts and four assistant groups across the relocation
        "session-mirror-resume": 12,     // ten from initial/, two more from the resumed turn
        "zero-cost": 0,                  // no transcript and no conversation frame: both halves are empty
    ]

    /// The overlay's outcome on the two synthetic fixtures, pinned the same way. Their `result` frames omit
    /// `duration_ms` and `total_cost_usd`, which `ResultFields` declares required on the bundle's authority, so each
    /// decodes as an opaque frame and raises no `TurnSummaryItem` at all.
    private static let expectedSyntheticOverlayFindings: Set<String> = [
        "dialog-fable-overage decision fab-0 request_user_dialog",
        "dialog-fable-overage decision fab-1 request_user_dialog",
        "dialog-fable-overage decision fab-2 request_user_dialog",
        "dialog-fable-overage decision fab-3 request_user_dialog",
        "dialog-fable-overage decision fab-4 request_user_dialog",
        "dialog-fable-overage turns 0 of 5 result frames",
        "dialog-refusal-fallback decision dlg-0 request_user_dialog",
        "dialog-refusal-fallback decision dlg-1 request_user_dialog",
        "dialog-refusal-fallback decision dlg-2 request_user_dialog",
        "dialog-refusal-fallback decision dlg-3 request_user_dialog",
        "dialog-refusal-fallback decision dlg-undeclared cancelled",
        "dialog-refusal-fallback turns 0 of 5 result frames",
    ]

    // MARK: Check two

    func testWireAndRecordProjectionsAgreeOnEveryFixture() throws {
        var findings: Set<String> = []
        var comparedPerFixture: [String: Int] = [:]
        let all = try FixtureCorpus.all()
        for fx in all {                                                   // all eighteen: no skip, no exclusion list
            let wire = try FixtureWireReplay.replay(fx)
            let file = try Self.fileProjection(fx)
            let fileOnly = try ProjectionComparison.fileOnlyRecordUUIDs(fx)
            let diffs = ProjectionComparison.compare(wire: wire.durable, file: file, fileOnly: fileOnly)
            comparedPerFixture[fx.name] = ProjectionComparison.itemsCompared(file, fileOnly: fileOnly)
            if fx.synthetic {
                for d in diffs { findings.insert("\(fx.name) \(d)") }
            } else {
                XCTAssertTrue(diffs.isEmpty, "\(fx.name): \(diffs.prefix(5).map(\.description))")
            }
        }
        // Three layers, each of which an empty comparison fails: the count the comparison saw equals an independent
        // walk of the same fixture's records, it equals the pinned outcome for that name, and the names are all
        // eighteen.
        for fx in all {
            let independent = try IndependentCount.comparedItems(fx)
            let compared = comparedPerFixture[fx.name]
            // A synthetic transcript need not be a chain, and neither dialog's is, so the walk's floor is a statement
            // about its constructor there and is pinned rather than asserted — exactly as the equality above is.
            if fx.synthetic {
                if compared != independent { findings.insert("\(fx.name) compared \(compared ?? -1) of \(independent) records-implied items") }
            } else {
                XCTAssertEqual(compared, independent, "\(fx.name): the comparison did not see every item")
            }
        }
        XCTAssertEqual(comparedPerFixture, Self.expectedComparedItems)
        XCTAssertEqual(Set(comparedPerFixture.keys), Set(all.map(\.name)))
        XCTAssertEqual(findings, Self.expectedSyntheticFindings)
    }

    // MARK: The overlay, from wire frames alone

    func testOverlayRendersDecisionsClustersAndTurnCostFromWireFramesAlone() throws {
        var findings: Set<String> = []
        var decisionsSeen = 0, turnsSeen = 0
        let all = try FixtureCorpus.all()
        var summaryFrames = 0
        for fx in all {
            let reducer = try FixtureWireReplay.replay(fx)

            // 1. Decisions. Every out-direction request of a decision subtype has an item, in the state the recording
            //    implies; the id set is derived from the raw frames and shares nothing with the reducer.
            let expected = try IndependentCount.decisionStates(fx)
            let modelled = reducer.overlay.decisions.filter { $0.value.kind != .other }
            XCTAssertEqual(Set(modelled.keys.map(\.rawValue)), Set(expected.keys),
                           "\(fx.name): the decision items do not match the recording's decision requests")
            decisionsSeen += modelled.count
            for (id, decision) in modelled {
                let state = Self.label(of: decision.state)
                if fx.synthetic { findings.insert("\(fx.name) decision \(id.rawValue) \(state)") }
                else { XCTAssertEqual(state, expected[id.rawValue], "\(fx.name): decision \(id.rawValue)") }
            }

            // 2. Turn cost. One `TurnSummaryItem` per `result` frame, carrying that frame's own duration and cost.
            let results = try IndependentCount.results(fx)
            if fx.synthetic {
                if reducer.overlay.turns.count != results.count {
                    findings.insert("\(fx.name) turns \(reducer.overlay.turns.count) of \(results.count) result frames")
                }
            } else {
                XCTAssertEqual(reducer.overlay.turns.map(\.id.key), results.map(\.uuid),
                               "\(fx.name): turn summaries do not match the recording's result frames")
                for (turn, result) in zip(reducer.overlay.turns, results) {
                    XCTAssertEqual(turn.durationMs, result.durationMs, "\(fx.name): result \(result.uuid) duration_ms")
                    XCTAssertEqual(turn.costUSD, result.cost, "\(fx.name): result \(result.uuid) total_cost_usd")
                }
            }
            turnsSeen += reducer.overlay.turns.count

            // 3. Clusters. No committed recording carries a `tool_use_summary`, so the absence is asserted rather
            //    than assumed, and the frame is constructed below from ids read off a replay at run time.
            summaryFrames += try IndependentCount.toolUseSummaryFrames(fx)
            XCTAssertTrue(reducer.overlay.clusters.isEmpty, "\(fx.name): a cluster with no tool_use_summary frame")
        }
        XCTAssertEqual(summaryFrames, 0, "a fixture now carries tool_use_summary: this test must read it, not construct one")
        XCTAssertEqual(findings, Self.expectedSyntheticOverlayFindings)
        // Vacuity guards: the corpus's seventeen decision requests and its twenty-four decodable result frames were
        // each reached. Both numbers are the sum of the independent walks above, so they cannot drift silently.
        XCTAssertEqual(decisionsSeen, try all.reduce(0) { $0 + (try IndependentCount.decisionStates($1).count) })
        XCTAssertEqual(decisionsSeen, 17)
        XCTAssertEqual(turnsSeen, 24)

        // 4. The cluster, from a constructed frame whose ids are read off a replayed recording, so no engine byte
        //    enters this file.
        let explore = try FixtureCorpus.named("explore-depth-1")
        let replayed = try FixtureWireReplay.replay(explore)
        let callIDs = replayed.durable.items.compactMap { item -> String? in
            if case .toolCall(let c) = item, c.provenance.agentID == nil { return c.toolUseID }
            return nil
        }
        XCTAssertFalse(callIDs.isEmpty, "explore-depth-1 has no main-stream tool call to cluster")
        var reducer = replayed
        let frame = FrameDecoder.decode(line: try JSONValue.object([
            "type": .string("tool_use_summary"),
            "summary": .string("afleet-invented-cluster-label"),
            "preceding_tool_use_ids": .array(callIDs.map(JSONValue.string)),
            "uuid": .string("00000000-0000-4000-8000-000000009001"),
            "session_id": .string(explore.sessionID.description),
        ]).canonicalData())
        _ = reducer.apply(.frame(frame, .first), at: Date(timeIntervalSince1970: 0))
        let key = ItemID(stream: reducer.stream, key: callIDs[0])
        XCTAssertEqual(reducer.overlay.clusters.count, 1)
        XCTAssertEqual(reducer.overlay.clusters[key]?.toolUseIDs, callIDs, "the cluster's ids are the frame's own")
        XCTAssertEqual(reducer.overlay.clusters[key]?.label, "afleet-invented-cluster-label")
    }

    /// The record reducer's merged projection of a fixture's `transcript/`. The `agent_metadata` a subagent stream
    /// carries lives in its `.meta.json` sidecar rather than in the JSONL, and `RecordReducer.merge` splices an agent
    /// stream by that record's `toolUseId`, so the sidecar is attached before the merge — without it every agent
    /// stream would silently vanish from the file half and check two would compare half a channel.
    static func fileProjection(_ fx: FixtureCorpus.Fixture) throws -> DurableProjection {
        var metadataByStream: [LogicalStream: AgentMetadataRecord] = [:]
        for (stream, url) in try fx.metaFiles() {
            metadataByStream[stream] = try JSONDecoder().decode(AgentMetadataRecord.self, from: try Data(contentsOf: url))
        }
        var projections: [StreamProjection] = []
        var main: LogicalStream?
        for (stream, kind, url) in try fx.transcriptFiles() {
            var projection = RecordReducer.reduce(try TranscriptReader(url: url).readAll().records,
                                                  stream: stream, sourceFile: url)
            projection.metadata = metadataByStream[stream]
            if case .mainTranscript = kind { main = stream }
            projections.append(projection)
        }
        return RecordReducer.merge(projections, main: main ?? LogicalStream(configHome: FixtureCorpus.recordedConfigHome,
                                                                            sessionID: fx.sessionID, name: .main))
    }

    private static func label(of state: DecisionItem.State) -> String {
        switch state {
        case .pending: "pending"
        case .answered(let outcome): outcome
        case .cancelled: "cancelled"
        case .policyAnswered(let error): "policyAnswered(\(error))"
        case .inert: "inert"
        }
    }
}
