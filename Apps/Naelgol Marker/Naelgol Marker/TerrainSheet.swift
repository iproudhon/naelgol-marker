import SwiftUI
import GolfCourse
import GolfTerrain

/// Download a course's terrain, on demand.
///
/// **A button rather than part of the import** *(user decision, 2026-08-30)*.
/// `CourseFinder` stays geometry-only: a DEM is another 6–15 s and three quarters
/// of a megabyte, it finds nothing at all outside the United States, and a golfer
/// searching for a course is answering a different question. So this is its own
/// step, reached from the course menu, and the cost of that is the one thing said
/// out loud below — **it has to be done before the round**, because a course has no
/// signal.
///
/// **The three checks are the sheet, not a detail behind it** — the same rule
/// `CourseFinder` follows, and for a sharper reason here: a grid built over 1/3
/// arc-second data instead of lidar, or one that clips a corner of the course, is
/// byte-identical in shape to a good one and produces holes whose plays-like number
/// is a metre out or silently absent. `golfctl course elevation` prints them; here
/// they are the rows a person reads before Save.
@available(iOS 17, *)
struct TerrainSheet: View {
    let course: Course
    /// What is already on disk, so the sheet can say "you have this" rather than
    /// offering a download that would overwrite it with the same thing.
    let existing: Elevation?
    let onSave: (Elevation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var grid: Elevation?
    @State private var report: Elevation3DEP.Report?
    @State private var coverage: Double?
    @State private var error: String?

    /// Every coordinate the course carries. Coverage is measured over these rather
    /// than over a bounding box: a grid that clips one corner leaves a handful of
    /// holes with no plays-like at all, which reads as a broken feature rather than
    /// as a file that is too small.
    private var points: [Coordinate] {
        course.holes.flatMap { h in
            h.line + h.fairway + h.green.polygon + h.tees.compactMap(\.at)
                + [h.green.center].compactMap { $0 }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Course", value: course.name)
                    if let e = existing, grid == nil {
                        LabeledContent("On this phone",
                                       value: "\(e.source.rawValue), \(Int(e.nativeResolution)) m native")
                    }
                } footer: {
                    // One literal, not a concatenation: `Text` parses markdown only
                    // from a `LocalizedStringKey`, and `"a" + "b"` is a `String`, so
                    // the bold United States rendered as literal asterisks. Caught
                    // by screenshot, which is the only way it could have been.
                    Text("Elevation comes from the USGS 3D Elevation Program — public domain, bare earth, and **United States only**. Download it before the round: a course has no signal.")
                }

                if let r = report, let g = grid {
                    Section("What arrived") {
                        // Lidar or not is the whole quality question, and
                        // `exportImage` will not volunteer it — the point service is
                        // asked separately for exactly this row.
                        check(r.nativeResolution > 0 && r.nativeResolution <= 1.5,
                              r.nativeResolution > 0
                                ? "\(Int(r.nativeResolution)) m native posts"
                                : "native resolution unknown",
                              r.nativeResolution <= 1.5 && r.nativeResolution > 0
                                ? "lidar — 10 cm spec"
                                : "not lidar; metre-scale error")
                        check(true,
                              String(format: "%.0f m of relief", r.maximum - r.minimum),
                              String(format: "%.0f m to %.0f m", r.minimum, r.maximum))
                        let cov = coverage ?? 0
                        check(cov > 0.999,
                              String(format: "%.1f%% of the course covered", cov * 100),
                              cov > 0.999 ? "every hole can be measured"
                                          : "some holes will show no rise")
                        let posts = g.nativePosts
                        LabeledContent("Grid",
                                       value: String(format: "%d × %d at %.1f × %.1f m",
                                                     g.width, g.height, posts.east, posts.north))
                    }

                    Section("Tee to green") {
                        ForEach(risen(g), id: \.0) { row in
                            LabeledContent("Hole \(row.0)",
                                           value: String(format: "%+.1f m", row.1))
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Terrain")
            .navigationBarTitleDisplayMode(.inline)
            // **The seed runs the download, not just the sheet.** Same argument as
            // `marker.find.query`: without it only the empty sheet can be looked at
            // here, so the three checks a person reads before Save — is it lidar,
            // does it cover the course, what does each hole rise — would ship
            // unreviewed. Scripted taps do not exist in this environment.
            .task {
                #if DEBUG
                if DemoSeed.fetchesTerrain, grid == nil, !working { fetch() }
                #endif
            }
            .safeAreaInset(edge: .bottom) {
                // Bottom, not the toolbar — the same placement the Marker dialogs
                // took for the same reason: this is the button a thumb reaches for.
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    if working {
                        ProgressView().padding(.trailing, 8)
                        Text("Downloading…").foregroundStyle(.secondary)
                    } else if let g = grid {
                        Button("Save") { onSave(g); dismiss() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(existing == nil ? "Download" : "Download again") { fetch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(points.isEmpty)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private func check(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Per-hole tee-to-green rise — the row a golfer can check against ground they
    /// have actually walked, which is the only verification available here.
    private func risen(_ g: Elevation) -> [(String, Double)] {
        course.holes.compactMap { h in
            guard let geo = h.geometry(),
                  let d = g.delta(from: geo.teeAt, to: geo.greenCenter) else { return nil }
            return (h.id, d)
        }
    }

    private func fetch() {
        let lats = points.map(\.lat), lons = points.map(\.lon)
        guard let s = lats.min(), let n = lats.max(),
              let w = lons.min(), let e = lons.max() else { return }
        // Padded, so a golfer standing on the next tee is still on the grid.
        let mPerDeg = .pi * Geodesy.earthRadius / 180
        let dLat = 150 / mPerDeg
        let dLon = 150 / (mPerDeg * cos((s + n) / 2 * .pi / 180))
        working = true; error = nil
        Task {
            do {
                let (g, r) = try await Elevation3DEP.fetch(
                    bounds: (south: s - dLat, west: w - dLon,
                             north: n + dLat, east: e + dLon))
                await MainActor.run {
                    grid = g; report = r; coverage = g.coverage(of: points); working = false
                }
            } catch {
                await MainActor.run { self.error = Self.message(for: error); working = false }
            }
        }
    }

    /// A network error is a sentence, not an `NSError` — the same rule
    /// `CourseFinder.message(for:)` was written for, and the actions differ per case.
    static func message(for error: Error) -> String {
        if let f = error as? Elevation3DEP.Failure { return f.description }
        if let f = error as? GeoTIFF.Failure {
            return "USGS sent something this cannot read (\(f)). Try again; if it "
                 + "persists the service has changed."
        }
        guard let u = error as? URLError else { return "\(error)" }
        switch u.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "No network. Terrain has to be downloaded before the round — "
                 + "a course has no signal."
        case .timedOut:
            return "USGS did not answer in time. A whole course is a megabyte or so; "
                 + "try again on a better connection."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .serverCertificateHasBadDate:
            return "The secure connection to nationalmap.gov failed. Something on this "
                 + "network is inspecting HTTPS — try cellular."
        default:
            return "Could not reach USGS: \(u.localizedDescription)"
        }
    }
}
