import AppKit
import Foundation
import GhosttyTerminal
import Synchronization
@testable import TerminalCore
import XCTest

private final class LockedArray<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    var value: [Element] {
        storage.withLock { $0 }
    }

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }
}

private final class ResizeCallbackSource: Sendable {
    typealias Callback = @Sendable (InMemoryTerminalViewport) -> Void

    private let callback = Mutex<Callback?>(nil)

    func install(_ callback: @escaping Callback) {
        self.callback.withLock { $0 = callback }
    }

    func send(_ viewport: InMemoryTerminalViewport) {
        let callback = callback.withLock { $0 }
        callback?(viewport)
    }
}

private struct FinishCall: Equatable, Sendable {
    let exitCode: UInt32
    let runtimeMilliseconds: UInt64
}

@MainActor
final class AdapterWiringTests: XCTestCase {
    /// This headless test asserts adapter wiring, not rendering; rendered-grid behavior belongs to G2.
    func testViewUsesTheInMemorySessionAndInstallsAController() {
        let surface = makeSurface()

        guard let terminalView = surface.view as? AppTerminalView else {
            XCTFail("app-terminal-view=absent")
            return
        }
        guard case let .inMemory(configuredSession) = terminalView.configuration.backend else {
            XCTFail("in-memory-backend=absent")
            return
        }

        XCTAssertTrue(configuredSession === surface.session, "configured-session=wrong")
        XCTAssertTrue(terminalView.controller != nil, "terminal-controller=absent")
        XCTAssertTrue(!surface.session.suppressesPixelOnlyResizes, "pixel-resize-delivery=suppressed")
        XCTAssertTrue(
            terminalView.configuration.resizeThrottleMilliseconds == 0,
            "resize-throttle=nonzero"
        )
        XCTAssertTrue(surface.session.readViewportText() == nil, "headless-surface=unexpected")
    }

    /// This headless test asserts input wiring, not rendering; rendered-grid behavior belongs to G2.
    func testSessionWriteDrivesOnInputWithBytesIntact() async {
        let surface = makeSurface()
        let received = LockedArray<Data>()
        let expected = Data([0x1B, 0x5B, 0x41, 0x00])
        surface.onInput = { data in
            received.append(data)
        }
        let session = surface.session

        await Task.detached {
            session.sendInput(expected)
        }.value

        XCTAssertTrue(received.value.count == 1, "onInput-count=\(received.value.count)")
        XCTAssertTrue(received.value.first == expected, "onInput-bytes=changed")
        XCTAssertTrue(session.readViewportText() == nil, "headless-surface=unexpected")
    }

    /// This headless test asserts resize wiring, not rendering; rendered-grid behavior belongs to G2.
    func testSessionResizeDrivesOnResizeWithGridAndPixelsIntact() async {
        let resizeSource = ResizeCallbackSource()
        let surface = makeSurface(resizeSource: resizeSource)
        let received = LockedArray<TerminalSize>()
        surface.onResize = { size in
            received.append(size)
        }
        let viewport = InMemoryTerminalViewport(
            columns: 113,
            rows: 37,
            widthPixels: 1_921,
            heightPixels: 1_073,
            cellWidthPixels: 17,
            cellHeightPixels: 29
        )

        await Task.detached {
            resizeSource.send(viewport)
        }.value

        XCTAssertTrue(received.value.count == 1, "onResize-count=\(received.value.count)")
        guard let size = received.value.first else { return }
        XCTAssertTrue(size.rows == 37, "onResize-rows=changed")
        XCTAssertTrue(size.columns == 113, "onResize-columns=changed")
        XCTAssertTrue(size.pixelWidth == 1_921, "onResize-pixel-width=changed")
        XCTAssertTrue(size.pixelHeight == 1_073, "onResize-pixel-height=changed")
        XCTAssertTrue(surface.session.readViewportText() == nil, "headless-surface=unexpected")
    }

    /// This headless test asserts exit wiring, not rendering; rendered-grid behavior belongs to G2.
    func testProcessExitFinishesTheSessionExactlyOnceAndOnlyFromTheExitCall() {
        let calls = LockedArray<FinishCall>()
        var surface: GhosttyTerminalSurface? = makeSurface(finishCalls: calls)
        let session = surface!.session
        weak let releasedSurface = surface

        surface!.processDidExit(code: 7)
        surface = nil

        XCTAssertTrue(releasedSurface == nil, "adapter-release=absent")
        XCTAssertTrue(calls.value.count == 1, "finish-count=\(calls.value.count)")
        XCTAssertTrue(calls.value.first?.exitCode == 7, "finish-exit-code=changed")
        XCTAssertTrue(calls.value.first?.runtimeMilliseconds == 42, "finish-runtime=changed")
        XCTAssertTrue(session.readViewportText() == nil, "headless-surface=unexpected")
    }

    /// This headless test asserts feed wiring and return behavior, not rendering; rendered-grid behavior belongs to G2.
    func testFeedWithoutAnAttachedSurfaceReturnsWithoutRendering() {
        let surface = makeSurface()
        let clock = ContinuousClock()
        let start = clock.now

        surface.feed(Data("invented output\r\n".utf8))

        XCTAssertTrue(clock.now - start < .seconds(1), "feed-returned=late")
        XCTAssertTrue(surface.session.readViewportText() == nil, "headless-surface=unexpected")
    }

    /// This headless test asserts terminal-description resource wiring, not rendering; rendered-grid behavior belongs to G2.
    func testTerminalDescriptionUsesSupportedResourceAndFallsBackWhenInjectedResourceIsNil() {
        let injectedDirectory = URL(filePath: "/invented/terminfo")
        let capable = makeSurface(terminfoDirectory: injectedDirectory)
        let fallback = makeSurface(terminfoDirectory: nil)
        let production = GhosttyTerminalSurface()

        XCTAssertTrue(capable.terminalDescription.term == "xterm-ghostty", "capable-TERM=changed")
        XCTAssertTrue(
            capable.terminalDescription.terminfoDirectory == injectedDirectory,
            "capable-terminfo=changed"
        )
        XCTAssertTrue(fallback.terminalDescription.term == "xterm-256color", "fallback-TERM=changed")
        XCTAssertTrue(fallback.terminalDescription.terminfoDirectory == nil, "fallback-terminfo=present")

        if let supportedDirectory = GhosttyRuntimeResources.terminfoDirectoryURL {
            XCTAssertTrue(production.terminalDescription.term == "xterm-ghostty", "production-TERM=changed")
            XCTAssertTrue(
                production.terminalDescription.terminfoDirectory == supportedDirectory,
                "production-terminfo=changed"
            )
        } else {
            XCTAssertTrue(production.terminalDescription.term == "xterm-256color", "production-fallback=absent")
            XCTAssertTrue(production.terminalDescription.terminfoDirectory == nil, "production-terminfo=present")
        }
    }

    /// This headless test asserts appearance wiring, not rendering; visual appearance belongs to G2.
    func testAppearanceMapsKnownThemeFontAndSizeToTheController() {
        let surface = makeSurface()

        surface.setAppearance(
            TerminalAppearance(themeName: "Dracula", fontName: "Invented Mono", fontSize: 15.5)
        )

        XCTAssertTrue(
            surface.terminalController.terminalConfiguration.rendered
                == "font-family = Invented Mono\nfont-size = 15.5",
            "font-appearance=changed"
        )
        XCTAssertTrue(
            surface.terminalController.theme.light.rendered.contains("background = 282a36"),
            "named-theme=absent"
        )
        XCTAssertTrue(
            surface.terminalController.theme.light == surface.terminalController.theme.dark,
            "named-theme=not-fixed"
        )
    }

    /// This headless test asserts that appearance state is per-surface, not rendering;
    /// visual appearance belongs to G2.
    func testAppearanceOnOneSurfaceLeavesAnotherSurfaceUntouched() {
        let first = makeSurface()
        let second = makeSurface()

        first.setAppearance(
            TerminalAppearance(themeName: "Dracula", fontName: "Invented Mono", fontSize: 15.5)
        )
        let third = makeSurface()

        XCTAssertFalse(
            first.terminalController === second.terminalController,
            "surface-controller=shared"
        )
        XCTAssertFalse(
            first.terminalController === TerminalController.shared,
            "surface-controller=process-wide"
        )
        XCTAssertTrue(
            second.terminalController.terminalConfiguration.rendered
                == TerminalConfiguration().rendered,
            "untouched-surface-font=changed"
        )
        XCTAssertTrue(
            second.terminalController.theme == TerminalTheme.default,
            "untouched-surface-theme=changed"
        )
        XCTAssertTrue(
            third.terminalController.terminalConfiguration.rendered
                == TerminalConfiguration().rendered,
            "new-surface-font=inherited"
        )
        XCTAssertTrue(third.terminalController.theme == TerminalTheme.default, "new-surface-theme=inherited")
        XCTAssertTrue(
            first.terminalController.terminalConfiguration.rendered
                == "font-family = Invented Mono\nfont-size = 15.5",
            "own-surface-font=absent"
        )
    }

    /// This headless test asserts clipboard-confirmation wiring and its decisions, not rendering;
    /// rendered-grid behavior belongs to G2.
    func testClipboardConfirmationDelegateIsInstalledRetainedAndKeepsTheDependencyDefault() {
        let surface = makeSurface()

        guard let terminalView = surface.view as? AppTerminalView else {
            XCTFail("app-terminal-view=absent")
            return
        }
        // The view holds its delegate weakly, so an unretained policy would be gone by now
        // and every protected request — a user's own paste included — would be denied.
        guard let installed = terminalView.delegate as? TerminalClipboardPolicy else {
            XCTFail("clipboard-confirmation-delegate=absent")
            return
        }

        XCTAssertTrue(installed === surface.clipboardPolicy, "clipboard-policy=unretained")
        XCTAssertTrue(TerminalClipboardPolicy.allows(.paste), "user-paste=denied")
        XCTAssertFalse(TerminalClipboardPolicy.allows(.osc52Read), "osc52-read=allowed")
        XCTAssertFalse(TerminalClipboardPolicy.allows(.osc52Write), "osc52-write=allowed")
        XCTAssertTrue(surface.session.readViewportText() == nil, "headless-surface=unexpected")
    }

    private func makeSurface(
        terminfoDirectory: URL? = nil,
        resizeSource: ResizeCallbackSource = ResizeCallbackSource(),
        finishCalls: LockedArray<FinishCall>? = nil
    ) -> GhosttyTerminalSurface {
        GhosttyTerminalSurface(
            terminfoDirectory: terminfoDirectory,
            sessionFactory: { write, resize, suppressesPixelOnlyResizes in
                resizeSource.install(resize)
                return InMemoryTerminalSession(
                    write: write,
                    resize: resize,
                    suppressesPixelOnlyResizes: suppressesPixelOnlyResizes
                )
            },
            finishSession: { session, exitCode, runtimeMilliseconds in
                finishCalls?.append(FinishCall(
                    exitCode: exitCode,
                    runtimeMilliseconds: runtimeMilliseconds
                ))
                session.finish(
                    exitCode: exitCode,
                    runtimeMilliseconds: runtimeMilliseconds
                )
            },
            runtimeMilliseconds: { 42 }
        )
    }
}
