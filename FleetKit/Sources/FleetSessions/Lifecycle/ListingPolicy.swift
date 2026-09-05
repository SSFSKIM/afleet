import Foundation

/// Which transcripts the sidebar lists, and how. The rules are data so the sidebar can name the one that decided,
/// and so a new rule is a row rather than a branch in a chain of `if`s.
public enum ListingPolicy {
    /// The fields C3's index exposes, as much of them as the policy reads. Task 11 adds an initialiser from C3's
    /// real entry type; every field is a plain wire value so this file depends on nothing above it.
    public struct IndexEntry: Hashable, Sendable {
        public var sessionID: String
        public var entrypoint: String?
        public var sessionKind: String?
        public var isSidechain: Bool
        public var teamName: String?
        /// The session this transcript was continued in; such a transcript folds into its continuation.
        public var continuedIn: String?
        public init(sessionID: String, entrypoint: String? = nil, sessionKind: String? = nil,
                    isSidechain: Bool = false, teamName: String? = nil, continuedIn: String? = nil) {
            self.sessionID = sessionID; self.entrypoint = entrypoint; self.sessionKind = sessionKind
            self.isSidechain = isSidechain; self.teamName = teamName; self.continuedIn = continuedIn
        }
    }
    public enum ReadOnlyReason: Hashable, Sendable { case teammate }
    public enum Mode: Hashable, Sendable { case ownedCandidate, readOnly(ReadOnlyReason) }
    public enum Reason: Hashable, Sendable { case sidechain, continuedIn(String) }
    public enum Verdict: Hashable, Sendable { case listed(Mode), excluded(Reason) }

    /// One rule: a name the sidebar can report and a decision that either fires or passes.
    public struct Rule: Sendable {
        public let name: String
        public let decide: @Sendable (IndexEntry) -> Verdict?
        public init(name: String, decide: @escaping @Sendable (IndexEntry) -> Verdict?) { self.name = name; self.decide = decide }
    }

    /// Evaluated in order; the first rule that fires decides. `default` always fires, so `include` is total.
    public static let rules: [Rule] = [
        Rule(name: "own-sdk-cli") { $0.entrypoint == "sdk-cli" ? .listed(.ownedCandidate) : nil },
        Rule(name: "sidechain") { $0.isSidechain ? .excluded(.sidechain) : nil },
        Rule(name: "continued-in") { $0.continuedIn.map { .excluded(.continuedIn($0)) } },
        Rule(name: "teammate") { $0.teamName != nil ? .listed(.readOnly(.teammate)) : nil },
        Rule(name: "default") { _ in .listed(.ownedCandidate) },
    ]

    public static func include(_ entry: IndexEntry) -> Verdict {
        for rule in rules { if let verdict = rule.decide(entry) { return verdict } }
        return .listed(.ownedCandidate)
    }
}
