import Foundation
import WireFrames

/// Structural redaction (parent §11, as revised at spec commit 22bc060 "Spec: §11 names the identity
/// redaction rule as C1's key set plus the email pattern").
///
/// Five rules, applied to a parsed frame before any byte reaches disk:
///
/// 1. **Whole-frame drop** — a `control_request` whose subtype is `update_environment_variables`.
/// 2. **Identity by key name** — `identityKeys` compared after `normalise` (lowercased, `_` and `-`
///    removed), or any key containing `email`. Fires on string values and on whole objects; numbers,
///    booleans, arrays and nulls are left alone.
/// 3. **Credentials by key-name fragment** — a *string* value under a name containing one of
///    `nameFragments`, with `counterExemptions` by exact name.
/// 4. **Email-shaped strings anywhere** — substituted inside any string value, wherever it sits.
/// 5. **MCP bodies over 4 KB** — replaced by an envelope carrying the byte count.
///
/// Two properties are load-bearing and both are pinned by tests.
///
/// *Rules 2 and 3 never rewrite a number.* `usage.input_tokens` and its siblings sit on every assistant
/// and result frame; a name rule that touched numbers would make each of those frames undecodable.
/// `RedactorTests.testTypedFramesStayTypedAfterRedaction` asserts the whole sample corpus survives.
///
/// *Some exemptions can only be expressed as a position.* A name alone cannot tell
/// `result.subagent_stats.killed.user` (a count of subagents the user killed) from an account id, nor
/// `get_usage`'s `behaviors[].key` (a behaviour enum) from a credential — so those two are keyed on the
/// path, which is why `walk` threads one. Mirrors C1's `Tools/probe/redact.py` `IDENTITY_COUNTER_PATHS`
/// and `SECRET_ENUM_PATHS`.
public enum Redactor {
    /// C1's `IDENTITY_KEYS`, already normalised. Matched *exactly*, never as a substring: `user` as a
    /// substring would swallow `UserPromptSubmit`, a hook-event name that is a dictionary key in the
    /// initialize payload. The `name`-suffixed entries are listed one by one for the same reason —
    /// `displayName` is structural (a `list_models` row field, a plugin catalogue field and a
    /// slash-command field), so redacting it would empty the model picker out of every capture.
    static let identityKeys: Set<String> = ["account", "accountuuid", "accountid", "accountname",
                                            "organization", "organizationuuid", "organizationid", "organizationname",
                                            "user", "userid", "useruuid", "username",
                                            "subscription", "subscriptiontype", "fullname",
                                            // Not in C1's set: the engine's own config key for the account
                                            // record (`oauthAccount`, cli.pretty.js). Its string form is already
                                            // covered by the "oauth" fragment; listing it here keeps the whole
                                            // object covered, as it was before the rule widened.
                                            "oauthaccount"]
    static let nameFragments = ["token", "oauth", "key", "secret", "authorization", "credential", "cookie", "password"]
    static let counterExemptions: Set<String> = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                                                 "thinking_tokens", "max_tokens", "tokens", "total_tokens", "max_thinking_tokens",
                                                 "maxTokens", "inputTokens", "outputTokens", "cacheReadInputTokens",
                                                 "cacheCreationInputTokens", "thinkingTokens",
                                                 // counters observed in Tests/Support/Samples that the plan's list omitted
                                                 "cumulative_dropped_tokens", "estimated_tokens", "estimated_tokens_delta",
                                                 "maxOutputTokens", "post_tokens", "pre_tokens"]
    /// Identity names whose *position* makes them counters.
    static let identityCounterPaths: Set<String> = ["subagent_stats.killed.user"]
    /// Credential-shaped names whose *position* makes them enums.
    static let secretEnumPaths: Set<String> = ["behaviors.key"]
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
        var v = walk(value, path: "")
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

    /// Array elements do not extend the path, so an exemption is written against the shape of the path
    /// rather than against where an element happened to sit: `behaviors[0].key` and `behaviors[3].key`
    /// are the same field.
    private static func walk(_ v: JSONValue, path: String) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, child) in o {
                let p = path.isEmpty ? k : path + "." + k
                if isIdentityName(normalise(k)), !isExempt(path: p, by: identityCounterPaths) {
                    switch child {
                    case .string, .object: out[k] = .string("<redacted>"); continue
                    default: break                      // a number under an identity name is a counter, not an identity
                    }
                }
                if case .string = child, isCredentialName(k), !isExempt(path: p, by: secretEnumPaths) {
                    out[k] = .string("<redacted>"); continue
                }
                out[k] = walk(child, path: p)
            }
            return .object(out)
        case .array(let a): return .array(a.map { walk($0, path: path) })
        case .string(let s): return .string(redactEmails(in: s))
        default: return v
        }
    }
    /// Folds the casing and the separators the wire mixes freely: the protocol writes `accountUuid` and
    /// `subscription_type` for the same kind of field.
    static func normalise(_ k: String) -> String { k.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
    static func isIdentityName(_ normalised: String) -> Bool {
        identityKeys.contains(normalised) || normalised.contains("email")
    }
    static func isCredentialName(_ k: String) -> Bool {
        if counterExemptions.contains(k) { return false }
        let lower = k.lowercased()
        return nameFragments.contains { lower.contains($0) }
    }
    /// A full trailing segment run, so a suffix cannot straddle a partial segment name.
    static func isExempt(path: String, by paths: Set<String>) -> Bool {
        paths.contains { path == $0 || path.hasSuffix("." + $0) }
    }
    // C1's EMAIL_RE, `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+`, scanned by hand rather than by
    // `Regex`: `Regex<Substring>` is not `Sendable`, so it cannot be a `static let` under language mode 6,
    // and rebuilding one per string leaf would compile a pattern on every field of every captured frame.
    // The TLD quantifier is `+`, not `{2,}`: this rule fails closed, and a single-letter TLD that slips
    // through reaches disk. `<email>` contains no `@`, so a second pass is a no-op.
    private static let localChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")
    private static let domainChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let letters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func redactEmails(in s: String) -> String {
        guard s.contains("@") else { return s }
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            guard c[i] == "@", i > 0, localChars.contains(c[i - 1]) else { out.append(c[i]); i += 1; continue }
            var start = i
            while start > 0, localChars.contains(c[start - 1]) { start -= 1 }
            var end = i + 1
            while end < c.count, domainChars.contains(c[end]) { end += 1 }
            // Greedy, exactly like the pattern: the longest domain run that still ends in `.` + letters.
            var stop = end
            while stop > i + 1 {
                let tail = c[(i + 1)..<stop]
                if let dot = tail.lastIndex(of: "."), dot > tail.startIndex, dot < tail.index(before: tail.endIndex),
                   tail[tail.index(after: dot)...].allSatisfy(letters.contains) {
                    break
                }
                stop -= 1
            }
            guard stop > i + 1 else { out.append(c[i]); i += 1; continue }
            out.removeLast(i - start)
            out += "<email>"
            i = stop
        }
        return out
    }
}
