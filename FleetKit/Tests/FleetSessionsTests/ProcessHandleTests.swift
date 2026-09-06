import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The seam itself, before any row depends on it: an event pushed into the scripted handle reaches a consumer that
/// holds the handle as `any ProcessHandle` and reads its `events` as the existential the protocol declares.
final class ProcessHandleTests: XCTestCase {
    func testTheScriptedHandleDeliversAPushedEvent() async throws {
        let scripted = ScriptedProcessHandle(epoch: .first, session: SessionID())
        let handle: any ProcessHandle = scripted

        let collector = Collector()
        let consumer = Task { [stream = handle.events] in
            for await event in stream { collector.append(event) }
            collector.finish()
        }

        scripted.push(.requestCancelled(RequestID(rawValue: "r-1"), .first))
        scripted.finish()
        await consumer.value

        XCTAssertTrue(collector.ended, "the consumer saw the end of the stream")
        XCTAssertEqual(collector.kinds, [.requestCancelled])
        guard case let .requestCancelled(id, epoch)? = collector.events.first else {
            return XCTFail("the one event was not the cancellation that was pushed")
        }
        XCTAssertEqual(id, RequestID(rawValue: "r-1"))
        XCTAssertEqual(epoch, .first)
    }

    private final class Collector: @unchecked Sendable {   // `lock` serialises both fields
        private let lock = NSLock()
        private var _events: [WireEvent] = []
        private var _ended = false
        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
        func append(_ e: WireEvent) { locked { _events.append(e) } }
        func finish() { locked { _ended = true } }
        var events: [WireEvent] { locked { _events } }
        var kinds: [WireEvent.Kind] { events.map(\.kind) }
        var ended: Bool { locked { _ended } }
    }
}
