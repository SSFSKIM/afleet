import Foundation

/// The stderr half of the report: the same facts, laid out for a person watching the run.
/// stdout stays pure JSON so the harness can be driven by a script.
enum Summary {

    static func write(_ report: [String: Any], status: Int32, to handle: FileHandle) {
        var lines: [String] = []
        lines.append("")
        lines.append("S3 — route \(report["route"] as? String ?? "?")")

        if let cold = report["coldLoad"] as? [String: Any] {
            if cold["reachedReady"] as? Bool == true {
                lines.append(String(format: "  cold load   process start -> ready  %8.1f ms   (gate: < 1000)",
                                    cold["processStartToReadyMs"] as? Double ?? -1))
                lines.append(String(format: "              navigation    -> ready  %8.1f ms",
                                    cold["navigationStartToReadyMs"] as? Double ?? -1))
            } else {
                lines.append("  cold load   never reached ready")
            }
        }

        if let large = report["fiveMegabyteFile"] as? [String: Any] {
            let bytes = large["bytes"] as? Int ?? 0
            lines.append(String(format: "  %d MB file  setText sync %.1f ms, to next render %.1f ms",
                                bytes / (1024 * 1024),
                                large["syncMs"] as? Double ?? -1,
                                large["toRenderMs"] as? Double ?? -1))
        }
        if let scroll = report["scroll"] as? [String: Any] {
            lines.append(String(format: "  scroll      p50 %.1f  p95 %.1f  worst %.1f ms over %d of %d requested frames%@",
                                scroll["p50Ms"] as? Double ?? -1,
                                scroll["p95Ms"] as? Double ?? -1,
                                scroll["worstMs"] as? Double ?? -1,
                                scroll["frames"] as? Int ?? 0,
                                scroll["requestedFrames"] as? Int ?? 0,
                                scroll["timedOut"] as? Bool == true ? "  (timed out)" : ""))
        }
        if let diff = report["diff"] as? [String: Any] {
            lines.append("  diff        computed=\(diff["computed"] as? Bool ?? false)"
                         + " changes=\(diff["changeCount"] as? Int ?? 0)"
                         + " renderedInsertLines=\(diff["renderedInsertLines"] as? Int ?? 0)")
        }
        if let reopen = report["reopen"] as? [String: Any] {
            lines.append("  reopen      succeeded=\(reopen["reopenSucceeded"] as? Bool ?? false)"
                         + " contentsReplaced=\(reopen["contentsReplaced"] as? Bool ?? false)"
                         + " lineRevealed=\(reopen["requestedLineRevealed"] as? Bool ?? false)"
                         + " models=\(reopen["modelCount"] as? Int ?? -1)")
            if let errors = reopen["errorsDuringReopen"] as? [String], !errors.isEmpty {
                for message in errors.prefix(3) { lines.append("              error: \(message)") }
            }
        }
        if let chunk = report["chunk"] as? [String: Any] {
            lines.append("  chunk       swift grammar loaded=\(chunk["loaded"] as? Bool ?? false)"
                         + " in \(Int(chunk["elapsedMs"] as? Double ?? -1)) ms")
        }
        if let workers = report["workers"] as? [String: Any],
           let started = workers["startedByFile"] as? [String: Bool] {
            for file in started.keys.sorted() {
                lines.append("  worker      \(file.padding(toLength: 17, withPad: " ", startingAt: 0)) started=\(started[file] ?? false)")
            }
            let messages = workers["messagesByMonacoWorker"] as? [String: Int] ?? [:]
            if let functional = workers["functional"] as? [String: Any] {
                for name in functional.keys.sorted() where name != "errors" {
                    let answered = (functional[name] as? [String: Any])?["answered"] as? Bool ?? false
                    // The answer and its attribution on one line: an answer with no traffic on
                    // Monaco's own worker for that service is the main-thread fallback.
                    lines.append("  service     \(name.padding(toLength: 17, withPad: " ", startingAt: 0))"
                                 + " answered=\(answered)"
                                 + " monacoWorkerMessages=\(messages[name].map(String.init) ?? "-")")
                }
            }
            lines.append("  editor.worker  monacoWorkerMessages=\(messages[WorkerEvidence.editorWorkerKey].map(String.init) ?? "-")"
                         + " computedDiff=\(workers["editorWorkerComputedDiff"] as? Bool ?? false)")
            if let recorded = workers["errorsByMonacoWorker"] as? [String: [String]], !recorded.isEmpty {
                for service in recorded.keys.sorted() {
                    lines.append("  ** Monaco's own \(service) worker recorded \(recorded[service]?.count ?? 0) error(s):"
                                 + " \(recorded[service]?.prefix(2).joined(separator: "; ") ?? "")")
                }
            }
            if workers["mainThreadFallback"] as? Bool == true {
                lines.append("  ** Monaco fell back to the main thread: Design §7 makes this a stop, not a fallback.")
            }
            if let why = workers["unprovenBecause"] as? String {
                lines.append("  workers     unproven: \(why)")
            }
            // The verdict's own line, so a reader is never left inferring it from the rows above.
            lines.append("  workers     proven=\(workers["proven"] as? Bool ?? false)"
                         + "  (allFiveStarted=\(workers["allFiveStarted"] as? Bool ?? false)"
                         + " allServicesAnswered=\(workers["allServicesAnswered"] as? Bool ?? false)"
                         + " editorWorkerComputedDiff=\(workers["editorWorkerComputedDiff"] as? Bool ?? false))")
        }
        if let errors = report["editorErrors"] as? [String], !errors.isEmpty {
            lines.append("  editor errors:")
            for message in errors.prefix(8) { lines.append("    - \(message)") }
        }
        let meaning: String
        switch status {
        case 0: meaning = "this route carries every load path and the cold load is within budget"
        case 2: meaning = "this route drops a load path — advance to the next route"
        case 4: meaning = "the window was given no frames; the render numbers are missing"
        case 5: meaning = "this route carries every load path; the cold load is over budget"
        case 6: meaning = "a render workload did not complete — the run carries no evidence for it"
        case 7: meaning = "the editor reported an error during the run"
        default: meaning = "see the report"
        }
        lines.append("  exit \(status) — \(meaning)")
        if let reason = (report["verdict"] as? [String: Any])?["reason"] as? String {
            lines.append("             \(reason)")
        }
        lines.append("")
        handle.write(Data(lines.joined(separator: "\n").utf8))
    }
}
