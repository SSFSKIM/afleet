import AfleetCore
import FleetKit
import Foundation
import TerminalCore
@testable import TerminalPanel
import XCTest

/// What a pane says about itself, as a value: the exit it shows, and the buttons it offers
/// (spec Design §2, §6; gate G3.2).
///
/// Every one of these assertions is on `PaneReadout` and never on a rendered `Text`, because the
/// view formats these fields and nothing else — so what the window shows is what is asserted here.
@MainActor
final class PaneReadoutTests: XCTestCase {

    private func request(purpose: PanePurpose) -> PaneRequest {
        PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "true"],
            cwd: URL(filePath: "/invented/channel"),
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: purpose
        )
    }

    private let everyPurpose: [PanePurpose] = [
        .hatch(SessionID(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)),
        .trustReview(SessionID(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)),
        .attach(JobShort(rawValue: "ab12")),
        .logs(JobShort(rawValue: "ab12")),
        .shell,
        .command,
    ]

    // MARK: Group 3 — where Restart pane is honest

    func testAShellPaneThatExitedOffersRestart() {
        let readout = PaneReadout(request: nil, state: .exited(.exited(code: 0)))

        XCTAssertTrue(readout.actions.contains(.restart),
                      "the one pane the panel made itself cannot be restarted")
        XCTAssertNil(readout.newPaneOrigin,
                     "a shell pane sent the user somewhere else for a pane it can reopen itself")
    }

    /// One assertion per `PanePurpose`, and all of them say no. W8 is binding — the panel never
    /// spawns `claude` on its own initiative — and item 47's `.command` *is* `claude`, so the
    /// button would be exactly that. A model that admitted `.command` fails this once.
    func testNoPaneRequestPurposeOffersRestartWhenItExits() {
        for purpose in everyPurpose {
            let readout = PaneReadout(request: request(purpose: purpose), state: .exited(.exited(code: 0)))
            XCTAssertFalse(readout.actions.contains(.restart),
                           "purpose=\(readout.purpose) offered Restart pane")
            XCTAssertNotNil(readout.newPaneOrigin,
                            "purpose=\(readout.purpose) says nowhere a new pane comes from")
        }
    }

    func testEveryPaneOffersClose() {
        let states: [PaneState] = [
            .starting,
            .running(4_242),
            .stopped(signal: SIGTSTP),
            .exited(.exited(code: 0)),
            .failed(.other("spawn refused")),
        ]
        for state in states {
            let readout = PaneReadout(request: nil, state: state)
            XCTAssertTrue(readout.actions.contains(.close), "state=\(readout.status) cannot be closed")
        }
    }

    // MARK: Group 5 — the exit, named

    func testAnExitedPaneNamesItsCode() {
        let readout = PaneReadout(request: nil, state: .exited(.exited(code: 3)))

        XCTAssertEqual(readout.status, .exited(code: 3), "status=\(readout.status)")
        XCTAssertTrue(readout.summary.contains("3"), "the exit summary does not name the code")
    }

    /// A signalled pane names the signal. 137 is `paneExitCode`'s lossy answer for C4, which keys
    /// re-adoption on the event and not the number; a person reading a pane is owed the signal.
    func testASignalledPaneNamesTheSignalAndNotTheLossyStatus() {
        let readout = PaneReadout(request: nil, state: .exited(.signalled(signal: SIGKILL)))

        XCTAssertEqual(readout.status, .signalled(signal: 9), "status=\(readout.status)")
        XCTAssertTrue(readout.summary.contains("SIGKILL"), "the summary does not name the signal")
        XCTAssertFalse(readout.summary.contains("137"), "the summary shows 128 + signal to a person")
    }

    func testAFailedPaneSaysItNeverStarted() {
        let readout = PaneReadout(request: nil, state: .failed(.other("posix_spawn refused")))

        XCTAssertEqual(readout.status, .failed, "status=\(readout.status)")
        XCTAssertTrue(readout.summary.lowercased().contains("never started"),
                      "the summary does not say the pane never started")
        XCTAssertEqual(readout.failureDetail, "posix_spawn refused", "the failure's reason is lost")
    }

    func testAStoppedPaneOffersContinueAndNotRestart() {
        let readout = PaneReadout(request: nil, state: .stopped(signal: SIGTSTP))

        XCTAssertEqual(readout.status, .suspended(signal: SIGTSTP), "status=\(readout.status)")
        XCTAssertTrue(readout.actions.contains(.resume), "a suspended pane cannot be continued")
        // A suspended child is a job the user suspended on purpose; restarting it would be the
        // panel destroying that work.
        XCTAssertFalse(readout.actions.contains(.restart), "a suspended pane offered Restart pane")
    }

    func testAPanesPurposeIsSaidInWords() {
        XCTAssertEqual(PaneReadout(request: nil, state: .starting).purpose, "Shell")
        let attached = PaneReadout(
            request: request(purpose: .attach(JobShort(rawValue: "ab12"))),
            state: .starting
        )
        XCTAssertTrue(attached.purpose.contains("ab12"), "purpose=\(attached.purpose)")
    }
}
