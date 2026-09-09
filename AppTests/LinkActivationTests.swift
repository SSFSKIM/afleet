import Foundation
import AppKit
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Root spec §9.6 and contract X7: **Cmd-click forces a new window**, and the modifier is read at the
/// click. C7's Parent-Level Acceptance item 3 states it of every `WorkspaceLink` a timeline click can
/// raise, so both of the timeline's emission paths are exercised here — the `.file` a tool row's path
/// opens and the `.url` a markdown link opens.
///
/// The distinction this file exists for is not "a link reached the router" — every existing link test
/// asserts that, and they all passed while both call sites named `.currentPanel` unconditionally. It
/// is that the *same* path, clicked twice, reaches the router with two different destinations.
///
/// Every path and URL below is invented and nothing is read from this machine (§11).
@MainActor
final class LinkActivationTests: XCTestCase {

    override func tearDown() async throws {
        LinkActivation.modifiers = { NSApp?.currentEvent?.modifierFlags ?? [] }
        try await super.tearDown()
    }

    // MARK: - The rule

    /// A tool row's path: Command held opens a new window, nothing held opens the current panel.
    func testAPathFromAToolRowCarriesTheModifiersOfItsClick() async throws {
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router, cwd: URL(filePath: "/invented/project"))

        LinkActivation.modifiers = { .command }
        FileLink.open("/invented/project/notes/an-invented-file.txt", line: 12, in: context)
        try await settle(router, until: 1)

        LinkActivation.modifiers = { [] }
        FileLink.open("/invented/project/notes/an-invented-file.txt", line: 12, in: context)
        try await settle(router, until: 2)

        let destinations = await router.destinations
        XCTAssertEqual(destinations, [.newWindow, .currentPanel],
                       "the two clicks reached the router as \(destinations)")
        let links = await router.opened
        XCTAssertEqual(links.filter { if case .file = $0 { true } else { false } }.count, 2,
                       "\(links.count) link(s) reached the router and not both were file links")
    }

    /// A markdown link's URL, on the same terms. `.url` is the case whose new window is the *system*
    /// browser rather than a popped-out tab (X7's `popsOutForNewWindow`), and that decision is the
    /// router's — what this side owes it is the destination the user asked for.
    func testAMarkdownURLCarriesTheModifiersOfItsClick() async throws {
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router)
        let destination = try XCTUnwrap(TimelineLinkDestination.url(for: "https://invented.example/one"))

        LinkActivation.modifiers = { .command }
        XCTAssertTrue(TimelineLinkDestination.open(destination, in: context), "the URL opened nothing")
        try await settle(router, until: 1)

        LinkActivation.modifiers = { [] }
        XCTAssertTrue(TimelineLinkDestination.open(destination, in: context), "the URL opened nothing")
        try await settle(router, until: 2)

        let destinations = await router.destinations
        XCTAssertEqual(destinations, [.newWindow, .currentPanel],
                       "the two clicks reached the router as \(destinations)")
        let urls = await router.openedURLs
        XCTAssertEqual(urls.count, 2, "\(urls.count) of the two links reached the router as a URL link")
    }

    /// Command with another modifier is still Command: the others carry no meaning for a link, and a
    /// reading that demanded Command *exactly* would drop the gesture for a user holding Caps Lock.
    func testCommandWithAnotherModifierIsStillANewWindow() async throws {
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router)

        LinkActivation.modifiers = { [.command, .shift] }
        FileLink.open("/invented/project/an-invented-file.txt", line: nil, in: context)
        try await settle(router, until: 1)

        let destinations = await router.destinations
        XCTAssertEqual(destinations, [.newWindow], "a Cmd-Shift click reached the router as \(destinations)")
    }

    // MARK: - Rig

    /// Waits for the fire-and-forget task both call sites spawn. Fulfilled by the delivery it waits
    /// for and given no deadline of its own; the harness's execution-time allowance is the watchdog.
    private func settle(_ router: RecordingLinkRouter, until count: Int) async throws {
        while await router.destinations.count < count { await Task.yield() }
    }
}
