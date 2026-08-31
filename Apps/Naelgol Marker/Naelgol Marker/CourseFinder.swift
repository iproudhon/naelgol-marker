import SwiftUI
import GolfSessionFormat
import GolfCourse
import GolfCourseOSM

/// Search OpenStreetMap for a course and download its geometry, on the phone.
///
/// *(User, 2026-08-30: "For course OSM gps data, I want to search and download from
/// the app.")* It is `golfctl course osm` with a keyboard instead of flags, and the
/// same three checks in front of the Save button — **a wrong partition and a crossed
/// green both look exactly like success**, so an importer that skipped them would
/// write a file that passes every structural test and reads a club and a half wrong.
/// The CLI prints them; here they are the confirmation screen.
///
/// Two things it deliberately does not do. It never **merges**: `--merge` exists so a
/// card can be laid over OSM geometry, and there is no card importer on the phone
/// yet, so offering a merge would offer a direction nothing here can complete. And it
/// never claims yardage — **OSM has none, in any region** — which the sheet says out
/// loud rather than leaving an empty column to be discovered on the first tee.
@MainActor
struct CourseFinder: View {
    /// Where the phone is, for "near me". Nil is a real answer: the search box still
    /// works, and the button is simply absent rather than present and dead.
    var here: Coordinate?
    /// The ids already in the library, so a save cannot silently replace one.
    ///
    /// **`CourseStore.save` is a replace**, so saving over an existing id destroys
    /// every `at` and `green.center` that was hand-placed in the editor — the thing
    /// "re-importing a card must never destroy placed coordinates" exists to prevent,
    /// reached by a different road. The CLI has `--id` and an explicit `--merge` for
    /// this; the sheet's equivalent is to refuse and say so. It is not a rare case:
    /// two Korean names can slug to the same ASCII, and re-running the finder on a
    /// course already imported is the obvious thing to do.
    var existingIDs: Set<String> = []
    /// Called with the course to keep. The library owns saving and selection.
    var onSave: (Course) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var sites: [CourseOSM.Site] = []
    @State private var candidates: [OSMCourse.Candidate] = []
    /// The name Overpass gave the facility, used when a candidate carries none.
    @State private var siteName: String?
    @State private var phase: Phase = .idle
    @State private var problem: String?

    enum Phase: Equatable { case idle, searching, listingSites, loading, listingCourses }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if let problem {
                    Section {
                        Text(problem)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                if phase == .listingSites { sitesSection }
                if phase == .listingCourses { coursesSection }
                Section {
                    Text("""
                         Geometry only — hole lines, greens, tee boxes, bunkers and \
                         water. OpenStreetMap carries no yardage anywhere, so per-tee \
                         distance and stroke index still come off the card.
                         """)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(OSMCourse.attributionText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Find a course")
            #if DEBUG
            // Scripted typing does not exist in this environment, so the results and
            // the checks in front of Save can only be reviewed by running the search
            // from a launch argument. See `DemoSeed.finderQuery`.
            .task {
                guard let q = DemoSeed.finderQuery, query.isEmpty else { return }
                query = q
                search()
            }
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Course name", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                if phase == .searching || phase == .loading { ProgressView() }
            }
            Button("Search OpenStreetMap") { search() }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty
                          || phase == .searching || phase == .loading)
            // **Only when there is a position.** The button's whole meaning is
            // "here", so with no fix it would search a coordinate nothing measured —
            // the same rule the legend's file-a-shot button follows.
            if let here {
                Button("Courses near me") { searchNearby(here) }
                    .disabled(phase == .searching || phase == .loading)
            }
        } footer: {
            Text("About half of US courses are mapped in OpenStreetMap. Korea is "
                 + "around 3%, so expect to find nothing and place the course by hand.")
        }
    }

    private var sitesSection: some View {
        Section("Facilities") {
            ForEach(sites) { site in
                Button {
                    load(.bbox(s: site.bbox.s, w: site.bbox.w,
                               n: site.bbox.n, e: site.bbox.e), named: site.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name)
                        Text(String(format: "%.4f, %.4f",
                                    (site.bbox.s + site.bbox.n) / 2,
                                    (site.bbox.w + site.bbox.e) / 2))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// **A site is often more than one course** — Corica Park is an 18 plus a par-3
    /// nine — so they are listed and the golfer picks, exactly as `--course` does.
    /// Never "take the biggest and say nothing": the greedy version of this walked
    /// out of one nine into another course's back nine and reported a confident
    /// *18 holes, par 63*.
    private var coursesSection: some View {
        Section("Courses here") {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                CourseCandidateRow(candidate: c, fallbackName: siteName,
                                   existingIDs: existingIDs) { course in
                    onSave(course)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Work

    private func search() {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        problem = nil; phase = .searching; sites = []; candidates = []
        Task {
            do {
                let found = try await CourseOSM.sites(named: name)
                guard !found.isEmpty else {
                    problem = "\(CourseOSM.Failure.noSite(name))"
                    phase = .idle
                    return
                }
                sites = found
                // One match is not a choice — go straight on rather than making the
                // golfer tap a list of one.
                if found.count == 1 {
                    load(.bbox(s: found[0].bbox.s, w: found[0].bbox.w,
                               n: found[0].bbox.n, e: found[0].bbox.e),
                         named: found[0].name)
                } else {
                    phase = .listingSites
                }
            } catch {
                problem = Self.message(for: error)
                phase = .idle
            }
        }
    }

    /// 3 km, which covers a course and its neighbours without asking Overpass for a
    /// city. The free instance rate-limits, and this button is one tap away from
    /// being pressed repeatedly while nothing appears to happen.
    private func searchNearby(_ at: Coordinate) {
        problem = nil; sites = []; candidates = []
        load(.around(lat: at.lat, lon: at.lon, radius: 3_000), named: nil)
    }

    private func load(_ target: CourseOSM.Where, named: String?) {
        phase = .loading
        siteName = named
        Task {
            do {
                let (data, auto) = try await CourseOSM.features(target)
                siteName = named ?? auto
                let elements = try OSMCourse.elements(from: data)
                let found = OSMCourse.candidates(in: elements)
                guard !found.isEmpty else {
                    // The honest message, and the one the CLI gives: this is the
                    // ordinary case in Korea and half the time in the US.
                    problem = """
                              No golf holes mapped here. That is the usual answer in \
                              Korea and about half the time in the US — place the \
                              course by hand in the editor instead.
                              """
                    phase = .idle
                    return
                }
                candidates = found
                phase = .listingCourses
            } catch {
                problem = Self.message(for: error)
                phase = .idle
            }
        }
    }

    /// **A sentence, not an `NSError` dump.**
    ///
    /// The first run of this screen printed forty lines of
    /// `NSURLErrorFailingURLPeerTrustErrorKey` at a golfer standing on a tee. A
    /// network error here has exactly three interesting shapes — no signal, the
    /// shared Overpass instance is busy, or something is inspecting TLS — and the
    /// action is different for each. `CourseOSM.Failure` already writes its own
    /// sentences and is passed through untouched.
    static func message(for error: Error) -> String {
        if let f = error as? CourseOSM.Failure { return f.description }
        guard let u = error as? URLError else { return "\(error)" }
        switch u.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "No network. OpenStreetMap has to be downloaded before the round — "
                 + "a course has no signal."
        case .timedOut:
            return "Overpass did not answer in time. It is a free shared service; wait "
                 + "a minute and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .serverCertificateHasBadDate:
            return "The secure connection to overpass-api.de failed. Something on this "
                 + "network is inspecting HTTPS — try cellular."
        default:
            return "Could not reach OpenStreetMap: \(u.localizedDescription)"
        }
    }
}

/// One candidate course, with the checks that decide whether it is safe to keep.
///
/// **The checks are the row, not a detail behind it.** `golfctl` prints them and a
/// person reads them before saving; the equivalent here has to be on screen at the
/// moment the Save button is, or the import silently becomes the thing the checks
/// exist to prevent.
@MainActor
private struct CourseCandidateRow: View {
    let candidate: OSMCourse.Candidate
    let fallbackName: String?
    let existingIDs: Set<String>
    let onSave: (Course) -> Void

    @State private var name: String = ""

    private var id: String { Course.slug(name.trimmingCharacters(in: .whitespaces)) }
    private var collides: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && existingIDs.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Course name", text: $name)
                .font(.system(size: 16, weight: .semibold))
                .textInputAutocapitalization(.words)
            Text("\(candidate.holes.count) holes · par \(candidate.par)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(Array(checks.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: 12))
                    .foregroundStyle(line.warning ? Color.orange : .secondary)
            }
            if collides {
                Text("A course is already saved as \(id). Saving would replace it and "
                     + "lose anything placed by hand — give this one a different name.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            Button("Save this course") {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, !collides else { return }
                onSave(candidate.course(id: id, name: n, updated: SessionClock.now()))
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || collides)
        }
        .padding(.vertical, 4)
        .onAppear {
            if name.isEmpty {
                name = OSMCourse.displayName(course: candidate.name, site: fallbackName) ?? "Course"
            }
        }
    }

    /// The same three the CLI runs, in the same order, plus whatever `report` found
    /// — greens and tees that could not be associated, and `teeAnomalies`, which is
    /// the only thing that ever caught a real fault on a real import.
    private var checks: [(text: String, warning: Bool)] {
        var out: [(String, Bool)] = []
        let tagged = candidate.holes.compactMap(\.handicap).count
        if candidate.handicapIsPermutation {
            out.append(("Stroke index is a complete 1–\(candidate.holes.count) "
                        + "permutation — this is one whole course", false))
        } else if tagged > 0 {
            out.append(("\(tagged)/\(candidate.holes.count) holes carry a stroke index and "
                        + "it is not a full permutation — the routing may have crossed "
                        + "into another course at this site", true))
        }

        let m = candidate.measuredTotal()
        if m.holes == candidate.holes.count, candidate.par > 0 {
            let yards = m.metres / DistanceUnit.yards.toMetres
            out.append((String(format: "%.0f yd measured over par %d — %.0f yd per hole-par",
                               yards, candidate.par, yards / Double(candidate.par)), false))
            if let warning = DistanceUnit.plausibility(total: yards, par: candidate.par) {
                out.append((warning + " For OSM geometry that means a green was matched to "
                            + "the wrong hole — nothing here came off a card.", true))
            }
        } else {
            out.append(("Only \(m.holes)/\(candidate.holes.count) holes have both a tee and "
                        + "a green, so the length check cannot run", true))
        }

        out.append(contentsOf: candidate.report.lines.map { ($0, true) })
        return out.map { (text: $0.0, warning: $0.1) }
    }
}
