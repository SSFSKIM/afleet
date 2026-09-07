import Foundation
import XCTest
@testable import Afleet

/// The trusted-directory selector, tested without a CLI and without a config home.
///
/// The document below is invented and lives in a `TempTree`; the config home it names is a **path
/// string** this test never creates, reads or writes. The selector is pure, which is what makes the
/// one rule that matters here — the exclusion of the config home and everything beneath it —
/// testable at all.
final class ScratchLiveGateTests: XCTestCase {

    /// Only a directory that is trusted, under the fixtures root, and outside the config home is a
    /// candidate. The other four entries each fail exactly one of those conditions.
    func testTheSelectorExcludesTheConfigHomeAndAnythingBeneathIt() throws {
        let tree = try TempTree()
        let configHome = "/private/tmp/afleet-fixtures/config-home"
        let document = """
        {"hasCompletedOnboarding":true,"projects":{
          "/private/tmp/afleet-fixtures/invented-trusted":{"hasTrustDialogAccepted":true},
          "/private/tmp/afleet-fixtures/invented-untrusted":{"hasTrustDialogAccepted":false},
          "/private/tmp/invented-outside-the-fixtures-root":{"hasTrustDialogAccepted":true},
          "\(configHome)":{"hasTrustDialogAccepted":true},
          "\(configHome)/projects/invented-slug":{"hasTrustDialogAccepted":true}
        }}
        """
        let file = try tree.file("invented-claude.json", document)

        let selected = ScratchLiveGate.trustedDirectories(inDocument: file,
                                                          excluding: URL(filePath: configHome))
        let paths = selected.map { $0.path(percentEncoded: false) }
        XCTAssertTrue(paths == ["/private/tmp/afleet-fixtures/invented-trusted"],
                      "the selector returned \(paths.count) directories: \(paths)")

        // The floor. A selector that returned nothing at all would satisfy every exclusion above
        // and prove none of them, which is the shape of a guard that passes by finding nothing.
        XCTAssertTrue(selected.count == 1, "the selector found no candidate, so the exclusions decided nothing")
    }

    /// A document with no trusted directory yields none, rather than a default.
    func testAnEmptyDocumentYieldsNoCandidate() throws {
        let tree = try TempTree()
        let file = try tree.file("invented-empty.json", #"{"hasCompletedOnboarding":true,"projects":{}}"#)
        let selected = ScratchLiveGate.trustedDirectories(inDocument: file,
                                                          excluding: URL(filePath: "/private/tmp/afleet-fixtures/config-home"))
        XCTAssertTrue(selected.isEmpty, "an empty projects map yielded \(selected.count) candidates")
    }
}
