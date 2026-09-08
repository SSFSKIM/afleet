import Foundation
import XCTest
@testable import SourceControlCore

/// The scratch-tree guard itself, under the two spellings that defeat a comparison made after
/// `resolvingSymlinksInPath()` alone (X9, ledger D15, tracker entry 24).
///
/// **Why demonstrating this is safe.** A refusal test's pre-fix run performs the very act the
/// guard forbids, so it must never be pointed at a real config home. Every path below is an
/// invented directory created inside a `TempTree` under the system temporary directory and passed
/// to the initialiser's injectable `configHomes:` parameter as a *stand-in* for a config home.
/// Nothing here reads or writes `~/.claude`, `$CLAUDE_CONFIG_DIR` or
/// `/tmp/afleet-fixtures/config-home`; the assertion that the guard held is a count of the entries
/// inside the stand-in, which is zero exactly when nothing was created (C5 tracker entry 52).
final class TempTreeGuardTests: XCTestCase {

    private var outer: TempTree!

    override func setUpWithError() throws {
        outer = try TempTree()
    }

    override func tearDown() {
        outer?.remove()
        outer = nil
    }

    /// macOS volumes are case-insensitive by default, so `.CLAUDE` and `.claude` are one
    /// directory. A `TMPDIR` naming a directory that does **not exist yet** keeps whatever
    /// spelling it was given — there is nothing on disk for symlink resolution to resolve — while
    /// the config home resolves to its own spelling, and a component comparison between the two
    /// finds no match. The directory then gets created inside the config home.
    func testATreeUnderAConfigHomeSpelledInAnotherCaseIsRefused() throws {
        let home = try outer.directory("stand-in/.claude")
        let requested = outer.root.appending(path: "stand-in/.CLAUDE/not-created-yet")

        assertRefused(temporaryDirectory: requested, configHomes: [home],
                      because: "a config home named in another case")
        assertNothingWasCreated(inside: home)
    }

    /// The same hole reached without case: the base is inside the stand-in home through a
    /// **symbolic link**, and its last component does not exist. Resolution leaves the whole path
    /// spelled as written, so the link is never followed and the containment check misses.
    func testATreeReachingAConfigHomeThroughASymlinkIsRefused() throws {
        let home = try outer.directory("linked/real/.claude")
        let link = outer.root.appending(path: "linked/by-another-name")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        let requested = link.appending(path: "not-created-yet")

        assertRefused(temporaryDirectory: requested, configHomes: [home],
                      because: "a config home reached through a symbolic link")
        assertNothingWasCreated(inside: home)
    }

    /// The spelling neither of the two above reaches, and the one that makes the guard fail open on
    /// an ordinary macOS host: the data volume is mounted twice. `/System/Volumes/Data/private/var/…`
    /// and `/private/var/…` are **one directory** — identical `(st_dev, st_ino)` — and `realpath(3)`
    /// *preserves* the firmlink prefix rather than removing it, so canonicalising both sides leaves
    /// two paths that share no components at all. A component comparison is then satisfied by
    /// nothing, the tree is created, and X9's forbidden write happens under a home spelled the
    /// other way. Measured on this host before it was written down.
    ///
    /// The stand-in home is an invented directory inside this test's own scratch tree, reached
    /// through the alias exactly as a real one would be; no real config home is read or written.
    func testATreeUnderAConfigHomeSpelledThroughTheDataVolumeAliasIsRefused() throws {
        let home = try outer.directory("aliased/.claude")
        let aliased = URL(filePath: "/System/Volumes/Data"
                          + TempTree.canonical(home).path(percentEncoded: false))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: aliased.path(percentEncoded: false)),
                          "this host does not mount the data volume under its second spelling")
        let requested = aliased.appending(path: "not-created-yet")

        assertRefused(temporaryDirectory: requested, configHomes: [home],
                      because: "a config home spelled through the data-volume alias")
        assertNothingWasCreated(inside: home)
    }

    /// A base that is nowhere near the stand-in home is still accepted, so that the two tests
    /// above are refusals of something rather than of everything.
    func testAnOrdinaryTemporaryDirectoryIsStillAccepted() throws {
        let home = try outer.directory("accepting/.claude")
        let requested = try outer.directory("accepting/scratch")
        let tree = try TempTree(temporaryDirectory: requested, configHomes: [home])
        defer { tree.remove() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.path(percentEncoded: false)),
                      "a scratch tree outside every config home was not created")
    }

    /// Asserts the initialiser refused, and reports no path on failure (§6.3, §11).
    private func assertRefused(temporaryDirectory: URL, configHomes: [URL], because reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            let tree = try TempTree(temporaryDirectory: temporaryDirectory, configHomes: configHomes)
            tree.remove()
            XCTFail("a scratch tree under \(reason) was created rather than refused",
                    file: file, line: line)
        } catch is XCTSkip {
        } catch {
            XCTFail("the guard threw something other than XCTSkip for \(reason)", file: file, line: line)
        }
    }

    /// The structural half: the stand-in config home holds nothing at all. A count, never a
    /// listing — an entry name here would be a temporary path.
    private func assertNothingWasCreated(inside home: URL, file: StaticString = #filePath,
                                         line: UInt = #line) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: home.path(percentEncoded: false)))?.count ?? -1
        XCTAssertEqual(entries, 0,
                       "the refused initialiser left \(entries) entries inside the stand-in config home",
                       file: file, line: line)
    }
}
