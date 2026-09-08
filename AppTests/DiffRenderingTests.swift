import Foundation
import SwiftUI
import XCTest
import ClaudeWire
@testable import Afleet

/// Records every path the card asked to read, and answers with the shipped reader.
///
/// The seam is the whole point: `DiffSource` reaches the filesystem through this member and
/// nowhere else, so a count of what arrived here is a count of every read the card made.
///
/// An actor, because the seam is `async` and off the main actor by design (scalpel-5#1): a double
/// that could only be reached from the main actor would not stand in for the thing under test.
actor RecordingReader: FileTextReading {
    private let underlying: FileTextReader
    private(set) var requested: [String] = []

    init(limitBytes: Int = FileTextReader.defaultLimitBytes) {
        underlying = FileTextReader(limitBytes: limitBytes)
    }

    func read(atPath path: String) async -> FileText {
        requested.append(path)
        return await underlying.read(atPath: path)
    }
}

/// A `DiffRendering` that draws nothing and remembers that it was asked.
///
/// Used to assert the negative: a card that fell back to the tool's input must not also have
/// handed a pair of sides to a renderer. Counting calls here is what stops a renderer that
/// silently diffed an unreadable file against empty from passing.
@MainActor
final class RendererProbe: DiffRendering {
    private(set) var calls = 0

    func view(before: String, after: String, path: String) -> AnyView {
        calls += 1
        return AnyView(EmptyView())
    }
}

/// Spec D9: the diff's two sources, the line-level difference over them, and what a card draws
/// when it cannot read the other side at all.
///
/// Every file here is invented, under `TempTree` — which refuses a root inside a config home
/// (X9, tracker 24) — and every failure message carries counts rather than the paths it built.
@MainActor
final class DiffRenderingTests: XCTestCase {

    // MARK: - Support

    private func texts(in body: Any) -> [String] { CardTree.texts(in: body) }

    private func kinds(_ lines: [DiffLine], _ kind: DiffLineKind) -> [String] {
        lines.filter { $0.kind == kind }.map(\.text)
    }

    /// The tool input as the wire carries it, parsed the way the card parses it.
    private func toolInput(_ name: String, _ fields: [String: Any]) throws -> ToolInput {
        let data = try JSONSerialization.data(withJSONObject: fields)
        return ToolInput.parse(name: name, input: try JSONDecoder().decode(JSONValue.self, from: data))
    }

    private func prepared(_ input: ToolInput, _ reader: RecordingReader) async throws -> DiffPreparation {
        let preparation = await DiffSource.prepare(input, reader: reader)
        return try XCTUnwrap(preparation, "a file-changing tool input produced nothing to draw")
    }

    /// How many reads went through the seam.
    private func requested(_ reader: RecordingReader) async -> Int { await reader.requested.count }

    private func sides(_ preparation: DiffPreparation) throws -> (before: String, after: String) {
        guard case .diff(let before, let after, _) = preparation else {
            XCTFail("the input produced no diff when both sides were readable")
            return ("", "")
        }
        return (before, after)
    }

    // MARK: - Write

    /// A `Write` to a path that does not exist diffs against empty, so every line is an
    /// addition and nothing is drawn as removed.
    func testAWriteToANewFileIsAllAdditions() async throws {
        let tree = try TempTree()
        let target = tree.root.appending(path: "invented-module/new-file.txt")
        let reader = RecordingReader()

        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\nbeta\ngamma"])
        let both = try sides(try await prepared(input, reader))
        XCTAssertTrue(both.before.isEmpty, "an absent file offered \(both.before.count) characters as the before side")

        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)
        XCTAssertEqual(kinds(lines, .added), ["alpha", "beta", "gamma"],
                       "\(kinds(lines, .added).count) of 3 lines were drawn as additions")
        XCTAssertEqual(kinds(lines, .removed).count, 0,
                       "\(kinds(lines, .removed).count) removals were drawn against a file that does not exist")
        XCTAssertEqual(kinds(lines, .context).count, 0,
                       "\(kinds(lines, .context).count) context lines were drawn against a file that does not exist")
        let reads1 = await requested(reader)
        XCTAssertEqual(reads1, 1, "\(reads1) reads for one Write")
    }

    /// A `Write` over a file that exists diffs against its current contents: the replaced line
    /// is drawn as a removal and an addition, and the lines that did not move stay context.
    func testAWriteOverAnExistingFileShowsBothSides() async throws {
        let tree = try TempTree()
        let target = try tree.file("invented-module/settled-file.txt", "alpha\nbeta\ngamma")
        let reader = RecordingReader()

        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\ndelta\ngamma"])
        let both = try sides(try await prepared(input, reader))
        XCTAssertEqual(both.before, "alpha\nbeta\ngamma",
                       "the before side carried \(both.before.count) characters of the file on disk")

        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)
        XCTAssertEqual(kinds(lines, .removed), ["beta"],
                       "\(kinds(lines, .removed).count) of 1 removals were drawn")
        XCTAssertEqual(kinds(lines, .added), ["delta"],
                       "\(kinds(lines, .added).count) of 1 additions were drawn")
        XCTAssertEqual(kinds(lines, .context), ["alpha", "gamma"],
                       "\(kinds(lines, .context).count) of 2 unchanged lines stayed context")
        let reads2 = await requested(reader)
        XCTAssertEqual(reads2, 1, "\(reads2) reads for one Write")
    }

    // MARK: - Edit

    /// An `Edit` diffs `old_string` against `new_string` in place: the surrounding lines come
    /// from the file, and only the three either side of the change do — a whole file drawn as
    /// context would bury a one-line edit.
    func testAnEditShowsOldAgainstNewWithContext() async throws {
        let tree = try TempTree()
        let body = (1...9).map { "line-\($0)" }.joined(separator: "\n")
        let target = try tree.file("invented-module/edited-file.txt", body)
        let reader = RecordingReader()

        let input = try toolInput("Edit", ["file_path": target.path,
                                           "old_string": "line-5",
                                           "new_string": "line-5-changed"])
        let both = try sides(try await prepared(input, reader))
        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)

        XCTAssertEqual(kinds(lines, .removed), ["line-5"],
                       "\(kinds(lines, .removed).count) of 1 removals were drawn for a one-line edit")
        XCTAssertEqual(kinds(lines, .added), ["line-5-changed"],
                       "\(kinds(lines, .added).count) of 1 additions were drawn for a one-line edit")
        XCTAssertEqual(kinds(lines, .context),
                       ["line-2", "line-3", "line-4", "line-6", "line-7", "line-8"],
                       "\(kinds(lines, .context).count) of 6 context lines came from the file")
        let reads3 = await requested(reader)
        XCTAssertEqual(reads3, 1, "\(reads3) reads for one Edit")
    }

    /// sweep#8: `replace_all` changes **every** occurrence, and the diff has to show that.
    ///
    /// The proposed change is what the user is consenting to. A diff built from the first match
    /// alone understates a `replace_all` by however many other occurrences the file holds, and the
    /// two clauses below are the two halves of the same fact: nothing the tool would change is left
    /// on the after side, and the occurrences it would leave alone on a plain `Edit` are still
    /// there. Both arms run over one file, so the flag is the only difference between them.
    func testReplaceAllChangesEveryOccurrenceAndAPlainEditChangesOne() async throws {
        let tree = try TempTree()
        let body = (1...9).map { $0 % 3 == 0 ? "target" : "line-\($0)" }.joined(separator: "\n")
        let target = try tree.file("invented-module/repeated.txt", body)
        XCTAssertEqual(body.components(separatedBy: "target").count - 1, 3,
                       "the invented file does not carry the three occurrences this test needs")

        let all = try toolInput("Edit", ["file_path": target.path, "old_string": "target",
                                         "new_string": "replaced", "replace_all": true])
        let everywhere = try sides(try await prepared(all, RecordingReader()))
        XCTAssertEqual(everywhere.after.components(separatedBy: "target").count - 1, 0,
                       "the after side still carries occurrences a replace_all would have changed")
        XCTAssertEqual(everywhere.after.components(separatedBy: "replaced").count - 1, 3,
                       "the after side carries fewer replacements than the tool would make")

        let one = try toolInput("Edit", ["file_path": target.path, "old_string": "target",
                                         "new_string": "replaced"])
        let once = try sides(try await prepared(one, RecordingReader()))
        XCTAssertEqual(once.after.components(separatedBy: "replaced").count - 1, 1,
                       "a plain Edit was drawn as changing more than the one occurrence it changes")
    }

    // MARK: - The file that cannot be read

    /// The discriminating clause. A file that exists and cannot be decoded is **not** a new
    /// file: the card shows the tool's own input, says why there is no diff, and hands no pair
    /// of sides to any renderer at all. A renderer that quietly diffed against empty would draw
    /// the whole write as additions and claim the file was new.
    ///
    /// **Trace assertion (Global Constraints, discriminating tests).** The read that cannot be
    /// executed as a failure is "a descriptor was left open on a user-content path": TCC blocks on
    /// the consent dialog rather than returning, so the break would hang the suite instead of
    /// failing it. The substitute is a trace on the one seam every read goes through — the recorded
    /// requests below account for every read the card made — together with the source scan in
    /// `testEveryUserContentReadIsBoundedAndClosesItsDescriptor`.
    func testAnUnreadableFileFallsBackToTheInputAndSaysSo() async throws {
        let tree = try TempTree()
        let target = tree.root.appending(path: "invented-module/opaque-file.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Bytes that are not UTF-8, so the file exists and its text cannot be recovered.
        try Data([0xFF, 0xFE, 0x00, 0x80, 0x81]).write(to: target)

        let reader = RecordingReader()
        let renderer = RendererProbe()
        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\nbeta"])

        guard case .verbatim(_, let sections) = try await prepared(input, reader) else {
            XCTFail("an unreadable file produced a diff instead of the tool's input")
            return
        }
        XCTAssertEqual(sections.count, 1, "\(sections.count) of 1 verbatim sections were offered")
        XCTAssertEqual(sections.first?.text, "alpha\nbeta",
                       "the verbatim section carried \(sections.first?.text.count ?? 0) characters of input")

        let card = DiffView(input: input, reader: reader, renderer: renderer)
        let preparation = await card.prepare()
        let prepared = try XCTUnwrap(preparation, "the card prepared nothing for a file-changing input")
        let body = DiffView(input: input, reader: reader, renderer: renderer, prepared: prepared).body
        XCTAssertTrue(texts(in: body).contains(DiffView.unreadableNotice),
                      "the card drew \(texts(in: body).count) lines and none of them said why there is no diff")
        XCTAssertEqual(renderer.calls, 0,
                       "\(renderer.calls) diffs were produced for a file the app cannot read")

        // Trace: every read went through the seam.
        let reads4 = await requested(reader)
        XCTAssertEqual(reads4, 2, "\(reads4) of 2 reads went through the seam")
    }

    // MARK: - Where the read happens, and how much of it

    /// scalpel-5#1: **no file is read while the card's body is being evaluated.**
    ///
    /// `body` is re-evaluated on every invalidation of anything the card observes, and it used to
    /// perform the whole-file read *and* the line-level difference on the main actor each time. The
    /// count of reads made while `body` runs is what says the read has left it; the count of
    /// differences actually computed is what says the second half went with it.
    func testTheRenderPassReadsNothingAndDiffsOnce() async throws {
        let tree = try TempTree()
        let target = try tree.file("invented-module/prepared.txt", "alpha\nbeta\ngamma")
        let reader = RecordingReader()
        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\ndelta\ngamma"])

        // The render pass, three times over, with nothing prepared and then with a preparation.
        let unprepared = DiffView(input: input, reader: reader)
        for _ in 0..<3 { _ = texts(in: unprepared.body) }
        let reads5 = await requested(reader)
        XCTAssertEqual(reads5, 0,
                       "\(reads5) reads were made inside the render pass")

        let preparation = await DiffView(input: input, reader: reader).prepare()
        let prepared = try XCTUnwrap(preparation, "the card prepared nothing for a Write")
        let afterPrepare = await requested(reader)
        XCTAssertEqual(afterPrepare, 1,
                       "one preparation made \(afterPrepare) reads")

        DiffLineCache.reset()
        let card = DiffView(input: input, reader: reader, prepared: prepared)
        for _ in 0..<4 { _ = texts(in: card.body) }
        XCTAssertEqual(DiffLineCache.computations, 1,
                       "four render passes computed \(DiffLineCache.computations) differences of one unchanged pair")
        let reads6 = await requested(reader)
        XCTAssertEqual(reads6, 1,
                       "\(reads6) of 1 reads for a card drawn four times")
    }

    /// scalpel-5#2, and the amended user-content rule's second half: a file past the reader's
    /// ceiling is **unreadable**, not truncated. Half a file diffed against a whole one would draw
    /// the missing half as a deletion the tool never proposed, so the card falls back to the input.
    func testAFilePastTheCeilingIsUnreadableRatherThanTruncated() async throws {
        let tree = try TempTree()
        let body = String(repeating: "abcdefghij\n", count: 512)
        let target = try tree.file("invented-module/oversized.txt", body)
        let ceiling = 64
        XCTAssertGreaterThan(body.utf8.count, ceiling, "the invented file does not exceed the ceiling")

        let reader = RecordingReader(limitBytes: ceiling)
        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha"])
        guard case .verbatim = try await prepared(input, reader) else {
            return XCTFail("a file past the reader's ceiling was diffed against a partial read of itself")
        }

        // And the bound is on the read itself: what came back is the ceiling's worth, no more.
        guard case .bytes(let bytes, let truncated) = BoundedFileRead.read(atPath: target.path, upTo: ceiling) else {
            return XCTFail("the bounded read could not read a file it had just been given")
        }
        XCTAssertEqual(bytes.count, ceiling, "\(bytes.count) bytes came back for a ceiling of \(ceiling)")
        XCTAssertTrue(truncated, "a file larger than the ceiling was not reported as truncated")
    }

    /// The same read refuses what it is not: a symbolic link at the final component (`O_NOFOLLOW`,
    /// so the swap a check-then-read leaves room for cannot happen) and a directory (`fstat` on the
    /// descriptor actually opened, not `lstat` on the name).
    func testTheBoundedReadRefusesALinkAndADirectory() throws {
        let tree = try TempTree()
        let target = try tree.file("invented-module/linked-to.txt", "alpha")
        let link = tree.root.appending(path: "invented-module/a-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        guard case .unreadable = BoundedFileRead.read(atPath: link.path, upTo: 4096) else {
            return XCTFail("a symbolic link at the final component was followed rather than refused")
        }
        guard case .unreadable = BoundedFileRead.read(atPath: tree.root.path, upTo: 4096) else {
            return XCTFail("a directory was read as though it were a file")
        }
        guard case .absent = BoundedFileRead.read(atPath: tree.root.appending(path: "nothing").path, upTo: 4096) else {
            return XCTFail("a path naming nothing was not reported absent")
        }
    }

    /// **The amended user-content rule, as a source scan.** The child's rule was "no descriptor on a
    /// user-content path"; it is now "no descriptor held across an await or beyond the bounded
    /// read" — a reader may open the file read-only with `O_NOFOLLOW`, read at most its bound and
    /// close before returning, which is the shape C7.3's `workingTreeFile` already holds. The
    /// amendment exists because the old rule forced `Data(contentsOf:)` and `String(contentsOf:)`,
    /// which have no bound at all: `mappedIfSafe` is a hint, and where the kernel will not map,
    /// Foundation reads the whole file into memory before any `prefix` runs.
    ///
    /// So the scan asserts three things of every file that reads a user-content path: no
    /// descriptor-*holding* object is constructed, no unbounded whole-file read is called, and
    /// every `open` is matched by a `defer { close(` in the same file.
    func testEveryUserContentReadIsBoundedAndClosesItsDescriptor() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // A descriptor that outlives the call holding it, and the two unbounded whole-file reads.
        let forbidden = ["FileHandle(", "InputStream(", "FileManager.default.contents(atPath",
                         "Data(contentsOf:", "Data(contentsOf ", "String(contentsOf"]
        for name in ["DiffRendering.swift", "AttributedDiffRenderer.swift", "SentFileRowView.swift"] {
            // Code only: these files document the rule, and the prose naming the calls it forbids
            // is not a call.
            let whole = try String(contentsOf: root.appending(path: "App/Decisions/\(name)"), encoding: .utf8)
            let source = whole.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let found = forbidden.filter { source.contains($0) }
            XCTAssertEqual(found.count, 0,
                           "\(found.count) unbounded or descriptor-holding reads appear in a file that reads "
                           + "user content")

            let opens = source.components(separatedBy: "= path.withCString { open(").count - 1
            let closes = source.components(separatedBy: "defer { close(").count - 1
            XCTAssertEqual(opens, closes,
                           "\(opens) descriptor(s) are opened and \(closes) are closed before the call returns")
            if opens > 0 {
                XCTAssertTrue(source.contains("O_NOFOLLOW"),
                              "a descriptor is opened on a user-content path without O_NOFOLLOW")
            }
        }
    }
}
