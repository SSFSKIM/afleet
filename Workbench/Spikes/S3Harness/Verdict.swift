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

    static func rule(_ report: [String: Any]) -> Ruling {
        let documentLoaded = report["documentLoaded"] as? Bool ?? false
        let chunkLoaded = (report["chunk"] as? [String: Any])?["loaded"] as? Bool ?? false
        let workers = report["workers"] as? [String: Any] ?? [:]
        let workersProven = workers["proven"] as? Bool ?? false
        let withinBudget = (report["coldLoad"] as? [String: Any])?["withinBudget"] as? Bool ?? false

        guard documentLoaded else {
            return Ruling(status: 2, reason: "the document never reported ready")
        }
        guard chunkLoaded, workersProven else {
            return Ruling(status: 2, reason: "this route drops a load path — advance to the next route")
        }
        return withinBudget
            ? Ruling(status: 0, reason: "every load path is carried and the cold load is within budget")
            : Ruling(status: 5, reason: "every load path is carried; the cold load is over budget")
    }

    /// Re-derives the worker summary from the evidence the report carries, so a stub cannot
    /// assert `proven` at the harness: the ruling reads the evidence, never the claim.
    static func ruleRecomputingWorkers(_ report: [String: Any]) -> Ruling {
        var recomputed = report
        let workers = report["workers"] as? [String: Any] ?? [:]
        recomputed["workers"] = WorkerEvidence.summarise(
            direct: workers["instantiation"] as? [[String: Any]] ?? [],
            functional: workers["functional"] as? [String: Any] ?? [:],
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
