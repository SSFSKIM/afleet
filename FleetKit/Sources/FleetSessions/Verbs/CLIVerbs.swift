import Foundation
import AfleetCore
import WireEnvironment
import WireFrames

/// Every `claude` subcommand afleet runs without a PTY, over C2's `ProcessRunner`. `attach` and `logs` are never
/// here: they need a terminal and are pane requests (X5 as amended).
///
/// Each call records one diagnostic carrying the verb, its exit code and its duration, and never its stdout; a
/// non-zero exit throws `LifecycleError.verbFailed`.
public struct CLIVerbs: Sendable {
    private let runner: any ProcessRunner
    private let binary: URL
    /// The home the verbs act on. The environment pins the same home through `CLAUDE_CONFIG_DIR`; the value is here
    /// too because `backgroundResume` has to read `jobs/` to find the job the CLI just created.
    private let configHome: ConfigHome
    /// `LaunchConfiguration.childEnvironment(over:configHome:)` for a dummy launch in `configHome`.
    private let environment: [String: String]
    private let diagnostics: any FleetDiagnosticsSink
    private let timeout: Duration

    public init(runner: any ProcessRunner, binary: URL, configHome: ConfigHome, environment: [String: String],
                diagnostics: any FleetDiagnosticsSink, timeout: Duration = .seconds(20)) {
        self.runner = runner; self.binary = binary; self.configHome = configHome; self.environment = environment
        self.diagnostics = diagnostics; self.timeout = timeout
    }

    // MARK: - Verbs

    public func agentsJSON() async throws -> [AgentsRow] {
        let out = try await run("agents", ["agents", "--json"])
        return AgentsRow.decodeArray(out.stdout)
    }

    public func stop(_ short: JobShort) async throws {
        _ = try await run("stop", ["stop", short.rawValue])
    }

    public func respawn(_ short: JobShort) async throws {
        _ = try await run("respawn", ["respawn", short.rawValue])
    }

    public func remove(_ short: JobShort) async throws {
        _ = try await run("rm", ["rm", short.rawValue])
    }

    public func authStatus() async throws -> JSONValue {
        let out = try await run("auth status", ["auth", "status"])
        return (try? JSONDecoder().decode(JSONValue.self, from: out.stdout)) ?? .null
    }

    public func authLogout() async throws {
        _ = try await run("auth logout", ["auth", "logout"])
    }

    /// Sends a session to the background and returns the short of the job the CLI created, found by diffing
    /// `jobs/*/state.json` for `resumeSessionId == id` and then confirmed in the roster.
    public func backgroundResume(_ id: SessionID, cwd: URL) async throws -> JobShort {
        let before = Set(jobShorts())
        _ = try await run("--bg --resume", ["--bg", "--resume", id.description])
        return try confirmed(matching: { $0.resumeSessionId == id.description }, notIn: before,
                             preferring: cwd, session: id.description)
    }

    /// Runs one command as a background job. An exec job carries no session, so the short is found by its newness
    /// alone.
    public func backgroundExec(_ command: String, cwd: URL) async throws -> JobShort {
        let before = Set(jobShorts())
        _ = try await run("--bg --exec", ["--bg", "--exec", command])
        return try confirmed(matching: { _ in true }, notIn: before, preferring: cwd, session: "")
    }

    // MARK: - Internals

    private func run(_ verb: String, _ arguments: [String]) async throws -> ProcessOutput {
        // A monotonic counter, not a Clock instant: this measures a call that already happened rather than driving
        // a timer, and the package's clocks stay injected.
        let start = DispatchTime.now().uptimeNanoseconds
        let out: ProcessOutput
        do {
            out = try await runner.run(binary, arguments: arguments, environment: environment, timeout: timeout)
        } catch {
            diagnostics.record(.verb(name: verb, exitCode: -1, durationMs: elapsedMs(since: start)))
            throw error
        }
        diagnostics.record(.verb(name: verb, exitCode: out.exitCode, durationMs: elapsedMs(since: start)))
        guard out.exitCode == 0 else { throw LifecycleError.verbFailed(verb: verb, exitCode: out.exitCode) }
        return out
    }

    private func elapsedMs(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    private func jobShorts() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: configHome.root.appending(path: "jobs").path(percentEncoded: false))
        )?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func job(_ short: String) -> JobRecord? {
        let url = configHome.root.appending(path: "jobs/\(short)/state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JobRecord.decode(data)
    }

    private func roster() -> RosterRecord? {
        let url = configHome.root.appending(path: "daemon/roster.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return RosterRecord.decode(data)
    }

    /// The one new job the predicate accepts that the roster also names. The CLI having exited zero is not enough:
    /// a job that never reached the roster is the `jobNotListedAfterBackground` diagnostic.
    private func confirmed(matching predicate: (JobRecord) -> Bool, notIn before: Set<String>,
                           preferring cwd: URL, session: String) throws -> JobShort {
        let workers = roster()?.workers ?? [:]
        let wanted = cwd.resolvingSymlinksInPath().path(percentEncoded: false)
        let candidates = jobShorts()
            .filter { !before.contains($0) }
            .compactMap { short in job(short).map(predicate) == true ? (short, job(short)?.cwd) : nil }
            // Two jobs created in the same instant is not a case the CLI produces, but when the record names a
            // directory, the one that names *this* directory is the one this call asked for.
            .sorted { a, b in (a.1 == wanted ? 0 : 1) < (b.1 == wanted ? 0 : 1) }
            .map(\.0)
        guard let short = candidates.first(where: { workers[$0] != nil }) else {
            diagnostics.record(.jobNotListedAfterBackground(session: session))
            throw LifecycleError.verbFailed(verb: "background", exitCode: 0)
        }
        return JobShort(rawValue: short)
    }
}
