// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParcelTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ParcelTracker", targets: ["ParcelTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "ParcelTracker", dependencies: ["Core"]),
        .testTarget(name: "ParcelTrackerTests", dependencies: ["ParcelTracker"])
    ]
)
