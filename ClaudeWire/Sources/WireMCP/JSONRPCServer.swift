import Foundation
import WireFrames

public struct MCPToolContext: Sendable { public var cwd: URL; public init(cwd: URL) { self.cwd = cwd } }

public enum HostToolInvocation: Hashable, Sendable {
    case sentFile(paths: [URL], caption: String?, status: String, display: String?)
}
public struct MCPToolResult: Sendable {
    public var content: [JSONValue]; public var isError: Bool; public var hostInvocation: HostToolInvocation?
    public init(content: [JSONValue], isError: Bool = false, hostInvocation: HostToolInvocation? = nil) { self.content = content; self.isError = isError; self.hostInvocation = hostInvocation }
    public static func text(_ s: String, isError: Bool = false, invocation: HostToolInvocation? = nil) -> MCPToolResult {
        .init(content: [.object(["type": .string("text"), "text": .string(s)])], isError: isError, hostInvocation: invocation)
    }
}
public struct MCPArgumentError: Error, Sendable { public var message: String; public init(_ m: String) { message = m } }

public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    /// Throws MCPArgumentError for malformed arguments (a JSON-RPC -32602); returns isError results for runtime failures.
    func call(arguments: JSONValue, context: MCPToolContext) async throws -> MCPToolResult
}

public enum MCPReply: Sendable { case response(JSONRPCMessage), notificationAck }

public actor AfleetMCPServer {
    public let serverVersion: String
    public let cwd: URL
    private let tools: [String: any MCPTool]
    private var inFlight: [JSONRPCID: Task<MCPToolResult, any Error>] = [:]

    public init(serverVersion: String, cwd: URL, tools: [any MCPTool]) {
        self.serverVersion = serverVersion; self.cwd = cwd
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func handle(_ message: JSONRPCMessage) async -> (MCPReply, HostToolInvocation?) {
        switch message {
        case .notification(let n):
            if n.method == "notifications/cancelled", let idv = n.params?["requestId"] {
                let id: JSONRPCID? = idv.intValue.map(JSONRPCID.number) ?? idv.stringValue.map(JSONRPCID.string)
                if let id { inFlight[id]?.cancel() }
            }
            return (.notificationAck, nil)
        case .response, .error:
            return (.notificationAck, nil)             // the CLI never sends these to a server; acknowledge and move on
        case .request(let r):
            switch r.method {
            case "initialize":
                return (.response(.response(.init(id: r.id, result: .object([
                    "protocolVersion": r.params?["protocolVersion"] ?? .string("2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("afleet"), "version": .string(serverVersion)]),
                ])))), nil)
            case "ping": return (.response(.response(.init(id: r.id, result: .object([:])))), nil)
            case "tools/list":
                let list = tools.values.sorted { $0.name < $1.name }.map { t -> JSONValue in
                    .object(["name": .string(t.name), "description": .string(t.description), "inputSchema": t.inputSchema])
                }
                return (.response(.response(.init(id: r.id, result: .object(["tools": .array(list)])))), nil)
            case "tools/call":
                // Runs inline on the actor; the transport (Task 10) calls handle() from a detached task per request so a long tool
                // never blocks the stdout reader, and notifications/cancelled reaches inFlight while the call is still running.
                guard let name = r.params?["name"]?.stringValue, let tool = tools[name] else {
                    return (.response(.error(.init(id: r.id, error: .init(code: -32602, message: "Unknown tool: \(r.params?["name"]?.stringValue ?? "?")")))), nil)
                }
                let args = r.params?["arguments"] ?? .object([:])
                let task = Task { try await tool.call(arguments: args, context: MCPToolContext(cwd: cwd)) }
                inFlight[r.id] = task
                defer { inFlight[r.id] = nil }
                do {
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    return (.response(.response(.init(id: r.id, result: .object(["content": .array(result.content), "isError": .bool(result.isError)])))), result.hostInvocation)
                } catch let e as MCPArgumentError {
                    return (.response(.error(.init(id: r.id, error: .init(code: -32602, message: e.message)))), nil)
                } catch is CancellationError {
                    return (.response(.error(.init(id: r.id, error: .init(code: -32800, message: "Request cancelled")))), nil)
                } catch {
                    return (.response(.response(.init(id: r.id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(String(describing: error))])]), "isError": .bool(true)])))), nil)
                }
            default:
                return (.response(.error(.init(id: r.id, error: .init(code: -32601, message: "Method not found: \(r.method)")))), nil)
            }
        }
    }
}
