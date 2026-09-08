import Foundation

/// The GitHub values this module reads out of `gh --json` documents.
///
/// **Where the field subsets come from.** Each model decodes a fixed subset of the fields the
/// composite's Grounding Baseline verified against `cli.github.com/manual` and this leaf re-checked
/// against `gh` 2.96.0's own `--json` help. `gh` prints *exactly* the fields the `--json` flag
/// names, so the subset in `GhCommands` and the properties here are one statement made twice, and
/// `GitHubModelTests.testEachFieldListIsExactlyWhatItsSampleCarries` pins them together.
///
/// **How strictly.** A field `gh` always emits is non-optional here, so a missing key is a decode
/// error rather than a default (ledger D9). That is what makes gate G3 — "the live API's document
/// decodes with no missing key" — falsifiable at all; a model of optionals could not fail it, which
/// is root spec §17.7's binding failure mode. The three fields GitHub documents as open-ended
/// enumerations decode instead through enums carrying an `.unknown(String)` case, so a value this
/// model has never seen is carried into the panel rather than crashing the read.

/// A GitHub account, as `gh` embeds it in an `author` or an `assignees` element.
///
/// `login` alone: the display name and the node id are in the document and are deliberately not
/// read, because nothing this module does needs them and every field read is a field that has to
/// keep working.
public struct GitHubUser: Hashable, Sendable, Decodable {
    public var login: String

    public init(login: String) { self.login = login }
}

/// A label on a pull request or an issue. `color` is `gh`'s six-digit RGB with no leading `#`.
public struct GitHubLabel: Hashable, Sendable, Decodable {
    public var name: String
    public var color: String?

    public init(name: String, color: String? = nil) {
        self.name = name
        self.color = color
    }
}

/// GitHub's `PullRequestReviewDecision`, plus the empty string `gh` emits when no review has been
/// requested at all, plus the carrier for a value this model does not know.
public enum ReviewDecision: Hashable, Sendable, Decodable {
    case approved
    case changesRequested
    case reviewRequired
    /// `gh` emits `""` when the pull request has requested no review.
    case notRequested
    /// A value GitHub has grown since this model was written. Carried, never fatal.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .reviewRequired
        case "": self = .notRequested
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .approved: "APPROVED"
        case .changesRequested: "CHANGES_REQUESTED"
        case .reviewRequired: "REVIEW_REQUIRED"
        case .notRequested: ""
        case .unknown(let value): value
        }
    }

    public var isUnknown: Bool { if case .unknown = self { true } else { false } }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// GitHub's `MergeStateStatus`. `reportedUnknown` is GitHub's own `UNKNOWN` — the merge state has
/// not been computed yet — and is a different statement from `unknown(_:)`, which is this model
/// meeting a value it has no case for.
public enum MergeStateStatus: Hashable, Sendable, Decodable {
    case behind
    case blocked
    case clean
    case dirty
    case draft
    case hasHooks
    case unstable
    case reportedUnknown
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "BEHIND": self = .behind
        case "BLOCKED": self = .blocked
        case "CLEAN": self = .clean
        case "DIRTY": self = .dirty
        case "DRAFT": self = .draft
        case "HAS_HOOKS": self = .hasHooks
        case "UNSTABLE": self = .unstable
        case "UNKNOWN": self = .reportedUnknown
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .behind: "BEHIND"
        case .blocked: "BLOCKED"
        case .clean: "CLEAN"
        case .dirty: "DIRTY"
        case .draft: "DRAFT"
        case .hasHooks: "HAS_HOOKS"
        case .unstable: "UNSTABLE"
        case .reportedUnknown: "UNKNOWN"
        case .unknown(let value): value
        }
    }

    public var isUnknown: Bool { if case .unknown = self { true } else { false } }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// GitHub's `MergeableState`. As above, `reportedUnknown` is GitHub's `UNKNOWN` — "not computed
/// yet", which is the value a freshly opened pull request carries for a few seconds.
public enum Mergeability: Hashable, Sendable, Decodable {
    case mergeable
    case conflicting
    case reportedUnknown
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        case "UNKNOWN": self = .reportedUnknown
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .mergeable: "MERGEABLE"
        case .conflicting: "CONFLICTING"
        case .reportedUnknown: "UNKNOWN"
        case .unknown(let value): value
        }
    }

    public var isUnknown: Bool { if case .unknown = self { true } else { false } }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// One pull request, as `gh pr list --json <GhCommands.pullRequestFields>` prints it.
///
/// `state` is left as a `String` — `OPEN`, `CLOSED`, `MERGED` — because it is a closed set the
/// caller filters on rather than renders decisions from, and `--state` on the command line is the
/// same string.
///
/// Check status is deliberately **not** here. `statusCheckRollup` is available on this object as a
/// nested union of `CheckRun` and `StatusContext` nodes that this leaf has no verified evidence
/// for; the flat, documented `gh pr checks --json` shape is what `CheckRun` below decodes, and
/// that is ledger D9.
public struct PullRequest: Hashable, Sendable, Decodable {
    public var number: Int
    public var title: String
    public var state: String
    public var isDraft: Bool
    public var author: GitHubUser
    public var headRefName: String
    public var baseRefName: String
    public var url: URL
    public var createdAt: Date
    public var updatedAt: Date
    public var reviewDecision: ReviewDecision
    public var mergeStateStatus: MergeStateStatus
    public var mergeable: Mergeability
    public var labels: [GitHubLabel]
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
}

/// One check on a pull request, as `gh pr checks --json <GhCommands.checkFields>` prints it.
///
/// `bucket` is `gh`'s own categorisation of `state` into `pass`, `fail`, `pending`, `skipping` or
/// `cancel` — the panel groups on it, so it is read rather than recomputed from `state`.
///
/// **The absent-value shapes, measured.** `gh` 2.96.0 declares this record in
/// `pkg/cmd/pr/checks/aggregate.go` as a Go struct whose `Link`, `Event`, `Workflow` and
/// `Description` are `string` and whose `StartedAt` and `CompletedAt` are `time.Time`. Marshalled,
/// an absent string is `""` and an absent timestamp is Go's zero instant `0001-01-01T00:00:00Z`;
/// neither is ever `null` and neither key is ever missing. Both are mapped to `nil` here, which is
/// why the optionality below is not a weakening of the strict-decode rule: the keys stay required.
public struct CheckRun: Hashable, Sendable, Decodable {
    public var name: String
    public var state: String
    public var bucket: String
    public var workflow: String?
    public var link: URL?
    public var startedAt: Date?
    public var completedAt: Date?
    public var description: String?
    public var event: String?

    /// Go's zero `time.Time`, marshalled. `gh` branches on `IsZero()` when it renders, so this is
    /// the value's own meaning rather than a guess about the year 1.
    static let zeroTimestamp = "0001-01-01T00:00:00Z"

    enum CodingKeys: String, CodingKey {
        case name, state, bucket, workflow, link, startedAt, completedAt, description, event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        bucket = try container.decode(String.self, forKey: .bucket)
        workflow = Self.present(try container.decode(String.self, forKey: .workflow))
        description = Self.present(try container.decode(String.self, forKey: .description))
        event = Self.present(try container.decode(String.self, forKey: .event))

        if let text = Self.present(try container.decode(String.self, forKey: .link)) {
            guard let url = URL(string: text) else {
                throw DecodingError.dataCorruptedError(forKey: .link, in: container,
                                                       debugDescription: "link is not a URL")
            }
            link = url
        } else {
            link = nil
        }
        startedAt = try Self.instant(container, .startedAt)
        completedAt = try Self.instant(container, .completedAt)
    }

    private static func present(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// An absent timestamp — empty or Go's zero instant — is `nil`; anything else must parse, so a
    /// timestamp in a shape this module cannot read fails loudly instead of vanishing.
    private static func instant(_ container: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) throws -> Date? {
        let text = try container.decode(String.self, forKey: key)
        guard !text.isEmpty, text != zeroTimestamp else { return nil }
        guard let date = try? Date(text, strategy: .iso8601) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                   debugDescription: "not an ISO 8601 instant")
        }
        return date
    }
}

/// One issue, as `gh issue list --json <GhCommands.issueFields>` prints it.
public struct Issue: Hashable, Sendable, Decodable {
    public var number: Int
    public var title: String
    public var state: String
    public var author: GitHubUser
    public var labels: [GitHubLabel]
    public var assignees: [GitHubUser]
    public var updatedAt: Date
    public var url: URL
}
