import Foundation

/// Reads pull requests, checks and issues by running the user's own `gh`.
///
/// afleet never holds a GitHub token: `gh` does, in its own configuration, and every call here is
/// a **read** made with the resolved environment so that `gh` finds the same host, the same token
/// and the same protocol the user's terminal does. Nothing in this module writes to `gh`'s
/// configuration, prompts for a login or mutates anything on GitHub.
public enum GhCommands {

    // MARK: - the field subsets

    /// The `--json` list for `gh pr list`. Verified against `gh` 2.96.0's own field help and the
    /// composite's Grounding Baseline against `cli.github.com/manual`; `PullRequest`'s properties
    /// are the same statement in Swift, and a test compares the two against the samples.
    ///
    /// `statusCheckRollup` is deliberately absent: check status comes from `gh pr checks --json`,
    /// whose flat shape is documented, and not from the nested union on this object (D9).
    public static let pullRequestFields = [
        "number", "title", "state", "isDraft", "author", "headRefName", "baseRefName", "url",
        "createdAt", "updatedAt", "reviewDecision", "mergeStateStatus", "mergeable", "labels",
        "additions", "deletions", "changedFiles",
    ]

    /// The `--json` list for `gh pr checks` — every field the verb offers on 2.96.0.
    public static let checkFields = [
        "name", "state", "bucket", "workflow", "link", "startedAt", "completedAt", "description",
        "event",
    ]

    /// The `--json` list for `gh issue list`.
    public static let issueFields = [
        "number", "title", "state", "author", "labels", "assignees", "updatedAt", "url",
    ]

    /// `gh pr checks` exits **8** when checks are still pending, and prints the checks anyway.
    /// Documented under `gh help exit-codes` and in the verb's own help; treating it as a failure
    /// would empty the panel exactly while CI is running. No other verb here accepts anything but
    /// zero (D3: exit codes are data at the process layer, and only a wrapper knows which mean
    /// failure).
    static let checksPendingExitCode: Int32 = 8

    /// How long a `gh` call may take. Longer than the local `git` budget because every one of
    /// these is a network round trip through GitHub's API, and a slow link is not a hang.
    static let readTimeout: Duration = .seconds(60)

    // MARK: - the commands

    /// The repository's pull requests in `state` (`open`, `closed`, `merged`, `all`), newest
    /// first, at most `limit` of them; `head` narrows to one head branch, which is how a panel
    /// asks "is there a pull request for the branch I am on".
    public static func pullRequests(root: URL, head: String?, state: String, limit: Int,
                                    environment: [String: String],
                                    runner: any ToolRunning) async throws -> [PullRequest] {
        var arguments = ["pr", "list", "--state", state, "--limit", "\(limit)"]
        if let head { arguments += ["--head", head] }
        arguments += ["--json", pullRequestFields.joined(separator: ",")]
        let output = try await run(arguments, root: root, environment: environment, runner: runner,
                                   accepting: [0])
        return try decodePullRequests(output.stdout)
    }

    /// Every check on one pull request.
    public static func checks(root: URL, pullRequest: Int, environment: [String: String],
                              runner: any ToolRunning) async throws -> [CheckRun] {
        let arguments = ["pr", "checks", "\(pullRequest)",
                         "--json", checkFields.joined(separator: ",")]
        let output = try await run(arguments, root: root, environment: environment, runner: runner,
                                   accepting: [0, checksPendingExitCode])
        return try decodeChecks(output.stdout)
    }

    /// The repository's open issues, at most `limit` of them.
    public static func issues(root: URL, limit: Int, environment: [String: String],
                              runner: any ToolRunning) async throws -> [Issue] {
        let arguments = ["issue", "list", "--limit", "\(limit)",
                         "--json", issueFields.joined(separator: ",")]
        let output = try await run(arguments, root: root, environment: environment, runner: runner,
                                   accepting: [0])
        return try decodeIssues(output.stdout)
    }

    /// One `gh` invocation, with the exit codes its verb accepts. A code outside the set becomes a
    /// panel-local `.commandFailed` and the output is never decoded — whatever a failing `gh`
    /// printed is a diagnostic, not a document (§10).
    private static func run(_ arguments: [String], root: URL, environment: [String: String],
                            runner: any ToolRunning, accepting: Set<Int32>) async throws -> ToolOutput {
        let output = try await runner.run(.gh, arguments: arguments, cwd: root,
                                          environment: environment, timeout: readTimeout)
        guard accepting.contains(output.exitCode) else {
            throw ToolError.commandFailed(tool: .gh, exitCode: output.exitCode,
                                          stderrTail: output.stderrTail)
        }
        return output
    }

    // MARK: - decoding

    /// `gh` prints RFC 3339 instants with a `Z` offset and no fractional seconds, which is what
    /// `.iso8601` reads.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func decodePullRequests(_ data: Data) throws -> [PullRequest] {
        try decode([PullRequest].self, from: data, subject: "pull requests")
    }

    public static func decodeChecks(_ data: Data) throws -> [CheckRun] {
        try decode([CheckRun].self, from: data, subject: "checks")
    }

    public static func decodeIssues(_ data: Data) throws -> [Issue] {
        try decode([Issue].self, from: data, subject: "issues")
    }

    /// Decodes one document, turning a `DecodingError` into this module's own panel-local error.
    ///
    /// The message carries the decoder's description, which names coding keys and types and no
    /// values, so nothing an account owns reaches a rendered error (§6.3, §11).
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                             subject: String) throws -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw ToolError.decodeFailed(subject: subject, message: message(for: error))
        }
    }

    /// A `DecodingError` as a short line: what went wrong and where in the document, never what
    /// the value was.
    private static func message(for error: DecodingError) -> String {
        let path = { (context: DecodingError.Context) in
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context))"
        case .typeMismatch(let expected, let context):
            return "expected \(expected) at \(path(context))"
        case .valueNotFound(let expected, let context):
            return "no value for \(expected) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupt data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return "the document did not decode"
        }
    }
}
