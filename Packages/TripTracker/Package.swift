// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TripTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TripTracker", targets: ["TripTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "TripTracker", dependencies: ["Core"]),
        .testTarget(name: "TripTrackerTests", dependencies: ["TripTracker"])
    ]
)
