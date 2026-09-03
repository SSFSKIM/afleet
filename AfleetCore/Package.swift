// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AfleetCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AfleetCore", targets: ["AfleetCore"])],
    targets: [
        .target(name: "AfleetCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AfleetCoreTests", dependencies: ["AfleetCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
