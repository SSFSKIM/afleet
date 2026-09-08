import Foundation
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
        XCTAssertLessThan(
            heartbeatMeasurements.medianLatencyMilliseconds,
            50,
            "median main-actor heartbeat latency reached one heartbeat interval"
        )
        XCTAssertLessThan(
            heartbeatMeasurements.maximumLatencyMilliseconds,
            500,
            "maximum main-actor heartbeat latency exceeded the responsiveness bound"
        )
        XCTAssertLessThanOrEqual(
            abs(heartbeatMeasurements.deliveredCount - heartbeatMeasurements.scheduledCount),
            Self.heartbeatCount / 10,
            "main-actor heartbeat delivery fell outside ten percent of schedule"
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
