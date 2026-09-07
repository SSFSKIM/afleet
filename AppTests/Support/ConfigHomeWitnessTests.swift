import Foundation
import Darwin
import XCTest
@testable import Afleet

/// The witness's own tests. Two of them are about the defect the rewrite exists to fix and one is
/// about the pin that keeps the allowlist honest.
///
/// Every tree here is a `TempTree` (X9). The one config home any of this reads is the fixed scratch
/// home at `/tmp/afleet-fixtures/config-home`, read with `lstat(2)` and nothing else.
final class ConfigHomeWitnessTests: XCTestCase {

    // MARK: - The pin

    /// Everything the scratch config home actually holds is a path some pattern explains.
    ///
    /// This is what makes the allowlist a claim rather than a wish. When the engine grows a new
    /// top-level name — as it did with `chrome/` between C4 and C5 — this fails naming the entry,
    /// and somebody decides whether it belongs on the list. A live gate that silently absorbed it
    /// would be reporting "nothing unexplained" about a set it had stopped checking.
    func testTheAllowlistPinMatchesTheScratchHome() throws {
        let root = URL(filePath: "/tmp/afleet-fixtures/config-home")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("no scratch config home on this machine; it lives under /tmp and dies with a reboot")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard !entries.isEmpty else {
            throw XCTSkip("the scratch config home is empty; there is no pin to check")
        }

        let unexplained = entries
            .filter { entry in !ConfigHomeWitness.childWrittenPaths.contains { ConfigHomeWitness.matches(entry, pattern: $0) } }
            .sorted()
        XCTAssertTrue(unexplained.isEmpty,
                      "the scratch config home holds \(unexplained.count) entries no pattern explains: \(unexplained)")

        // The two-directional half. A pin that only ever widens is a pin that stops meaning
        // anything, so the reading has to have exercised the list rather than found it irrelevant.
        let matched = ConfigHomeWitness.childWrittenPaths.filter { pattern in
            entries.contains { ConfigHomeWitness.matches($0, pattern: pattern) }
        }
        XCTAssertTrue(matched.count >= 8,
                      "only \(matched.count) of the pinned patterns matched anything in the scratch home")
    }

    // MARK: - The defect the rewrite exists to fix

    /// A truncation inside `projects/<slug>/`, an append at depth three and a same-size atomic
    /// replace are all reported — and the top-level-name witness this replaces reports none of them.
    ///
    /// The blind implementation runs **first and in the same test**, deliberately. A witness tested
    /// only against a change to the top-level name set would be exactly as blind as the one it
    /// replaces and would pass just as happily, so the demonstration that the old shape misses these
    /// three is part of the evidence rather than a note about a run somebody once did.
    func testTheWitnessDetectsANestedMutation() throws {
        let tree = try TempTree()
        let home = try tree.directory("invented-config-home")
        let transcript = try tree.file("invented-config-home/projects/invented-slug/invented-session.jsonl",
                                       String(repeating: "invented line\n", count: 40))
        let deep = try tree.file("invented-config-home/daemon/invented/depth-three/record.json",
                                 #"{"invented":1}"#)
        let replaced = try tree.file("invented-config-home/cache/invented-models.json", "0123456789")

        let witness = ConfigHomeWitness(root: home)
        let before = witness.read()
        let topLevelBefore = Self.topLevelNames(home)
        XCTAssertTrue(before.count == 3, "the tree the witness is about did not land: \(before.count) files")

        // 1. A truncation of a file inside `projects/<slug>/`.
        try Data().write(to: transcript)
        // 2. An append at depth three.
        try (#"{"invented":1}"# + "\n").write(to: deep, atomically: false, encoding: .utf8)
        // 3. A same-size atomic replace: identical bytes, new inode, and possibly the same whole
        //    second. Only the inode says this happened.
        try "9876543210".write(to: replaced, atomically: true, encoding: .utf8)

        let difference = ConfigHomeWitness.difference(from: before, to: witness.read())
        XCTAssertTrue(difference.modified.contains("projects/invented-slug/invented-session.jsonl"),
                      "the truncation inside a project directory was not reported")
        XCTAssertTrue(difference.modified.contains("daemon/invented/depth-three/record.json"),
                      "the append at depth three was not reported")
        XCTAssertTrue(difference.modified.contains("cache/invented-models.json"),
                      "the same-size atomic replace was not reported")
        XCTAssertTrue(difference.created.isEmpty && difference.deleted.isEmpty,
                      "the scenario created or deleted nothing, yet the witness says \(difference.summary)")

        // And the shape this replaces, over the same three mutations.
        XCTAssertTrue(Self.topLevelNames(home) == topLevelBefore,
                      "the scenario was supposed to leave the top-level names alone")
    }

    /// The comparison discriminates: a path no pattern explains is reported, and a path a pattern
    /// explains but the named child cannot account for is reported too.
    ///
    /// The second half is what a filesystem diff cannot do on its own. `sessions/<pid>.json` is a
    /// path the allowlist explains for *any* engine; only the pid says it was this test's child.
    func testAnUnattributedChangeIsReported() {
        var difference = ConfigHomeWitness.Difference()
        difference.created = ["sessions/4242.json", "sessions/9999.json", "invented-intruder.json",
                              "projects/invented-slug/00000000-0000-4000-8000-000000000001.jsonl"]

        let attribution = ConfigHomeWitness.Attribution(childPID: 4242,
                                                        session: "00000000-0000-4000-8000-000000000001")
        let reported = ConfigHomeWitness.unattributed(difference, attribution: attribution)
        XCTAssertTrue(reported == ["invented-intruder.json", "sessions/9999.json"],
                      "expected the intruder and the other engine's record; got \(reported)")

        // Without an attribution the allowlist alone decides, which is the weaker claim C4 made and
        // is still the right one for a path that carries no identity.
        let byAllowlistAlone = ConfigHomeWitness.unattributed(difference)
        XCTAssertTrue(byAllowlistAlone == ["invented-intruder.json"],
                      "the allowlist alone should explain both records; got \(byAllowlistAlone)")

        // And a narrowed list reports what the full one explains, so a green run is a run in which
        // the comparison could have failed.
        let narrowed = ConfigHomeWitness.unattributed(difference, against: ["projects/"])
        XCTAssertTrue(narrowed.count == 3, "the narrowed list explained \(4 - narrowed.count) of four paths")
    }

    // MARK: - The witness this one replaces

    /// C4's shape in miniature: the names directly under the root, and nothing else.
    private static func topLevelNames(_ root: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }
}
