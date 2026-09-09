import AppKit
import Foundation
import TerminalCore

struct RecordingSurfaceSnapshot: Sendable {
    let totalByteCount: Int
    let deliveryCount: Int
    let largestDeliveryByteCount: Int
    let processExitCount: Int
}

/// A headless surface that records delivery shape without retaining the flood itself.
/// Keeping only counters makes the responsiveness test exercise PTY delivery rather than
/// allocating an unbounded second copy of the child's output in its stand-in renderer.
@MainActor
final class RecordingSurface: TerminalSurface {
    let view = NSView()
    var onInput: (@Sendable (Data) -> Void)?
    var onResize: (@Sendable (TerminalSize) -> Void)?
    let terminalDescription = TerminalDescription(term: "xterm-256color")

    private var totalByteCount = 0
    private var deliveryCount = 0
    private var largestDeliveryByteCount = 0
    private var processExitCount = 0

    func feed(_ output: Data) {
        totalByteCount += output.count
        deliveryCount += 1
        largestDeliveryByteCount = max(largestDeliveryByteCount, output.count)
    }

    func processDidExit(code _: Int32) {
        processExitCount += 1
    }

    func setAppearance(_: TerminalAppearance) {}

    var snapshot: RecordingSurfaceSnapshot {
        RecordingSurfaceSnapshot(
            totalByteCount: totalByteCount,
            deliveryCount: deliveryCount,
            largestDeliveryByteCount: largestDeliveryByteCount,
            processExitCount: processExitCount
        )
    }
}

struct HeartbeatMeasurements: Sendable {
    let scheduledCount: Int
    let deliveredCount: Int
    let medianLatencyMilliseconds: Double
    let maximumLatencyMilliseconds: Double
}

/// A common-mode timer is scheduled on the main run loop, the UI event loop serviced by
/// `MainActor` on macOS. Unlike another Swift task, it is not made artificially responsive by
/// cooperative-executor fairness when terminal delivery has saturated the actor.
@MainActor
final class MainActorHeartbeatProbe {
    private let intervalSeconds: TimeInterval
    private let intervalNanoseconds: UInt64
    private let scheduledCount: Int
    private var timer: Timer?
    private var startNanoseconds: UInt64 = 0
    private var latenciesNanoseconds: [UInt64] = []

    init(interval: Duration, scheduledCount: Int) {
        let components = interval.components
        precondition(components.seconds >= 0 && components.attoseconds >= 0)
        intervalSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        intervalNanoseconds = UInt64(components.seconds) * 1_000_000_000
            + UInt64(components.attoseconds / 1_000_000_000)
        self.scheduledCount = scheduledCount
    }

    func start() {
        startNanoseconds = DispatchTime.now().uptimeNanoseconds
        latenciesNanoseconds.removeAll(keepingCapacity: true)
        let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() -> HeartbeatMeasurements {
        timer?.invalidate()
        timer = nil
        let sorted = latenciesNanoseconds.sorted()
        let median: Double
        if sorted.isEmpty {
            median = .infinity
        } else if sorted.count.isMultiple(of: 2) {
            let upper = sorted.count / 2
            median = Double(sorted[upper - 1] + sorted[upper]) / 2_000_000
        } else {
            median = Double(sorted[sorted.count / 2]) / 1_000_000
        }
        let maximum = Double(sorted.last ?? .max) / 1_000_000
        return HeartbeatMeasurements(
            scheduledCount: scheduledCount,
            deliveredCount: sorted.count,
            medianLatencyMilliseconds: median,
            maximumLatencyMilliseconds: maximum
        )
    }

    private func recordHeartbeat() {
        let heartbeatNumber = latenciesNanoseconds.count + 1
        let expected = startNanoseconds + UInt64(heartbeatNumber) * intervalNanoseconds
        let actual = DispatchTime.now().uptimeNanoseconds
        latenciesNanoseconds.append(actual > expected ? actual - expected : 0)
    }
}
