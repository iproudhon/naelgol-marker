// swift-tools-version: 5.9
import PackageDescription

// naelvol's inference engine, quarantined.
//
// This is a second package rather than two more targets in `Naelvol` for one
// measured reason: `TensorFlowLiteC.xcframework` ships `ios-arm64` and the iOS
// simulator and **no macOS slice**, and SwiftPM builds every target in a package,
// so a binary target here would take `swift test` down for the metadata codec and
// the pose geometry too. Quarantined, `Naelvol` stays testable on a Mac and this
// package is only ever built for iOS, by Xcode.
//
// `Vendor/` is NOT in git — 171 MB of xcframework. Run `Tools/fetch-tflite.sh`
// once after cloning.
let package = Package(
    name: "NaelvolTFLite",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NaelvolPoseTFLite", targets: ["NaelvolPoseTFLite"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .binaryTarget(name: "TensorFlowLiteC", path: "Vendor/TensorFlowLiteC.xcframework"),
        .binaryTarget(name: "TensorFlowLiteCCoreML", path: "Vendor/TensorFlowLiteCCoreML.xcframework"),
        .binaryTarget(name: "TensorFlowLiteCMetal", path: "Vendor/TensorFlowLiteCMetal.xcframework"),

        // Google's Swift wrapper over the C API, vendored verbatim (Apache-2.0).
        // `import TensorFlowLite` resolves to this. Not modified: a patched copy
        // is a fork nobody can re-sync.
        .target(name: "TensorFlowLite",
                dependencies: ["TensorFlowLiteC", "TensorFlowLiteCCoreML", "TensorFlowLiteCMetal"],
                exclude: ["LICENSE"],
                // **The C library is C++ inside**, and the delegates are thin
                // wrappers over CoreML, Metal and Accelerate. CocoaPods adds these
                // for you; a binary target does not, and the failure is a wall of
                // missing `std::` symbols at link time in the *app*, not here.
                linkerSettings: [
                    .linkedLibrary("c++"),
                    .linkedFramework("Accelerate"),
                    .linkedFramework("CoreML"),
                    .linkedFramework("Metal"),
                ]),

        // MoveNet on TFLite. The keypoint model it fills in lives in `NaelvolPose`.
        .target(name: "NaelvolPoseTFLite",
                dependencies: ["TensorFlowLite",
                               .product(name: "NaelvolPose", package: "Naelvol")]),
    ]
)
