import Foundation
import XCTest
import AfleetCore
import FleetKit
@testable import Afleet

/// A Claude Code config home built from nothing, under a `TempTree`.
///
/// X9 is not relaxed for tests: this never touches `~/.claude`, `$CLAUDE_CONFIG_DIR` or
/// `/tmp/afleet-fixtures/config-home`. `TempTree.init` canonicalises its root and throws `XCTSkip`
/// before creating anything if the temporary directory somehow resolves inside one, so a home built
/// here is a home afleet made up.
///
/// Every byte written here is invented. No transcript line, session id, slug or title comes from any
/// recording or from any real home (§11).
struct ScratchConfigHome {

    let tree: TempTree
    let root: URL

    /// A transcript to write, described by the fields the listing join actually reads.
    struct Transcript {
        var session: SessionID
        var slug: String
        var cwd: String
        var mtime: Date
        var entrypoint: String?
        var sessionKind: String?
        var isSidechain: Bool
        var teamName: String?
        var continuedIn: SessionID?

        init(session: SessionID, slug: String = "invented-project", cwd: String = "/invented/project",
             mtime: Date = Date(), entrypoint: String? = nil, sessionKind: String? = nil,
             isSidechain: Bool = false, teamName: String? = nil, continuedIn: SessionID? = nil) {
            self.session = session; self.slug = slug; self.cwd = cwd; self.mtime = mtime
            self.entrypoint = entrypoint; self.sessionKind = sessionKind; self.isSidechain = isSidechain
            self.teamName = teamName; self.continuedIn = continuedIn
        }
    }

    init(tree: TempTree? = nil, directory: String = "config-home") throws {
        let tree = try tree ?? TempTree()
        self.tree = tree
        self.root = try tree.directory(directory)
    }

    var configHome: ConfigHome { ConfigHome(root: URL(fileURLWithPath: root.path), source: .environment) }

    // MARK: - Writing

    /// One main transcript under `projects/<slug>/<session>.jsonl`, with its mtime set.
    @discardableResult
    func write(_ transcript: Transcript) throws -> URL {
        let directory = root.appending(path: "projects/\(transcript.slug)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = "00000000-0000-4000-8000-000000000001"
        let assistant = "00000000-0000-4000-8000-000000000002"
        var head: [String] = [
            #""type":"user""#,
            #""sessionId":"\#(transcript.session)""#,
            #""uuid":"\#(user)""#,
            #""parentUuid":null"#,
            #""isSidechain":\#(transcript.isSidechain)"#,
            #""cwd":"\#(transcript.cwd)""#,
            #""timestamp":"2026-01-01T00:00:00.000Z""#,
            #""message":{"role":"user","content":"invented prompt"}"#,
        ]
        if let entrypoint = transcript.entrypoint { head.append(#""entrypoint":"\#(entrypoint)""#) }
        if let kind = transcript.sessionKind { head.append(#""sessionKind":"\#(kind)""#) }
        if let team = transcript.teamName { head.append(#""teamName":"\#(team)""#) }

        var lines = [
            "{" + head.joined(separator: ",") + "}",
            #"{"type":"assistant","sessionId":"\#(transcript.session)","uuid":"\#(assistant)","parentUuid":"\#(user)","isSidechain":\#(transcript.isSidechain),"cwd":"\#(transcript.cwd)","timestamp":"2026-01-01T00:00:01.000Z","message":{"id":"msg_invented","role":"assistant","content":[{"type":"text","text":"invented reply"}]}}"#,
            #"{"type":"last-prompt","sessionId":"\#(transcript.session)","leafUuid":"\#(user)","lastPrompt":"invented prompt"}"#,
        ]
        if let continued = transcript.continuedIn {
            lines.append(#"{"type":"continued-in","sessionId":"\#(transcript.session)","continuedInSessionId":"\#(continued)"}"#)
        }
        let file = directory.appending(path: "\(transcript.session).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: transcript.mtime], ofItemAtPath: file.path)
        return file
    }

    /// `<configHome>/sessions/<pid>.json`, the CLI's registry record. Read-only in production; this
    /// is a test writing into its own invented home, never a real one.
    @discardableResult
    func writeRegistryRecord(pid: Int32, session: SessionID, cwd: String = "/invented/project",
                             kind: String = "interactive", entrypoint: String? = nil) throws -> URL {
        let directory = root.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = RegistryRecord(pid: pid, sessionId: session.description, cwd: cwd,
                                    startedAt: Date().timeIntervalSince1970 * 1000,
                                    kind: kind, entrypoint: entrypoint)
        let file = directory.appending(path: "\(pid).json")
        try JSONEncoder().encode(record).write(to: file)
        return file
    }

    /// `<configHome>/daemon/roster.json`, keyed by job short.
    @discardableResult
    func writeRoster(_ workers: [String: Int32]) throws -> URL {
        let directory = root.appending(path: "daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = RosterRecord(proto: 1, supervisorPid: 1,
                                  updatedAt: Date().timeIntervalSince1970 * 1000,
                                  workers: workers.mapValues { RosterRecord.Worker(pid: $0) })
        let file = directory.appending(path: "roster.json")
        try JSONEncoder().encode(record).write(to: file)
        return file
    }

    /// `<configHome>/.claude.json`. `projects` keys are written in the order given, which is the
    /// order `ClaudeProjects.order` is expected to recover.
    @discardableResult
    func writeClaudeJSON(projects: [String] = [], onboarded: Bool = true) throws -> URL {
        let entries = projects.map { #""\#($0)":{"hasTrustDialogAccepted":true}"# }.joined(separator: ",")
        let text = #"{"hasCompletedOnboarding":\#(onboarded),"projects":{\#(entries)}}"#
        let file = root.appending(path: ".claude.json")
        try Data(text.utf8).write(to: file)
        return file
    }

    // MARK: - Reading it back

    /// A real `TranscriptIndex` over this home, persisting in memory. C3's own parser is what turns
    /// the transcripts above into the `entrypoint`, `isSidechain`, `teamName` and `continuedIn` the
    /// listing join reads, so the join is exercised end to end rather than against hand-made entries.
    func index() -> TranscriptIndex {
        TranscriptIndex(configHome: configHome, storage: InMemoryIndexStorage())
    }
}
