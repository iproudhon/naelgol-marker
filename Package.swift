// swift-tools-version: 5.9
import PackageDescription

// NOTE: SPM declares platform floors once, per package — not per target.
// The floor here is the LOWEST any target needs, so that a host app on iOS 16/17
// can import the low-floor libraries. Targets that need newer APIs gate them with
// @available(iOS 17, *) / @available(iOS 26, macOS 26, *) in source.
// See docs/PLAN.md §3 for the per-target floor table.

let package = Package(
    name: "Marker",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GolfSessionFormat", targets: ["GolfSessionFormat"]),
        .library(name: "GolfCaptureCore", targets: ["GolfCaptureCore"]),
        .library(name: "GolfCaptureMotion", targets: ["GolfCaptureMotion"]),
        .library(name: "GolfTranscription", targets: ["GolfTranscription"]),
        .library(name: "AnthropicClient", targets: ["AnthropicClient"]),
        .library(name: "GolfReconstruction", targets: ["GolfReconstruction"]),
        .library(name: "GolfStore", targets: ["GolfStore"]),
        .library(name: "GolfInsight", targets: ["GolfInsight"]),
        .library(name: "GolfMap", targets: ["GolfMap"]),
        .library(name: "GolfEval", targets: ["GolfEval"]),
        .executable(name: "golfctl", targets: ["golfctl"]),
    ],
    dependencies: [
        // TODO(phase-2): .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")
        //                 -> products WhisperKit, SpeakerKit  (see docs/PLAN.md §3)
        // TODO(phase-3): .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // The contract. Zero dependencies. Both halves speak this.
        .target(name: "GolfSessionFormat"),

        // Capture — audio + location. Cross-platform so the recorder runs on a Mac.
        .target(name: "GolfCaptureCore", dependencies: ["GolfSessionFormat"]),

        // Capture — motion + barometric altitude. iOS-only (#if os(iOS) inside).
        .target(name: "GolfCaptureMotion", dependencies: ["GolfSessionFormat", "GolfCaptureCore"]),

        // ASR + diarization behind one protocol. Apple path is @available(iOS 26, macOS 26).
        .target(name: "GolfTranscription", dependencies: ["GolfSessionFormat"]),

        // Minimal /v1/messages client. Knows nothing about golf.
        .target(name: "AnthropicClient"),

        // Evidence bundle -> Claude -> structured round + self-verification.
        // NO `resources:` here on purpose. Declaring them generates Bundle.module,
        // and prompt/schema must resolve from --prompt/--schema PATHS so tuning is
        // edit-and-rerun instead of rebuild-per-edit. See CLAUDE.md.
        .target(name: "GolfReconstruction",
                dependencies: ["GolfSessionFormat", "AnthropicClient"]),

        // Persistence: rounds, holes, shots, players, courses.
        .target(name: "GolfStore", dependencies: ["GolfSessionFormat"]),

        // Play suggestion from accumulated history.
        .target(name: "GolfInsight", dependencies: ["GolfSessionFormat", "GolfStore"]),

        // Map + elevation profile rendering.
        .target(name: "GolfMap", dependencies: ["GolfSessionFormat", "GolfStore"]),

        // Reconstruction accuracy metrics vs ground truth.
        .target(name: "GolfEval", dependencies: ["GolfSessionFormat", "GolfReconstruction"]),

        .executableTarget(name: "golfctl",
                          dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                         "GolfTranscription", "GolfReconstruction",
                                         "GolfEval"]),

        .testTarget(name: "MarkerTests",
                    dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                   "GolfReconstruction"]),
    ]
)
