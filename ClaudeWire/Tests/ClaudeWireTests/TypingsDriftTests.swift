import XCTest
import WireFrames
import WireTestSupport

/// Optional: compares the pinned typings' SDKMessage union with the Swift routing tables and declared keys. Skipped when .typings/ is absent.
final class TypingsDriftTests: XCTestCase {
    private var typings: URL { TestPaths.support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".typings/package/sdk.d.ts") }

    /// (type, subtype?) → property names (required and optional) for every member of `SDKMessage`.
    private func unionMembers() throws -> [(type: String, subtype: String?, required: Set<String>, all: Set<String>)] {
        // sdk.d.ts ships with CRLF line endings; normalise before any line-oriented parsing below.
        let text = try String(contentsOf: typings, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        guard let union = text.range(of: #"export declare type SDKMessage = "#) else { throw XCTSkip("SDKMessage union not found") }
        let tail = text[union.upperBound...]
        let names = tail[..<tail.firstIndex(of: ";")!].split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [(String, String?, Set<String>, Set<String>)] = []
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
            if let type { out.append((type, subtype, required, all)) }
        }
        return out
    }

    /// Swift declared keys per (type, subtype?), from the Fields types. `type`/`subtype` themselves are declared everywhere.
    private static let swiftDeclared: [String: [String]] = [
        "assistant": AssistantFields.declaredKeys, "user": UserFields.declaredKeys, "stream_event": StreamEventFields.declaredKeys,
        "result": ResultFields.declaredKeys, "tool_progress": ToolProgressFields.declaredKeys, "tool_use_summary": ToolUseSummaryFields.declaredKeys,
        "rate_limit_event": RateLimitEventFields.declaredKeys, "auth_status": AuthStatusFields.declaredKeys, "prompt_suggestion": PromptSuggestionFields.declaredKeys,
        "conversation_reset": ConversationResetFields.declaredKeys,
    ]

    /// Top-level keys of the recorded sample for a (type, subtype?) key, or [] when there is no sample.
    ///
    /// The typings are one authority and the recorded engine output is the other, and they are not
    /// always in step: sdk.d.ts 0.3.259 ships against CLI 2.1.259 but omits fields the CLI really
    /// emits. A declared key witnessed in a recorded sample is therefore not stale — the typings lag.
    private func witnessedKeys(for key: String) -> Set<String> {
        let name = key.hasPrefix("system/") ? "system_" + key.dropFirst(7) : key
        guard let data = try? TestPaths.sample(name),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set(object.keys)
    }

    func testEveryUnionMemberIsRouted() throws {
        guard FileManager.default.fileExists(atPath: typings.path) else { throw XCTSkip("run Tools/fetch-typings.sh to enable the drift test") }
        var unrouted: [String] = []
        for m in try unionMembers() {
            if m.type == "system" { if let st = m.subtype, !SystemFrame.knownSubtypes.contains(st) { unrouted.append("system/\(st)") } }
            else if Self.swiftDeclared[m.type] == nil { unrouted.append(m.type) }
        }
        XCTAssertTrue(unrouted.isEmpty, "SDKMessage members without a Swift route: \(unrouted.sorted())")
    }

    func testDeclaredKeysExistInTypingsAndRequiredKeysAreDeclared() throws {
        guard FileManager.default.fileExists(atPath: typings.path) else { throw XCTSkip("run Tools/fetch-typings.sh to enable the drift test") }
        var stale: [String] = [], missing: [String] = []
        var byKey: [String: (required: Set<String>, all: Set<String>)] = [:]
        for m in try unionMembers() {                         // two `user` members merge
            let key = m.subtype.map { "system/\($0)" } ?? m.type
            let prev = byKey[key] ?? ([], [])
            byKey[key] = (prev.all.isEmpty ? m.required : prev.required.intersection(m.required), prev.all.union(m.all))
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
}
