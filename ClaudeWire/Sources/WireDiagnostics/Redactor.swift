import Foundation
import WireFrames

/// Structural redaction (parent §11 as amended): string values under credential-like names, whole account objects,
/// whole update_environment_variables frames, MCP bodies over 4 KB.
///
/// The name rule deliberately applies to **string values only**. Numbers, booleans, arrays and objects are never
/// rewritten by it, because `usage.input_tokens` and its siblings sit on every assistant and result frame and a
/// name rule that touched numbers would turn each of those into an undecodable frame. `counterExemptions` is a
/// second, belt-and-braces guard for a counter that ever arrives as a string.
public enum Redactor {
    static let nameFragments = ["token", "oauth", "key", "secret", "authorization", "credential", "cookie", "password"]
    static let counterExemptions: Set<String> = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "thinking_tokens", "max_tokens", "tokens", "total_tokens", "max_thinking_tokens", "maxTokens", "inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "thinkingTokens",
                                                       // counters observed in Tests/Support/Samples that the plan's list omitted
                                                       "cumulative_dropped_tokens", "estimated_tokens", "estimated_tokens_delta", "maxOutputTokens", "post_tokens", "pre_tokens"]
    static let accountKeys: Set<String> = ["account", "oauthAccount", "organization", "user", "email", "emailAddress"]
    public static let mcpBodyLimit = 4096

    /// Redacts one wire line. Returns canonical bytes — a captured line is canonicalised (keys sorted,
    /// whitespace dropped, integral numbers normalised), not byte-identical to what arrived on the wire.
    /// `nil` means the line is not captured at all: it did not parse, or the frame is dropped wholesale.
    public static func redact(line: Data) -> Data? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), let r = redact(v) else { return nil }
        return try? r.canonicalData()
    }
    /// nil means "drop this frame entirely".
    public static func redact(_ value: JSONValue) -> JSONValue? {
        if value["type"]?.stringValue == "control_request", value["request"]?["subtype"]?.stringValue == "update_environment_variables" { return nil }
        var v = walk(value)
        if value["type"]?.stringValue == "control_request", value["request"]?["subtype"]?.stringValue == "mcp_message",
           var req = v["request"]?.objectValue, let msg = req["message"], let bytes = try? msg.canonicalData(), bytes.count > mcpBodyLimit {
            req["message"] = .object(["jsonrpc": msg["jsonrpc"] ?? .string("2.0"), "id": msg["id"] ?? .null, "method": msg["method"] ?? .null, "truncated": .integer(Int64(bytes.count))])
            if var o = v.objectValue { o["request"] = .object(req); v = .object(o) }
        }
        if value["type"]?.stringValue == "control_response", var resp = v["response"]?.objectValue, var inner = resp["response"]?.objectValue,
           let msg = inner["mcp_response"], let bytes = try? msg.canonicalData(), bytes.count > mcpBodyLimit {
            inner["mcp_response"] = .object(["jsonrpc": .string("2.0"), "id": msg["id"] ?? .null, "truncated": .integer(Int64(bytes.count))])
            resp["response"] = .object(inner)
            if var o = v.objectValue { o["response"] = .object(resp); v = .object(o) }
        }
        return v
    }
    private static func walk(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, child) in o {
                if accountKeys.contains(k), case .object = child { out[k] = .string("<redacted>"); continue }
                if case .string = child, isCredentialName(k) { out[k] = .string("<redacted>"); continue }
                out[k] = walk(child)
            }
            return .object(out)
        case .array(let a): return .array(a.map { walk($0) })
        default: return v
        }
    }
    static func isCredentialName(_ k: String) -> Bool {
        if counterExemptions.contains(k) { return false }
        let lower = k.lowercased()
        return nameFragments.contains { lower.contains($0) }
    }
}
