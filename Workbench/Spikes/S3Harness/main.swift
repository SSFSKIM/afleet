import AppKit
import Darwin
import EditorCore
import Foundation

// The S3 harness (spec Design §8, gate G2). One route per process, because the first of the two
// cold-load numbers is measured from *process start* and a second route in the same process
// would be warm by definition.
//
//   swift run [-c release] --package-path Workbench S3Harness \
//       [--route scheme|blob|file] [--hold] [--frames <n>] [--bytes <n>]
//
// `--hold` leaves the window up after the report for the human half of "no visible jank";
// `--frames` and `--bytes` shrink the scroll sample and the synthetic file when the run is a
// diagnostic rather than a measurement.
//
// Its report goes to stdout as one JSON object and nothing else, so the run is scriptable; the
// human-readable summary goes to stderr. Exit 0 when the route carries the document, a
// dynamic-import chunk and all five workers — the workers proven by answering, not merely by
// starting without an error; 2 when it does not, which is the signal to advance to the next
// route; 5 when every load path is carried but the cold load is over budget, which is a
// measurement and not a broken run.

/// The kernel's own record of when this process began, which is earlier than anything Swift can
/// observe: it includes dyld, the SwiftPM-built binary's startup and AppKit's. The gate is
/// "cold load under one second from `swift run`", so the clock has to start where the process
/// does and not where `main` does.
func processStartDate() -> Date {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let started = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
}

let start = processStartDate()
let arguments = CommandLine.arguments

var options = Spike.Options()
options.holdOpen = arguments.contains("--hold")

var route = WorkerLoadingRoute.schemeForEverything
if let index = arguments.firstIndex(of: "--route"), index + 1 < arguments.count {
    switch arguments[index + 1] {
    case "scheme": route = .schemeForEverything
    case "blob": route = .blobWorkers
    case "file": route = .fileURLForEverything
    default:
        FileHandle.standardError.write(Data("unknown route \(arguments[index + 1])\n".utf8))
        exit(64)
    }
}
if let index = arguments.firstIndex(of: "--frames"), index + 1 < arguments.count,
   let frames = Int(arguments[index + 1]) {
    options.scrollFrames = frames
}
if let index = arguments.firstIndex(of: "--bytes"), index + 1 < arguments.count,
   let bytes = Int(arguments[index + 1]) {
    options.sourceBytes = bytes
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)

Trace.start = start
Trace.log("main: route \(route.rawValue)")

let spike = MainActor.assumeIsolated { Spike(route: route, processStart: start, options: options) }

MainActor.assumeIsolated { spike.openWindow() }
Trace.log("main: window open, entering the run loop")

// The work is started from `applicationDidFinishLaunching` rather than from a bare `Task` in
// top-level code. Top-level code's implicit main-actor context is not the same executor AppKit
// drains once `NSApplication.run()` has taken the thread, and a task enqueued before the run
// loop owns the thread is never picked up — which presents as a process that opens a window and
// then does nothing at all. Starting from the delegate callback is the ordering that has AppKit
// already running when the first job is enqueued.
final class Launcher: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.log("app: did finish launching")
        // Ordered front again, and above everything, only now.
        //
        // `requestAnimationFrame` stops in an occluded window: AppKit reports the window
        // unoccluded only once it is genuinely on screen, and WebKit stops driving frames when
        // it is not. A harness launched from a terminal that covers the screen therefore
        // measures nothing at all — every rAF-based probe simply never fires. This was found by
        // running it: the first two runs recorded no frame and no render callback whatsoever.
        spike.bringWindowForward()
        Task { @MainActor in await drive() }
    }
}

@MainActor
func drive() async {
    let status = await spike.run()

    let payload = try? JSONSerialization.data(
        withJSONObject: spike.finalReport,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(payload ?? Data("{\"error\":\"report is not JSON-representable\"}".utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))

    Summary.write(spike.finalReport, status: status, to: FileHandle.standardError)

    guard spike.holdsOpen else {
        exit(status)
    }
    // --hold is the human half of "no visible jank": the numbers are already printed, the
    // window stays up, and the person looking at it is named as the witness in the report
    // rather than replaced by a number that cannot see.
    FileHandle.standardError.write(Data("\n--hold: the window is open. Ctrl-C to finish.\n".utf8))
}

let launcher = Launcher()
application.delegate = launcher
application.run()
