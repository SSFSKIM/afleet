import Foundation
import XCTest

/// Reads the recorded control exchanges out of a fixture's `frames.ndjson`.
///
/// Every engine byte a router test asserts against, and every answer it hands a replay script, comes from here
/// rather than from a literal in the test: the bytes are the reviewed recording's own (root `CLAUDE.md`, spec §11).
/// A test that needs a shape the corpus does not record says so in its doc comment and scripts it with invented
/// identifiers instead.
enum FixtureAnswers {

    /// One recorded exchange: the host request's payload, and the engine's answer as either a body or an error string.
    struct Exchange {
        /// The recorded `request` object, `subtype` included.
        let request: [String: Any]
        /// The `response.response` body of a `success` answer; nil for an error and for a bare success.
        let body: [String: Any]?
        /// The `response.error` string of an `error` answer; nil otherwise.
        let error: String?
    }

    struct NotRecorded: Error, CustomStringConvertible {
        let fixture: String, subtype: String, occurrence: Int
        var description: String {
            "fixture \(fixture) records no answer for host request \(subtype) #\(occurrence)"
        }
    }

    /// The `occurrence`-th (zero-based) host `control_request` of `subtype` in `fixture`, with the answer that
    /// named its request id.
    static func exchange(_ fixture: String, _ subtype: String, occurrence: Int = 0) throws -> Exchange {
        let lines = try String(contentsOf: FakeClaudeLaunch.fixture(fixture).appending(path: "frames.ndjson"),
                               encoding: .utf8)
        var requests: [(id: String, request: [String: Any])] = []
        var answers: [String: [String: Any]] = [:]
        for line in lines.split(separator: "\n") where !line.isEmpty {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["dropped"] == nil, let frame = record["frame"] as? [String: Any] else { continue }
            switch (record["dir"] as? String, frame["type"] as? String) {
            case ("in", "control_request"):
                guard let id = frame["request_id"] as? String,
                      let request = frame["request"] as? [String: Any],
                      request["subtype"] as? String == subtype else { continue }
                requests.append((id, request))
            case ("out", "control_response"):
                guard let response = frame["response"] as? [String: Any],
                      let id = response["request_id"] as? String else { continue }
                answers[id] = response
            default: continue
            }
        }
        guard occurrence < requests.count, let answer = answers[requests[occurrence].id] else {
            throw NotRecorded(fixture: fixture, subtype: subtype, occurrence: occurrence)
        }
        return Exchange(request: requests[occurrence].request,
                        body: answer["response"] as? [String: Any],
                        error: answer["error"] as? String)
    }

    /// The recorded answer body, which the test hands a replay script as the engine's answer.
    static func body(_ fixture: String, _ subtype: String, occurrence: Int = 0) throws -> [String: Any] {
        let exchange = try exchange(fixture, subtype, occurrence: occurrence)
        guard let body = exchange.body else {
            throw NotRecorded(fixture: fixture, subtype: subtype, occurrence: occurrence)
        }
        return body
    }

    /// The recorded error string of an answer whose subtype is `error`.
    static func error(_ fixture: String, _ subtype: String, occurrence: Int = 0) throws -> String {
        let exchange = try exchange(fixture, subtype, occurrence: occurrence)
        guard let error = exchange.error else {
            throw NotRecorded(fixture: fixture, subtype: subtype, occurrence: occurrence)
        }
        return error
    }
}
