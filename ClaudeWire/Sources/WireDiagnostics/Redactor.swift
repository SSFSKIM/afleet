import Foundation
import WireFrames

/// Structural redaction for the capture file (parent §11).
///
/// **This type mirrors C1's `Tools/probe/redact.py` rule set. A divergence is a defect, not a choice.**
/// Mirrored from that file as of 2026-09-05, against spec commits `22bc060` ("§11 names the identity
/// redaction rule as C1's key set plus the email pattern") and `ed87a22` ("§11 makes C1's full redaction
/// rule set canonical for the capture redactor"). Both redactors feed the same human review, so a byte one
/// lets through is invisible to the other's tests; keep them together, and when you change one, change both.
/// `RedactorDifferentialTests` runs C1's redactor against this one over shared vectors whenever the sibling
/// worktree is present, and skips when it is not.
///
/// The one rule deliberately not mirrored is C1's rule 3, the home-directory and hostname substitution.
/// It needs the recording machine's home path and hostname, which this redactor is not given, and a capture
/// is written into the user's own log directory rather than committed to a repository — rewriting their own
/// paths out of it would cost the reader the thing they opened it for. Recorded here so the next reader sees
/// the gap; if captures ever become shareable artefacts it has to be added.
///
/// Two properties are load-bearing and both are pinned by tests. *Fail closed*: where a rule cannot tell
/// whether something is sensitive, it redacts. *Typed frames stay typed*: `usage.input_tokens` and its
/// siblings sit on every assistant and result frame, and `subagent_stats.killed.user` on every result frame,
/// so the exemptions that keep those decodable are not cosmetic.
public enum Redactor {
    // MARK: - Constants, mirrored name for name from redact.py

    /// redact.py IDENTITY_KEYS (line 67), already normalised. Matched *exactly*, never as a substring:
    /// `user` as a substring would swallow `UserPromptSubmit`, a hook-event name used as a dictionary key,
    /// and `user_message_uuid`, which links an assistant frame to its user turn. The `name`-suffixed entries
    /// are listed one by one for the same reason — `displayName` is a model row, a plugin catalogue entry
    /// and a slash-command field. `email` is the one substring match.
    static let identityKeys: Set<String> = ["account", "accountuuid", "accountid", "accountname",
                                            "organization", "organizationuuid", "organizationid", "organizationname",
                                            "user", "userid", "useruuid", "username",
                                            "subscription", "subscriptiontype", "fullname"]
    /// redact.py SECRET_WORDS (line 71).
    static let secretWords = ["token", "oauth", "key", "secret", "credential", "authorization", "cookie", "password", "bearer"]
    /// redact.py USAGE_COUNTERS (line 73), compared against the lowercased key, not the normalised one.
    static let usageCounters: Set<String> = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                                             "thinking_tokens", "max_tokens", "tokens", "total_tokens", "maxtokens", "rawmaxtokens"]
    /// redact.py SECRET_EXEMPT (line 81), normalised. Structural names that happen to contain a secret word:
    /// `projectKey` names the directory a GUI reads to replay history, so its value is load-bearing.
    static let secretExempt: Set<String> = ["apikeysource", "hookcallbackids", "projectkey"]
    /// redact.py SECRET_STRUCTURE_PATHS (line 95). Rule 5's own output, whose keys all contain "key" and
    /// whose values are lists of setting *names* — redacting them would leave a settings response saying nothing.
    static let secretStructurePaths: Set<String> = ["effective_keys", "sources_keys", "sources_keys.keys", "rules.secrets", "rules.oauth_flow"]
    /// redact.py IDENTITY_COUNTER_PATHS (line 180). `killed.user` counts subagents the user killed; it sits
    /// beside `killed.parent` and `killed.system` and appears on every result frame.
    static let identityCounterPaths: Set<String> = ["subagent_stats.killed.user"]
    /// redact.py SECRET_ENUM_PATHS (line 190). `get_usage`'s `behaviors[].key` is an enum of behaviour names.
    static let secretEnumPaths: Set<String> = ["behaviors.key"]
    /// redact.py OAUTH_SUBTYPES (line 97).
    static let oauthSubtypes: Set<String> = ["claude_authenticate", "claude_oauth_callback", "claude_oauth_wait_for_completion",
                                             "mcp_authenticate", "mcp_oauth_callback_url"]
    public static let mcpBodyLimit = 4096

    // MARK: - Entry points

    /// Redacts one wire line. Returns canonical bytes — a captured line is canonicalised (keys sorted,
    /// whitespace dropped, integral numbers normalised), not byte-identical to what arrived on the wire.
    /// `nil` means the line is not captured at all: it did not parse, or the frame is dropped wholesale.
    public static func redact(line: Data) -> Data? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), let r = redact(v) else { return nil }
        return try? r.canonicalData()
    }
    /// One frame. `nil` means "drop this frame entirely" — redact.py `redact_frame` (line 376).
    public static func redact(_ value: JSONValue) -> JSONValue? { Rules().frame(value) }

    // MARK: - Name and path predicates, shared with the tests

    /// redact.py `_norm_key` (line 102): folds the casing and the separators the wire mixes freely.
    static func normalise(_ k: String) -> String { k.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") }
    /// redact.py `_path_exempt` (line 195): list indices are stripped, so an exemption is written against
    /// the shape of the path; matching is on a full trailing segment run so a suffix cannot straddle a
    /// partial segment name.
    static func isExempt(path: String, by paths: Set<String>) -> Bool {
        var bare = ""
        var depth = 0
        for ch in path {
            if ch == "[" { depth += 1; continue }
            if ch == "]" { depth -= 1; continue }
            if depth == 0 { bare.append(ch) }
        }
        return paths.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }
    /// redact.py `_contains_string` (line 108): keys are not leaves, only values are.
    static func containsString(_ v: JSONValue) -> Bool {
        switch v {
        case .string: return true
        case .object(let o): return o.values.contains(where: containsString)
        case .array(let a): return a.contains(where: containsString)
        default: return false
        }
    }
    /// redact.py `_is_token_counter` (line 121). `token` is the one secret word that also names arithmetic.
    /// The name half requires that `token` is the *only* secret word present, so `oauth_token` is never a
    /// counter; the value half requires that nothing under the value is a string, which is what actually
    /// separates a credential from a count — including a whole dict of counters.
    static func isTokenCounter(_ lowercasedKey: String, _ value: JSONValue) -> Bool {
        if secretWords.contains(where: { $0 != "token" && lowercasedKey.contains($0) }) { return false }
        return !containsString(value)
    }
    /// redact.py `_is_secret_key` (line 143). The rule fires on any secret-named field whatever its type —
    /// reading it as "any secret-named *string*" is what left `{"authorization": {"value": "Bearer .."}}`
    /// on disk. `null` is never redacted: there is nothing there to leak and a placeholder would change the
    /// field's type for no gain.
    static func isSecretKey(_ k: String, _ value: JSONValue) -> Bool {
        let lk = k.lowercased()
        if secretExempt.contains(normalise(k)) || usageCounters.contains(lk) { return false }
        if case .null = value { return false }
        if !secretWords.contains(where: { lk.contains($0) }) { return false }
        return !isTokenCounter(lk, value)
    }
    /// redact.py `_secret_field` (line 219): the whole of rule 2 in one place.
    static func isSecretField(_ k: String, _ value: JSONValue, path: String) -> Bool {
        isSecretKey(k, value) && !isExempt(path: path, by: secretEnumPaths) && !isExempt(path: path, by: secretStructurePaths)
    }

    // MARK: - The rules

    /// The patterns live on a value rather than in statics because `Regex` is not `Sendable` and so cannot
    /// be a stored global under language mode 6. One `Rules` is built per frame.
    struct Rules {
        // redact.py lines 33 to 55.
        let email = #/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]+/#
        let skAnt = #/sk-ant-[A-Za-z0-9_\-]+/#
        let jwt = #/eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}/#
        let queryRun = #/([?&][A-Za-z0-9_\-]+=)([A-Fa-f0-9]{32,}|[A-Za-z0-9+/=_\-]{32,})/#
        let lsLong = #/([-dlbcps][-rwxSsTtLl]{9}[@+.]?\s+\d+\s+)(\S+)(\s+)(\S+)/#
        let placeholderKey = #/^<[^<>]*>(#\d+)?$/#
        let query = #/\?[\s\S]*$/#

        /// redact.py `redact_text` (line 269), less rule 3. The `ls -l` owner and group columns are matched
        /// by *position*: a directory listing carries the recording machine's account name where no
        /// name-keyed rule looks. Idempotent — `<user>` and `<group>` substitute to themselves.
        func text(_ s: String) -> String {
            var out = s.replacing(email, with: "<email>")
            out = out.replacing(skAnt, with: "<redacted>")
            out = out.replacing(jwt, with: "<redacted>")
            out = out.replacing(queryRun) { m in m.1 + "<redacted>" }
            out = out.replacing(lsLong) { m in m.1 + "<user>" + m.3 + "<group>" }
            return out
        }
        func isIdentityKey(_ nk: String) -> Bool {
            if (try? placeholderKey.wholeMatch(in: nk)) != nil { return false }
            return Redactor.identityKeys.contains(nk) || nk.contains("email")
        }

        /// redact.py `redact_json` (line 302). Keys are data too — project maps are keyed by absolute path
        /// and contact maps by address — so a key is redacted like any string, and a collision between two
        /// keys that map onto one placeholder is disambiguated rather than silently dropped.
        ///
        /// Keys are visited in sorted order. C1 visits them in wire order, which a Swift dictionary does not
        /// keep; the two differ only in which of two colliding keys gets the `#2` suffix.
        func json(_ v: JSONValue, path: String) -> JSONValue {
            switch v {
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for k in o.keys.sorted() {
                    let child = o[k]!
                    var rk = text(k)
                    if out[rk] != nil {
                        var n = 2
                        while out["\(rk)#\(n)"] != nil { n += 1 }
                        rk = "\(rk)#\(n)"
                    }
                    let p = path.isEmpty ? rk : path + "." + rk
                    let nk = Redactor.normalise(k)
                    if isIdentityKey(nk), !Redactor.isExempt(path: p, by: Redactor.identityCounterPaths) {
                        let placeholder = nk.contains("email") ? "<email>" : "<\(rk)>"
                        out[rk] = keep(child, ifAlready: placeholder) ?? .string(placeholder)
                        continue
                    }
                    if nk == "apikeysource" {
                        // redact.py line 329. Note the accepted set is narrower than the identity rule's:
                        // `none` is the real value the engine emits when no API key is configured.
                        let placeholder = "<\(rk)>"
                        if child == .null || child == .string("none") || child == .string(placeholder) { out[rk] = child }
                        else { out[rk] = .string(placeholder) }
                        continue
                    }
                    if Redactor.isSecretField(k, child, path: p) { out[rk] = .string("<redacted>"); continue }
                    out[rk] = json(child, path: p)
                }
                return .object(out)
            case .array(let a):
                return .array(a.enumerated().map { json($1, path: "\(path)[\($0)]") })
            case .string(let s):
                return .string(text(s))
            default:
                return v
            }
        }
        /// `null` and a value this rule already produced are left alone, so a second pass changes nothing.
        private func keep(_ v: JSONValue, ifAlready placeholder: String) -> JSONValue? {
            if case .null = v { return v }
            if v == .string(placeholder) || v == .string("<email>") { return v }
            return nil
        }

        /// redact.py `_truncate_mcp` (line 351).
        func truncateMCP(_ msg: JSONValue?) -> JSONValue? {
            guard let msg, case .object(let o) = msg, let bytes = try? msg.canonicalData(), bytes.count > Redactor.mcpBodyLimit else { return msg }
            var kept: [String: JSONValue] = [:]
            for k in ["jsonrpc", "id", "method"] where o[k] != nil { kept[k] = o[k] }
            kept["truncated"] = .integer(Int64(bytes.count))
            return .object(kept)
        }

        /// redact.py `_redact_urls` (line 359), rule 6: a callback URL is not always top-level.
        func urls(_ node: JSONValue) -> JSONValue {
            switch node {
            case .object(let o): return .object(o.mapValues(urls))
            case .array(let a): return .array(a.map(urls))
            case .string(let s) where s.hasPrefix("http") && s.contains("?"): return .string(s.replacing(query, with: "?<redacted>"))
            default: return node
            }
        }

        /// redact.py `redact_frame` (line 376). The frame-scoped rules (4, 5, 6) run before the recursive
        /// walk of rules 1 and 2: rule 5 needs the pre-redaction `effective` dict and rule 4 the
        /// pre-redaction body size.
        ///
        /// C1 gates rules 4, 5 and 6 on the correlated request subtype, firing on its own subtype *or on an
        /// unknown one* so that a rule never fails open exactly when a frame is least understood. This
        /// redactor sees one line with no correlation map, which is C1's unknown case, so all three fire.
        func frame(_ value: JSONValue) -> JSONValue? {
            let type = value["type"]?.stringValue
            if type == "control_request" {
                let sub = value["request"]?["subtype"]?.stringValue
                if sub == "update_environment_variables" { return nil }
                var f = value
                if sub == "mcp_message", var req = f["request"]?.objectValue, var o = f.objectValue {
                    req["message"] = truncateMCP(req["message"]) ?? .null   // C1 assigns None rather than dropping the key
                    o["request"] = .object(req)
                    f = .object(o)
                }
                return json(f, path: "")
            }
            if type == "control_response" {
                var f = value
                if var outer = f.objectValue, var resp = outer["response"]?.objectValue, var body = resp["response"]?.objectValue {
                    if body["mcp_response"] != nil { body["mcp_response"] = truncateMCP(body["mcp_response"]) ?? .null }
                    if let eff = body.removeValue(forKey: "effective") {
                        body["effective_keys"] = .array((eff.objectValue?.keys.sorted() ?? []).map(JSONValue.string))
                    }
                    if let srcs = body.removeValue(forKey: "sources") {
                        body["sources_keys"] = .array((srcs.arrayValue ?? []).compactMap { s in
                            guard let s = s.objectValue else { return nil }
                            return .object(["source": s["source"] ?? .null,
                                            "keys": .array((s["settings"]?.objectValue?.keys.sorted() ?? []).map(JSONValue.string))])
                        })
                    }
                    resp["response"] = urls(.object(body))
                    outer["response"] = .object(resp)
                    f = .object(outer)
                }
                return json(f, path: "")
            }
            return json(value, path: "")
        }
    }
}
