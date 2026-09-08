import Foundation

public struct TerminalSize: Hashable, Sendable {
    public var rows: Int
    public var columns: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(rows: Int, columns: Int, pixelWidth: Int, pixelHeight: Int) {
        self.rows = rows
        self.columns = columns
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct TerminalDescription: Hashable, Sendable {
    public var term: String
    public var terminfoDirectory: URL?

    public init(term: String, terminfoDirectory: URL? = nil) {
        self.term = term
        self.terminfoDirectory = terminfoDirectory
    }
}

public enum PTYStopPolicy: Hashable, Sendable {
    case report
    case detach
}

public struct PTYSpawnRequest: Hashable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var cwd: URL
    public var environment: [String: String]
    public var size: TerminalSize
    public var terminal: TerminalDescription
    public var stopPolicy: PTYStopPolicy

    public init(
        executable: URL,
        arguments: [String],
        cwd: URL,
        environment: [String: String],
        size: TerminalSize,
        terminal: TerminalDescription,
        stopPolicy: PTYStopPolicy = .report
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.size = size
        self.terminal = terminal
        self.stopPolicy = stopPolicy
    }
}
