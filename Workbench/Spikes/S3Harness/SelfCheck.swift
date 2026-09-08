import Foundation

/// `--self-check`: the harness's own test.
///
/// S3 is an executable, so its tests are its own runs — and the one claim a reader of a spike
/// takes on trust ("the exit status means the numbers above are real") cannot be driven from a
/// real run, because a real run does not produce a missing measurement on demand. So the
/// verdict is a pure function of the report and this drives it from stubbed reports: one
/// complete, and one per piece of evidence removed.
///
/// It opens no window and touches nothing. Exit 0 when every ruling matches, 1 otherwise, with
/// the mismatches named on stderr.
enum SelfCheck {

    private struct Scenario {
        let name: String
        let expected: Int32
        /// A fragment the reason must contain. A status alone is not enough: three scenarios
        /// once returned the right status naming the wrong missing piece.
        let because: String
        let report: [String: Any]
    }

    static func run() -> Int32 {
        var failures: [String] = []
        var lines: [String] = ["", "S3 --self-check — the verdict, driven from stubbed reports"]

        for scenario in scenarios() {
            let ruling = Verdict.ruleRecomputingWorkers(scenario.report)
            let ok = ruling.status == scenario.expected && ruling.reason.contains(scenario.because)
            if !ok {
                failures.append("\(scenario.name): expected exit \(scenario.expected)"
                                + " naming \"\(scenario.because)\", got \(ruling.status) — \(ruling.reason)")
            }
            lines.append(String(format: "  %@ exit %d (expected %d)  %@ — %@",
                                ok ? "ok  " : "FAIL",
                                ruling.status, scenario.expected,
                                scenario.name.padding(toLength: 52, withPad: " ", startingAt: 0),
                                ruling.reason))
        }

        lines.append(failures.isEmpty
                     ? "  \(scenarios().count) rulings, all as expected"
                     : "  \(failures.count) of \(scenarios().count) rulings are wrong")
        lines.append("")
        FileHandle.standardError.write(Data(lines.joined(separator: "\n").utf8))
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - The stubs

    /// A run in which everything the report prints is present. Every other scenario is this one
    /// with a single piece of evidence removed, so a scenario's name is also the difference.
    private static func healthy() -> [String: Any] {
        [
            "route": "scheme",
            "documentLoaded": true,
            "coldLoad": ["reachedReady": true, "processStartToReadyMs": 556.0,
                         "navigationStartToReadyMs": 346.0, "budgetMs": 1000, "withinBudget": true],
            "frameLiveness": ["frames": 60, "framesAvailable": true, "occlusionOverridden": false],
            "chunk": ["loaded": true, "elapsedMs": 18.0],
            "fiveMegabyteFile": ["bytes": 5_243_442, "lines": 209_919, "syncMs": 88.0,
                                 "toRenderMs": 104.0, "toSecondFrameMs": 125.0, "complete": true],
            // Annotated: an all-numeric literal infers `[String: Double]`, `frames` becomes
            // 180.0, and `as? Int` then reads nil — a stub that lies in the shape the verdict
            // is most likely to be wrong about. The self-check found this on its first run.
            "scroll": ["requestedFrames": 180, "frames": 180, "timedOut": false,
                       "p50Ms": 17.0, "p95Ms": 28.0, "worstMs": 52.0] as [String: Any],
            "reopen": ["contentsReplaced": true, "requestedLineRevealed": true,
                       "errorsDuringReopen": [String](), "reopenSucceeded": true],
            "diff": ["computed": true, "changeCount": 508, "renderedInsertLines": 23,
                     "renderedDeleteLines": 33, "renderedDiffDecorations": 98, "viewLines": 91,
                     "diffPaneDisplayed": true],
            "workers": [
                "instantiation": WorkerEvidence.workerFiles.map { ["file": $0, "started": true] },
                "functional": Dictionary(uniqueKeysWithValues:
                    WorkerEvidence.languageServices.map { ($0, ["answered": true] as [String: Any]) }),
                "editorWorkerComputedDiff": true,
                "monacoWorkers": ["workerCount": 5, "fallbackWarnings": [String](),
                                  "byService": monacoWorkerCounts(received: 6)],
            ] as [String: Any],
            "editorErrors": [String](),
        ]
    }

    /// The per-service message counts the instrumentation reports for Monaco's *own* workers.
    private static func monacoWorkerCounts(received: Int) -> [String: Any] {
        var counts: [String: Any] = [:]
        for service in WorkerEvidence.languageServices + ["editor"] {
            counts[service] = ["workers": 1, "sent": received, "received": received, "errors": [String]()]
        }
        return counts
    }

    private static func mutating(_ key: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var report = healthy()
        var branch = report[key] as? [String: Any] ?? [:]
        change(&branch)
        report[key] = branch
        return report
    }

    private static func scenarios() -> [Scenario] {
        [
            Scenario(name: "a complete run, within budget", expected: 0, because: "within budget", report: healthy()),

            // The load paths: the route search's own signal, unchanged.
            Scenario(name: "the document never reported ready", expected: 2, because: "never reported ready",
                     report: mutating("documentLoaded") { _ in }.merging(["documentLoaded": false]) { _, new in new }),
            Scenario(name: "the dynamic-import chunk did not load", expected: 2, because: "dynamic-import chunk did not load",
                     report: mutating("chunk") { $0["loaded"] = false }),
            Scenario(name: "a language service did not answer", expected: 2, because: "json language service did not answer",
                     report: mutating("workers") {
                         var functional = $0["functional"] as? [String: Any] ?? [:]
                         functional["json"] = ["answered": false]
                         $0["functional"] = functional
                     }),
            // C2: Monaco's own workers exchanged nothing, so the functional answers came from
            // the main-thread fallback and the direct probe's population proves nothing.
            Scenario(name: "Monaco's own workers exchanged no messages", expected: 2, because: "ran on the main thread",
                     report: mutating("workers") {
                         $0["monacoWorkers"] = ["workerCount": 0, "byService": [String: Any](),
                                                "fallbackWarnings": ["Could not create web worker(s)."]]
                     }),
            // Traffic is not health: a worker can exchange messages and then die, and a verdict
            // that reads only the counts calls that route carried.
            Scenario(name: "a worker exchanged messages and then recorded an error", expected: 2,
                     because: "Monaco's own css worker recorded 1 error",
                     report: mutating("workers") {
                         var counts = monacoWorkerCounts(received: 6)
                         counts["css"] = ["workers": 1, "sent": 6, "received": 6,
                                          "errors": ["Worker terminated: css.worker.js"]]
                         $0["monacoWorkers"] = ["workerCount": 5, "fallbackWarnings": [String](),
                                                "byService": counts]
                     }),
            Scenario(name: "the editor worker exchanged no messages", expected: 2, because: "editor worker exchanged",
                     report: mutating("workers") {
                         var counts = monacoWorkerCounts(received: 6)
                         counts["editor"] = ["workers": 1, "sent": 3, "received": 0, "errors": [String]()]
                         $0["monacoWorkers"] = ["workerCount": 5, "fallbackWarnings": [String](),
                                                "byService": counts]
                     }),

            // C1: a run that produced no render evidence is not a pass.
            Scenario(name: "the window was given no animation frames", expected: 4, because: "no animation frames",
                     report: mutating("frameLiveness") { $0["frames"] = 0; $0["framesAvailable"] = false }),
            Scenario(name: "the 5 MB file's recorder never completed", expected: 6, because: "render recorder never completed",
                     report: mutating("fiveMegabyteFile") {
                         $0["complete"] = false
                         $0["timedOutWaitingForFrame"] = true
                     }),
            Scenario(name: "the scroll histogram recorded no frames", expected: 6, because: "scroll histogram recorded no frames",
                     report: mutating("scroll") { $0["frames"] = 0 }),
            // A partial histogram is a different number from the one the gate asks for: the
            // probe's timeout can return any positive count, and percentiles over a truncated
            // sample describe a scroll that was never finished.
            Scenario(name: "the scroll stopped short of the requested frames", expected: 6,
                     because: "recorded 90 of 180 requested frames",
                     report: mutating("scroll") { $0["frames"] = 90; $0["timedOut"] = true }),
            Scenario(name: "the diff pane was never displayed", expected: 6, because: "diff pane was never displayed",
                     report: mutating("diff") { $0["diffPaneDisplayed"] = false }),
            Scenario(name: "the diff rendered nothing into the DOM", expected: 6, because: "rendered nothing into the DOM",
                     report: mutating("diff") {
                         $0["renderedDiffDecorations"] = 0
                         $0["renderedInsertLines"] = 0
                         $0["renderedDeleteLines"] = 0
                     }),
            Scenario(name: "reopening the open file did not succeed", expected: 6, because: "already on screen did not succeed",
                     report: mutating("reopen") { $0["reopenSucceeded"] = false }),
            Scenario(name: "the editor reported an error", expected: 7, because: "the editor reported 1 error",
                     report: healthy().merging(["editorErrors": ["open failed: model exists"]]) { _, new in new }),

            Scenario(name: "every load path, cold load over budget", expected: 5, because: "over budget",
                     report: mutating("coldLoad") { $0["withinBudget"] = false
                                                    $0["processStartToReadyMs"] = 1_864.0 }),
        ]
    }
}
