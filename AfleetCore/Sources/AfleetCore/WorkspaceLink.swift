import Foundation

public enum WorkspaceLink: Hashable, Sendable {
    case file(URL, line: Int?)
    case diff(DiffRef)
    case url(URL)
    case commit(String)
    case pullRequest(Int)
    case command(String)
}

public struct DiffRef: Hashable, Sendable {
    public var repository: URL      // working-tree root
    public var path: String         // repository-relative
    public var base: Base
    public enum Base: Hashable, Sendable {
        case workingTreeAgainstHEAD
        case commit(String)
        case commitAgainstParent(String)
    }
    public init(repository: URL, path: String, base: Base) {
        self.repository = repository; self.path = path; self.base = base
    }
}
