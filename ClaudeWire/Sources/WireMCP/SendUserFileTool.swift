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
        guard let files = arguments["files"]?.arrayValue, files.allSatisfy({ $0.stringValue != nil }), !files.isEmpty else { throw MCPArgumentError("files must be a non-empty array of strings") }
        guard let status = arguments["status"]?.stringValue, ["normal", "proactive"].contains(status) else { throw MCPArgumentError("status must be 'normal' or 'proactive'") }
        let display = arguments["display"]?.stringValue
        if let display, !["render", "attach"].contains(display) { throw MCPArgumentError("display must be 'render' or 'attach'") }
        let root = context.cwd.standardizedFileURL
        var resolved: [URL] = []
        for f in files.compactMap(\.stringValue) {
            let url = (f.hasPrefix("/") ? URL(fileURLWithPath: f) : root.appendingPathComponent(f)).standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: url.path) else { return .text("Cannot read \(f): no such file or not readable", isError: true) }
            resolved.append(url)
        }
        let names = resolved.map(\.lastPathComponent).joined(separator: ", ")
        return .text("Sent \(resolved.count) file\(resolved.count == 1 ? "" : "s") to the user: \(names)",
                     invocation: .sentFile(paths: resolved, caption: arguments["caption"]?.stringValue, status: status, display: display))
    }
}
