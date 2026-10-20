// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sweep", targets: ["Sweep"]),
        .library(name: "SweepCore", targets: ["SweepCore"]),
    ],
    targets: [
        // File-system scanning and cleaning logic. No UI code, so it can be unit tested.
        .target(name: "SweepCore"),
        // The SwiftUI app.
        .executableTarget(name: "Sweep", dependencies: ["SweepCore"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
    ]
)
