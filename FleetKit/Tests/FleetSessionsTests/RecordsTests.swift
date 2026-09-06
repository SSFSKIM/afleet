import XCTest
@testable import FleetSessions

/// The four holder files decode the way the CLI's own defensive reader does. Every identifier here is invented:
/// no byte of these samples came off a real engine (parent §11).
final class RecordsTests: XCTestCase {
    func testAFullRegistryRecordDecodesAndUnknownKeysAreDropped() throws {
        let json = """
        {"pid": 4242, "sessionId": "2f7c1a90-1111-4a2b-8c3d-0e5f60718293",
         "cwd": "/scratch/project", "startedAt": 1757040761000, "procStart": "Fri Sep  5 03:12:41 2026",
         "version": "2.1.258", "peerProtocol": 1, "peerFeatures": ["a"], "kind": "interactive",
         "entrypoint": "cli", "pidDomain": "local", "messagingSocketPath": "/scratch/sock",
         "name": "invented-name", "nameSource": "user", "nameSince": 1757040761000,
         "jobId": "j00001", "parkedJobId": "j00002", "status": "busy", "waitingFor": "permission",
         "state": "working", "detail": "a detail", "tempo": "fast", "unknownFutureKey": {"x": 1}}
        """
        let record = try XCTUnwrap(RegistryRecord.decode(Data(json.utf8)))
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.sessionId, "2f7c1a90-1111-4a2b-8c3d-0e5f60718293")
        XCTAssertEqual(record.cwd, "/scratch/project")
        XCTAssertEqual(record.startedAt, 1_757_040_761_000)
        XCTAssertEqual(record.procStart, "Fri Sep  5 03:12:41 2026")
        XCTAssertEqual(record.version, "2.1.258")
        XCTAssertEqual(record.kind, "interactive")
        XCTAssertEqual(record.entrypoint, "cli")
        XCTAssertEqual(record.name, "invented-name")
        XCTAssertEqual(record.nameSource, "user")
        XCTAssertEqual(record.jobId, "j00001")
        XCTAssertEqual(record.parkedJobId, "j00002")
        XCTAssertEqual(record.status, "busy")
        XCTAssertEqual(record.waitingFor, "permission")
        XCTAssertEqual(record.state, "working")
        XCTAssertEqual(record.detail, "a detail")
        XCTAssertEqual(record.tempo, "fast")
        XCTAssertEqual(record.messagingSocketPath, "/scratch/sock")

        // The record is read-only, so an unknown key has nowhere to live: it is dropped and never re-emitted.
        let round = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        XCTAssertNil(round?["unknownFutureKey"])
        XCTAssertNil(round?["peerProtocol"])
    }

    func testAMistypedRequiredFieldIsRejectedAsNilRatherThanThrown() {
        let json = #"{"pid": "4242", "sessionId": "2f7c1a90-1111-4a2b-8c3d-0e5f60718293", "cwd": "/x", "startedAt": 1, "kind": "interactive"}"#
        XCTAssertNil(RegistryRecord.decode(Data(json.utf8)))
    }

    func testAMistypedOptionalFieldBecomesNilAndTheRecordSurvives() throws {
        let json = #"{"pid": 4242, "sessionId": "2f7c1a90-1111-4a2b-8c3d-0e5f60718293", "cwd": "/x", "startedAt": 1, "kind": "interactive", "name": 17, "status": ["busy"]}"#
        let record = try XCTUnwrap(RegistryRecord.decode(Data(json.utf8)))
        XCTAssertNil(record.name)
        XCTAssertNil(record.status)
        XCTAssertEqual(record.pid, 4242)
    }

    func testTheThreeJobStatesAndTheRosterDecode() throws {
        let working = try XCTUnwrap(JobRecord.decode(Data(#"{"state":"working","template":"bg","sessionId":"2f7c1a90-1111-4a2b-8c3d-0e5f60718293","cwd":"/scratch"}"#.utf8)))
        XCTAssertEqual(working.state, "working")
        XCTAssertFalse(working.isTerminal)
        let blocked = try XCTUnwrap(JobRecord.decode(Data(#"{"state":"blocked","needs":"permission"}"#.utf8)))
        XCTAssertEqual(blocked.needs, "permission")
        XCTAssertFalse(blocked.isTerminal)
        let stopped = try XCTUnwrap(JobRecord.decode(Data(#"{"state":"stopped","resumeSessionId":"2f7c1a90-1111-4a2b-8c3d-0e5f60718293"}"#.utf8)))
        XCTAssertTrue(stopped.isTerminal)
        XCTAssertEqual(JobRecord.terminalStates, ["done", "failed", "stopped"])
        XCTAssertNil(JobRecord.decode(Data(#"{"template":"bg"}"#.utf8)), "a job with no state is not a job record")

        let roster = try XCTUnwrap(RosterRecord.decode(Data(#"{"proto":1,"supervisorPid":900,"updatedAt":17.5,"workers":{"j00001":{"pid":4242,"procStart":"Fri Sep  5 03:12:41 2026"}}}"#.utf8)))
        XCTAssertEqual(roster.proto, 1)
        XCTAssertEqual(roster.supervisorPid, 900)
        XCTAssertEqual(Set(roster.workers.keys), ["j00001"])
        XCTAssertEqual(roster.workers["j00001"]?.pid, 4242)
        XCTAssertNil(RosterRecord.decode(Data(#"{"proto":1}"#.utf8)), "a roster with no workers is not a roster")
    }

    func testAnAgentsArrayDecodesAJobRowAndAnInteractiveRow() {
        let json = """
        [{"pid": 4243, "id": "j00001", "cwd": "/scratch", "kind": "background", "startedAt": 1757040761000,
          "sessionId": "2f7c1a90-1111-4a2b-8c3d-0e5f60718293", "state": "working"},
         {"pid": 4242, "cwd": "/scratch", "kind": "interactive", "startedAt": 1757040760000,
          "sessionId": "3a8d2b01-2222-4c3d-9e4f-1a2b3c4d5e6f", "status": "idle"}]
        """
        let rows = AgentsRow.decodeArray(Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "j00001")
        XCTAssertEqual(rows[0].state, "working")
        XCTAssertEqual(rows[0].kind, "background")
        XCTAssertNil(rows[1].id)
        XCTAssertNil(rows[1].state)
        XCTAssertEqual(rows[1].status, "idle")
        XCTAssertEqual(rows[1].pid, 4242)
    }
}
