import Foundation
import AfleetCore
import PanelHostAPI

/// STUB — the declarations T4's suite is written against, before the document exists.
/// Replaced in the next commit; here so the tests fail on their own assertions.
public struct FilesPanelState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = FilesPanelState.currentSchemaVersion
    public var openFiles: [OpenFile] = []
    public var selectedPath: String?
    public var showsHiddenFiles = false
    public var showsGitIgnored = false
    public var filter = ""

    public struct OpenFile: Codable, Equatable, Sendable {
        public var path: String
        public var line: Int
        public var column: Int
        public var rendersMarkdown: Bool
        public init(path: String, line: Int, column: Int, rendersMarkdown: Bool) {
            self.path = path; self.line = line; self.column = column; self.rendersMarkdown = rendersMarkdown
        }
    }

    public static let empty = FilesPanelState()
    public init() {}
}

/// STUB — see above.
public actor FilesPanelStore {
    public nonisolated let key: String

    public static func configHomeHash(_ configHome: URL) -> String { "" }

    public init(store: any ScopedStore, configHome: URL, session: SessionID,
                coalescingInterval: Duration = .milliseconds(250)) {
        self.key = ""
    }

    public func load() async -> FilesPanelState { .empty }
    public func save(_ state: FilesPanelState) {}
    public func flush() async {}
}
