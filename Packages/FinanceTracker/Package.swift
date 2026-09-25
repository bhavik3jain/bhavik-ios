// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinanceTracker",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FinanceTracker", targets: ["FinanceTracker"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "FinanceTracker", dependencies: ["Core"]),
        .testTarget(name: "FinanceTrackerTests", dependencies: ["FinanceTracker", "Core"])
    ]
)
