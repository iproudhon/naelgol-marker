// swift-tools-version: 5.9
import PackageDescription

// naelvol — swing video browsing, capture and editing.
//
// A SEPARATE package on purpose. It shares a repository with Marker and nothing
// else: **no target here may import a `Golf*` target**. A swing's round context
// arrives as `SwingContext`, a plain value the host fills in. Lifting this
// directory into its own repository is a `git mv` and a path change in the app's
// project file.
//
// The floor is iOS 16 / macOS 13, the same as Marker's. Everything here builds on
// macOS — the iOS-only halves compile to nothing behind `#if os(iOS)` — so
// `swift test` covers the metadata codec, the filters and the pose geometry.
//
// **TensorFlow Lite lives in the `TFLite/` package next door, not here, and that
// is structural.** Its xcframeworks carry `ios-arm64` and the iOS simulator and no
// macOS slice at all, so a target in *this* package that linked them would break
// `swift test` for everything else: SwiftPM builds every target in a package, not
// just the ones a test needs. Measured, not assumed — "no such module
// 'TensorFlowLiteCCoreML'" on the first `swift test` after adding them.
let package = Package(
    name: "Naelvol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "NaelvolCore", targets: ["NaelvolCore"]),
        .library(name: "NaelvolPose", targets: ["NaelvolPose"]),
        .library(name: "NaelvolCapture", targets: ["NaelvolCapture"]),
        .library(name: "NaelvolUI", targets: ["NaelvolUI"]),
    ],
    targets: [
        // The swing, its metadata codec, its sources and the filters over them.
        .target(name: "NaelvolCore"),

        // Keypoint geometry: `Golfer`, velocities, the torso crop tracker, the
        // estimator protocol. No inference engine — that is `NaelvolPoseTFLite`.
        .target(name: "NaelvolPose", dependencies: ["NaelvolCore"]),

        // Camera, format picking, AVAssetWriter, gravity, hand-pose trigger.
        .target(name: "NaelvolCapture", dependencies: ["NaelvolCore", "NaelvolPose"]),

        // SwiftUI surface. UIKit only inside: preview layer, player, range slider.
        .target(name: "NaelvolUI",
                dependencies: ["NaelvolCore", "NaelvolPose", "NaelvolCapture"]),

        .testTarget(name: "NaelvolTests", dependencies: ["NaelvolCore", "NaelvolPose"]),
    ]
)
