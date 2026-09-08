import Foundation

/// The run's exit status, as a pure function of the report the run printed.
///
/// It is a separate, argument-free function rather than a tail of `Spike.run` so that the one
/// thing a spike's reader has to trust — "exit 0 means the numbers above are real" — can be
/// driven from a stubbed report and shown to fail. `main.swift`'s `--evaluate-report` is that
/// driver: the harness's own test, because an executable's tests are its own runs.
enum Verdict {

    struct Ruling {
        let status: Int32
        let reason: String
    }

    /// The evidence the report prints, and what its absence is called.
    ///
    /// Every one of these is a workload the run is documented as performing. A run that did not
    /// perform one has nothing to say about it, and a status that ignored the difference would
    /// let a route exit 0 with no large-buffer or diff-render evidence at all.
    private static func missingRenderEvidence(_ report: [String: Any]) -> String? {
        let large = report["fiveMegabyteFile"] as? [String: Any] ?? [:]
        if large["complete"] as? Bool != true || large["toRenderMs"] == nil || large["toRenderMs"] is NSNull {
            return "the 5 MB file's render recorder never completed"
        }
        let scroll = report["scroll"] as? [String: Any] ?? [:]
        let recordedFrames = scroll["frames"] as? Int ?? 0
        let requestedFrames = scroll["requestedFrames"] as? Int ?? 0
        if recordedFrames <= 0 {
            return "the scroll histogram recorded no frames"
        }
        // A positive count is not the workload. The probe's timeout returns whatever it has by
        // then, and percentiles over a truncated sample describe a scroll that never finished.
        if requestedFrames <= 0 || recordedFrames != requestedFrames {
            return "the scroll histogram recorded \(recordedFrames) of \(requestedFrames)"
                + " requested frames"
        }
        let diff = report["diff"] as? [String: Any] ?? [:]
        if diff["diffPaneDisplayed"] as? Bool != true {
            return "the diff pane was never displayed"
        }
        if (diff["renderedDiffDecorations"] as? Int ?? 0) <= 0
            || (diff["viewLines"] as? Int ?? 0) <= 0 {
            return "the diff rendered nothing into the DOM"
        }
        let reopen = report["reopen"] as? [String: Any] ?? [:]
        if reopen["reopenSucceeded"] as? Bool != true {
            return "re-opening the path already on screen did not succeed"
        }
        return nil
    }

    /// Six statuses. A run that measured nothing and a run that measured something bad are
    /// different findings, and a script that saw only "not zero" would advance the route search
    /// over a cold load that is merely slow — a number no other route changes. What the statuses
    /// have in common is the rule this function exists for: **a missing piece of evidence is
    /// never a pass.**
    ///
    ///   0  every load path, every workload, cold load within budget
    ///   2  a load path is missing, or a worker answered and then errored — advance a route
    ///   4  the window was given no animation frames; the render numbers are missing
    ///   5  every load path and workload; the cold load is over budget
    ///   6  a render workload did not complete — the reason names which
    ///   7  the editor reported an error during the run
    static func rule(_ report: [String: Any]) -> Ruling {
        let documentLoaded = report["documentLoaded"] as? Bool ?? false
        let chunkLoaded = (report["chunk"] as? [String: Any])?["loaded"] as? Bool ?? false
        let workers = report["workers"] as? [String: Any] ?? [:]
        let workersProven = workers["proven"] as? Bool ?? false
        let withinBudget = (report["coldLoad"] as? [String: Any])?["withinBudget"] as? Bool ?? false
        let framesAvailable = (report["frameLiveness"] as? [String: Any])?["framesAvailable"] as? Bool ?? false
        let editorErrors = report["editorErrors"] as? [String] ?? []

        guard documentLoaded else {
            return Ruling(status: 2, reason: "the document never reported ready")
        }
        guard chunkLoaded else {
            return Ruling(status: 2, reason: "the dynamic-import chunk did not load — advance to the next route")
        }
        guard workersProven else {
            let why = workers["unprovenBecause"] as? String ?? "the workers are not proven"
            return Ruling(status: 2, reason: "\(why) — advance to the next route")
        }
        // Before the render evidence, because a window given no frames explains every render
        // measurement that is missing below and is a fact about this process, not the route.
        guard framesAvailable else {
            return Ruling(status: 4, reason: "the window was given no animation frames;"
                          + " the render numbers are missing")
        }
        if let missing = missingRenderEvidence(report) {
            return Ruling(status: 6, reason: "\(missing) — the run carries no evidence for it")
        }
        guard editorErrors.isEmpty else {
            return Ruling(status: 7, reason: "the editor reported \(editorErrors.count) error(s):"
                          + " \(editorErrors.prefix(2).joined(separator: "; "))")
        }
        return withinBudget
            ? Ruling(status: 0, reason: "every load path is carried, every workload completed,"
                     + " and the cold load is within budget")
            : Ruling(status: 5, reason: "every load path is carried and every workload completed;"
                     + " the cold load is over budget")
    }

    /// Re-derives the worker summary from the evidence the report carries, so a stub cannot
    /// assert `proven` at the harness: the ruling reads the evidence, never the claim.
    static func ruleRecomputingWorkers(_ report: [String: Any]) -> Ruling {
        var recomputed = report
        let workers = report["workers"] as? [String: Any] ?? [:]
        recomputed["workers"] = WorkerEvidence.summarise(
            direct: workers["instantiation"] as? [[String: Any]] ?? [],
            functional: workers["functional"] as? [String: Any] ?? [:],
            instrumented: workers["monacoWorkers"] as? [String: Any] ?? [:],
            diffComputed: workers["editorWorkerComputedDiff"] as? Bool ?? false
        )
        return rule(recomputed)
    }

    /// `--evaluate-report <path>`: rule on a report read from disk and exit with the status.
    /// Prints the status and the named reason on stdout, and nothing else.
    static func evaluate(path: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            FileHandle.standardError.write(Data("not a JSON report\n".utf8))
            return 64
        }
        let ruling = ruleRecomputingWorkers(report)
        FileHandle.standardOutput.write(Data("status=\(ruling.status) reason=\(ruling.reason)\n".utf8))
        return ruling.status
    }
}
