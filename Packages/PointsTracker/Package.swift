// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointsTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PointsTracker", targets: ["PointsTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "PointsTracker", dependencies: ["Core"]),
        .testTarget(name: "PointsTrackerTests", dependencies: ["PointsTracker"])
    ]
)
