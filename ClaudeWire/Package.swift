// swift-tools-version: 6.2
import PackageDescription

let v6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "ClaudeWire",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ClaudeWire", targets: ["ClaudeWire"])],
    dependencies: [.package(path: "../AfleetCore")],
    targets: [
        .target(name: "WireFrames", dependencies: [.product(name: "AfleetCore", package: "AfleetCore")], swiftSettings: v6),
        .target(name: "WireMCP", dependencies: ["WireFrames"], swiftSettings: v6),
        .target(name: "WireEnvironment", dependencies: ["WireFrames", .product(name: "AfleetCore", package: "AfleetCore")], swiftSettings: v6),
        .target(name: "WireDiagnostics", dependencies: ["WireFrames", .product(name: "AfleetCore", package: "AfleetCore")], swiftSettings: v6),
        .target(name: "WireTransport", dependencies: ["WireFrames", "WireMCP", "WireEnvironment", "WireDiagnostics",
                                                     .product(name: "AfleetCore", package: "AfleetCore")], swiftSettings: v6),
        .target(name: "ClaudeWire", dependencies: ["WireFrames", "WireMCP", "WireEnvironment", "WireDiagnostics", "WireTransport",
                                                   .product(name: "AfleetCore", package: "AfleetCore")], swiftSettings: v6),
        .target(name: "WireTestSupport", dependencies: ["WireFrames"], path: "Sources/WireTestSupport", swiftSettings: v6),
        .testTarget(name: "WireFramesTests", dependencies: ["WireFrames", "WireTestSupport"], swiftSettings: v6),
        .testTarget(name: "WireMCPTests", dependencies: ["WireMCP", "WireTestSupport"], swiftSettings: v6),
        .testTarget(name: "WireEnvironmentTests", dependencies: ["WireEnvironment", "WireTestSupport"], swiftSettings: v6),
        .testTarget(name: "WireDiagnosticsTests", dependencies: ["WireDiagnostics", "WireTestSupport"], swiftSettings: v6),
        .testTarget(name: "WireTransportTests", dependencies: ["WireTransport", "WireTestSupport"], swiftSettings: v6),
        .testTarget(name: "ClaudeWireTests", dependencies: ["ClaudeWire", "WireTestSupport"], swiftSettings: v6),
    ]
)
