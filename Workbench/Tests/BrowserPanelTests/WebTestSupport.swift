import Foundation
import Network
import Observation
import XCTest
@testable import BrowserPanel

/// What milestone 3's `WKWebView` tests are driven by: a loopback HTTP server the test owns, and
/// two ways of waiting that a broken implementation cannot turn into a hang.
///
/// Grounding probes 1 and 2 measured both halves before any of this was written — a bare
/// `swift test` process creates a `WKWebView`, loads a page and runs JavaScript with no app bundle,
/// and reaches `http://127.0.0.1:<port>` with no ATS exception, because a test process has no
/// Info.plist for ATS to read. The Info.plist keys Q14 names are the built app's business and are
/// witnessed at G1, not here.
///
/// The server lives in the test target and never in the module: `BrowserPanel` imports no
/// `Network`, and `ImportGraphTests` would say so.

// MARK: - The loopback server

/// One canned response per path, over `127.0.0.1` on a port the kernel chooses, counting what was
/// asked for. Cancelled on teardown; nothing survives a test.
///
/// `@unchecked Sendable` with a lock rather than an actor: `NWListener`'s handlers are delivered on
/// a dispatch queue, and a counter a test reads synchronously after an awaited navigation is
/// simpler to reason about than a hop for every byte.
final class LoopbackHTTPServer: @unchecked Sendable {

    struct DidNotStart: Error, CustomStringConvertible {
        let reason: String
        var description: String { "the loopback server did not start: \(reason)" }
    }

    /// Path to the HTML served for it. A path with no page answers 404, which is a real answer and
    /// not a hang.
    private let pages: [String: String]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "afleet.browserpanel.tests.loopback")
    private let lock = NSLock()
    private var requestedPaths: [String] = []
    private var started: CheckedContinuation<Void, Error>?
    private var didSettleStart = false

    /// The base URL, once `start()` has returned. Loopback, so §11 holds: no test names a real host.
    private(set) var baseURL = URL(string: "http://127.0.0.1/")!

    init(pages: [String: String]) throws {
        self.pages = pages
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: settleStart(.success(()))
            case .failed(let error): settleStart(.failure(DidNotStart(reason: "\(error)")))
            case .cancelled: settleStart(.failure(DidNotStart(reason: "cancelled")))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            started = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
        guard let port = listener.port?.rawValue,
              let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw DidNotStart(reason: "no port")
        }
        baseURL = url
    }

    func stop() {
        listener.cancel()
    }

    /// Every path requested, in order.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths
    }

    func requestCount(for path: String) -> Int {
        requests.filter { $0 == path }.count
    }

    /// A URL under this server for `path`, so no test writes a port into a string.
    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    // MARK: The connection

    private func settleStart(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = didSettleStart ? nil : started
        didSettleStart = true
        started = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            // A GET has no body, so the blank line that ends the headers is the whole request.
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.receive(connection, accumulated: buffer)
                return
            }
            self.respond(connection, to: text)
        }
    }

    private func respond(_ connection: NWConnection, to request: String) {
        let target = request
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first?
            .split(separator: " ").dropFirst().first
            .map(String.init) ?? "/"
        let path = String(target.prefix { $0 != "?" && $0 != "#" })

        lock.lock()
        requestedPaths.append(path)
        lock.unlock()

        let body = Data((pages[path] ?? "<html><body>not here</body></html>").utf8)
        let status = pages[path] == nil ? "404 Not Found" : "200 OK"
        // `no-store`, because a reload that is answered from the cache is a reload this suite's
        // request count cannot see.
        let head = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
        connection.send(content: Data(head.utf8) + body,
                        isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Waiting

extension XCTestCase {

    /// Every wait in this suite is fulfilled by a real event — an observed change to the chrome
    /// state, or a delegate callback — and every one carries a deadline, so a broken implementation
    /// fails the suite instead of hanging it.
    static let webDeadline: TimeInterval = 20

    /// An expectation fulfilled when `condition` holds of the chrome state, now or after any
    /// observed change to a property the condition reads.
    ///
    /// It re-arms rather than observing once, because `withObservationTracking` fires a single time
    /// and a title arrives some navigations after the URL does.
    @MainActor
    func chromeReaches(_ state: BrowserChromeState,
                       _ description: String,
                       _ condition: @escaping @MainActor (BrowserChromeState) -> Bool) -> XCTestExpectation {
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        ChromeWaiter(state: state, condition: condition, reached: reached).arm()
        return reached
    }

    /// Runs `body`, then waits for the tab's next settled navigation — `didFinish` or a failure,
    /// never a sleep.
    @MainActor
    func navigating(_ tab: BrowserWebTab,
                    _ description: String,
                    file: StaticString = #filePath,
                    line: UInt = #line,
                    _ body: @MainActor () -> Void) async {
        let settled = expectation(description: description)
        settled.assertForOverFulfill = false
        tab.navigationDidSettle = { _ in settled.fulfill() }
        defer { tab.navigationDidSettle = nil }
        body()
        await fulfillment(of: [settled], timeout: Self.webDeadline)
    }
}

/// The re-arming half of `chromeReaches`. A `@MainActor` class, so it is `Sendable` and can be
/// captured by observation's `onChange`; that capture is also what keeps it alive until the state
/// it is watching moves or the deadline passes.
@MainActor
private final class ChromeWaiter {

    private let state: BrowserChromeState
    private let condition: @MainActor (BrowserChromeState) -> Bool
    private let reached: XCTestExpectation
    private var fulfilled = false

    init(state: BrowserChromeState,
         condition: @escaping @MainActor (BrowserChromeState) -> Bool,
         reached: XCTestExpectation) {
        self.state = state
        self.condition = condition
        self.reached = reached
    }

    func arm() {
        guard !fulfilled else { return }
        var satisfied = false
        withObservationTracking {
            satisfied = condition(state)
        } onChange: { [self] in
            Task { @MainActor in arm() }
        }
        if satisfied {
            fulfilled = true
            reached.fulfill()
        }
    }
}
