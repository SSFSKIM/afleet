import Foundation
import GhosttyTerminal
import Synchronization
@testable import TerminalCore
import XCTest

final class FloodTests: XCTestCase {
    private static let heartbeatInterval = Duration.milliseconds(50)
    private static let heartbeatCount = 200
    private static let floodDuration = Duration.seconds(10)
    private static let byteFlowFloor = 1 * 1024 * 1024

    func testFloodKeepsMainActorResponsiveWhileBytesFlow() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }

        let heartbeat = await MainActorHeartbeatProbe(
            interval: Self.heartbeatInterval,
            scheduledCount: Self.heartbeatCount
        )
        let surface = await RecordingSurface()
        let process = try PTYProcess(
            spawning: PTYSpawnRequest(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "/bin/stty raw -echo; exec /usr/bin/yes"],
                cwd: directory,
                environment: [:],
                size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
                terminal: TerminalDescription(term: "xterm-256color"),
                stopPolicy: .report
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let consumer = Task { @MainActor in
            var endedCount = 0
            for await event in process.events {
                switch event {
                case let .output(bytes):
                    surface.feed(bytes)
                case .stopped:
                    break
                case let .ended(termination):
                    endedCount += 1
                    surface.processDidExit(code: termination.paneExitCode)
                }
            }
            return (surface.snapshot, endedCount)
        }
        defer { consumer.cancel() }

        await heartbeat.start()
        defer { Task { @MainActor in _ = heartbeat.stop() } }
        try await Task.sleep(for: Self.floodDuration)
        let (heartbeatMeasurements, sampledSurfaceMeasurements) = await MainActor.run {
            (heartbeat.stop(), surface.snapshot)
        }
        await process.teardown()
        let (finalSurfaceMeasurements, endedCount) = await consumer.value

        print(
            String(
                format: "G3a median=%.3fms maximum=%.3fms delivered=%d/%d bytes=%d",
                heartbeatMeasurements.medianLatencyMilliseconds,
                heartbeatMeasurements.maximumLatencyMilliseconds,
                heartbeatMeasurements.deliveredCount,
                heartbeatMeasurements.scheduledCount,
                sampledSurfaceMeasurements.totalByteCount
            )
        )

        XCTAssertGreaterThanOrEqual(
            sampledSurfaceMeasurements.totalByteCount,
            Self.byteFlowFloor,
            "the responsiveness sample did not carry enough terminal output to be a flood"
        )
        // The median, the maximum, the delivered count and the byte total printed above are
        // recorded for regression signal, and that is all they are: they are *not* this gate's
        // evidence. A tight latency bound was measured to be the worst of both worlds here — the
        // defect it was written against (synchronous per-read main-actor delivery) left the
        // median at 3.878 ms, comfortably inside a 50 ms bound, while an ordinarily loaded
        // machine running the full suite pushed the same *unmutated* code to a 67.852 ms median.
        // It passed on the bug and failed on the load. The gate's real discriminators are the
        // coalescing assertion below and the bounded-buffer test, both demonstrated to fail under
        // mutation.
        //
        // What is asserted from the timings instead is a freeze, not a slowdown. A heartbeat
        // scheduled every 50 ms that goes five whole seconds without being delivered did not lose
        // a race with a busy machine; it found a main actor that actually stalled, which is the
        // property G3 is about. A contended machine that is still scheduling work never reaches
        // this ceiling.
        XCTAssertLessThan(
            heartbeatMeasurements.maximumLatencyMilliseconds,
            5_000,
            "the main actor stalled: a heartbeat waited seconds to be delivered"
        )
        XCTAssertGreaterThanOrEqual(
            sampledSurfaceMeasurements.largestDeliveryByteCount,
            PTYProcess.outputDeliveryByteLimit / 2,
            "the flood remained split into read-sized deliveries instead of coalesced chunks"
        )
        XCTAssertLessThanOrEqual(
            sampledSurfaceMeasurements.largestDeliveryByteCount,
            PTYProcess.outputDeliveryByteLimit,
            "one main-actor delivery exceeded the documented byte cap"
        )
        XCTAssertEqual(endedCount, 1, "the flood child did not emit exactly one ended event")
        XCTAssertEqual(
            finalSurfaceMeasurements.processExitCount,
            1,
            "the recording surface did not observe exactly one process exit"
        )
    }


    /// G3's bound has to hold for the whole path, not only for the PTY layer's own buffer. The
    /// renderer's queue takes whatever it is handed without a limit of its own, and a host that
    /// resumes reading the moment `feed` returns therefore accumulates outside every bound this
    /// child measures. With the adapter holding the backlog and the host waiting on it, a renderer
    /// that is far behind a `yes` child leaves the resident backlog under the cap, and nothing is
    /// dropped: what the renderer parsed plus what is still outstanding is what the host fed.
    func testSlowRendererKeepsOutstandingBytesUnderTheCapWithoutDropping() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let parsedByteCount = Mutex(0)
        // Roughly 3 MB/s against a `yes` child that produces two orders of magnitude more: the
        // renderer is behind for the whole ten seconds, which is the condition under test.
        let surface = await GhosttyTerminalSurface(
            terminfoDirectory: nil,
            feedBarrier: { session, byteCount in
                session.waitForPendingOutput()
                usleep(20_000)
                parsedByteCount.withLock { $0 += byteCount }
            },
            // The bound under test is the backlog's, not the attach gate's: this surface is
            // never put in a window, and a stand-in stands for the renderer that would be.
            isAttached: { _ in true }
        )
        let process = try PTYProcess(
            spawning: PTYSpawnRequest(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "/bin/stty raw -echo; exec /usr/bin/yes"],
                cwd: directory,
                environment: [:],
                size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
                terminal: TerminalDescription(term: "xterm-256color"),
                stopPolicy: .report
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let measurements = Mutex(FloodFeedMeasurements())
        let consumer = Task { @MainActor in
            for await event in process.events {
                guard case let .output(bytes) = event else { continue }
                surface.feed(bytes)
                await surface.awaitFeedCapacity()
                let outstanding = surface.outstandingFeedByteCount
                measurements.withLock {
                    $0.fedByteCount += bytes.count
                    $0.largestOutstandingByteCount = max(
                        $0.largestOutstandingByteCount,
                        outstanding
                    )
                }
            }
        }
        defer { consumer.cancel() }

        try await Task.sleep(for: Self.floodDuration)
        let sampled = measurements.withLock { $0 }
        let outstanding = await surface.outstandingFeedByteCount
        consumer.cancel()
        await process.teardown()

        print(
            String(
                format: "G3c fed=%d largest-outstanding=%d parsed=%d",
                sampled.fedByteCount,
                sampled.largestOutstandingByteCount,
                parsedByteCount.withLock { $0 }
            )
        )

        XCTAssertGreaterThanOrEqual(
            sampled.fedByteCount,
            Self.byteFlowFloor,
            "the sample did not carry enough terminal output to be a flood"
        )
        // One chunk of headroom: the delivery that crosses the cap is accepted whole, and the
        // host only waits afterwards.
        XCTAssertLessThanOrEqual(
            sampled.largestOutstandingByteCount,
            GhosttyTerminalSurface.feedBufferByteLimit + PTYProcess.outputDeliveryByteLimit,
            "renderer-backlog=unbounded"
        )
        XCTAssertLessThanOrEqual(
            outstanding,
            GhosttyTerminalSurface.feedBufferByteLimit + PTYProcess.outputDeliveryByteLimit,
            "renderer-backlog=unbounded"
        )
        XCTAssertGreaterThan(parsedByteCount.withLock { $0 }, 0, "renderer-parsed=0")
        XCTAssertLessThanOrEqual(
            parsedByteCount.withLock { $0 },
            sampled.fedByteCount,
            "renderer-parsed=more-than-fed"
        )
        XCTAssertGreaterThanOrEqual(
            parsedByteCount.withLock { $0 } + outstanding,
            sampled.fedByteCount,
            "renderer-backlog=dropped-bytes"
        )
    }

    func testMainActorStallDoesNotDuplicateOutstandingDelivery() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let outputByteCount = PTYProcess.outputBufferByteLimit * 2
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: """
                /bin/stty raw -echo
                IFS= read -r _
                /usr/bin/head -c \(outputByteCount) /dev/zero
                """
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        // The consumer intentionally runs away from MainActor. While MainActor is unavailable,
        // the read queue can fill its bounded buffer, but it must still have only one submission
        // outstanding for the first delivery when the actor resumes.
        let consumer = Task.detached {
            var totalByteCount = 0
            var endedCount = 0
            for await event in process.events {
                switch event {
                case let .output(bytes):
                    totalByteCount += bytes.count
                case .stopped:
                    break
                case .ended:
                    endedCount += 1
                }
            }
            return (totalByteCount, endedCount)
        }
        defer { consumer.cancel() }
        let releaseProducer = Task.detached {
            try await Task.sleep(for: .milliseconds(25))
            try await process.write(Data("go\n".utf8))
        }

        await MainActor.run {
            let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {}
        }
        try await releaseProducer.value
        let result = try await PTYTestChild.withDeadline(seconds: 5) {
            await consumer.value
        }

        XCTAssertEqual(
            result.0,
            outputByteCount,
            "one in-flight output delivery was submitted more than once"
        )
        XCTAssertEqual(result.1, 1, "the finite flood did not emit exactly one ended event")
    }

    func testUnreadConsumerBackpressuresWithoutDroppingAndStreamStillTerminates() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let completionMarker = directory.appending(path: "producer-completed")
        let outputByteCount = PTYProcess.outputBufferByteLimit * 8
        let script = """
        /usr/bin/head -c \(outputByteCount) /dev/zero
        /usr/bin/touch "$AFLEET_COMPLETION_MARKER"
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: script,
                environment: ["AFLEET_COMPLETION_MARKER": completionMarker.path]
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        // With no iterator, a bounded userspace buffer fills and leaves the producer blocked on
        // the pty. An unbounded stream drains the whole payload and creates this marker instead.
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: completionMarker.path),
            "an unread consumer allowed the producer to outrun the bounded output buffer"
        )

        let surface = await RecordingSurface()
        let consumer = Task { @MainActor in
            var endedCount = 0
            for await event in process.events {
                switch event {
                case let .output(bytes):
                    surface.feed(bytes)
                case .stopped:
                    break
                case let .ended(termination):
                    endedCount += 1
                    surface.processDidExit(code: termination.paneExitCode)
                }
            }
            return (surface.snapshot, endedCount)
        }
        defer { consumer.cancel() }
        let result = try await PTYTestChild.withDeadline(seconds: 15) {
            await consumer.value
        }

        XCTAssertEqual(
            result.0.totalByteCount,
            outputByteCount,
            "backpressure changed or lost bytes from the finite payload"
        )
        XCTAssertLessThanOrEqual(
            result.0.largestDeliveryByteCount,
            PTYProcess.outputDeliveryByteLimit,
            "a delayed-consumer delivery exceeded the documented byte cap"
        )
        XCTAssertEqual(result.1, 1, "the delayed consumer did not receive exactly one ended event")
        XCTAssertEqual(
            result.0.processExitCount,
            1,
            "the delayed recording surface did not observe exactly one process exit"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: completionMarker.path),
            "the producer did not resume after the consumer began reading"
        )
    }
}

private struct FloodFeedMeasurements: Sendable {
    var fedByteCount = 0
    var largestOutstandingByteCount = 0
}
