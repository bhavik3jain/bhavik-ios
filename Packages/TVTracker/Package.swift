// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TVTracker",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "TVTracker", targets: ["TVTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "TVTracker", dependencies: ["Core"]),
        .testTarget(name: "TVTrackerTests", dependencies: ["TVTracker"])
    ]
)
