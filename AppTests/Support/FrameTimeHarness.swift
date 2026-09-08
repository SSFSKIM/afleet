import AppKit
import Foundation
import OSLog
import QuartzCore
@testable import Afleet

/// What one measured run reports.
struct FrameTimeReport {
    var p50: TimeInterval = 0
    var p99: TimeInterval = 0
    var worst: TimeInterval = 0
    /// Frames measured, after the warm-up window is discarded.
    var sampled: Int = 0
    /// Display-link intervals longer than one and a half times the nominal refresh period. Reported
    /// because a dropped frame is what a user sees, and **not asserted**, because the nominal period
    /// itself is about 16.7 ms on a sixty-hertz panel: an assertion on the interval would be red on
    /// a perfectly idle machine and would say nothing about the renderer.
    var dropped: Int = 0
    var phases: RenderPhases = RenderPhases()

    var milliseconds: (p50: Double, p99: Double, worst: Double) {
        (p50 * 1000, p99 * 1000, worst * 1000)
    }
}

/// The S7 instrument: a real window, on screen, with the frame's work timed on the main thread.
///
/// **What is measured, and why it is not the display-link interval.** "Frame time under 16 ms"
/// means the work of a frame fits inside a frame's budget. The interval between display-link
/// callbacks does not measure that: it is pinned to the panel's refresh period, so on an idle
/// sixty-hertz display every interval reads about 16.7 ms and a p99 taken over intervals is red
/// before the renderer has done anything at all. What this measures instead is the span from the
/// start of one update to the point where the view hierarchy is laid out and ready to draw —
/// update, layout, display — on the main thread, which is the work a slow renderer actually adds
/// and the work that makes a frame drop.
///
/// The drop count is kept beside it as the corroborating signal, reported and never asserted.
///
/// **The instrument is tested before the spike is trusted.** `FrameTimeHarnessTests` drives it with
/// a closure that blocks the main thread for forty milliseconds every tenth update and requires the
/// reported p99 to exceed sixteen; then with an empty closure and requires it to be under. An
/// instrument that cannot go red is not an instrument, and one that is always red is not either.
@MainActor
final class FrameTimeHarness: NSObject {

    /// Samples inside this window after the first update are discarded. The first frames of a
    /// hosted view pay for font loading, layer creation and the first layout of every visible row —
    /// real costs, but not the steady-state cost the gate is about, and at ninety samples a single
    /// warm-up spike *is* the ninety-ninth percentile.
    static let warmUp: TimeInterval = 0.5

    private var window: NSWindow?
    private var link: CADisplayLink?
    private var update: ((Int) -> RenderPhases)?

    private var samples: [TimeInterval] = []
    private var phases = RenderPhases()
    private var dropped = 0

    private var updatesPerSecond: Double = 30
    private var deadline: Date = .distantPast
    private var startedAt: Date = .distantPast
    private var lastUpdate: Date = .distantPast
    private var lastCallback: CFTimeInterval = 0
    private var nominal: CFTimeInterval = 1.0 / 60.0
    private var updateCount = 0
    private var finish: (@MainActor (FrameTimeReport) -> Void)?

    private let signposter = OSSignposter(subsystem: "com.afleet.app", category: "s7")

    /// Drives `update` at `updatesPerSecond` for `duration`, hosting `view` in a real window.
    ///
    /// `update` returns the phase split for that update, so the report can say which of hosting,
    /// markdown and highlighting dominated — which is what separates the child spec's branch 2 from
    /// its branch 3.
    func measure(view: NSView, updatesPerSecond rate: Double, duration: TimeInterval,
                 update: @escaping (Int) -> RenderPhases) async -> FrameTimeReport {
        self.update = update
        self.updatesPerSecond = rate
        samples = []
        phases = RenderPhases()
        dropped = 0
        updateCount = 0

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentLayoutRect
        view.autoresizingMask = [.width, .height]
        window.orderFrontRegardless()
        self.window = window

        startedAt = Date()
        deadline = startedAt.addingTimeInterval(duration)
        lastUpdate = .distantPast
        lastCallback = 0

        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        nominal = link.duration > 0 ? link.duration : 1.0 / 60.0
        link.add(to: .main, forMode: .common)
        self.link = link

        let report: FrameTimeReport = await withCheckedContinuation { continuation in
            self.finish = { result in continuation.resume(returning: result) }
        }
        return report
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The corroborating signal: an interval materially longer than the panel's period is a
        // frame the machine did not deliver.
        if lastCallback > 0 {
            let interval = link.timestamp - lastCallback
            if interval > nominal * 1.5 { dropped += 1 }
        }
        lastCallback = link.timestamp

        let now = Date()
        guard now < deadline else { stop(); return }
        guard now.timeIntervalSince(lastUpdate) >= 1.0 / updatesPerSecond else { return }
        lastUpdate = now

        let index = updateCount
        updateCount += 1

        // The measured span: the update, then the layout and display it forces. Stopping at the end
        // of the closure would time our own bookkeeping and leave SwiftUI's layout — the expensive
        // half, and the half a hosted row adds — outside the number.
        let state = signposter.beginInterval("frame")
        let began = ContinuousClock.now
        let step = update?(index) ?? RenderPhases()
        let hostStart = ContinuousClock.now
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
        let hostingCost = Self.seconds(since: hostStart)
        let elapsed = Self.seconds(since: began)
        signposter.endInterval("frame", state)

        phases = phases + RenderPhases(hosting: step.hosting + hostingCost,
                                       markdown: step.markdown, highlight: step.highlight)
        guard now.timeIntervalSince(startedAt) > Self.warmUp else { return }
        samples.append(elapsed)
    }

    private func stop() {
        link?.invalidate(); link = nil
        window?.orderOut(nil); window = nil
        let sorted = samples.sorted()
        var report = FrameTimeReport()
        report.sampled = sorted.count
        report.dropped = dropped
        report.phases = phases
        if !sorted.isEmpty {
            report.p50 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.50))]
            report.p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            report.worst = sorted[sorted.count - 1]
        }
        let finish = self.finish
        self.finish = nil
        finish?(report)
    }

    private static func seconds(since instant: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now - instant
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
