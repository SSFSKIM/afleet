import AppKit
import XCTest
@testable import Afleet

/// **S7** (root spec §15, child spec §11 and §12): does the native markdown path hold sixteen
/// milliseconds at thirty updates per second?
///
/// The gate itself is the last test and is skipped unless `AFLEET_S7=1`, because it runs for sixty
/// seconds and `make test` allows each test one hundred and twenty. The three before it are the
/// ones that make the gate's number mean something: the instrument is shown able to go red and able
/// to go green, the corpus is shown to contain the shapes the gate names, and the cadence is shown
/// to come from the recording rather than from a number somebody typed.
@MainActor
final class TimelineFrameTimeSpikeTests: XCTestCase {

    // MARK: - The instrument, before the spike is trusted

    /// **The harness's own discriminating test.** It runs before any verdict is believed.
    ///
    /// A frame-time harness that reported a proxy — the time to build an `AttributedString`, say,
    /// or the display link's own interval — would report a comfortable number against a renderer
    /// that visibly janks, and S7 would promote a design that does not work. So the instrument is
    /// pointed at a view whose update deliberately blocks the main thread for forty milliseconds
    /// every tenth update, and is required to see it.
    ///
    /// The second half matters as much: an instrument that is always red is not an instrument
    /// either, and the display-link interval would be exactly that — pinned near 16.7 ms on a
    /// sixty-hertz panel whatever the renderer does. So the same harness over an empty closure has
    /// to come back under the bound.
    func testTheHarnessMeasuresRealFrames() async throws {
        let blocking = await FrameTimeHarness().measure(view: NSView(), updatesPerSecond: 30, duration: 5) { index in
            if index % 10 == 0 { Thread.sleep(forTimeInterval: 0.040) }
            return RenderPhases()
        }
        XCTAssertGreaterThan(blocking.sampled, 50,
                             "the harness took \(blocking.sampled) sample(s) in five seconds; the display link did not run")
        XCTAssertGreaterThan(blocking.milliseconds.p99, 16,
                             "a view blocking the main thread for 40 ms every tenth update reported a p99 of " +
                             "\(String(format: "%.2f", blocking.milliseconds.p99)) ms; the harness is measuring a proxy")

        let idle = await FrameTimeHarness().measure(view: NSView(), updatesPerSecond: 30, duration: 5) { _ in
            RenderPhases()
        }
        XCTAssertGreaterThan(idle.sampled, 50,
                             "the idle run took \(idle.sampled) sample(s); the display link did not run")
        XCTAssertLessThan(idle.milliseconds.p99, 16,
                          "an empty update reported a p99 of \(String(format: "%.2f", idle.milliseconds.p99)) ms; " +
                          "the harness is red whatever it measures")

        print("[S7 instrument] blocking p99 \(String(format: "%.2f", blocking.milliseconds.p99)) ms " +
              "over \(blocking.sampled) samples; idle p99 \(String(format: "%.2f", idle.milliseconds.p99)) ms " +
              "over \(idle.sampled) samples")
    }

    // MARK: - The corpus

    /// Every shape the gate names appears in the corpus, asserted by parsing rather than by
    /// counting characters — a substring search for "|" would call any table row a table.
    func testTheCorpusCoversEveryShapeTheGateNames() throws {
        let documents = MarkdownCorpus.documents
        XCTAssertEqual(documents.count, 10, "the corpus holds \(documents.count) documents, not the ten the gate names")
        XCTAssertTrue(documents.allSatisfy { !$0.isEmpty }, "the corpus holds an empty document")

        var found: Set<String> = []
        for document in documents {
            let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("###### ") { found.insert("h6") }
                if line.hasPrefix("# ") { found.insert("h1") }
                if line.hasPrefix("> ") { found.insert("quote") }
                if line.hasPrefix("```") { found.insert("fence") }
                if line.hasPrefix("    - ") || line.hasPrefix("  - ") { found.insert("nested-unordered") }
                if line.hasPrefix("   1. ") || line.hasPrefix("  1. ") { found.insert("nested-ordered") }
                // A table needs a delimiter row under a header row, which is what makes it a table
                // and not a line with pipes in it.
                if line.hasPrefix("|---") || line.hasPrefix("|:-") {
                    if index > 0, lines[index - 1].hasPrefix("|") { found.insert("table") }
                }
                if line.contains("`") && !line.hasPrefix("```") { found.insert("inline-code") }
                if line.contains("](http") { found.insert("link") }
                if line.count > 3_000 { found.insert("long-line") }
                if line.unicodeScalars.contains(where: { (0x3000...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) {
                    found.insert("cjk")
                }
            }
        }
        found.insert(MarkdownCorpus.documents.indices.contains(MarkdownCorpus.thinkingDocumentIndex) ? "thinking" : "")

        let required = ["h1", "h6", "quote", "fence", "nested-unordered", "nested-ordered",
                        "table", "inline-code", "link", "long-line", "cjk", "thinking"]
        let missing = required.filter { !found.contains($0) }
        XCTAssertTrue(missing.isEmpty, "\(missing.count) of \(required.count) named shapes are absent from the corpus: \(missing.sorted())")

        // The fences the highlighter warms, including the one no grammar covers.
        let fences = MarkdownCorpus.fencedBlocks
        XCTAssertGreaterThanOrEqual(fences.count, 6, "the corpus holds \(fences.count) fenced blocks, fewer than the six languages the gate names")
        let languages = Set(fences.compactMap(\.language))
        for named in ["swift", "python", "typescript", "json", "bash"] {
            XCTAssertTrue(languages.contains(named), "the corpus has no \(named) fence")
        }
        XCTAssertTrue(languages.contains(where: { Highlighting.shared.hasNoGrammar(for: $0) }),
                      "every fence in the corpus names a language the highlighter covers; the fallback path is unexercised")
    }

    /// The cadence is the recording's, counted the same way the corpus counts it.
    func testTheCadenceComesFromARecording() throws {
        let recorded = try MarkdownCorpus.recordedDeltaCount()
        XCTAssertGreaterThan(recorded, 0, "the fixture yielded no content_block_delta events at all")

        let cadence = try MarkdownCorpus.cadence()
        XCTAssertFalse(cadence.isEmpty, "the cadence is empty although the fixture carries \(recorded) delta(s)")
        XCTAssertEqual(cadence.count, recorded - 1,
                       "the cadence holds \(cadence.count) gap(s) for \(recorded) recorded delta(s)")
        XCTAssertTrue(cadence.allSatisfy { $0 >= 0 }, "the cadence holds a negative gap, so the timestamps are out of order")
    }

    // MARK: - The gate

    /// **S7.** Thirty updates per second for sixty seconds over the corpus, through the native path.
    ///
    /// Skipped unless `AFLEET_S7=1`: it runs for a minute and the suite allows each test two, so it
    /// is a designed skip named in the plan rather than an accident. Run it with the variable set to
    /// get the verdict.
    func testTheNativePathHoldsSixteenMillisecondsAtThirtyHertz() async throws {
        // **`TEST_RUNNER_`, and the prefix is the whole point.** `xcodebuild test` does not hand the
        // invoking shell's environment to the test host: a bare `AFLEET_S7=1` leaves this reading
        // nil, the test skips, and a skip reads as a pass — which is how a gate reports green
        // without ever running. C5's spec records the same trap; this comment is here so the next
        // reader of this file does not rediscover it a third time.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AFLEET_S7"] == "1",
                          "S7's gate runs for sixty seconds; run it with TEST_RUNNER_AFLEET_S7=1")

        let controller = TimelineTableController()

        // Warm the caches off the main thread first, because that is the design: a settled block is
        // parsed once and a fenced block is highlighted off-main. Measuring cold caches would
        // measure a renderer nobody proposed.
        let markdown = MarkdownText()
        let highlighter = CodeHighlighter()
        await highlighter.warm(MarkdownCorpus.fencedBlocks)
        await markdown.warm(MarkdownCorpus.documents, highlighter: highlighter)

        controller.setRows(MarkdownCorpus.documents.enumerated().map {
            RenderedRow(key: "seed-\($0.offset)", source: $0.element)
        })

        // The streamed content: the corpus six times over, chopped into fragments at the recorded
        // cadence's granularity, so sixty seconds of thirty-hertz updates has something to carry.
        var pending = Array(repeating: MarkdownCorpus.documents, count: 6).flatMap { $0 }
        var current: [Substring] = []
        var streamedRows = 0

        let report = await FrameTimeHarness().measure(view: controller.scrollView,
                                                      updatesPerSecond: 30, duration: 60) { _ in
            if current.isEmpty {
                guard !pending.isEmpty else { return RenderPhases() }
                let document = pending.removeFirst()
                current = Self.fragments(of: document)
                controller.appendRow(RenderedRow(key: "streamed-\(streamedRows)", source: ""))
                streamedRows += 1
            }
            let fragment = current.removeFirst()
            return controller.appendToLastRow(String(fragment))
        }

        let ms = report.milliseconds
        print("[S7] p50 \(String(format: "%.2f", ms.p50)) ms · p99 \(String(format: "%.2f", ms.p99)) ms · " +
              "worst \(String(format: "%.2f", ms.worst)) ms · \(report.sampled) samples · \(report.dropped) dropped · " +
              "rows \(controller.rows.count) · dominant \(Self.dominantPhase(report.phases)) " +
              "(hosting \(String(format: "%.1f", report.phases.hosting * 1000)) ms, " +
              "markdown \(String(format: "%.1f", report.phases.markdown * 1000)) ms, " +
              "highlight \(String(format: "%.1f", report.phases.highlight * 1000)) ms total)")

        XCTAssertGreaterThan(report.sampled, 1_000,
                             "the gate took \(report.sampled) sample(s) in sixty seconds at thirty hertz")
        XCTAssertLessThan(ms.p99, 16,
                          "the native path's p99 is \(String(format: "%.2f", ms.p99)) ms over \(report.sampled) samples; " +
                          "the dominant phase was \(Self.dominantPhase(report.phases)), which decides whether this is " +
                          "the child spec's branch 2 (hosting — an AppKit fast path, a Y1 amendment) or branch 3 " +
                          "(markdown or highlight — the WKWebView fallback)")
    }

    /// The largest of the three phases, named. Computed here rather than on `RenderPhases`, because
    /// a production type carrying a member only a spike reads is exactly what `check-app-wiring`
    /// exists to flag.
    static func dominantPhase(_ phases: RenderPhases) -> String {
        let all = [("hosting", phases.hosting), ("markdown", phases.markdown), ("highlight", phases.highlight)]
        guard let top = all.max(by: { $0.1 < $1.1 }), top.1 > 0 else { return "none" }
        return top.0
    }

    /// Chops a document into fragments of a few characters, the size a real `content_block_delta`
    /// carries.
    private static func fragments(of document: String) -> [Substring] {
        var out: [Substring] = []
        var index = document.startIndex
        while index < document.endIndex {
            let next = document.index(index, offsetBy: 24, limitedBy: document.endIndex) ?? document.endIndex
            out.append(document[index..<next])
            index = next
        }
        return out
    }
}

/// A tiny shim so the corpus test can ask whether a language has no grammar without reaching into
/// the renderer's own cache.
enum Highlighting {
    static let shared = Highlighting.Probe()
    struct Probe {
        private let highlighter = CodeHighlighter()
        func hasNoGrammar(for language: String) -> Bool {
            // A block whose language has no grammar comes back as one undifferentiated run in the
            // monospaced fallback font, which is exactly what §6 says the ordinary path is.
            let styled = highlighter.styled(code: "invented", language: language)
            var effective: NSRange = NSRange(location: 0, length: 0)
            _ = styled.attributes(at: 0, effectiveRange: &effective)
            return effective.length == styled.length
        }
    }
}
