import Foundation
import ClaudeWire
import FleetKit

// MARK: - The form a tool's result takes

/// One tool result, in the shape the engine's own renderer states it (parity §41.16.6, §41.16.7).
///
/// A value and not a view, because the sentence is the part worth asserting: parity's table names
/// the singular/plural rule, the error normalisation and the "raw text behind a disclosure" rule,
/// and each of those is a property of the sentence rather than of the layout that draws it.
struct ToolResultForm: Equatable {

    /// The one line under the call. `Read 12 lines`, `Found 1 file`, `Invalid tool parameters`.
    var headline: String

    /// A second line the table names for some tools: the read range, the write path, the count of
    /// files a match count is spread across. Nil when the tool's form has none.
    var detail: String?

    /// What the engine actually returned, kept whole for the disclosure. Parity §41.16.6: the
    /// normalised sentence replaces the raw text on screen and never destroys it.
    var raw: String?

    var isError: Bool = false

    /// The result is not in yet — the call is a `tool_use` with no `tool_result` (§8).
    var isRunning: Bool = false
}

/// The eleven per-tool forms C6.1 implements, and the generic one every other tool takes.
///
/// **Where the forms come from.** `docs/tui-parity/areas/41-tui-rendering.md` §41.16.7 tabulates
/// about thirty of the engine's own renderers; this implements the eleven §8 of the child spec
/// names — `Read`, `Edit`, `Write`, `Bash`, `Grep`, `Glob`, `Agent`, `WebFetch`, `WebSearch`,
/// `TodoWrite` and the `mcp__<server>__<tool>` family — and the rest take the generic form, with the
/// parity table as the map for the remainder (tracker 135).
enum ToolResultForms {

    // MARK: - The entry point

    static func form(for call: ToolCallItem) -> ToolResultForm {
        // "Running" is not a flag the engine sends. Parity §41.16.2 records that
        // `set_in_progress_tool_use_ids` is dropped before the wire, so running is exactly "a
        // `tool_use` with no matching `tool_result`" — which is the status C3 computes.
        if call.status == .running { return ToolResultForm(headline: running(call), isRunning: true) }
        if call.status == .denied { return denied(call) }
        if call.isError == true || call.status == .failed { return error(call) }
        return completed(call)
    }

    // MARK: - Error normalisation (parity §41.16.6)

    /// `InputValidationError:` → *Invalid tool parameters*; a result that is not a string at all →
    /// *Tool execution failed*; anything else prefixed `Error: ` unless it already carries that
    /// prefix or `Cancelled: `. The raw text survives in `raw`, which the row puts behind a
    /// disclosure.
    static func error(_ call: ToolCallItem) -> ToolResultForm {
        let raw = text(of: call.result)
        return ToolResultForm(headline: errorHeadline(raw), raw: raw, isError: true)
    }

    static func errorHeadline(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Tool execution failed" }
        if raw.contains("InputValidationError: ") { return "Invalid tool parameters" }
        let first = firstLine(raw)
        if first.hasPrefix("Error: ") || first.hasPrefix("Cancelled: ") { return first }
        return "Error: " + first
    }

    /// A call the host refused. Parity gives `Edit` its own sentence; every other tool reads as the
    /// refusal it was.
    static func denied(_ call: ToolCallItem) -> ToolResultForm {
        if case .edit(let input) = call.input {
            return ToolResultForm(headline: "User rejected update to \(input.filePath)", isError: true)
        }
        return ToolResultForm(headline: "User rejected \(userFacingName(of: call.name))", isError: true)
    }

    // MARK: - The running forms

    static func running(_ call: ToolCallItem) -> String {
        switch call.name {
        case "Bash": "Running…"
        case "Agent": "Initializing…"
        case "WebFetch": "Fetching…"
        case "WebSearch":
            if case .webSearch(let input) = call.input { "Searching: \(input.query)" } else { "Searching…" }
        default: "Running…"
        }
    }

    // MARK: - The completed forms

    private static func completed(_ call: ToolCallItem) -> ToolResultForm {
        let body = text(of: call.result)
        switch call.name {
        case "Read": return read(call, body)
        case "Edit": return edit(call)
        case "Write": return write(call)
        case "Bash": return bash(call, body)
        case "Grep", "Glob": return search(call, body)
        case "Agent": return agent(call, body)
        case "WebFetch": return webFetch(call, body)
        case "WebSearch": return webSearch(call, body)
        case "TodoWrite": return todoWrite(call)
        default:
            if let mcp = mcpFamily(of: call.name) { return self.mcp(mcp, body) }
            return generic(body)
        }
    }

    /// `Read <bold N> line(s)`, with the header's ` · lines A-B` when the call named a range, and
    /// the image and PDF forms the table lists beside it.
    static func read(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        guard case .read(let input) = call.input else { return generic(body) }
        if let kind = call.structuredResult?["type"]?.stringValue, kind == "image" || kind == "pdf" {
            return ToolResultForm(headline: kind == "image" ? "Read image" : "Read PDF", raw: body)
        }
        let lines = lineCount(body)
        var detail: String?
        if let offset = input.offset {
            let last = input.limit.map { offset + $0 - 1 }
            detail = last.map { "lines \(offset)-\($0)" } ?? "lines from \(offset)"
        }
        return ToolResultForm(headline: "Read \(count(lines, "line"))", detail: detail, raw: body)
    }

    /// `Added N lines, removed M lines` — parity's capitalisation trick: the first clause is
    /// capitalised and the second is not.
    static func edit(_ call: ToolCallItem) -> ToolResultForm {
        let (added, removed) = patchCounts(call.structuredResult)
        var headline: String
        switch (added, removed) {
        case (0, 0): headline = "Edited"
        case (let a, 0): headline = "Added \(count(a, "line"))"
        case (0, let r): headline = "Removed \(count(r, "line"))"
        case (let a, let r): headline = "Added \(count(a, "line")), removed \(count(r, "line"))"
        }
        var detail: String?
        if case .edit(let input) = call.input { detail = input.filePath }
        return ToolResultForm(headline: headline, detail: detail)
    }

    /// `Wrote <bold N> lines to <bold path>`.
    static func write(_ call: ToolCallItem) -> ToolResultForm {
        guard case .write(let input) = call.input else { return generic(nil) }
        let lines = input.content.isEmpty ? 0 : input.content.split(separator: "\n", omittingEmptySubsequences: false).count
        return ToolResultForm(headline: "Wrote \(count(lines, "line")) to \(input.filePath)", raw: input.content)
    }

    /// `Done`, `(No output)`, or `Running in the background (↓ to manage)`.
    ///
    /// The live "last five lines while running" the terminal shows is **not** available here:
    /// parity §41.16.7 records that `tool_progress` frames are emitted only under
    /// `CLAUDE_CODE_REMOTE`, so a background command's output comes from the registry's
    /// `TaskOutputTailer` and a foreground one arrives whole at completion.
    static func bash(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        if case .bash(let input) = call.input, input.runInBackground == true {
            return ToolResultForm(headline: "Running in the background", raw: body)
        }
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResultForm(headline: "(No output)")
        }
        return ToolResultForm(headline: "Done", detail: "\(count(lineCount(body), "line")) of output", raw: body)
    }

    /// `Grep` and `Glob` share one renderer and three modes: `content` counts lines, `count` counts
    /// matches across files, and the default counts files. The singular is parity's own — the
    /// trailing `s` is sliced off at one.
    static func search(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        let found = lineCount(body)
        var mode = "files_with_matches"
        if case .grep(let input) = call.input, let named = input.outputMode { mode = named }
        switch mode {
        case "content":
            return ToolResultForm(headline: "Found \(count(found, "line"))", raw: body)
        case "count":
            let files = matchedFiles(body)
            return ToolResultForm(headline: "Found \(count(matchTotal(body), "match", plural: "matches"))",
                                  detail: files > 0 ? "across \(count(files, "file"))" : nil,
                                  raw: body)
        default:
            return ToolResultForm(headline: "Found \(count(found, "file"))", raw: body)
        }
    }

    /// `Done (N tool uses)` — the chip beside it carries the type, the status and the elapsed time,
    /// so this is the result half alone.
    static func agent(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        let uses = call.structuredResult?["totalToolUseCount"]?.intValue.map(Int.init)
        return ToolResultForm(headline: uses.map { "Done (\(count($0, "tool use")))" } ?? "Done", raw: body)
    }

    /// `Received <size> (<status>)`.
    static func webFetch(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        let size = ByteCountFormatter.string(fromByteCount: Int64(body?.utf8.count ?? 0), countStyle: .file)
        let status = call.structuredResult?["code"]?.intValue ?? call.structuredResult?["status"]?.intValue
        return ToolResultForm(headline: status.map { "Received \(size) (\($0))" } ?? "Received \(size)", raw: body)
    }

    /// `Did <n> search(es)`.
    static func webSearch(_ call: ToolCallItem, _ body: String?) -> ToolResultForm {
        let queries = call.structuredResult?["queries"]?.arrayValue?.count ?? 1
        return ToolResultForm(headline: "Did \(count(queries, "search", plural: "searches"))", raw: body)
    }

    /// The one form that **exceeds** the terminal: parity §41.16.7 records that `TodoWrite` has no
    /// result renderer at all there, so the todos surface only in a progress bar. Here the list the
    /// call itself carries is the row.
    static func todoWrite(_ call: ToolCallItem) -> ToolResultForm {
        let todos = call.rawInput["todos"]?.arrayValue ?? []
        let completed = todos.filter { $0["status"]?.stringValue == "completed" }.count
        return ToolResultForm(headline: "Updated \(count(todos.count, "todo"))",
                              detail: todos.isEmpty ? nil : "\(completed) completed")
    }

    /// `mcp__<server>__<tool>`, split into the two names the row shows instead of the raw one.
    static func mcpFamily(of name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts.dropFirst().joined(separator: "__"))
    }

    static func mcp(_ family: (server: String, tool: String), _ body: String?) -> ToolResultForm {
        guard let body, !body.isEmpty else {
            return ToolResultForm(headline: "(No content)", detail: family.server)
        }
        return ToolResultForm(headline: "\(family.tool) · \(family.server)",
                              detail: "\(count(lineCount(body), "line"))", raw: body)
    }

    static func generic(_ body: String?) -> ToolResultForm {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResultForm(headline: "(No output)")
        }
        return ToolResultForm(headline: "Done", detail: "\(count(lineCount(body), "line"))", raw: body)
    }

    // MARK: - Reading a result

    /// A result's text, whether the engine wrote a bare string or the block array it uses when a
    /// tool returns more than prose. Nil is "there is no text here", which is what makes
    /// *Tool execution failed* reachable.
    static func text(of value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        if let blocks = value.arrayValue {
            let texts = blocks.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        if let text = value["text"]?.stringValue { return text }
        return nil
    }

    /// The name a row shows for a tool: the MCP family's own tool name, or the engine's.
    static func userFacingName(of name: String) -> String { mcpFamily(of: name)?.tool ?? name }

    // MARK: - Counting

    /// Parity's singular rule, which the engine implements by slicing the trailing `s` at one.
    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(plural ?? noun + "s")"
    }

    static func lineCount(_ body: String?) -> Int {
        guard let body, !body.isEmpty else { return 0 }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.count
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// Added and removed line counts from `structuredPatch`, the shape §41.16.8 names.
    static func patchCounts(_ structured: JSONValue?) -> (added: Int, removed: Int) {
        guard let hunks = structured?["structuredPatch"]?.arrayValue else { return (0, 0) }
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk["lines"]?.arrayValue ?? [] {
                guard let text = line.stringValue else { continue }
                if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    /// `count` mode's two numbers: the engine prints `<path>:<n>` per file.
    private static func matchTotal(_ body: String?) -> Int {
        guard let body else { return 0 }
        return body.split(separator: "\n").reduce(0) { total, line in
            total + (line.split(separator: ":").last.flatMap { Int($0) } ?? 0)
        }
    }

    private static func matchedFiles(_ body: String?) -> Int { lineCount(body) }
}
