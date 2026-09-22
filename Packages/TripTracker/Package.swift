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
        // "Core" too, not just "TripTracker" — Support.swift's makeContext()
        // builds an in-memory store straight off CloudSharedStore.makeContainer(),
        // the same way the app itself does, rather than duplicating that setup.
        .testTarget(name: "TripTrackerTests", dependencies: ["TripTracker", "Core"])
    ]
)
