import Foundation
import GolfSessionFormat
import GolfCourse
import GolfCourseOSM

/// `golfctl course osm --name "Corica Park" [--course 1] [--out Courses]`
///
/// Geometry from OpenStreetMap: hole centre-lines, green outlines, per-colour tee
/// boxes, bunkers and water. **Never yardage** — `dist` is on 0.3% of US hole ways
/// and 1.8% of Korean ones, so per-tee distance and stroke index still come from a
/// card. `--merge` is the intended finish: OSM under, card over.
func cmdCourseOSM(_ args: Args) {
    let target: CourseOSM.Where
    if let name = args.string("name") {
        target = .name(name)
    } else if let at = args.string("at") {
        let parts = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { fail("--at wants lat,lon — e.g. --at 37.7379,-122.2324") }
        target = .around(lat: parts[0], lon: parts[1],
                         radius: Double(args.int("radius") ?? 2000))
    } else if let box = args.string("bbox") {
        let p = box.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 4 else { fail("--bbox wants south,west,north,east") }
        target = .bbox(s: p[0], w: p[1], n: p[2], e: p[3])
    } else {
        fail("""
        usage: golfctl course osm --name "Corica Park"
                                  | --at <lat,lon> [--radius 2000]
                                  | --bbox <s,w,n,e>
                                  [--course <n>] [--id corica-park-south] [--name-as "..."]
                                  [--out Courses] [--merge] [--dry-run]

          Hole lines, green outlines, tee boxes, bunkers and water from OpenStreetMap.
          About half of all US courses are mapped; Korea is ~3%, so expect nothing there.

          OSM carries no yardage anywhere. Import the card over the top:
            golfctl course osm    --name "Corica Park" --id corica-park-south --out Courses
            golfctl course import --card card.jpg --id corica-park-south --out Courses --merge

          A site is often more than one course — Corica Park is an 18 plus a par-3
          nine. They are listed, and --course picks one (default: the largest).

          The result is ODbL. Fine for private use, which distributes nothing;
          share-alike applies the moment a file leaves the group.
        """)
    }

    let outDir = URL(fileURLWithPath: args.string("out", default: "Courses")!)

    runBlocking {
        print("querying Overpass …")
        // **The site is resolved here rather than inside the client**, so the other
        // matches can be *listed*. The client used to `print` them itself; it is a
        // library now — shared with the app's course finder, which shows them as a
        // list to pick from — and a library that writes to stdout is a library that
        // cannot be used from a UI.
        var resolved = target
        var siteName: String?
        do {
            if case .name(let n) = target {
                let found = try await CourseOSM.sites(named: n)
                guard let site = found.first else { fail("\(CourseOSM.Failure.noSite(n))") }
                if found.count > 1 {
                    print("  \(found.count) facilities match '\(n)' — using \(site.name).")
                    print("  Others: \(found.dropFirst().map(\.name).joined(separator: ", "))")
                }
                resolved = .bbox(s: site.bbox.s, w: site.bbox.w,
                                 n: site.bbox.n, e: site.bbox.e)
                siteName = site.name
            }
        } catch let e as CourseOSM.Failure { fail("\(e)") }

        let data: Data
        do { (data, _) = try await CourseOSM.features(resolved) }
        catch let e as CourseOSM.Failure { fail("\(e)") }

        let elements = try OSMCourse.elements(from: data)
        let holeWays = elements.filter { $0.tags["golf"] == "hole" }
        print("  \(elements.count) golf features, \(holeWays.count) hole way(s)")
        guard !holeWays.isEmpty else {
            fail("""
                 no golf=hole ways here. This course is not mapped in OSM — which is the
                 usual case in Korea and about half the time in the US. Place it by hand
                 in the app's course editor instead.
                 """)
        }

        let candidates = OSMCourse.candidates(in: elements)
        guard !candidates.isEmpty else { fail("found hole ways but could not assemble a course") }

        print("")
        for (i, c) in candidates.enumerated() {
            let m = c.measuredTotal()
            let name = c.name.map { " \"\($0)\"" } ?? ""
            print(String(format: "  [%d]%@ %d holes, par %d, %@%@",
                         i + 1, name, c.holes.count, c.par,
                         m.holes > 0 ? String(format: "%.0f m measured over %d", m.metres, m.holes)
                                     : "no geometry",
                         c.handicapIsPermutation ? ", stroke index 1–\(c.holes.count) ✓" : ""))
        }
        print("")

        let pick = (args.int("course") ?? 1) - 1
        guard candidates.indices.contains(pick) else {
            fail("--course \(pick + 1) — there are \(candidates.count)")
        }
        let chosen = candidates[pick]

        for line in chosen.report.lines { print("  note: \(line)") }

        // Two independent checks on the association, because a crossed green makes
        // a file that passes every *structural* check and reads a club and a half
        // wrong. Neither is fatal — this is a draft the user amends — but a silent
        // pass is exactly what must not happen.
        verify(chosen)

        let name = args.string("name-as")
            ?? OSMCourse.displayName(course: chosen.name, site: siteName) ?? "Course"
        let id = args.string("id") ?? CourseImport.slug(name)
        var course = chosen.course(id: id, name: name, updated: SessionClock.now())

        let store = CourseStore(directory: outDir)
        if args.bool("merge"), let existing = try? store.load(id: id) {
            // OSM is `self` (it holds the geometry) and the existing file is the
            // card. That direction matters: `merging(card:)` keeps `self`'s source,
            // so the ODbL stamp survives, and card par/handicap/yardage win over
            // OSM's — a card is authoritative for card data.
            course = course.merging(card: existing)
            print("  merged with the existing \(id) — card numbers kept over OSM's")
        }

        describe(course, holeRef: nil)
        print("  source     osm — \(OSMCourse.attributionText)")

        if args.bool("dry-run") { print("  --dry-run: nothing written"); return }
        try store.save(course)
        print("wrote \(store.url(for: id).path)")
        if course.holes.allSatisfy({ $0.tees.allSatisfy { $0.distance == nil } }) {
            print("""

                  No yardage — OSM never has any. Photograph the card at the first tee and:
                    golfctl course import --card card.jpg --id \(id) --out \(outDir.path) --merge
                  """)
        }
    }
}

/// The checks that catch a mis-associated green. Structure cannot see it; only the
/// numbers can.
private func verify(_ c: OSMCourse.Candidate) {
    // 1. Stroke index. Where OSM tags `handicap` it is a labelled partition of the
    //    site for free — at Corica it is on exactly the 18 and none of the par-3
    //    nine — so a valid 1…n permutation independently confirms that the routing
    //    chain picked out one whole course and not a mixture of two.
    let tagged = c.holes.compactMap(\.handicap).count
    if c.handicapIsPermutation {
        print("  check: stroke index is a complete 1–\(c.holes.count) permutation — "
              + "this is one whole course")
    } else if tagged > 0 {
        print("  warn:  \(tagged)/\(c.holes.count) holes carry a stroke index and it is not a "
              + "1–\(c.holes.count) permutation. The routing may have crossed into another "
              + "course at this site — check the hole list below against the card.")
    }

    // 2. Length per par. Wrong green, right structure: the file looks perfect and
    //    every distance is nonsense. This is the only thing that sees it.
    let m = c.measuredTotal()
    guard m.holes == c.holes.count, c.par > 0 else {
        print("  warn:  only \(m.holes)/\(c.holes.count) holes have both a tee and a green, "
              + "so the length check cannot run")
        return
    }
    let yards = m.metres / DistanceUnit.yards.toMetres
    print(String(format: "  check: %.0f m / %.0f yd over par %d — %.0f yd per hole-par",
                 m.metres, yards, c.par, yards / Double(c.par)))
    if let warning = DistanceUnit.plausibility(total: yards, par: c.par) {
        print("  warn:  \(warning)")
        print("         For OSM geometry that means a green was matched to the wrong hole, "
              + "not a unit problem — nothing here came off a card.")
    }
}
