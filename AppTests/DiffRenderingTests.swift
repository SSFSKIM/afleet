import Foundation
import SwiftUI
import XCTest
import ClaudeWire
@testable import Afleet

/// Records every path the card asked to read, and answers with the shipped reader.
///
/// The seam is the whole point: `DiffSource` reaches the filesystem through this member and
/// nowhere else, so a count of what arrived here is a count of every read the card made.
@MainActor
final class RecordingReader: FileTextReading {
    private let underlying = FileTextReader()
    private(set) var requested: [String] = []

    func read(atPath path: String) -> FileText {
        requested.append(path)
        return underlying.read(atPath: path)
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

    private func prepared(_ input: ToolInput, _ reader: RecordingReader) throws -> DiffPreparation {
        try XCTUnwrap(DiffSource.prepare(input, reader: reader),
                      "a file-changing tool input produced nothing to draw")
    }

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
    func testAWriteToANewFileIsAllAdditions() throws {
        let tree = try TempTree()
        let target = tree.root.appending(path: "invented-module/new-file.txt")
        let reader = RecordingReader()

        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\nbeta\ngamma"])
        let both = try sides(try prepared(input, reader))
        XCTAssertTrue(both.before.isEmpty, "an absent file offered \(both.before.count) characters as the before side")

        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)
        XCTAssertEqual(kinds(lines, .added), ["alpha", "beta", "gamma"],
                       "\(kinds(lines, .added).count) of 3 lines were drawn as additions")
        XCTAssertEqual(kinds(lines, .removed).count, 0,
                       "\(kinds(lines, .removed).count) removals were drawn against a file that does not exist")
        XCTAssertEqual(kinds(lines, .context).count, 0,
                       "\(kinds(lines, .context).count) context lines were drawn against a file that does not exist")
        XCTAssertEqual(reader.requested.count, 1, "\(reader.requested.count) reads for one Write")
    }

    /// A `Write` over a file that exists diffs against its current contents: the replaced line
    /// is drawn as a removal and an addition, and the lines that did not move stay context.
    func testAWriteOverAnExistingFileShowsBothSides() throws {
        let tree = try TempTree()
        let target = try tree.file("invented-module/settled-file.txt", "alpha\nbeta\ngamma")
        let reader = RecordingReader()

        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\ndelta\ngamma"])
        let both = try sides(try prepared(input, reader))
        XCTAssertEqual(both.before, "alpha\nbeta\ngamma",
                       "the before side carried \(both.before.count) characters of the file on disk")

        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)
        XCTAssertEqual(kinds(lines, .removed), ["beta"],
                       "\(kinds(lines, .removed).count) of 1 removals were drawn")
        XCTAssertEqual(kinds(lines, .added), ["delta"],
                       "\(kinds(lines, .added).count) of 1 additions were drawn")
        XCTAssertEqual(kinds(lines, .context), ["alpha", "gamma"],
                       "\(kinds(lines, .context).count) of 2 unchanged lines stayed context")
        XCTAssertEqual(reader.requested.count, 1, "\(reader.requested.count) reads for one Write")
    }

    // MARK: - Edit

    /// An `Edit` diffs `old_string` against `new_string` in place: the surrounding lines come
    /// from the file, and only the three either side of the change do — a whole file drawn as
    /// context would bury a one-line edit.
    func testAnEditShowsOldAgainstNewWithContext() throws {
        let tree = try TempTree()
        let body = (1...9).map { "line-\($0)" }.joined(separator: "\n")
        let target = try tree.file("invented-module/edited-file.txt", body)
        let reader = RecordingReader()

        let input = try toolInput("Edit", ["file_path": target.path,
                                           "old_string": "line-5",
                                           "new_string": "line-5-changed"])
        let both = try sides(try prepared(input, reader))
        let lines = AttributedDiffRenderer.lines(before: both.before, after: both.after)

        XCTAssertEqual(kinds(lines, .removed), ["line-5"],
                       "\(kinds(lines, .removed).count) of 1 removals were drawn for a one-line edit")
        XCTAssertEqual(kinds(lines, .added), ["line-5-changed"],
                       "\(kinds(lines, .added).count) of 1 additions were drawn for a one-line edit")
        XCTAssertEqual(kinds(lines, .context),
                       ["line-2", "line-3", "line-4", "line-6", "line-7", "line-8"],
                       "\(kinds(lines, .context).count) of 6 context lines came from the file")
        XCTAssertEqual(reader.requested.count, 1, "\(reader.requested.count) reads for one Edit")
    }

    /// sweep#8: `replace_all` changes **every** occurrence, and the diff has to show that.
    ///
    /// The proposed change is what the user is consenting to. A diff built from the first match
    /// alone understates a `replace_all` by however many other occurrences the file holds, and the
    /// two clauses below are the two halves of the same fact: nothing the tool would change is left
    /// on the after side, and the occurrences it would leave alone on a plain `Edit` are still
    /// there. Both arms run over one file, so the flag is the only difference between them.
    func testReplaceAllChangesEveryOccurrenceAndAPlainEditChangesOne() throws {
        let tree = try TempTree()
        let body = (1...9).map { $0 % 3 == 0 ? "target" : "line-\($0)" }.joined(separator: "\n")
        let target = try tree.file("invented-module/repeated.txt", body)
        XCTAssertEqual(body.components(separatedBy: "target").count - 1, 3,
                       "the invented file does not carry the three occurrences this test needs")

        let all = try toolInput("Edit", ["file_path": target.path, "old_string": "target",
                                         "new_string": "replaced", "replace_all": true])
        let everywhere = try sides(try prepared(all, RecordingReader()))
        XCTAssertEqual(everywhere.after.components(separatedBy: "target").count - 1, 0,
                       "the after side still carries occurrences a replace_all would have changed")
        XCTAssertEqual(everywhere.after.components(separatedBy: "replaced").count - 1, 3,
                       "the after side carries fewer replacements than the tool would make")

        let one = try toolInput("Edit", ["file_path": target.path, "old_string": "target",
                                         "new_string": "replaced"])
        let once = try sides(try prepared(one, RecordingReader()))
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
    /// executed as a failure is "a descriptor was opened on a user-content path": TCC blocks on
    /// the consent dialog rather than returning, so the break would hang the suite instead of
    /// failing it. The substitute is a trace on the one seam every read goes through — the
    /// recorded requests below account for every read the card made — together with a scan of
    /// the two files that make them, asserting no descriptor-holding API appears in either.
    func testAnUnreadableFileFallsBackToTheInputAndSaysSo() throws {
        let tree = try TempTree()
        let target = tree.root.appending(path: "invented-module/opaque-file.bin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Bytes that are not UTF-8, so the file exists and its text cannot be recovered.
        try Data([0xFF, 0xFE, 0x00, 0x80, 0x81]).write(to: target)

        let reader = RecordingReader()
        let renderer = RendererProbe()
        let input = try toolInput("Write", ["file_path": target.path, "content": "alpha\nbeta"])

        guard case .verbatim(_, let sections) = try prepared(input, reader) else {
            XCTFail("an unreadable file produced a diff instead of the tool's input")
            return
        }
        XCTAssertEqual(sections.count, 1, "\(sections.count) of 1 verbatim sections were offered")
        XCTAssertEqual(sections.first?.text, "alpha\nbeta",
                       "the verbatim section carried \(sections.first?.text.count ?? 0) characters of input")

        let body = DiffView(input: input, reader: reader, renderer: renderer).body
        XCTAssertTrue(texts(in: body).contains(DiffView.unreadableNotice),
                      "the card drew \(texts(in: body).count) lines and none of them said why there is no diff")
        XCTAssertEqual(renderer.calls, 0,
                       "\(renderer.calls) diffs were produced for a file the app cannot read")

        // Trace: every read went through the seam, and the seam holds no descriptor.
        XCTAssertEqual(reader.requested.count, 2, "\(reader.requested.count) of 2 reads went through the seam")
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let descriptorAPIs = ["FileHandle(", "InputStream(", "fileDescriptor", "open(atPath",
                              "FileManager.default.contents(atPath"]
        for name in ["DiffRendering.swift", "AttributedDiffRenderer.swift"] {
            let source = try String(contentsOf: root.appending(path: "App/Decisions/\(name)"), encoding: .utf8)
            let found = descriptorAPIs.filter { source.contains($0) }
            XCTAssertEqual(found.count, 0,
                           "\(found.count) descriptor-holding APIs appear where a user-content path is read")
        }
    }
}
