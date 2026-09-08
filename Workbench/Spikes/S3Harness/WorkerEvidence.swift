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

    static func summarise(direct: [[String: Any]],
                          functional: [String: Any],
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

        return [
            "instantiation": direct,
            "functional": functional,
            "allFiveStarted": allFive,
            "startedByFile": started,
            "answeredByService": answered,
            "allServicesAnswered": allAnswered,
            "editorWorkerComputedDiff": diffComputed,
            // The verdict's own key. Every one of the four language workers answered a request
            // only it can answer, and editor.worker computed the diff; instantiation alone is
            // not enough, because silence during the settle window is what a dead worker also
            // looks like.
            "proven": allFive && allAnswered && diffComputed,
            // Named so the report never reads as if silence proved life.
            "note": "instantiation records the module worker's `error` event; `started: true` means"
                + " no load error inside the settle window. The functional block is the positive"
                + " claim: editor.worker is witnessed by the diff's computed line changes."
                + " `proven` requires both, and is what the verdict reads.",
        ]
    }
}
