// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GymTracker",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "GymTracker", targets: ["GymTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "GymTracker", dependencies: ["Core"]),
        .testTarget(name: "GymTrackerTests", dependencies: ["GymTracker"])
    ]
)
