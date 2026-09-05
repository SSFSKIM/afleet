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

/// What an unexpected tool throw leaves behind for the host, alongside the summarised result the model sees.
/// Metadata only, and deliberately so: the error's own description is frame-derived payload. This travels out
/// through `handle`'s return rather than through a sink on this actor, so the module keeps its single
/// dependency on `WireFrames` and the recorded event can carry the epoch, which only the transport knows.
public struct MCPToolFailure: Hashable, Sendable {
    public let tool: String
    public let errorType: String
    public let domain: String
    public let code: Int
    public init(tool: String, errorType: String, domain: String, code: Int) {
        self.tool = tool; self.errorType = errorType; self.domain = domain; self.code = code
    }
}

public actor AfleetMCPServer {
    /// The MCP protocol revisions whose surface afleet actually implements.
    ///
    /// The engine, acting as the MCP client, sends the newest entry of its own supported list
    /// (bundle 2.1.258 cli.pretty.js:679251) and then rejects a reply outside that list
    /// (`if (!r.includes(a.protocolVersion)) throw`, 679254). Its list now leads with
    /// `2025-11-25` (143537), so echoing whatever the client asked for would have afleet assert
    /// it speaks a revision newer than the surface below, and would silently agree to any
    /// behaviour a future revision makes mandatory. Every entry here is also in the engine's
    /// list, so the negotiated value always passes its check.
    public static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Answered when the client asks for a revision outside `supportedProtocolVersions`.
    public static let preferredProtocolVersion = "2025-06-18"

    public let serverVersion: String
    public let cwd: URL
    private let tools: [String: any MCPTool]
    private var inFlight: [JSONRPCID: Task<MCPToolResult, any Error>] = [:]
    /// Ids a `notifications/cancelled` has claimed while their call was still in flight.
    ///
    /// `Task.cancel()` alone is a request, not an outcome: a tool that ignores cancellation, swallows it, or
    /// finished a moment before the notification was handled still returns a result, and that result would go
    /// out as a success carrying a host invocation for work the client has already withdrawn. This is the
    /// durable record that decides the answer once the call comes back. Bounded by construction — an id is
    /// entered only while `inFlight` holds it, and leaves with it.
    private var cancelled: Set<JSONRPCID> = []

    public init(serverVersion: String, cwd: URL, tools: [any MCPTool]) {
        self.serverVersion = serverVersion; self.cwd = cwd
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    /// The one answer a cancelled call may produce, whatever the tool went on to return.
    private static func cancelledResponse(_ id: JSONRPCID) -> MCPReply {
        .response(.error(.init(id: id, error: .init(code: -32800, message: "Request cancelled"))))
    }

    public func handle(_ message: JSONRPCMessage) async -> (MCPReply, HostToolInvocation?, MCPToolFailure?) {
        switch message {
        case .notification(let n):
            if n.method == "notifications/cancelled", let idv = n.params?["requestId"] {
                let id: JSONRPCID? = idv.intValue.map(JSONRPCID.number) ?? idv.stringValue.map(JSONRPCID.string)
                if let id, let running = inFlight[id] { cancelled.insert(id); running.cancel() }
            }
            return (.notificationAck, nil, nil)
        case .response, .error:
            return (.notificationAck, nil, nil)             // the CLI never sends these to a server; acknowledge and move on
        case .request(let r):
            switch r.method {
            case "initialize":
                let requested = r.params?["protocolVersion"]?.stringValue
                let negotiated = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                    ?? Self.preferredProtocolVersion
                return (.response(.response(.init(id: r.id, result: .object([
                    "protocolVersion": .string(negotiated),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("afleet"), "version": .string(serverVersion)]),
                ])))), nil, nil)
            case "ping": return (.response(.response(.init(id: r.id, result: .object([:])))), nil, nil)
            case "tools/list":
                let list = tools.values.sorted { $0.name < $1.name }.map { t -> JSONValue in
                    .object(["name": .string(t.name), "description": .string(t.description), "inputSchema": t.inputSchema])
                }
                return (.response(.response(.init(id: r.id, result: .object(["tools": .array(list)])))), nil, nil)
            case "tools/call":
                // Runs inline on the actor; the transport (Task 10) calls handle() from a detached task per request so a long tool
                // never blocks the stdout reader, and notifications/cancelled reaches inFlight while the call is still running.
                guard let name = r.params?["name"]?.stringValue, let tool = tools[name] else {
                    return (.response(.error(.init(id: r.id, error: .init(code: -32602, message: "Unknown tool: \(r.params?["name"]?.stringValue ?? "?")")))), nil, nil)
                }
                let args = r.params?["arguments"] ?? .object([:])
                let task = Task { try await tool.call(arguments: args, context: MCPToolContext(cwd: cwd)) }
                inFlight[r.id] = task
                defer { inFlight[r.id] = nil; cancelled.remove(r.id) }
                do {
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    if cancelled.contains(r.id) { return (Self.cancelledResponse(r.id), nil, nil) }
                    // A failure never carries a host invocation out of this actor. Task 10 turns the
                    // invocation into a user-visible item ("file sent"), so letting one ride an
                    // isError result would announce something that did not happen. No tool sets both
                    // today; this guards the contract for the ones that come later.
                    let invocation = result.isError ? nil : result.hostInvocation
                    return (.response(.response(.init(id: r.id, result: .object(["content": .array(result.content), "isError": .bool(result.isError)])))), invocation, nil)
                } catch let e as MCPArgumentError {
                    if cancelled.contains(r.id) { return (Self.cancelledResponse(r.id), nil, nil) }
                    return (.response(.error(.init(id: r.id, error: .init(code: -32602, message: e.message)))), nil, nil)
                } catch is CancellationError {
                    return (Self.cancelledResponse(r.id), nil, nil)
                } catch {
                    if cancelled.contains(r.id) { return (Self.cancelledResponse(r.id), nil, nil) }
                    // An unexpected throw stays a runtime failure (isError), not a protocol error —
                    // but this text is model-visible, and a Foundation error's description carries the
                    // full filesystem path it failed on. Summarise instead of echoing it.
                    let ns = error as NSError
                    let failure = MCPToolFailure(tool: name, errorType: "\(type(of: error))", domain: ns.domain, code: ns.code)
                    let summary = "Tool \(name) failed unexpectedly (\(type(of: error)))"
                    return (.response(.response(.init(id: r.id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(summary)])]), "isError": .bool(true)])))), nil, failure)
                }
            default:
                return (.response(.error(.init(id: r.id, error: .init(code: -32601, message: "Method not found: \(r.method)")))), nil, nil)
            }
        }
    }
}
