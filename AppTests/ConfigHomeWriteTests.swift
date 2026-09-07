import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// X9's app-side half: **who could have changed it**.
///
/// `ConfigHomeWitness` reports what changed under a config home during a scenario. During G1e's
/// scenario a legitimate `claude` child is writing into that same tree, and no filesystem diff can
/// tell its write from afleet's — so the diff alone can never carry the never-write claim. This test
/// carries the other half: it drives the app through everything the composition root does that
/// reaches a filesystem, with every write routed through one injectable seam, and asserts the seam
/// was handed no path under the config home at all.
///
/// The config home here is an invented one under a `TempTree`, built from nothing. Nothing in this
/// file reads or writes `~/.claude`, `$CLAUDE_CONFIG_DIR` or `/tmp/afleet-fixtures/config-home`.
final class ConfigHomeWriteTests: XCTestCase {

    func testNoAppCodePathWritesUnderAConfigHome() async throws {
        let tree = try TempTree()
        let home = try ScratchConfigHome(tree: tree)
        let session = SessionID("5c500009-0000-4000-8000-000000000001")!
        try home.write(ScratchConfigHome.Transcript(session: session,
                                                    slug: "invented-project",
                                                    cwd: try tree.directory("invented-project").path))
        try home.writeClaudeJSON(projects: ["/invented/project"])

        let recorder = WriteRecorder()
        let binary = tree.root.appending(path: "claude-that-never-runs")
        let environment = LaunchFixtures.environment(home: tree.root, configHome: home.root)
        var sequence = LaunchSequence(
            storeRoot: try tree.directory("store"),
            diagnosticsRoot: try tree.directory("logs"),
            resolveEnvironment: { environment },
            locateBinary: { _, _ in binary },
            checkVersion: { _, _ in .accepted(SemanticVersion(major: 2, minor: 1, patch: 263)) },
            writes: recorder.seam,
            makeWatcher: { _ in StubWatcher() })
        // `makeStore` and `makeDiagnostics` are deliberately **not** injected: the production
        // defaults are what carry the seam, and a test that supplied its own would be asserting
        // about wiring it had done itself.
        let box = ModelBox()
        sequence.makeCoordinator = { @MainActor workspace in
            let coordinator = FleetCoordinator(workspace: workspace)
            box.value = coordinator
            return coordinator
        }

        // 1. A full launch: the store, the four diagnostics sinks, C3's index, a real `Fleet`.
        let route = await sequence.run()
        let workspace = try XCTUnwrap(route.workspace, "the launch did not reach a workspace")
        let coordinator = try await MainActor.run { try XCTUnwrap(box.value, "the launch built no coordinator") }

        // 2. The registration sweep, which is what the coordinator does with the built snapshot.
        await coordinator.model.whenChanged { $0.allRows.count > 0 }
        let rows = await MainActor.run { coordinator.model.allRows.count }

        // 3. A channel open and 4. a decision answer, both through the real fleet. Neither can
        //    succeed — the binary does not exist and there is no decision — and neither needs to:
        //    the subject is the filesystem each path touches on its way to refusing.
        let key = ChannelKey(configHome: home.root, session: session)
        _ = try? await workspace.fleet.perform(.open, on: key)
        _ = try? await workspace.fleet.perform(.answer(RequestID(rawValue: "invented-request"),
                                                       .error("invented")), on: key)

        // 5. A settings write, which is the one store write a user causes directly.
        var settings = await AfleetSettingsStore.read(from: workspace.store)
        settings.developer.rawFrameCapture = true
        try await AfleetSettingsStore.write(settings, to: workspace.store)
        workspace.diagnostics.flush()

        await MainActor.run { coordinator.stop() }
        await workspace.fleet.shutdown()

        // The floors first. A seam that received nothing proves nothing, and a launch that painted
        // no rows never reached the registration sweep this test claims to have driven.
        let written = recorder.written
        let delegated = recorder.delegated
        XCTAssertTrue(written.count > 0, "the write seam received no path at all, so it was not wired in")
        XCTAssertTrue(delegated.count > 0, "no write root was declared to the seam")
        XCTAssertTrue(rows > 0, "the launch painted no rows, so no registration sweep happened")

        // A count above zero would be satisfied by one path from one component. Both of the app's
        // write paths have to appear, or the seam is wired into half the app and the claim covers
        // half the app. The names are constants of this repository, not identifiers from a home.
        let names = Set(written.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("state.afleet.json"),
                      "the store's own writes did not reach the seam; \(names.count) distinct names did")
        XCTAssertTrue(names.contains("app.log") && names.contains("timeline.log"),
                      "the app's diagnostics sinks did not reach the seam; \(names.count) distinct names did")

        // The claim.
        let inside = WriteRecorder.paths(written + delegated, under: home.root)
        XCTAssertTrue(inside.isEmpty,
                      "\(inside.count) of \(written.count + delegated.count) app writes were aimed under the config home")

        // And the proof that the claim could have failed. The same predicate, against an invented
        // root that everything in this test *is* under — never against a real config home, which is
        // the one demonstration X9 does not permit.
        let underTheTree = WriteRecorder.paths(written + delegated, under: tree.root)
        XCTAssertTrue(underTheTree.count == written.count + delegated.count,
                      "the predicate found \(underTheTree.count) of \(written.count + delegated.count) paths under the tree they all live in")
    }

    /// Every filesystem-mutating call in the app is in a file that carries the seam.
    ///
    /// The test above proves the seam saw no config-home path. It cannot prove the seam saw
    /// *everything*: a new `App/` file that reaches `FileManager` directly would be invisible to it
    /// and the suite would stay green while the invariant quietly stopped holding. This is the
    /// static half — it fails naming the file and the call, so a write added outside the seam is a
    /// decision somebody makes on purpose.
    func testEveryFilesystemWriteInTheAppIsBehindTheSeam() throws {
        // Unambiguous spellings only: each of these creates, replaces or removes something on disk
        // wherever it appears, so a match is a write and never a false positive.
        let mutating = ["createDirectory(", "createFile(", "removeItem(", "moveItem(", "copyItem(",
                        "forWritingTo:", "forUpdatingAtPath:", ".write(to:", "O_CREAT", "unlink("]
        // The files allowed to contain one, each of which must also route through the seam.
        let behindTheSeam: Set<String> = ["DiagnosticsComposer.swift"]

        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App", directoryHint: .isDirectory)
        var read = 0
        var offenders: [String] = []
        var seamCarriers: Set<String> = []
        let walk = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path), "App/ could not be walked")
        for case let relative as String in walk where relative.hasSuffix(".swift") {
            let name = (relative as NSString).lastPathComponent
            guard let source = try? String(contentsOf: root.appending(path: relative), encoding: .utf8) else { continue }
            read += 1
            for spelling in mutating where source.contains(spelling) {
                if behindTheSeam.contains(name) {
                    if source.contains("writes.willWrite") { seamCarriers.insert(name) }
                } else {
                    offenders.append("\(name) contains \(spelling)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, "\(offenders.count) app writes outside the seam: \(offenders.sorted())")
        // Both floors: the walk read files, and the allowlisted file really does both write and
        // report. An allowlist entry that had stopped writing would make this scan vacuous.
        XCTAssertTrue(read > 20, "the walk read only \(read) files under App/")
        XCTAssertTrue(seamCarriers == behindTheSeam,
                      "\(behindTheSeam.count - seamCarriers.count) allowlisted files no longer write through the seam")
    }

    /// The coordinator the launch built. A single-owner box; every access is on the main actor.
    private final class ModelBox: @unchecked Sendable {
        @MainActor var value: FleetCoordinator?
        init() {}
    }
}

/// Every path the app declared to `AppFileWrites`, in order.
///
/// `@unchecked Sendable` is sound because both mutable fields are read and written only inside
/// `lock`, this instance's private `NSLock`; that lock is the serialising mechanism.
final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    private var roots: [URL] = []

    var seam: AppFileWrites {
        AppFileWrites(willWrite: { [self] url in lock.lock(); files.append(url); lock.unlock() },
                      willDelegate: { [self] url in lock.lock(); roots.append(url); lock.unlock() })
    }

    var written: [URL] { lock.lock(); defer { lock.unlock() }; return files }
    var delegated: [URL] { lock.lock(); defer { lock.unlock() }; return roots }

    /// Those of `paths` that are `root` or lie beneath it, canonicalised on both sides.
    ///
    /// Canonicalising both sides is the whole of the guard: `CLAUDE_CONFIG_DIR` is an arbitrary
    /// string, `/tmp` is a symlink to `/private/tmp`, and comparing a resolved path against an
    /// unresolved one is a check that fails open — which is `LaunchSequence.overlappingWriteRoot`'s
    /// own reasoning, and why it is `CanonicalPath` that does the work here too.
    static func paths(_ paths: [URL], under root: URL) -> [URL] {
        let home = CanonicalPath.string(root)
        return paths.filter { url in
            let candidate = CanonicalPath.string(url)
            return candidate == home || candidate.hasPrefix(home + "/")
        }
    }
}
