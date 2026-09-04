// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConsumerSmoke",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../")],
    targets: [
        .executableTarget(name: "ConsumerSmoke",
                          dependencies: [.product(name: "ClaudeWire", package: "ClaudeWire")],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
