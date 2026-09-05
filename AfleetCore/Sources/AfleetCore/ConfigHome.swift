import Foundation

public struct ConfigHome: Hashable, Codable, Sendable {
    public var root: URL
    public var source: Source
    public var projectDirName: String?
    public enum Source: String, Codable, Sendable { case environment, `default` }
    public init(root: URL, source: Source, projectDirName: String? = nil) {
        self.root = root; self.source = source; self.projectDirName = projectDirName
    }
}
