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
        .library(name: "GolfCourse", targets: ["GolfCourse"]),
        .library(name: "GolfCourseOSM", targets: ["GolfCourseOSM"]),
        .library(name: "GolfTerrain", targets: ["GolfTerrain"]),
        .library(name: "GolfMap", targets: ["GolfMap"]),
        .library(name: "GolfEval", targets: ["GolfEval"]),
        .executable(name: "golfctl", targets: ["golfctl"]),
    ],
    dependencies: [
        // WhisperKit — the ASR engine as of 2026-08-27 *(user decision)*. Multilingual
        // model, task fixed to `.transcribe`, language left nil so it auto-detects.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
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
        .target(name: "GolfTranscription",
                dependencies: ["GolfSessionFormat",
                               .product(name: "WhisperKit", package: "WhisperKit")]),

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

        // Per-course tee/green/hole geometry, and the distance + bearing math over
        // it. NOT ground truth — GolfReconstruction may and must read this, since a
        // shot cannot be placed on a hole without knowing where the hole is.
        .target(name: "GolfCourse", dependencies: ["GolfSessionFormat"]),

        // Overpass — the query and the socket, and nothing else. Split out from
        // `golfctl` on 2026-08-30 so the **app** can search and download a course
        // too: an executable target cannot be imported. Deliberately not folded into
        // `GolfCourse`, which stays network-free so `OSMCourse`'s assembly is
        // testable without one.
        .target(name: "GolfCourseOSM", dependencies: ["GolfCourse"]),

        // USGS 3DEP over the wire, plus the small GeoTIFF reader that decodes it.
        // Split from `GolfCourse` for the same reason `GolfCourseOSM` is: the grid
        // type, its sampling and its datum rule stay network-free and testable with
        // a synthetic raster, and the app can import the fetcher when a course is
        // downloaded on the phone.
        .target(name: "GolfTerrain", dependencies: ["GolfCourse"]),

        // Hole view (vector + satellite), map, elevation profile.
        .target(name: "GolfMap", dependencies: ["GolfSessionFormat", "GolfStore", "GolfCourse"]),

        // Reconstruction accuracy metrics vs ground truth.
        .target(name: "GolfEval", dependencies: ["GolfSessionFormat", "GolfReconstruction"]),

        .executableTarget(name: "golfctl",
                          dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                         "GolfCourse", "GolfCourseOSM", "GolfTerrain",
                                         "GolfTranscription",
                                         "AnthropicClient", "GolfReconstruction",
                                         "GolfEval"]),

        .testTarget(name: "MarkerTests",
                    dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                   "GolfCourse", "GolfCourseOSM", "GolfTerrain", "GolfMap",
                                   "GolfReconstruction",
                                   "GolfTranscription",
                                   .product(name: "WhisperKit", package: "WhisperKit")]),
    ]
)
