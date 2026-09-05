import Foundation
import ClaudeWire

/// Which field the displayed title came from. `fallback` covers both terminal branches: `Autonomous session` and the
/// first eight characters of the session id.
public enum TitleSource: String, Sendable, Codable {
    case agentName, customTitle, aiTitle, summary, firstPrompt, fallback
}

/// The engine's `getLogDisplayTitle` (§35.19.7; 2.1.258 `$ke`, line 54145), transcribed.
///
/// ```js
/// let r = t.firstPrompt?.startsWith(`<${iO}>`), o = t.firstPrompt ? XBe(t.firstPrompt) : "", i = o && !r,
///     a = t.agentName || t.customTitle || t.aiTitle || t.summary || (i ? o : void 0) || e
///         || (r ? "Autonomous session" : void 0) || (t.sessionId ? t.sessionId.slice(0, 8) : "") || "";
/// return bkt(a).trim();
/// ```
///
/// `iO` is `"tick"`, so the autonomous branch is a first prompt that opens with `<tick>`. `x` is
/// `/<([a-z][\w-]*)(?:\s[^>]*)?>[\s\S]*?<\/\1>\n?/g`; `XBe` strips it and trims, `bkt` strips, trims, and returns the
/// input untouched when stripping emptied it. The engine's second parameter `e` — a title the caller already had — has
/// no counterpart here and is dropped: this index reads only the file.
///
/// JavaScript's `||` treats `""` as falsy, so a source that is present but empty falls through, and so does a first
/// prompt that is nothing but an XML-ish block.
public enum TitlePrecedence {
    public static let autonomousSession = "Autonomous session"
    /// The tag whose presence at the head of the first prompt marks an autonomous session (`iO`, 2.1.258 line 54013).
    public static let autonomousTag = "tick"

    public static func title(agentName: String?, customTitle: String?, aiTitle: String?, summary: String?,
                             firstPrompt: String?, sessionID: SessionID) -> (String, TitleSource) {
        let opensWithTag = firstPrompt?.hasPrefix("<\(autonomousTag)>") ?? false
        let strippedPrompt = firstPrompt.map(stripped) ?? ""
        let usablePrompt = (!strippedPrompt.isEmpty && !opensWithTag) ? strippedPrompt : nil

        let chosen: (String, TitleSource)
        if let value = present(agentName) { chosen = (value, .agentName) }
        else if let value = present(customTitle) { chosen = (value, .customTitle) }
        else if let value = present(aiTitle) { chosen = (value, .aiTitle) }
        else if let value = present(summary) { chosen = (value, .summary) }
        else if let value = usablePrompt { chosen = (value, .firstPrompt) }
        else if opensWithTag { chosen = (autonomousSession, .fallback) }
        else { chosen = (String(sessionID.description.prefix(8)), .fallback) }

        return (display(chosen.0), chosen.1)
    }

    private static func present(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `bkt(a).trim()`: the strip wins unless it emptied the string, in which case the original stands.
    private static func display(_ value: String) -> String {
        let s = stripped(value)
        return s.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }

    /// `XBe`: every `<tag …>…</tag>` block removed, then trimmed. `\w` is JavaScript's ASCII class, spelled out here
    /// because ICU's `\w` is Unicode-aware and would match more.
    private static func stripped(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        let cleaned = blockPattern.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try — a literal pattern that compiles or the type is broken.
        try! NSRegularExpression(pattern: "<([a-z][A-Za-z0-9_-]*)(?:\\s[^>]*)?>[\\s\\S]*?</\\1>\\n?")
    }()
}
