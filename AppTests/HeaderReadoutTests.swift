import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Gate **G4**: the channel header reads back and never remembers (child spec §10).
///
/// Every engine answer here is **replayed from a committed fixture** — `control-shapes` and
/// `exit-plan-mode` for `get_settings` and the handshake, `zero-cost` for `get_context_usage`, which
/// is the only recording that carries that subtype — and every identifier the tests invent is
/// visibly nobody's. No assertion prints a path, a title or a value read out of a fixture: the
/// comparisons below are booleans and counts with messages written for them (§11).
@MainActor
final class HeaderReadoutTests: XCTestCase {

    // MARK: - G4's discriminating clause

    /// The readout is the engine's answer, not the last thing this app asked for, and not the
    /// answer before it either.
    ///
    /// Three modes are in play and they are all different: the first readback says one thing, a
    /// click asks for a second, and the second readback says a third. A header that echoed the click
    /// shows the click; a header that remembered its first answer shows the first. Only a header
    /// that displays the newest readback passes.
    func testTheReadoutIsTheAnswerAndNotTheRequest() async throws {
        let rig = try await Rig()
        await rig.double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await rig.double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)

        await rig.model.refreshReadbacks()
        XCTAssertTrue(rig.model.readout.mode == .plan,
                      "the first readback did not reach the readout, so nothing that follows is a change")

        // The click: a mode this app asked the engine for, through the same lifecycle the readout
        // reads. It is recorded on the double's log, which is how the assertion below knows the
        // header had something to echo.
        let click = AnyControlRequest(subtype: "set_permission_mode", payload: .object(["mode": .string("acceptEdits")]))
        _ = try await rig.double.send(click, on: rig.key)

        // And the engine's answer, which agrees with neither.
        await rig.double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)
        await rig.model.refreshReadbacks()

        XCTAssertTrue(rig.model.readout.mode == .default,
                      "the readout does not carry the mode the second readback named")
        XCTAssertFalse(rig.model.readout.mode == .acceptEdits,
                       "the readout carries the mode that was asked for rather than the one read back")
        XCTAssertFalse(rig.model.readout.mode == .plan,
                       "the readout kept its first answer instead of the newest one")
        XCTAssertTrue(rig.model.readout.model != nil,
                      "the answer's applied model did not reach the readout")

        let sent = await rig.double.sentSubtypes
        XCTAssertTrue(sent.contains("set_permission_mode"),
                      "the click never went out, so the readback had nothing to disagree with")
        XCTAssertEqual(sent.filter { $0 == "get_settings" }.count, 2,
                       "\(sent.filter { $0 == "get_settings" }.count) settings readback(s) were taken, not 2")
    }

    // MARK: - Contract Y5, asserted mechanically

    /// No file under `App/Timeline/` constructs a ClaudeWire request spec.
    ///
    /// Y5 is invisible at the call site: `send` takes an `AnyControlRequest` and both spellings of
    /// one compile. The only way this stays true as the leaf grows is a check over the text.
    func testNoClaudeWireSpecIsConstructed() throws {
        let root = FixtureRunner.repositoryRoot.appending(path: "App/Timeline")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                                       "App/Timeline could not be walked")
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for spec in ["GetSettings(", "GetContextUsage("] where text.contains(spec) {
                // The file's name and never its path (§11).
                offenders.append("\(url.lastPathComponent):\(spec)")
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the scan read no Swift files, so finding nothing proves nothing")
        XCTAssertTrue(offenders.isEmpty, "\(offenders.count) ClaudeWire spec construction(s) under App/Timeline: \(offenders)")
    }

    // MARK: - The rig

    /// One channel over a recording lifecycle double, with no workspace: nothing here opens a
    /// transcript, so nothing here reads or writes any config home (X9).
    @MainActor
    struct Rig {

        static let branch = "invented-branch-one"

        let key: ChannelKey
        let double: ComposerLifecycleDouble
        let model: ChannelTimelineModel

        init(origin: ChannelOrigin = .owned(.ready), live: Bool = true) async throws {
            key = ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                             session: SidebarFixtures.session("c"))
            double = ComposerLifecycleDouble()
            // The fleet owns a supervisor for a live channel, which is what makes `events(of:)`
            // answer with a stream and `engineReports(of:)` with the retained handshake.
            if live { await double.openEvents(of: key) }
            model = ChannelTimelineModel(key: key, workspace: nil, lifecycle: double)
            model.adopt(ChannelHeader(row: Self.row(key, entry: Self.entry(key, branch: Self.branch), origin: origin)))
        }

        /// An index entry with an invented branch, which is where a branch comes from.
        static func entry(_ key: ChannelKey, branch: String) -> IndexEntry {
            IndexEntry(sessionID: key.session,
                       path: URL(fileURLWithPath: "/invented/config-home/projects/invented/transcript.jsonl"),
                       slug: "invented", cwd: "/invented/project", title: "invented title",
                       titleSource: .firstPrompt, preview: "invented preview", gitBranch: branch,
                       mtime: Date(timeIntervalSince1970: 0), size: 1)
        }

        /// The row the column hands the model, built from the entry the way `ChannelRegistrar`
        /// builds one: the branch is the entry's field and never a literal written here.
        ///
        /// **Presence is pinned.** C4 recomputes it in `ChannelSupervisor.publish()`, so a row that
        /// inherited whatever a double happened to publish would be asserting on somebody else's
        /// default.
        static func row(_ key: ChannelKey, entry: IndexEntry, origin: ChannelOrigin) -> ChannelRow {
            var row = ChannelRow(key: key, title: entry.title, titleSource: entry.titleSource,
                                 preview: entry.preview, cwd: entry.cwd.map { URL(fileURLWithPath: $0) },
                                 gitBranch: entry.gitBranch, agentName: entry.agentName, mtime: entry.mtime,
                                 isRecent: true, mode: .ownedCandidate, decidingRule: "invented-rule",
                                 isProvisional: false)
            var state = SidebarFixtures.state(key, origin: origin)
            state.presence = .idle
            row.state = state
            return row
        }
    }

    /// How many readbacks of one subtype the double has been asked for. A count, never a value.
    static func polls(_ double: ComposerLifecycleDouble, of subtype: String) async -> Int {
        await double.sentSubtypes.filter { $0 == subtype }.count
    }

    // MARK: - Reading the recordings

    /// The body the engine answered one control request with, matched by the request id the
    /// recording carries. Answers are matched to their ask rather than guessed at by shape.
    static func answer(_ fixture: String, to subtype: String) throws -> JSONValue {
        let (asked, answers) = try exchange(fixture)
        let id = try XCTUnwrap(asked[subtype], "fixture \(fixture) carries no control request of subtype \(subtype)")
        return try XCTUnwrap(answers[id], "fixture \(fixture) carries no answer to its \(subtype) request")
    }

    /// The channel's handshake, as the fleet retains it: the recorded `initialize` answer, wrapped
    /// the way `ClaudeProcess` wraps one.
    static func handshake(_ fixture: String) throws -> WireEvent {
        let raw = try answer(fixture, to: "initialize")
        return .handshakeCompleted(Handshake(initialize: InitializeResponse(raw: raw), pending: []), .first)
    }

    /// The fixture's `result` frames, as the events a channel's consumers see.
    static func results(_ fixture: String) throws -> [WireEvent] {
        try FixtureRunner.frames(fixture).compactMap { frame in
            if case .result = frame { return .frame(frame, .first) }
            return nil
        }
    }

    /// Every control request's subtype-to-id, and every answer by the id it answers. One pass, both
    /// directions of the recording: an ask is written into the engine and its answer comes back out.
    private static func exchange(_ fixture: String) throws -> (asked: [String: String], answers: [String: JSONValue]) {
        let url = FixtureRunner.directory(fixture).appending(path: "frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        var asked: [String: String] = [:]
        var answers: [String: JSONValue] = [:]
        for line in text.split(separator: "\n") {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let frame = value["frame"] else { continue }
            switch frame["type"]?.stringValue {
            case "control_request":
                if let subtype = frame["request"]?["subtype"]?.stringValue,
                   let id = frame["request_id"]?.stringValue { asked[subtype] = id }
            case "control_response":
                if let id = frame["response"]?["request_id"]?.stringValue,
                   let body = frame["response"]?["response"] { answers[id] = body }
            default: continue
            }
        }
        return (asked, answers)
    }
}
