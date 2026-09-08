import Foundation
import XCTest
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 4: the per-tool result forms, the error normalisation and the running rule.
///
/// The forms come from `docs/tui-parity/areas/41-tui-rendering.md` §41.16.6 and §41.16.7, which
/// tabulate the engine's own renderers. Every input here is invented (§11); what is asserted is the
/// sentence shape, and — where the parity table names one — the singular/plural rule.
final class ToolResultFormTests: XCTestCase {

    // MARK: - Errors

    /// Parity §41.16.6's normalisation, all three arms, with the raw text surviving behind the
    /// disclosure.
    func testErrorsAreNormalised() {
        let validation = InventedItems.toolCall("Read", result: .string("InputValidationError: offset must be ≥ 1"),
                                                isError: true, status: .failed)
        XCTAssertEqual(ToolResultForms.form(for: validation).headline, "Invalid tool parameters",
                       "an InputValidationError reads \(ToolResultForms.form(for: validation).headline)")
        XCTAssertNotNil(ToolResultForms.form(for: validation).raw,
                        "the normalised error dropped the raw text the disclosure shows")

        // A result that is not a string at all — the shape a tool returns when it fails structurally.
        let structural = InventedItems.toolCall("Bash", result: .object(["code": .integer(2)]),
                                                isError: true, status: .failed)
        XCTAssertEqual(ToolResultForms.form(for: structural).headline, "Tool execution failed",
                       "a non-string result reads \(ToolResultForms.form(for: structural).headline)")

        let plain = InventedItems.toolCall("Bash", result: .string("no such invented file"),
                                           isError: true, status: .failed)
        XCTAssertEqual(ToolResultForms.form(for: plain).headline, "Error: no such invented file",
                       "an ordinary failure reads \(ToolResultForms.form(for: plain).headline)")
        XCTAssertEqual(ToolResultForms.errorHeadline("Cancelled: an invented interruption"),
                       "Cancelled: an invented interruption",
                       "a cancellation was prefixed a second time")
        XCTAssertTrue(ToolResultForms.form(for: plain).isError, "a failed call did not report itself failed")
    }

    // MARK: - Running

    /// Running is inferred, not sent.
    ///
    /// Parity §41.16.2: `set_in_progress_tool_use_ids` is in the dropped list, so it never reaches
    /// the wire and "in progress" is exactly "a `tool_use` with no matching `tool_result`". C3
    /// computes that as `ToolCallItem.status == .running`, and the matching result flips it.
    func testRunningIsAnUnmatchedToolUse() {
        let running = InventedItems.toolCall("Bash", status: .running)
        let form = ToolResultForms.form(for: running)
        XCTAssertTrue(form.isRunning, "an unmatched tool_use did not render as running")
        XCTAssertEqual(form.headline, "Running…", "a running Bash reads \(form.headline)")

        let done = InventedItems.toolCall("Bash", result: .string("an invented line of output"), status: .completed)
        XCTAssertFalse(ToolResultForms.form(for: done).isRunning,
                       "the matching tool_result left the call running")
        XCTAssertEqual(ToolResultForms.form(for: done).headline, "Done",
                       "a finished Bash reads \(ToolResultForms.form(for: done).headline)")

        // The three tools whose running forms parity names separately.
        XCTAssertEqual(ToolResultForms.running(InventedItems.toolCall("Agent", status: .running)), "Initializing…")
        XCTAssertEqual(ToolResultForms.running(InventedItems.toolCall("WebFetch", status: .running)), "Fetching…")
        XCTAssertEqual(ToolResultForms.running(InventedItems.toolCall("WebSearch",
                                                                     input: .object(["query": .string("an invented query")]),
                                                                     status: .running)),
                       "Searching: an invented query")
    }

    // MARK: - Read

    /// `Read <bold N> line(s)` with the header's ` · lines A-B`, and the singular at one.
    func testReadFormSingularAndPlural() {
        let many = InventedItems.toolCall("Read",
                                          input: .object(["file_path": .string("/invented/path/notes.md"),
                                                          "offset": .integer(20), "limit": .integer(3)]),
                                          result: .string("one\ntwo\nthree"))
        let form = ToolResultForms.form(for: many)
        XCTAssertEqual(form.headline, "Read 3 lines", "a three-line read reads \(form.headline)")
        XCTAssertEqual(form.detail, "lines 20-22", "the read range reads \(form.detail ?? "nothing")")

        let one = InventedItems.toolCall("Read",
                                         input: .object(["file_path": .string("/invented/path/notes.md")]),
                                         result: .string("one"))
        XCTAssertEqual(ToolResultForms.form(for: one).headline, "Read 1 line",
                       "a one-line read reads \(ToolResultForms.form(for: one).headline)")
        XCTAssertNil(ToolResultForms.form(for: one).detail,
                     "a read with no offset was given a range anyway")
    }

    // MARK: - Edit and Write

    /// Parity's capitalisation trick — `Added 2 lines, removed 1 line` — and `Wrote N lines to
    /// <path>`, plus the rejection sentence `Edit` alone has.
    func testEditAndWriteForms() {
        let patch = JSONValue.object([
            "structuredPatch": .array([.object(["lines": .array([.string("+one"), .string("+two"), .string("-old")])])]),
        ])
        let edit = InventedItems.toolCall("Edit",
                                          input: .object(["file_path": .string("/invented/path/file.swift"),
                                                          "old_string": .string("old"), "new_string": .string("new")]),
                                          result: .string("ok"), structured: patch)
        XCTAssertEqual(ToolResultForms.form(for: edit).headline, "Added 2 lines, removed 1 line",
                       "the edit reads \(ToolResultForms.form(for: edit).headline)")

        let rejected = InventedItems.toolCall("Edit",
                                              input: .object(["file_path": .string("/invented/path/file.swift"),
                                                              "old_string": .string("old"), "new_string": .string("new")]),
                                              status: .denied)
        XCTAssertEqual(ToolResultForms.form(for: rejected).headline,
                       "User rejected update to /invented/path/file.swift",
                       "the rejection reads \(ToolResultForms.form(for: rejected).headline)")

        let write = InventedItems.toolCall("Write",
                                           input: .object(["file_path": .string("/invented/path/new.txt"),
                                                           "content": .string("one\ntwo")]),
                                           result: .string("ok"))
        XCTAssertEqual(ToolResultForms.form(for: write).headline, "Wrote 2 lines to /invented/path/new.txt",
                       "the write reads \(ToolResultForms.form(for: write).headline)")
    }

    // MARK: - Bash

    /// `Done`, `(No output)` and the background sentence. The live "last five lines" the terminal
    /// shows is deliberately absent: parity §41.16.7 records that `tool_progress` frames are emitted
    /// only under `CLAUDE_CODE_REMOTE`, so a foreground command's output arrives whole at completion
    /// and a background one is the registry's `TaskOutputTailer`'s.
    func testBashForms() {
        let quiet = InventedItems.toolCall("Bash",
                                           input: .object(["command": .string("an-invented-command")]),
                                           result: .string(""))
        XCTAssertEqual(ToolResultForms.form(for: quiet).headline, "(No output)",
                       "a silent command reads \(ToolResultForms.form(for: quiet).headline)")

        let noisy = InventedItems.toolCall("Bash",
                                           input: .object(["command": .string("an-invented-command")]),
                                           result: .string("one\ntwo\nthree"))
        XCTAssertEqual(ToolResultForms.form(for: noisy).detail, "3 lines of output",
                       "the output count reads \(ToolResultForms.form(for: noisy).detail ?? "nothing")")

        let background = InventedItems.toolCall("Bash",
                                                input: .object(["command": .string("an-invented-command"),
                                                                "run_in_background": .bool(true)]),
                                                result: .string("started"))
        XCTAssertEqual(ToolResultForms.form(for: background).headline, "Running in the background",
                       "a backgrounded command reads \(ToolResultForms.form(for: background).headline)")
    }

    // MARK: - Grep and Glob

    /// One renderer, three modes, and the singular parity states by slicing the trailing `s`.
    func testGrepAndGlobShareOneFormWithItsSingularRule() {
        let glob = InventedItems.toolCall("Glob",
                                          input: .object(["pattern": .string("**/*.invented")]),
                                          result: .string("/invented/a\n/invented/b"))
        XCTAssertEqual(ToolResultForms.form(for: glob).headline, "Found 2 files",
                       "a two-file glob reads \(ToolResultForms.form(for: glob).headline)")

        let one = InventedItems.toolCall("Glob",
                                         input: .object(["pattern": .string("**/*.invented")]),
                                         result: .string("/invented/a"))
        XCTAssertEqual(ToolResultForms.form(for: one).headline, "Found 1 file",
                       "a one-file glob reads \(ToolResultForms.form(for: one).headline)")

        let content = InventedItems.toolCall("Grep",
                                             input: .object(["pattern": .string("invented"),
                                                             "output_mode": .string("content")]),
                                             result: .string("a:1:invented\nb:2:invented\nc:3:invented"))
        XCTAssertEqual(ToolResultForms.form(for: content).headline, "Found 3 lines",
                       "a content-mode grep reads \(ToolResultForms.form(for: content).headline)")

        let counted = InventedItems.toolCall("Grep",
                                             input: .object(["pattern": .string("invented"),
                                                             "output_mode": .string("count")]),
                                             result: .string("/invented/a:2\n/invented/b:5"))
        let form = ToolResultForms.form(for: counted)
        XCTAssertEqual(form.headline, "Found 7 matches", "a count-mode grep reads \(form.headline)")
        XCTAssertEqual(form.detail, "across 2 files", "the secondary count reads \(form.detail ?? "nothing")")
    }

    // MARK: - Agent, WebFetch and WebSearch

    func testAgentWebFetchAndWebSearchForms() {
        let agent = InventedItems.toolCall("Agent",
                                           input: .object(["description": .string("an invented errand"),
                                                           "prompt": .string("an invented brief")]),
                                           result: .string("done"),
                                           structured: .object(["totalToolUseCount": .integer(7)]))
        XCTAssertEqual(ToolResultForms.form(for: agent).headline, "Done (7 tool uses)",
                       "a finished agent reads \(ToolResultForms.form(for: agent).headline)")

        let fetch = InventedItems.toolCall("WebFetch",
                                           input: .object(["url": .string("https://invented.example/page")]),
                                           result: .string(String(repeating: "x", count: 2_048)),
                                           structured: .object(["code": .integer(200)]))
        XCTAssertTrue(ToolResultForms.form(for: fetch).headline.hasPrefix("Received "),
                      "a fetch reads \(ToolResultForms.form(for: fetch).headline)")
        XCTAssertTrue(ToolResultForms.form(for: fetch).headline.hasSuffix("(200)"),
                      "the fetch dropped its status: \(ToolResultForms.form(for: fetch).headline)")

        let search = InventedItems.toolCall("WebSearch",
                                            input: .object(["query": .string("an invented query")]),
                                            result: .string("one result"),
                                            structured: .object(["queries": .array([.string("an invented query")])]))
        XCTAssertEqual(ToolResultForms.form(for: search).headline, "Did 1 search",
                       "one search reads \(ToolResultForms.form(for: search).headline)")
    }

    // MARK: - TodoWrite, the MCP family and the generic form

    /// `TodoWrite` is **absent** from parity's renderer table — the terminal shows todos only in a
    /// progress bar — so this is the one form that deliberately exceeds it, read from the call's own
    /// input. The MCP family is keyed on `mcp__<server>__<tool>`, and every tool outside the eleven
    /// takes the generic form (tracker 135 carries the remainder, with §41.16.7 as its map).
    func testTodoWriteMCPAndGenericForms() {
        let todos = InventedItems.toolCall("TodoWrite",
                                           input: .object(["todos": .array([
                                               .object(["content": .string("an invented step"), "status": .string("completed")]),
                                               .object(["content": .string("a second invented step"), "status": .string("pending")]),
                                           ])]),
                                           result: .string("ok"))
        XCTAssertEqual(ToolResultForms.form(for: todos).headline, "Updated 2 todos",
                       "the todo write reads \(ToolResultForms.form(for: todos).headline)")
        XCTAssertEqual(ToolResultForms.form(for: todos).detail, "1 completed",
                       "the todo detail reads \(ToolResultForms.form(for: todos).detail ?? "nothing")")

        let family = ToolResultForms.mcpFamily(of: "mcp__invented-server__invented_tool")
        XCTAssertEqual(family?.server, "invented-server", "the MCP server name did not parse")
        XCTAssertEqual(family?.tool, "invented_tool", "the MCP tool name did not parse")
        XCTAssertNil(ToolResultForms.mcpFamily(of: "Read"), "a first-party tool parsed as an MCP one")

        let mcp = InventedItems.toolCall("mcp__invented-server__invented_tool", result: .string("one\ntwo"))
        XCTAssertEqual(ToolResultForms.form(for: mcp).headline, "invented_tool · invented-server",
                       "the MCP row reads \(ToolResultForms.form(for: mcp).headline)")
        let empty = InventedItems.toolCall("mcp__invented-server__invented_tool", result: .string(""))
        XCTAssertEqual(ToolResultForms.form(for: empty).headline, "(No content)",
                       "an empty MCP result reads \(ToolResultForms.form(for: empty).headline)")

        let generic = InventedItems.toolCall("AnInventedTool", result: .string("one\ntwo"))
        XCTAssertEqual(ToolResultForms.form(for: generic).headline, "Done",
                       "an unmodelled tool reads \(ToolResultForms.form(for: generic).headline)")
    }
}
