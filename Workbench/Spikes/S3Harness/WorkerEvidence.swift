import Foundation

/// What the run knows about the five workers, reduced to one dictionary and one boolean.
///
/// Pure, and separate from the probes that gather it, for the same reason `Verdict` is: the
/// claim "the workers are alive" is the one finding S3 exists to make, and a claim that cannot
/// be driven from stubbed evidence cannot be shown to fail.
enum WorkerEvidence {

    /// The five worker entries the bundle ships.
    static let workerFiles = ["editor.worker.js", "ts.worker.js", "json.worker.js",
                              "css.worker.js", "html.worker.js"]

    /// The four language services, by the key each answers under in the functional probe.
    static let languageServices = ["css", "html", "json", "typescript"]

    /// The key the instrumentation files a worker under when its label is not a language's.
    static let editorWorkerKey = "editor"

    /// The messages Monaco's own worker for `service` exchanged with the page.
    private static func exchanged(_ instrumented: [String: Any], _ service: String) -> Int {
        let byService = instrumented["byService"] as? [String: Any] ?? [:]
        let bucket = byService[service] as? [String: Any] ?? [:]
        return bucket["received"] as? Int ?? 0
    }

    /// `direct` is the instantiation probe's own worker population; `instrumented` is the count
    /// of messages exchanged on the workers **Monaco itself created**, which is the only
    /// population the functional answers can be attributed to.
    ///
    /// The distinction is the whole point. Monaco falls back to running its language services on
    /// the main thread without raising anything a probe can catch — it logs "Could not create web
    /// worker(s). Falling back to loading web worker code in main thread" and carries on — so a
    /// verdict built from "a worker the harness constructed started" plus "a functional answer
    /// arrived" can read `proven` on a page whose workers are all dead. What is required here is
    /// per service: the answer arrived **and** that service's own Monaco worker exchanged
    /// messages; and for the diff, the change list **and** traffic on the editor worker.
    static func summarise(direct: [[String: Any]],
                          functional: [String: Any],
                          instrumented: [String: Any],
                          diffComputed: Bool) -> [String: Any] {
        let started = Dictionary(uniqueKeysWithValues: direct.compactMap { entry -> (String, Bool)? in
            guard let file = entry["file"] as? String else { return nil }
            return (file, entry["started"] as? Bool ?? false)
        })
        let allFive = workerFiles.allSatisfy { started[$0] == true }

        let answered = Dictionary(uniqueKeysWithValues: languageServices.map { name in
            (name, (functional[name] as? [String: Any])?["answered"] as? Bool ?? false)
        })
        let allAnswered = answered.values.allSatisfy { $0 }

        let messages = Dictionary(uniqueKeysWithValues:
            (languageServices + [editorWorkerKey]).map { ($0, exchanged(instrumented, $0)) })
        let provenByService = Dictionary(uniqueKeysWithValues: languageServices.map { name in
            (name, (answered[name] ?? false) && (messages[name] ?? 0) > 0)
        })
        let editorWorkerExchanged = (messages[editorWorkerKey] ?? 0) > 0
        let fallbackWarnings = instrumented["fallbackWarnings"] as? [String] ?? []
        // The named shape of the composite's fourth resort: the service answered, so something
        // computed it, and no worker of Monaco's own carried a message — which is the main
        // thread. Design §7 makes that a stop, not a fallback.
        let mainThreadFallback = !fallbackWarnings.isEmpty
            || languageServices.contains { (answered[$0] ?? false) && (messages[$0] ?? 0) == 0 }

        let proven = allFive && allAnswered && diffComputed
            && provenByService.values.allSatisfy { $0 } && editorWorkerExchanged

        var unprovenBecause: String?
        if !proven {
            if !allFive {
                unprovenBecause = "a worker entry did not instantiate"
            } else if let silent = languageServices.sorted().first(where: { !(answered[$0] ?? false) }) {
                unprovenBecause = "the \(silent) language service did not answer"
            } else if !diffComputed {
                unprovenBecause = "the editor worker did not compute the diff"
            } else if let onMain = languageServices.sorted().first(where: { (messages[$0] ?? 0) == 0 }) {
                unprovenBecause = "the \(onMain) service answered but Monaco's own \(onMain) worker"
                    + " exchanged no messages — the service ran on the main thread"
            } else if !editorWorkerExchanged {
                unprovenBecause = "the diff was computed but Monaco's own editor worker exchanged"
                    + " no messages — the computation ran on the main thread"
            }
        }

        var summary: [String: Any] = [
            "instantiation": direct,
            "functional": functional,
            "monacoWorkers": instrumented,
            "allFiveStarted": allFive,
            "startedByFile": started,
            "answeredByService": answered,
            "allServicesAnswered": allAnswered,
            "messagesByMonacoWorker": messages,
            "provenByService": provenByService,
            "editorWorkerComputedDiff": diffComputed,
            "editorWorkerExchangedMessages": editorWorkerExchanged,
            "mainThreadFallback": mainThreadFallback,
            "proven": proven,
            // Named so the report never reads as if silence proved life, and never as if an
            // answer from an unknown thread proved a worker.
            "note": "instantiation is the harness's own worker population and records only the"
                + " module worker's `error` event. The functional block is the positive claim,"
                + " and it is attributed: `proven` requires, per service, that the answer arrived"
                + " AND that Monaco's own worker for that service exchanged messages — and for"
                + " the diff, the change list AND traffic on Monaco's editor worker. Without the"
                + " second half an answer from Monaco's silent main-thread fallback is"
                + " indistinguishable from a working worker.",
        ]
        if let unprovenBecause { summary["unprovenBecause"] = unprovenBecause }
        return summary
    }
}
