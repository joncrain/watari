// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Watari",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WatariCore", targets: ["WatariCore"]),
    ],
    targets: [
        .target(
            name: "WatariCore",
            path: "Sources/WatariCore"
        ),
        .testTarget(
            name: "WatariCoreTests",
            dependencies: ["WatariCore"],
            path: "Tests/WatariCoreTests"
        ),
    ]
)
