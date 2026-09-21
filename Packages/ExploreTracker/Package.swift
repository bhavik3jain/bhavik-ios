// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExploreTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ExploreTracker", targets: ["ExploreTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "ExploreTracker", dependencies: ["Core"]),
        .testTarget(name: "ExploreTrackerTests", dependencies: ["ExploreTracker", "Core"])
    ]
)
