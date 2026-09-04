import XCTest
import WireTestSupport

/// Parent X1, executable: `ClaudeWire` depends on `AfleetCore` alone, and no module imports upward.
///
/// The verdict is derived, not transcribed. The per-module allowance comes from `Package.swift`'s
/// own target dependencies, so this test cannot drift out of date the way a hand-kept table does;
/// the only literals here are the two things the manifest cannot state — the foreign modules a
/// source file may import besides its declared dependencies, and the layer order X1 fixes.
final class ImportGraphTests: XCTestCase {
    private var packageRoot: URL { TestPaths.support.deletingLastPathComponent().deletingLastPathComponent() }
    private var sourcesRoot: URL { packageRoot.appendingPathComponent("Sources") }

    /// Foreign modules any source may import. `AfleetCore` is not here: it is a declared dependency
    /// in the manifest wherever it is legitimate, so it goes through the same derivation as the rest.
    private let alwaysAllowed: Set<String> = ["Foundation", "CryptoKit"]

    /// X1's layering. A target may depend only on strictly lower ranks.
    private let rank: [String: Int] = [
        "AfleetCore": 0,
        "WireFrames": 1,
        "WireMCP": 2, "WireEnvironment": 2, "WireDiagnostics": 2, "WireTestSupport": 2,
        "WireTransport": 3,
        "ClaudeWire": 4,
    ]

    private func moduleNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sourcesRoot.path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    /// target name → declared dependency module names, read out of `Package.swift`.
    private func manifestDependencies(modules: Set<String>) throws -> [String: Set<String>] {
        let text = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let head = try NSRegularExpression(pattern: #"\.target\(name:\s*"([A-Za-z0-9_]+)""#)
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
        var out: [String: Set<String>] = [:]
        for m in head.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(m.range(at: 1), in: text)!])
            // Every target in this manifest ends with `swiftSettings:`; the slice between is the target's body.
            let bodyStart = Range(m.range, in: text)!.upperBound
            guard let bodyEnd = text.range(of: "swiftSettings:", options: [], range: bodyStart..<text.endIndex)?.lowerBound else {
                XCTFail("target \(name) has no swiftSettings: to bound its body")
                continue
            }
            let body = String(text[bodyStart..<bodyEnd])
            var deps: Set<String> = []
            for q in quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let s = String(body[Range(q.range(at: 1), in: body)!])
                if s != name, modules.contains(s) || s == "AfleetCore" { deps.insert(s) }
            }
            out[name] = deps
        }
        return out
    }

    /// Every module directory under Sources/ is a target in the manifest, so none escapes the check below.
    func testEveryModuleIsDeclaredInTheManifest() throws {
        let modules = try moduleNames()
        let declared = try manifestDependencies(modules: Set(modules))
        for module in modules {
            XCTAssertNotNil(declared[module], "Sources/\(module) is not a .target in Package.swift")
            XCTAssertNotNil(rank[module], "Sources/\(module) has no X1 layer rank")
        }
    }

    /// The manifest's own edges obey X1: only AfleetCore comes from outside, and every edge points down.
    func testManifestEdgesPointDownward() throws {
        let modules = Set(try moduleNames())
        for (target, deps) in try manifestDependencies(modules: modules) {
            guard let here = rank[target] else { continue }
            for dep in deps.sorted() {
                guard let there = rank[dep] else {
                    XCTFail("\(target) depends on \(dep), which is outside AfleetCore and this package")
                    continue
                }
                XCTAssertLessThan(there, here, "\(target) depends on \(dep), which X1's layering forbids")
            }
        }
    }

    /// No source imports anything but Foundation, CryptoKit, or a dependency its target declares.
    func testSourcesImportOnlyDeclaredDependencies() throws {
        let modules = try moduleNames()
        let declared = try manifestDependencies(modules: Set(modules))
        let regex = try NSRegularExpression(pattern: #"^\s*(?:@_exported\s+)?import\s+(?:struct\s+|class\s+|enum\s+|func\s+|var\s+|typealias\s+)?([A-Za-z_][A-Za-z0-9_]*)"#,
                                            options: [.anchorsMatchLines])
        for module in modules {
            let dir = sourcesRoot.appendingPathComponent(module)
            let allowed = alwaysAllowed.union(declared[module] ?? []).union([module])
            let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            XCTAssertFalse(files.isEmpty, "\(module) has no sources")
            for f in files {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let imported = String(text[Range(m.range(at: 1), in: text)!])
                    XCTAssertTrue(allowed.contains(imported),
                                  "\(module)/\(f) imports \(imported), which X1 forbids (\(module) declares \(declared[module]?.sorted() ?? []))")
                }
            }
        }
    }
}
