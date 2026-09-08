import Foundation

/// One decoration `git log` printed beside a commit — a branch, a remote-tracking branch, a tag,
/// or `HEAD` itself.
///
/// The kinds come from what `%D` prints, measured on `git` 2.55.0; see `GitLog.refs(from:)` for
/// the syntax and for the one ambiguity the shortened form leaves behind.
public struct GitRef: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// `HEAD` itself, whether attached (`HEAD -> main`) or detached (a bare `HEAD`). When it
        /// is attached the branch it points at is carried as a separate `.branch` ref, so a
        /// consumer that wants "the current branch" reads the branch and a consumer that wants
        /// "where the cursor is" reads this one.
        case head
        /// A local branch.
        case branch
        /// A remote-tracking branch. `name` is the branch part alone: `origin/main` is
        /// `.remoteBranch(remote: "origin")` named `main`.
        case remoteBranch(remote: String)
        case tag
    }

    public var kind: Kind
    /// `"main"`, `"v0.1"`, `"HEAD"`; for `remoteBranch`, the branch part without the remote.
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// One commit as the graph view needs it: the identity, the edges out of it, what is drawn beside
/// it, and the one line of message a row shows.
///
/// This is deliberately not everything a commit has. The body, the committer, the tree and the
/// signature are absent because contract W7's format string does not ask for them and a row does
/// not draw them; a detail view that wants them issues its own `git show`.
public struct GitCommit: Hashable, Sendable, Identifiable {
    /// The full 40-character object name — never abbreviated here, because an abbreviation is a
    /// display decision and two abbreviations can collide.
    public var hash: String
    /// Parent hashes in git's own order. The *first* parent is load-bearing for lane assignment:
    /// it is the one that keeps a commit's lane.
    public var parents: [String]
    public var refs: [GitRef]
    public var authorName: String
    /// `%at`, the author date, which is a Unix timestamp in seconds.
    public var authorTimestamp: Date
    /// `%s`, the first line of the message.
    public var subject: String

    public var id: String { hash }

    public init(hash: String, parents: [String], refs: [GitRef],
                authorName: String, authorTimestamp: Date, subject: String) {
        self.hash = hash
        self.parents = parents
        self.refs = refs
        self.authorName = authorName
        self.authorTimestamp = authorTimestamp
        self.subject = subject
    }
}
