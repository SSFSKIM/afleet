import Foundation
import WireFrames

/// Mirrors the built-in SendUserFile shape: files[], caption?, status, display? (parent §6.8).
/// Verified against the bundled tool at ~/claude-code-bundle/2.1.258/cli.pretty.js:485919
/// (files: array of string, min 1; caption optional; status enum normal|proactive, required;
/// display enum render|attach, optional).
public struct SendUserFileTool: MCPTool {
    public init() {}
    public var name: String { "send_user_file" }
    public var description: String { "Send one or more files to the user. Use status 'proactive' for unsolicited results and 'normal' when replying; display 'render' opens an inline preview, 'attach' offers a download." }
    public var inputSchema: JSONValue {
        .object(["type": .string("object"),
                 "properties": .object([
                    "files": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Paths, absolute or relative to the working directory")]),
                    "caption": .object(["type": .string("string")]),
                    "status": .object(["type": .string("string"), "enum": .array([.string("normal"), .string("proactive")])]),
                    "display": .object(["type": .string("string"), "enum": .array([.string("render"), .string("attach")])]),
                 ]),
                 "required": .array([.string("files"), .string("status")])])
    }
    public func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult {
        // A bare string is coerced to a one-element array, mirroring the built-in's Zod preprocess
        // (`fs((e) => typeof e === "string" ? [e] : e, R(i()).min(1))`, bundle 2.1.258:485919). The
        // model was trained against a runtime that accepts this, so its output distribution includes
        // it; and "a.txt" means exactly ["a.txt"], so rejecting it buys no disambiguation and costs a
        // turn. Anything else non-conforming is still a protocol error.
        let files: [JSONValue]
        switch arguments["files"] {
        case .string(let one): files = [.string(one)]
        case .array(let many): files = many
        default: throw MCPArgumentError("files must be a non-empty array of strings")
        }
        guard !files.isEmpty, files.allSatisfy({ $0.stringValue != nil }) else { throw MCPArgumentError("files must be a non-empty array of strings") }
        guard let status = arguments["status"]?.stringValue, ["normal", "proactive"].contains(status) else { throw MCPArgumentError("status must be 'normal' or 'proactive'") }
        let display = arguments["display"]?.stringValue
        if let display, !["render", "attach"].contains(display) { throw MCPArgumentError("display must be 'render' or 'attach'") }
        let root = context.cwd.standardizedFileURL
        var resolved: [URL] = []
        for f in files.compactMap(\.stringValue) {
            // `~` is expanded before the absolute-path test, so `~/report.pdf` does not become
            // `<cwd>/~/report.pdf`. A relative path resolves against the channel cwd and a `..` may
            // walk out of it; that is intended, not a hole — this tool deliberately accepts any
            // absolute path the model can read, so confining the relative form would be an
            // inconsistency rather than a boundary.
            let expanded = (f as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)).standardizedFileURL
            // isReadableFile(atPath:) is also true for a readable directory, which would report a send
            // Task 10 cannot perform; the built-in resolves per-file metadata and cannot reach that state.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
                return .text("Cannot send \(f): no such file, not readable, or a directory", isError: true)
            }
            resolved.append(url)
        }
        let names = resolved.map(\.lastPathComponent).joined(separator: ", ")
        return .text("Sent \(resolved.count) file\(resolved.count == 1 ? "" : "s") to the user: \(names)",
                     invocation: .sentFile(paths: resolved, caption: arguments["caption"]?.stringValue, status: status, display: display))
    }
}
