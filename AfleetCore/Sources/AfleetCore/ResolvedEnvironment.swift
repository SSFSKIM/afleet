import Foundation

public struct ResolvedEnvironment: Hashable, Codable, Sendable {
    public var variables: [String: String]
    public var shell: String
    public var capturedAt: Date
    public var mode: CaptureMode
    public enum CaptureMode: String, Codable, Sendable { case interactiveLogin, login, processFallback }

    public init(variables: [String: String], shell: String, capturedAt: Date, mode: CaptureMode) {
        self.variables = variables; self.shell = shell; self.capturedAt = capturedAt; self.mode = mode
    }
    public var path: [String] {
        (variables["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }
}
