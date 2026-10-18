// swift-tools-version: 6.2
import PackageDescription

// AudioLensKit holds the logic that doesn't need AppKit or Core Audio devices (settings
// models, EQ math, the per-app audio processor, headphone-correction parsing, sync
// encryption), so `swift test` covers it. The app is built by build_app.sh.
let package = Package(
    name: "AudioLens",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "AudioLensKit"),
        .executableTarget(name: "AudioLens", dependencies: ["AudioLensKit"]),
        .testTarget(name: "AudioLensKitTests", dependencies: ["AudioLensKit"]),
    ]
)
