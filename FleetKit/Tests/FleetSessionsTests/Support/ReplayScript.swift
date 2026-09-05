import Foundation

/// Builds a `FAKE_CLAUDE_SCRIPT` file for a fixture replay.
///
/// A script's `expect` and `answer` steps run as soon as the replayer reaches them, and it reaches the first one
/// *before* the first recorded line — before the initialize response is even out. A script that opened with an
/// `expect` would therefore block the handshake it is waiting behind. Only an `emit` step waits, so every script
/// this builds opens with one gated on the fixture's own `auth_status` being out: that is one frame past the
/// initialize response, so the handshake has landed and the fork's identity has arrived, and it is *before* the
/// fixture's remaining recorded host inputs, so a control request the host sends the moment the handshake returns —
/// which is exactly what the quiescent restart does — meets a waiting `expect` rather than a recorded input line
/// that would call it unexpected and fail the replay. The frame the gate emits is one the fixture itself recorded,
/// re-emitted, so no byte here is composed.
enum ReplayScript {

    /// One `expect` for a control request of `subtype`, with `matching` as further dotted-key assertions on the
    /// frame, followed by the `answer` the engine gives it. A missing request fails the replay with exit 3.
    static func exchange(_ subtype: String, matching: [String: Any] = [:],
                         answer body: [String: Any]? = nil) -> [[String: Any]] {
        var expect: [String: Any] = ["type": "control_request", "request.subtype": subtype]
        for (key, value) in matching { expect[key] = value }
        var response: [String: Any] = ["subtype": "success"]
        if let body { response["response"] = body }
        return [["expect": expect, "timeout_ms": 60_000],
                ["answer": ["type": "control_response", "response": response]]]
    }

    /// The same, answered with the engine's error envelope: `{subtype: "error", request_id, error: <a bare string>}` —
    /// no `response` key and a bare string, the shape the `control-shapes` recording confirmed on the wire.
    static func failure(_ subtype: String, matching: [String: Any] = [:], error: String) -> [[String: Any]] {
        var expect: [String: Any] = ["type": "control_request", "request.subtype": subtype]
        for (key, value) in matching { expect[key] = value }
        return [["expect": expect, "timeout_ms": 60_000],
                ["answer": ["type": "control_response", "response": ["subtype": "error", "error": error]]]]
    }

    /// A `generic-success` rule: any host request of these subtypes that no `expect` is waiting for is answered with
    /// a bare success rather than failing the replay as an unexpected frame.
    static func genericSuccess(_ subtypes: [String]) -> [[String: Any]] {
        [["rule": "generic-success", "subtypes": subtypes]]
    }

    /// Writes the steps, behind the gate, into a fresh file under `directory`.
    static func write(_ steps: [[String: Any]], fixture: String, into directory: URL) throws -> URL {
        let script: [[String: Any]] = [try gate(fixture: fixture)] + steps
        let url = directory.appending(path: "script-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: script, options: [.sortedKeys]).write(to: url)
        return url
    }

    /// The gate: the fixture's last recorded `transcript_mirror`, re-emitted, due once the fixture's `auth_status`
    /// is out. `after` counts frames the replay has emitted, so the number is the out-frames recorded ahead of
    /// `auth_status`: one more emission than that is `auth_status` itself.
    private static func gate(fixture: String) throws -> [String: Any] {
        let lines = try String(contentsOf: FakeClaudeLaunch.fixture(fixture).appending(path: "frames.ndjson"),
                               encoding: .utf8)
        var outs = 0
        var outsBeforeIdentity: Int?
        var lastMirror: Any?
        for line in lines.split(separator: "\n") where !line.isEmpty {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["dropped"] == nil, record["dir"] as? String == "out",
                  let frame = record["frame"] as? [String: Any] else { continue }
            let type = frame["type"] as? String
            if type == "auth_status", outsBeforeIdentity == nil { outsBeforeIdentity = outs }
            if type == "transcript_mirror" { lastMirror = frame }
            outs += 1
        }
        struct NoGate: Error, CustomStringConvertible {
            let fixture: String, missing: String
            var description: String { "fixture \(fixture) records no \(missing) to gate a script on" }
        }
        guard let after = outsBeforeIdentity else { throw NoGate(fixture: fixture, missing: "auth_status") }
        guard let frame = lastMirror else { throw NoGate(fixture: fixture, missing: "transcript_mirror") }
        return ["emit": frame, "after": after]
    }
}
