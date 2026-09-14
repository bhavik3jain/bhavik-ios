// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FuelTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FuelTracker", targets: ["FuelTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "FuelTracker", dependencies: ["Core"]),
        .testTarget(
            name: "FuelTrackerTests",
            dependencies: ["FuelTracker"],
            resources: [.process("Fixtures")]
        )
    ]
)
