import AppKit
import Foundation
import TerminalCore

// The S1 harness (spec Design, gate G2). One `NSWindow`, one `GhosttyTerminalSurface`, one
// `PTYProcess`, and one leg per process:
//
//   swift run --package-path Workbench S1Harness selftest
//   swift run --package-path Workbench S1Harness flood [--seconds <n>]
//   swift run --package-path Workbench S1Harness shell
//   swift run --package-path Workbench S1Harness attach <short> [--detach] [--seconds <n>]
//
// `selftest` and `flood` are machine-checked and exit with a status: 0 pass, 1 fail. `shell`
// holds the window open for the half of G2a only a person at the screen can witness — the IME
// composition, the live drag, and whether it looks right. `attach` is G2b/c: it renders a
// background job's screen, delivers a Ctrl+Z, and reports what the PTY layer observed.
//
// **This harness never starts an engine.** The promptless `claude --bg --resume` job the attach
// leg attaches to is started by hand, outside this process, so that no `CLAUDE_CODE_*` marker
// from this harness can reach it. The harness's own child environment is built by name from
// `ChildEnvironment.allowedNames` and is never the inherited one.
//
// Nothing printed here is a path, an environment, or a session id (root §6.3, §11): the report
// is counts and durations.

// Line buffering, because most of what this harness prints is read while it is still running —
// a leg's progress down a pipe, and the `shell` leg's own note to the person at the screen. Block
// buffering holds all of it until exit, which for a leg that holds its window open is never.
setvbuf(stdout, nil, _IOLBF, 0)

let application = NSApplication.shared
// An unbundled `swift run` binary is a background app by default: it never becomes key, never
// receives an input method, and would fail G2a's IME leg for a reason that says nothing about
// the renderer. `.regular` plus an activation is what makes the window a real one.
application.setActivationPolicy(.regular)

let leg: Leg
switch Leg.parse(Array(CommandLine.arguments.dropFirst())) {
case let .success(parsed):
    leg = parsed
case let .failure(message):
    FileHandle.standardError.write(Data("\(message)\n\(Leg.usage)\n".utf8))
    exit(64)
}

let harness = MainActor.assumeIsolated { Harness(leg: leg) }

// The leg starts from `applicationDidFinishLaunching`, not from a bare `Task` in top-level code:
// a task enqueued before the run loop owns the thread is never picked up, which presents as a
// window that opens and then does nothing (S3 recorded the same ordering).
final class Launcher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        harness.openWindow()
        Task { @MainActor in
            let status = await harness.run()
            exit(status)
        }
    }
}

let launcher = Launcher()
application.delegate = launcher
application.run()
