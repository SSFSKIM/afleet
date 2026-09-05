import Foundation

public enum ShellEnvelope {
    public static let perStreamCap = 65_536
    /// Every control tag neutralized, opening or closing, case-insensitive, whitespace-tolerant (§6.6).
    public static let neutralizedTags: [String] = [
        "bash-input", "bash-stdout", "bash-stderr", "bash-exit-code", "system-reminder", "task-notification", "agent-message",
        "teammate-message", "cross-session-message", "remote-review", "slack-ping", "slack-tag-message", "fetched-web-content",
        "coordinator-relay", "artifact-type-instructions", "local-command-stdout", "local-command-stderr", "command-message", "command-name",
    ]
    private static let tagRegex: NSRegularExpression = {
        let alternatives = neutralizedTags.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // "<" optional whitespace, optional "/", optional whitespace, tag name, then a non-name char (whitespace, ">" or "/")
        return try! NSRegularExpression(pattern: #"<\s*/?\s*(?:"# + alternatives + #")(?=[\s>/])"#, options: [.caseInsensitive])
    }()
    private static let channelRegex = try! NSRegularExpression(pattern: #"<\s*channel\s+source\s*="#, options: [.caseInsensitive])
    private static let turnMarker = try! NSRegularExpression(pattern: #"(?m)^(Human|Assistant):"#)
    private static let forgedPrefix = try! NSRegularExpression(pattern: #"(?m)^(\[harness|\[Subagent hand-back\]|NOTE: this agent stopped at its )"#)

    public static func wrap(command: String, stdout: Data, stderr: Data) -> String {
        let (out, outNote) = cap(stdout, name: "stdout")
        let (err, errNote) = cap(stderr, name: "stderr")
        return "<bash-input>\(neutralize(command))</bash-input>\n<bash-stdout>\(neutralize(out))\(outNote)</bash-stdout>\n<bash-stderr>\(neutralize(err))\(errNote)</bash-stderr>"
    }
    static func cap(_ data: Data, name: String) -> (String, String) {
        let kept = data.count > perStreamCap ? data.prefix(perStreamCap) : data[...]
        let text = String(decoding: kept, as: UTF8.self)     // invalid sequences become U+FFFD
        let note = data.count > perStreamCap ? "\n[afleet: \(data.count - perStreamCap) bytes of \(name) omitted]" : ""
        return (text, note)
    }
    public static func neutralize(_ s: String) -> String {
        var r = s
        func sub(_ re: NSRegularExpression, _ transform: (String) -> String) {
            let ns = r as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: r, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += transform(ns.substring(with: m.range))
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            r = out
        }
        sub(tagRegex) { "&lt;" + $0.dropFirst() }
        sub(channelRegex) { "&lt;" + $0.dropFirst() }
        sub(turnMarker) { String($0.dropLast()) + "&#58;" }
        sub(forgedPrefix) { "\u{200B}" + $0 }          // zero-width space breaks the line-start match the engine looks for
        return r
    }
}
