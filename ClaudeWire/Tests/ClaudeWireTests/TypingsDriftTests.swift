import XCTest
import ClaudeWire
import WireFrames
import WireTestSupport

/// Optional: compares the pinned typings' SDKMessage union with the Swift routing tables and declared keys. Skipped when .typings/ is absent.
final class TypingsDriftTests: XCTestCase {
    private var typingsRoot: URL {
        TestPaths.support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".typings/package")
    }
    private var typings: URL { typingsRoot.appendingPathComponent("sdk.d.ts") }

    private func skipUnlessFetched() throws {
        guard FileManager.default.fileExists(atPath: typings.path) else { throw XCTSkip("run Tools/fetch-typings.sh to enable the drift test") }
    }

    // MARK: - parsing sdk.d.ts

    private struct Member {
        var type: String
        var subtype: String?
        var required: Set<String>
        var all: Set<String>
        /// `system/<subtype>` for a system frame, else the type name. The key both Swift tables are indexed by.
        var key: String { subtype.map { "system/\($0)" } ?? type }
    }

    /// The declared names of the `SDKMessage` union, with one level of union-of-unions flattened.
    ///
    /// `SDKResultMessage` is declared `= SDKResultSuccess | SDKResultError` rather than as an object body,
    /// so a parser that only looks for `= {` drops the entire `result` frame and never says so.
    private func unionLeafNames(in text: String) -> (leaves: [String], unresolved: [String]) {
        func alias(_ name: String) -> [String]? {
            guard let start = text.range(of: "export declare type \(name) = ") else { return nil }
            guard let end = text[start.upperBound...].firstIndex(of: ";") else { return nil }
            let rhs = text[start.upperBound..<end]
            guard !rhs.contains("{") else { return nil }                 // has a body: it is a leaf
            return rhs.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let union = text.range(of: #"export declare type SDKMessage = "#),
              let end = text[union.upperBound...].firstIndex(of: ";") else { return ([], []) }
        var queue = text[union.upperBound..<end].split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var leaves: [String] = [], unresolved: [String] = [], seen = Set<String>()
        while let name = queue.first {
            queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            if text.range(of: "export declare type \(name) = {") != nil { leaves.append(name) }
            else if let members = alias(name) { queue.append(contentsOf: members) }
            else { unresolved.append(name) }
        }
        return (leaves, unresolved)
    }

    /// (type, subtype?) → property names (required and optional) for every leaf of `SDKMessage`.
    private func unionMembers() throws -> (members: [Member], unresolved: [String]) {
        // sdk.d.ts ships with CRLF line endings; normalise before any line-oriented parsing below.
        let text = try String(contentsOf: typings, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        guard text.range(of: #"export declare type SDKMessage = "#) != nil else { throw XCTSkip("SDKMessage union not found") }
        let (names, unresolved) = unionLeafNames(in: text)
        var out: [Member] = []
        for name in names {
            guard let start = text.range(of: "export declare type \(name) = {") else { continue }
            var depth = 0, body: [String] = []
            for line in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if depth == 0 && s.hasPrefix("};") { break }
                if depth == 0, let m = s.range(of: #"^\s+([A-Za-z_][A-Za-z0-9_]*)(\?)?:"#, options: .regularExpression) { body.append(String(s[m]).trimmingCharacters(in: .whitespaces)) }
                depth += s.filter { $0 == "{" }.count - s.filter { $0 == "}" }.count
            }
            var required = Set<String>(), all = Set<String>(), type: String?, subtype: String?
            for prop in body {
                let n = prop.trimmingCharacters(in: CharacterSet(charactersIn: "?:"))
                let optional = prop.hasSuffix("?:")
                all.insert(n); if !optional { required.insert(n) }
            }
            if let m = text[start.upperBound...].range(of: #"type: '([a-z_]+)'"#, options: .regularExpression) { type = String(text[m]).components(separatedBy: "'")[1] }
            if let m = text[start.upperBound...].range(of: #"subtype: '([a-z_]+)'"#, options: .regularExpression), type == "system" { subtype = String(text[m]).components(separatedBy: "'")[1] }
            if let type { out.append(Member(type: type, subtype: subtype, required: required, all: all)) }
        }
        return (out, unresolved)
    }

    /// `unionMembers()` plus the floor that keeps an empty parse from reading as a clean bill of health.
    ///
    /// Both drift assertions below are "this list of findings is empty", which a parser that matched nothing
    /// would also satisfy. These four checks are what make a silent parse failure a failure.
    private func verifiedUnionMembers() throws -> [Member] {
        let (members, unresolved) = try unionMembers()
        XCTAssertEqual(unresolved, [], "SDKMessage names whose declaration could not be parsed at all")
        XCTAssertGreaterThanOrEqual(members.count, 30, "the member-body pattern matched almost nothing; the parse, not the typings, is what broke")
        // The type/subtype discriminants are extracted separately from the property bodies, so a dead body
        // pattern still yields the full member list with every property set empty. Assert the bodies too.
        XCTAssertEqual(members.filter { $0.all.isEmpty }.map(\.key), [], "members parsed with no properties at all")
        let keys = Set(members.map(\.key))
        for expected in ["assistant", "result", "system/init"] {
            XCTAssertTrue(keys.contains(expected), "\(expected) is missing from the parse; found \(keys.sorted())")
        }
        return members
    }

    // MARK: - the Swift side

    /// Swift declared keys per (type, subtype?), from the Fields types. `type`/`subtype` themselves are declared everywhere.
    private static let swiftDeclared: [String: [String]] = [
        "assistant": AssistantFields.declaredKeys, "user": UserFields.declaredKeys, "stream_event": StreamEventFields.declaredKeys,
        "result": ResultFields.declaredKeys, "tool_progress": ToolProgressFields.declaredKeys, "tool_use_summary": ToolUseSummaryFields.declaredKeys,
        "rate_limit_event": RateLimitEventFields.declaredKeys, "auth_status": AuthStatusFields.declaredKeys, "prompt_suggestion": PromptSuggestionFields.declaredKeys,
        "conversation_reset": ConversationResetFields.declaredKeys,
    ]

    /// Top-level keys of the recorded sample for a (type, subtype?) key, or [] when there is no sample.
    ///
    /// The typings are one authority and the recorded engine output is the other, and they are not always in
    /// step: sdk.d.ts 0.3.259 ships against CLI 2.1.259 but omits fields the CLI really emits. A declared key
    /// witnessed in a recording is therefore not stale — the typings lag.
    ///
    /// Limitation, to be re-anchored in Task 12: the evidence read here is `Tests/Support/Samples`, which is
    /// hand-written. `Fixtures/` is the externally verified corpus and the honest authority; this target does
    /// not reach it yet. A frame with no sample falls back to the typings alone, which errs toward reporting
    /// more findings rather than fewer.
    private func witnessedKeys(for key: String) -> Set<String> {
        let name = key.hasPrefix("system/") ? "system_" + key.dropFirst(7) : key
        guard let data = try? TestPaths.sample(name),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(object.keys)
    }

    // MARK: - tests

    func testEveryUnionMemberIsRouted() throws {
        try skipUnlessFetched()
        var unrouted: [String] = []
        for m in try verifiedUnionMembers() {
            if m.type == "system" { if let st = m.subtype, !SystemFrame.knownSubtypes.contains(st) { unrouted.append("system/\(st)") } }
            else if Self.swiftDeclared[m.type] == nil { unrouted.append(m.type) }
        }
        XCTAssertTrue(unrouted.isEmpty, "SDKMessage members without a Swift route: \(unrouted.sorted())")
    }

    func testDeclaredKeysExistInTypingsAndRequiredKeysAreDeclared() throws {
        try skipUnlessFetched()
        var stale: [String] = [], missing: [String] = []
        var byKey: [String: (required: Set<String>, all: Set<String>)] = [:]
        for m in try verifiedUnionMembers() {       // the two `user` members, and result's success/error arms, merge
            let prev = byKey[m.key] ?? ([], [])
            byKey[m.key] = (prev.all.isEmpty ? m.required : prev.required.intersection(m.required), prev.all.union(m.all))
        }
        for (key, typ) in byKey {
            let declared: [String]? = key.hasPrefix("system/") ? SystemFrame.declaredKeys[String(key.dropFirst(7))] : Self.swiftDeclared[key]
            guard let declared else { continue }
            let witnessed = witnessedKeys(for: key)
            for d in declared where d != "type" && d != "subtype" && !typ.all.contains(d) && !witnessed.contains(d) { stale.append("\(key).\(d)") }
            for r in typ.required where !declared.contains(r) { missing.append("\(key).\(r)") }
        }
        XCTAssertTrue(stale.isEmpty, "Swift declares keys neither the typings nor a recorded sample have (renamed or removed): \(stale.sorted())")
        XCTAssertTrue(missing.isEmpty, "typings require keys Swift does not declare: \(missing.sorted())")
    }

    /// The two version lines are independent, but the artifacts are cut together and share their patch
    /// component: SDK 0.3.259 ships against CLI 2.1.259. Comparing that component is the cheapest available
    /// signal that the fetched typings and `ProtocolBaseline` describe the same engine build.
    func testFetchedTypingsMatchTheProtocolBaselinePatchComponent() throws {
        try skipUnlessFetched()
        let data = try Data(contentsOf: typingsRoot.appendingPathComponent("package.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdkVersion = manifest["version"] as? String else { return XCTFail("no version in the fetched package.json") }
        XCTAssertEqual(sdkVersion.split(separator: ".").last, ProtocolBaseline.version.split(separator: ".").last,
                       "fetched typings \(sdkVersion) and ProtocolBaseline \(ProtocolBaseline.version) are not the same engine build")
    }
}
