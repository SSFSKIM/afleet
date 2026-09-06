import Foundation
import AfleetCore
import WireEnvironment
import WireFrames

/// A runner that can also start a child in a named working directory.
///
/// C2's `ProcessRunner` has no working-directory parameter and `ClaudeWire` is C2's, so this is FleetKit's own seam
/// *over* that protocol rather than a change to it: a `DirectoryProcessRunner` is a `ProcessRunner` everywhere one
/// is wanted, and the extra method is what the two `--bg` verbs need — a job created for a project has to be
/// created *in* that project rather than in whatever directory afleet itself was started from.
public protocol DirectoryProcessRunner: ProcessRunner {
    func run(_ executable: URL, arguments: [String], environment: [String: String], cwd: URL,
             timeout: Duration) async throws -> ProcessOutput
}

/// The production conformance, over C2's runner.
///
/// `/usr/bin/env -C <directory>` changes directory and then `exec`s the binary, so the child *is* the binary — its
/// exit status, its stdout and its stderr are its own — and C2's tested spawn, pipe draining and timeout keep
/// owning the process. Reimplementing all of that here to gain one `chdir` would be the larger risk by far.
public struct FoundationDirectoryRunner: DirectoryProcessRunner {
    private let base: any ProcessRunner
    private let env: URL

    public init(base: any ProcessRunner = FoundationProcessRunner(), env: URL = URL(filePath: "/usr/bin/env")) {
        self.base = base; self.env = env
    }

    public func run(_ executable: URL, arguments: [String], environment: [String: String],
                    timeout: Duration) async throws -> ProcessOutput {
        try await base.run(executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    public func run(_ executable: URL, arguments: [String], environment: [String: String], cwd: URL,
                    timeout: Duration) async throws -> ProcessOutput {
        try await base.run(env,
                           arguments: ["-C", cwd.path(percentEncoded: false),
                                       executable.path(percentEncoded: false)] + arguments,
                           environment: environment, timeout: timeout)
    }
}

/// Every `claude` subcommand afleet runs without a PTY, over the working-directory seam above. `attach` and `logs`
/// are never here: they need a terminal and are pane requests (X5 as amended).
///
/// Each call records one diagnostic carrying the verb, its exit code and its duration, and never its stdout; a
/// non-zero exit throws `LifecycleError.verbFailed`.
public struct CLIVerbs: Sendable {
    private let runner: any DirectoryProcessRunner
    private let binary: URL
    /// The home the verbs act on. The environment pins the same home through `CLAUDE_CONFIG_DIR`; the value is here
    /// too because `backgroundResume` has to read `jobs/` to find the job the CLI just created.
    private let configHome: ConfigHome
    /// `LaunchConfiguration.childEnvironment(over:configHome:)` for a dummy launch in `configHome`.
    private let environment: [String: String]
    private let diagnostics: any FleetDiagnosticsSink
    private let readTimeout: Duration
    private let mutationTimeout: Duration
    /// Drives the roster confirmation's bounded re-read. Production passes `ContinuousClock`.
    private let clock: any Clock<Duration>

    /// A verb that only asks a question: `agents --json` and `auth status`. Both answer off state the daemon has
    /// already written, and neither waits on a worker — G5 measured `agents --json` at 0.2 s against the installed
    /// 2.1.263 — so twenty seconds is a generous ceiling and stays the one that was always here.
    public static let readBudget = Duration.seconds(20)
    /// A verb that changes the daemon's world: the two `--bg` forms, `stop`, `respawn`, `rm` and `auth logout`.
    ///
    /// Each of these is fast: measured from a shell against 2.1.263 in G5's scratch home, `--bg --exec` returns in
    /// 1.1 s, `stop` in 0.70 s, `rm` in 0.7 s, and the fourth merge-evidence run spawned a job, listed it, stopped
    /// it and confirmed its removal in 5.287 s end to end with a cold daemon in that total. The only thing a
    /// mutation waits on beyond its own work is reaching a daemon that may be cold, and the daemon is transient:
    /// it exits five idle seconds after its last client and boots again on the next one, in about 0.3 s.
    ///
    /// This was ninety seconds for one commit, sized from the seventy tracker entry 27 observed between a verb
    /// being invoked and the daemon logging the spawn. That observation was not the daemon being slow. It was the
    /// runner learning a child's exit from `waitUntilExit()` on the global dispatch queue, which does not
    /// overcommit: under a loaded suite every worker was blocked, the exit was never observed, and the verb was
    /// failed by its own timer long after the child had succeeded. The exit now arrives on
    /// `process.terminationHandler`, so no measurement behind ninety survives. Thirty seconds is the real numbers
    /// with roughly twenty times their margin.
    ///
    /// The asymmetry is still the point: a read that hangs costs a stale listing, while a mutation abandoned
    /// mid-request leaves the daemon honouring a change afleet has already given up on — exactly what the second
    /// merge-evidence run saw when a twenty-second `stop` was SIGTERMed two seconds before the daemon logged
    /// `settled (killed)`.
    public static let mutationBudget = Duration.seconds(30)

    public init(runner: any DirectoryProcessRunner, binary: URL, configHome: ConfigHome,
                environment: [String: String],
                diagnostics: any FleetDiagnosticsSink, readTimeout: Duration = CLIVerbs.readBudget,
                mutationTimeout: Duration = CLIVerbs.mutationBudget,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.runner = runner; self.binary = binary; self.configHome = configHome; self.environment = environment
        self.diagnostics = diagnostics; self.readTimeout = readTimeout; self.mutationTimeout = mutationTimeout
        self.clock = clock
    }

    /// How long the new job has to appear in `daemon/roster.json`, and how often that file is re-read. Whether the
    /// daemon writes the roster before `--bg` exits is not a fact this package has probe evidence for, so the
    /// confirmation assumes neither timing: it succeeds on the first read when the entry is already there and waits
    /// for it otherwise.
    private static let rosterBudget = Duration.seconds(3)
    private static let rosterInterval = Duration.milliseconds(200)

    // MARK: - Verbs

    public func agentsJSON() async throws -> [AgentsRow] {
        let out = try await run("agents", ["agents", "--json"], budget: readTimeout)
        return AgentsRow.decodeArray(out.stdout)
    }

    public func stop(_ short: JobShort) async throws {
        _ = try await run("stop", ["stop", short.rawValue], budget: mutationTimeout)
    }

    public func respawn(_ short: JobShort) async throws {
        _ = try await run("respawn", ["respawn", short.rawValue], budget: mutationTimeout)
    }

    public func remove(_ short: JobShort) async throws {
        _ = try await run("rm", ["rm", short.rawValue], budget: mutationTimeout)
    }

    public func authStatus() async throws -> JSONValue {
        let out = try await run("auth status", ["auth", "status"], budget: readTimeout)
        return (try? JSONDecoder().decode(JSONValue.self, from: out.stdout)) ?? .null
    }

    public func authLogout() async throws {
        _ = try await run("auth logout", ["auth", "logout"], budget: mutationTimeout)
    }

    /// Sends a session to the background and returns the short of the job the CLI created, found by diffing
    /// `jobs/*/state.json` for `resumeSessionId == id` and then confirmed in the roster.
    ///
    /// `cwd` is the job's working directory — the CLI runs there through the seam above — and is also the
    /// tie-breaker between candidate job records.
    public func backgroundResume(_ id: SessionID, cwd: URL) async throws -> JobShort {
        let before = Set(jobShorts())
        _ = try await run("--bg --resume", ["--bg", "--resume", id.description], cwd: cwd, budget: mutationTimeout)
        // `requireNew: false`, and that is the whole of the fix. The daemon reuses a session's existing short when
        // the same session is backgrounded again — the live gate watched it write
        // `bg claimed-spare fdb4e2d6 (fleet)` under the very short the job had been adopted from — so a newness
        // filter here rejects the one job this call is about. Adopt-then-send-back is not a corner: it is §7.4's
        // own round trip, and it could never have completed. The session id is the discriminator this verb has and
        // the roster confirmation below is what proves the worker is live now, so newness adds nothing here.
        return try await confirmed(matching: { $0.resumeSessionId == id.description }, notIn: before,
                                   requireNew: false, disambiguatingWith: cwd, verb: "--bg --resume",
                                   session: id.description)
    }

    /// Runs one command as a background job in `cwd`. An exec job carries no session, so the short is found by its
    /// newness alone.
    public func backgroundExec(_ command: String, cwd: URL) async throws -> JobShort {
        let before = Set(jobShorts())
        _ = try await run("--bg --exec", ["--bg", "--exec", command], cwd: cwd, budget: mutationTimeout)
        // `requireNew: true`: an exec job carries no session, so newness is the only thing that tells this call's
        // job from every other exec job in the home.
        return try await confirmed(matching: { _ in true }, notIn: before, requireNew: true,
                                   disambiguatingWith: cwd, verb: "--bg --exec", session: "")
    }

    // MARK: - Internals

    /// `cwd` nil is a verb that acts on the config home and cares nothing for where it runs; a verb that names one
    /// runs there. `budget` is the caller's class of verb — `readBudget` or `mutationBudget` — rather than one
    /// timeout for everything, so a `stop` is never abandoned on a ceiling chosen for a listing.
    private func run(_ verb: String, _ arguments: [String], cwd: URL? = nil,
                     budget: Duration) async throws -> ProcessOutput {
        // A monotonic counter, not a Clock instant: this measures a call that already happened rather than driving
        // a timer, and the package's clocks stay injected.
        let start = DispatchTime.now().uptimeNanoseconds
        let out: ProcessOutput
        do {
            if let cwd {
                out = try await runner.run(binary, arguments: arguments, environment: environment, cwd: cwd,
                                           timeout: budget)
            } else {
                out = try await runner.run(binary, arguments: arguments, environment: environment, timeout: budget)
            }
        } catch {
            diagnostics.record(.verb(name: verb, exitCode: -1, durationMs: elapsedMs(since: start)))
            throw error
        }
        let duration = elapsedMs(since: start)
        diagnostics.record(.verb(name: verb, exitCode: out.exitCode, durationMs: duration))
        // Checked before the exit code, because a child the runner had to kill reports an exit code that says
        // nothing: the fact worth carrying is that the budget ran out, not the signal that ended it.
        guard !out.timedOut else {
            throw LifecycleError.verbTimedOut(verb: verb, afterMs: duration,
                                              childState: out.timeoutState ?? "unsampled")
        }
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

    /// The one new job the predicate accepts that the roster also names, waited for rather than demanded at once.
    ///
    /// The CLI having exited zero is not enough — the spec's confirmation is the roster — but neither is one read
    /// the instant it exits: nothing in this package's evidence says the daemon writes `daemon/roster.json` before
    /// `--bg` returns. So the roster is re-read every `rosterInterval` until `rosterBudget` runs out, which is
    /// correct whichever way the daemon does it. A job that never reaches the roster is the
    /// `jobNotListedAfterBackground` diagnostic.
    ///
    /// `requireNew` says whether a short that already existed may be the answer. It may not for an exec job, whose
    /// only discriminator is newness; it may for a resumed session, whose discriminator is the session id and whose
    /// short the daemon reuses when the same session is backgrounded a second time.
    ///
    /// `cwd` is a tie-breaker between candidate records and nothing more; see the warnings on the two callers.
    private func confirmed(matching predicate: @escaping (JobRecord) -> Bool, notIn before: Set<String>,
                           requireNew: Bool, disambiguatingWith cwd: URL, verb: String,
                           session: String) async throws -> JobShort {
        let wanted = cwd.resolvingSymlinksInPath().path(percentEncoded: false)
        let attempts = max(1, Int(Self.rosterBudget / Self.rosterInterval) + 1)
        for attempt in 0..<attempts {
            if attempt > 0, (try? await clock.sleep(for: Self.rosterInterval)) == nil { break }
            let workers = roster()?.workers ?? [:]
            let candidates = jobShorts()
                .filter { !requireNew || !before.contains($0) }
                .compactMap { short -> (String, String?)? in
                    guard let record = job(short), predicate(record) else { return nil }
                    return (short, record.cwd)
                }
                // Two jobs created in the same instant is not a case the CLI produces, but when the record names a
                // directory, the one that names *this* directory is the one this call asked for.
                .sorted { a, b in (a.1 == wanted ? 0 : 1) < (b.1 == wanted ? 0 : 1) }
                .map(\.0)
            if let short = candidates.first(where: { workers[$0] != nil }) { return JobShort(rawValue: short) }
        }
        diagnostics.record(.jobNotListedAfterBackground(session: session))
        throw LifecycleError.verbFailed(verb: verb, exitCode: 0)
    }
}
