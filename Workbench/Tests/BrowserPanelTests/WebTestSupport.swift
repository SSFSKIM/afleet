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

    /// Path to the `Location:` a `302` answers with. A server redirect is the one navigation a page
    /// cannot forge and the app cannot see coming, and WebKit reuses the *triggering* action for it
    /// — so a clicked link or a submitted form can arrive at a non-web scheme still wearing the
    /// gesture that started it. Proving that needs a real server hop, which is why the server
    /// learned to redirect at the D38 fix wave.
    private let redirects: [String: String]

    /// Paths the server accepts a request for and then **never answers**, leaving the navigation
    /// loading until something stops it. What a stop control has to be tested against: a page that
    /// finishes on its own would settle whether the control worked or not.
    private let stalls: Set<String>

    /// Paths the server answers by closing the connection with no response at all. A load that
    /// fails for an ordinary reason — the far end went away — without any test reaching a network.
    private let drops: Set<String>

    private let listener: NWListener
    private let queue = DispatchQueue(label: "afleet.browserpanel.tests.loopback")
    private let lock = NSLock()
    private var requestedPaths: [String] = []
    /// Connections a stalled path is holding open. Kept because an `NWConnection` nobody retains is
    /// a *closed* one, which is a failed load rather than a load that never finishes.
    private var held: [NWConnection] = []
    private var requestExpectations: [(path: String, expectation: XCTestExpectation)] = []
    private var started: CheckedContinuation<Void, Error>?
    private var didSettleStart = false

    /// The base URL, once `start()` has returned. Loopback, so §11 holds: no test names a real host.
    private(set) var baseURL = URL(string: "http://127.0.0.1/")!

    init(pages: [String: String],
         redirects: [String: String] = [:],
         stalls: Set<String> = [],
         drops: Set<String> = []) throws {
        self.pages = pages
        self.redirects = redirects
        self.stalls = stalls
        self.drops = drops
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
        lock.lock()
        let holding = held
        held = []
        lock.unlock()
        for connection in holding { connection.cancel() }
        listener.cancel()
    }

    /// Every path requested, in order.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths
    }

    /// Fulfils `expectation` once `path` has been requested, so a test that must act *while* a
    /// navigation is in flight waits for the request rather than for the chrome to catch up.
    func expectRequest(_ path: String, _ expectation: XCTestExpectation) {
        lock.lock()
        let already = requestedPaths.contains(path)
        if !already { requestExpectations.append((path, expectation)) }
        lock.unlock()
        if already { expectation.fulfill() }
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
        let waiting = requestExpectations.filter { $0.path == path }
        requestExpectations.removeAll { $0.path == path }
        lock.unlock()
        for entry in waiting { entry.expectation.fulfill() }

        if drops.contains(path) {
            connection.cancel()
            return
        }

        if stalls.contains(path) {
            // Held open deliberately, and retained: the connection is cancelled at teardown.
            lock.lock()
            held.append(connection)
            lock.unlock()
            return
        }

        if let location = redirects[path] {
            let head = """
                HTTP/1.1 302 Found\r
                Location: \(location)\r
                Content-Length: 0\r
                Cache-Control: no-store\r
                Connection: close\r
                \r

                """
            connection.send(content: Data(head.utf8),
                            isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }

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

    /// An expectation fulfilled when `condition` holds of an observable object, now or after any
    /// observed change to a property the condition reads.
    ///
    /// It re-arms rather than observing once, because `withObservationTracking` fires a single time
    /// and the value a test is waiting for often arrives a change or two later — a title lands some
    /// navigations after the URL does, a quick-open list lands after its subscription attaches.
    @MainActor
    func observed<T: AnyObject>(_ object: T,
                                _ description: String,
                                _ condition: @escaping @MainActor (T) -> Bool) -> XCTestExpectation {
        let reached = expectation(description: description)
        reached.assertForOverFulfill = false
        ObservationWaiter(object: object, condition: condition, reached: reached).arm()
        return reached
    }

    /// The chrome-state spelling of `observed`, kept because milestone 3's tests read better for it.
    @MainActor
    func chromeReaches(_ state: BrowserChromeState,
                       _ description: String,
                       _ condition: @escaping @MainActor (BrowserChromeState) -> Bool) -> XCTestExpectation {
        observed(state, description, condition)
    }

    /// Waits, with a deadline, until the stub store has been asked to write `count` times.
    @MainActor
    func writeAttempts(_ store: InMemoryScopedStore, reach count: Int) async {
        let reached = expectation(description: "the store is asked to write \(count) times")
        await store.expectWriteAttempts(count, reached)
        await fulfillment(of: [reached], timeout: Self.webDeadline)
    }

    /// Waits, with a deadline, until the coalescer has opened a window and begun its sleep.
    @MainActor
    func sleepBegins(_ sleeper: ManualSleeper) async {
        let began = expectation(description: "the coalescing window opens")
        await sleeper.expectSleep(began)
        await fulfillment(of: [began], timeout: Self.webDeadline)
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

/// The re-arming half of `observed`. A `@MainActor` class, so it is `Sendable` and can be captured
/// by observation's `onChange`; that capture is also what keeps it alive until the object it is
/// watching moves or the deadline passes.
@MainActor
private final class ObservationWaiter<T: AnyObject> {

    private let object: T
    private let condition: @MainActor (T) -> Bool
    private let reached: XCTestExpectation
    private var fulfilled = false

    init(object: T,
         condition: @escaping @MainActor (T) -> Bool,
         reached: XCTestExpectation) {
        self.object = object
        self.condition = condition
        self.reached = reached
    }

    func arm() {
        guard !fulfilled else { return }
        var satisfied = false
        withObservationTracking {
            satisfied = condition(object)
        } onChange: { [self] in
            Task { @MainActor in arm() }
        }
        if satisfied {
            fulfilled = true
            reached.fulfill()
        }
    }
}
