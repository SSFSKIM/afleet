import Foundation
import PanelHostAPI
import SourceControlCore

/// What the panel shows when a link could not be opened: one line, and a hint when there is a
/// thing the user can do about it (§10 — a tool failure is panel-local and never an exception that
/// reaches the channel).
///
/// Neither field ever carries what a tool printed. A rendered error is a published byte (§6.3,
/// §11), and `gh`'s stderr holds host names, account names and repository paths; it is read here to
/// *classify* a failure and never to quote one.
public struct BrowserLinkError: Sendable, Equatable {
    public let message: String
    /// The one thing the user can do, when there is one — `gh auth login` for a `gh` that is not
    /// authenticated. `nil` otherwise: a panel that offered the same remedy for every failure would
    /// send the user to re-authenticate over a mistyped number.
    public let hint: String?

    public init(message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }
}

/// Turns `WorkspaceLink.pullRequest(Int)` into the page it names (Q2, ruled at the gate).
///
/// The link is a bare number. The repository it belongs to is `git`/`gh` knowledge, so this runs
/// `gh pr view <n> --json url` through C7.3's `ToolRunner` in the channel's repository root and
/// decodes the one field it asked for. Building `https://<host>/<owner>/<repo>/pull/<n>` from
/// `git remote get-url` was rejected at the gate: every remote spelling, SSH aliases, enterprise
/// hosts and `insteadOf` rewrites would be a parser this panel owns and gets wrong.
///
/// **Which repository** is Q3: the host's currently selected channel, read through an injected
/// provider rather than cached, because a link can arrive before the Browser tab has ever been
/// drawn. No channel is a row and never a guess.
///
/// **Nothing here prompts for a login.** `gh` is run as a read with stdin on `/dev/null` (the
/// runner's own guarantee), and a `gh` that is not authenticated exits non-zero and becomes the row
/// below carrying the `gh auth login` hint. afleet never holds a token and never runs a login verb.
@MainActor
public struct PullRequestURLResolver {

    /// What one lookup produced.
    public enum Resolution: Sendable, Equatable {
        case resolved(URL)
        case failed(BrowserLinkError)
        /// The read was cancelled, so there is nothing to report: a cancelled lookup is one the
        /// panel asked to stop, not a failure the user is owed a row about (`ToolError.cancelled`).
        case cancelled
    }

    /// The one field `--json url` returns, as a document.
    private struct Document: Decodable {
        let url: URL
    }

    /// Longer than the local `git` budget because the `gh` half is a network round trip through
    /// GitHub's API and a slow link is not a hang. It is this panel's own number: `GhCommands`
    /// keeps its budget internal, and a wrapper's timeout is a property of the wrapper.
    static let readTimeout: Duration = .seconds(60)

    private let runner: any ToolRunning
    private let channel: @MainActor () -> ChannelContext?

    public init(runner: any ToolRunning = ToolRunner(),
                channel: @escaping @MainActor () -> ChannelContext?) {
        self.runner = runner
        self.channel = channel
    }

    /// The page for pull request `number` in the selected channel's repository.
    ///
    /// It does not throw. Every way this can fail — no channel, not a repository, no `gh`, a `gh`
    /// that is not logged in, a number that is not a pull request, output that is not the document
    /// asked for — is a value the panel renders in its own area (§10).
    public func resolve(_ number: Int) async -> Resolution {
        guard let context = channel() else {
            return .failed(BrowserLinkError(
                message: "Open a channel to look up a pull request."))
        }
        let environment = context.environment.variables
        do {
            let root = try await GitCommands.repositoryRoot(cwd: context.cwd,
                                                            environment: environment,
                                                            runner: runner)
            let output = try await runner.run(.gh,
                                              arguments: ["pr", "view", "\(number)", "--json", "url"],
                                              cwd: root, environment: environment,
                                              timeout: Self.readTimeout)
            // Before the exit code, never after: a `gh` that handled `SIGTERM` at the end of its
            // budget can exit 0 with half a document behind it, and the exit code alone cannot tell
            // that from a finished read (C7.3's `requireCompleted`, R7/1e).
            try output.requireCompleted(tool: .gh, timeout: Self.readTimeout)
            // Zero and nothing else. `gh pr checks` accepts 8 while checks are pending; `pr view`
            // has no such code, and a wrapper declares the ones it accepts (C7.3 D3).
            guard output.exitCode == 0 else {
                throw ToolError.commandFailed(tool: .gh, exitCode: output.exitCode,
                                              stderrTail: output.stderrTail)
            }
            do {
                return .resolved(try JSONDecoder().decode(Document.self, from: output.stdout).url)
            } catch {
                throw ToolError.decodeFailed(subject: "pull-request url",
                                             message: "\(error)")
            }
        } catch let error as ToolError {
            return Self.resolution(for: error, number: number)
        } catch {
            return .failed(BrowserLinkError(
                message: "Pull request #\(number) could not be looked up."))
        }
    }

    /// One line for each way the lookup can fail, and the hint where there is one.
    ///
    /// The pull-request number appears because it is what the user just clicked; nothing else the
    /// tools produced does.
    static func resolution(for error: ToolError, number: Int) -> Resolution {
        switch error {
        case .cancelled:
            return .cancelled
        case .binaryNotFound(let tool):
            return .failed(BrowserLinkError(
                message: "Pull request #\(number) needs \(tool.rawValue), which is not on this "
                       + "session's PATH."))
        case .notARepository:
            return .failed(BrowserLinkError(
                message: "This channel's folder is not a Git repository, so pull request "
                       + "#\(number) has no home."))
        case .timedOut:
            return .failed(BrowserLinkError(
                message: "GitHub CLI did not answer in time for pull request #\(number)."))
        case .commandFailed(_, let exitCode, let stderrTail):
            return .failed(BrowserLinkError(
                message: "GitHub CLI could not open pull request #\(number) (exit \(exitCode)).",
                hint: mentionsAuthentication(stderrTail) ? authHint : nil))
        case .decodeFailed:
            return .failed(BrowserLinkError(
                message: "GitHub CLI answered with something this panel could not read."))
        default:
            return .failed(BrowserLinkError(
                message: "Pull request #\(number) could not be looked up."))
        }
    }

    static let authHint = "Run `gh auth login` in a terminal, then try the link again."

    /// Whether a `gh` failure is about not being signed in.
    ///
    /// `gh` says so in several ways across verbs and versions, so this matches on the phrases and
    /// not on an exit code: `pr view` exits 1 for a missing login and for a number that is not a
    /// pull request alike, and offering the login remedy for the second would send the user to
    /// re-authenticate over a typo. The tail is read here and never rendered (§11).
    static func mentionsAuthentication(_ stderrTail: String) -> Bool {
        let lowered = stderrTail.lowercased()
        return lowered.contains("gh auth login")
            || lowered.contains("authentication")
            || lowered.contains("not logged in")
            || lowered.contains("no authentication token")
    }
}
