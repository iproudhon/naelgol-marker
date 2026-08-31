import XCTest
@testable import GolfCourse

/// Fixtures are hand-built Overpass JSON. They are small on purpose — each one
/// isolates a single way OSM golf data is awkward, and every one of these is a
/// shape that showed up in the real Corica Park response.
final class OSMCourseTests: XCTestCase {

    // MARK: - Fixture helpers

    private static let origin = Coordinate(lat: 37.7379, lon: -122.2324)

    /// Metres east/north of the fixture origin, so a hole can be described by its
    /// shape rather than by hand-computed coordinates.
    private func at(_ east: Double, _ north: Double) -> Coordinate {
        Geodesy.coordinate(from: Self.origin, east: east, north: north)
    }

    private func ring(_ centre: Coordinate, _ r: Double) -> [Coordinate] {
        (0..<12).map { Geodesy.point(from: centre, bearing: Double($0) * 30, distance: r) }
    }

    private func way(_ id: Int, _ tags: [String: String], _ pts: [Coordinate]) -> [String: Any] {
        ["type": "way", "id": id, "tags": tags,
         "geometry": pts.map { ["lat": $0.lat, "lon": $0.lon] }]
    }

    private func elements(_ ways: [[String: Any]]) throws -> [OSMCourse.Element] {
        let data = try JSONSerialization.data(withJSONObject: ["elements": ways])
        return try OSMCourse.elements(from: data)
    }

    /// One straight hole: the centre-line way, a green ring at the far end, and a
    /// tee ring at the near end.
    private func hole(id: Int, ref: String, par: Int, handicap: Int?,
                      tee: Coordinate, green: Coordinate,
                      teeColours: [String] = ["black", "white"],
                      reversed: Bool = false) -> [[String: Any]] {
        var tags = ["golf": "hole", "ref": ref, "par": "\(par)"]
        if let handicap { tags["handicap"] = "\(handicap)" }
        var out = [way(id, tags, reversed ? [green, tee] : [tee, green])]
        out.append(way(id + 1, ["golf": "green"], ring(green, 12)))
        for (i, c) in teeColours.enumerated() {
            let spot = Geodesy.point(from: tee, bearing: Geodesy.bearing(from: tee, to: green),
                                     distance: Double(i) * 14)
            out.append(way(id + 2 + i, ["golf": "tee", "tee": c], ring(spot, 5)))
        }
        return out
    }

    // MARK: - Orientation

    /// `golf=hole` ways are *conventionally* drawn tee → green, and a reversed one
    /// renders the hole backwards with the camera pointing at the tee. Whichever
    /// end sits nearer a green is the green end, whatever order the way is in.
    func testAReversedHoleWayIsStillOrientedTeeToGreen() throws {
        let tee = at(0, 0), green = at(0, 350)
        for reversed in [false, true] {
            let els = try elements(hole(id: 100, ref: "1", par: 4, handicap: 1,
                                        tee: tee, green: green, reversed: reversed))
            let c = try XCTUnwrap(OSMCourse.candidates(in: els).first)
            let g = try XCTUnwrap(c.holes[0].geometry(tee: c.holes[0].tee(named: "black")))
            XCTAssertEqual(Geodesy.distance(g.teeAt, tee), 0, accuracy: 2,
                           "reversed=\(reversed): tee end picked wrong")
            XCTAssertEqual(g.measuredLength, 350, accuracy: 5)
        }
    }

    // MARK: - Splitting a site into courses

    /// The failure that made `split` what it is. Corica Park is an 18 and a par-3
    /// nine on one property, both numbered from 1, geographically interleaved. A
    /// greedy "nearest next tee" chain walked out of one course into the other and
    /// reported a confident 18 holes at par 63.
    ///
    /// Here: two 3-hole routings running side by side, 90 m apart — closer to each
    /// other than consecutive holes are to themselves — so a per-hole decision has
    /// to cross and a per-ref matching must not.
    func testInterleavedCoursesSharingHoleNumbersDoNotCross() throws {
        var ways: [[String: Any]] = []
        var id = 100
        for (course, offsetE) in [(0, 0.0), (1, 90.0)] {
            for i in 0..<3 {
                let tee = at(offsetE, Double(i) * 420)
                let green = at(offsetE, Double(i) * 420 + 350)
                // Course 0 is the one with stroke indexes, as at Corica.
                ways += hole(id: id, ref: "\(i + 1)", par: 4,
                             handicap: course == 0 ? i + 1 : nil,
                             tee: tee, green: green)
                id += 20
            }
        }
        let cands = OSMCourse.candidates(in: try elements(ways))
        XCTAssertEqual(cands.count, 2)
        for c in cands {
            XCTAssertEqual(c.refs.sorted(), ["1", "2", "3"], "a routing must be 1,2,3 once each")
            // Every hole in a routing must agree about whether it has a stroke
            // index — mixing them is precisely what crossing over looks like.
            let tagged = c.holes.filter { $0.handicap != nil }.count
            XCTAssertTrue(tagged == 0 || tagged == c.holes.count,
                          "routing mixes holes from both courses: \(c.holes.map(\.handicap))")
        }
        let eighteen = try XCTUnwrap(cands.first { $0.holes.allSatisfy { $0.handicap != nil } })
        XCTAssertTrue(eighteen.handicapIsPermutation)
    }

    // MARK: - Association

    /// Assignment is exclusive: two holes may not claim the same green. Without it
    /// the nearest-per-hole answer gives a short hole its neighbour's green and the
    /// file still passes every structural check.
    func testTwoHolesCannotShareOneGreen() throws {
        // Two greens 40 m apart, both within reach of both holes' green ends.
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300))
        ways += hole(id: 200, ref: "2", par: 4, handicap: 2, tee: at(40, 0), green: at(40, 300))
        let cands = OSMCourse.candidates(in: try elements(ways))
        let holes = try XCTUnwrap(cands.first).holes
        let centres = holes.compactMap { $0.green.center }
        XCTAssertEqual(centres.count, 2)
        XCTAssertGreaterThan(Geodesy.distance(centres[0], centres[1]), 1,
                             "both holes were given the same green")
    }

    /// A named green at a golf course is a practice green — the real ones are
    /// unnamed because the hole beside them carries the number. Corica has two,
    /// and one of them sits close enough to hole 1 to be stolen.
    func testPracticeGreensAreNotUsedAsHoleGreens() throws {
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300))
        ways.append(way(900, ["golf": "green", "name": "Practice Putting Green"],
                        ring(at(30, 290), 12)))
        let els = try elements(ways)
        let c = try XCTUnwrap(OSMCourse.candidates(in: els).first)
        XCTAssertEqual(Geodesy.distance(try XCTUnwrap(c.holes[0].green.center), at(0, 300)),
                       0, accuracy: 3)
        XCTAssertEqual(c.report.practiceGreensSkipped, 1)
    }

    /// **Untagged tee polygons are adopted** *(user decision, 2026-08-30)*, named
    /// from their place in the length order and marked `inferredName` all the way to
    /// the screen. This test asserted the opposite until then — 107 of Coyote
    /// Creek's 112 tee polygons carry no colour, so dropping them left 16 of 18
    /// holes with no tee at all.
    func testAnUntaggedTeeIsAdoptedAndNamedFromTheLengthOrder() throws {
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300))
        ways.append(way(900, ["golf": "tee"], ring(at(25, -10), 6)))
        let els = try elements(ways)
        let c = try XCTUnwrap(OSMCourse.candidates(in: els).first)
        let inferred = c.holes[0].tees.filter { $0.inferredName == true }
        XCTAssertEqual(inferred.count, 1)
        // "black" and "white" are already taken by the fixture's tagged tees, so the
        // ramp walks past them rather than producing two tees with one name.
        XCTAssertFalse(["black", "white"].contains(inferred[0].name))
        XCTAssertEqual(c.report.teesUntagged, 0)
        XCTAssertEqual(c.report.teesNamedByLength?.count, 1)
    }

    /// What survives of the old rule: a practice or driving-range polygon is still
    /// refused, because a phantom tee can win `Hole.defaultTee` and put the big
    /// number and the camera in the wrong place.
    func testARangeOrPracticeTeeIsStillRefused() throws {
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300))
        ways.append(way(900, ["golf": "tee", "name": "Practice Tee"], ring(at(25, -10), 6)))
        ways.append(way(901, ["golf": "driving_range"], ring(at(-30, -10), 40)))
        ways.append(way(902, ["golf": "tee"], ring(at(-30, -10), 5)))
        let c = try XCTUnwrap(OSMCourse.candidates(in: try elements(ways)).first)
        XCTAssertEqual(c.holes[0].tees.filter { $0.inferredName == true }.count, 0)
        XCTAssertEqual(c.report.teesUntagged, 2)
    }

    /// `tee=yellow;3` is a tee shared between two courses. The colour is what a
    /// group says out loud; the hole number glued to it is noise.
    func testASharedTeeKeepsOnlyItsColour() throws {
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300),
                        teeColours: [])
        ways.append(way(900, ["golf": "tee", "tee": "yellow;3"], ring(at(0, 0), 5)))
        let els = try elements(ways)
        let c = try XCTUnwrap(OSMCourse.candidates(in: els).first)
        XCTAssertEqual(c.holes[0].tees.map(\.name), ["yellow"])
    }

    /// Bunkers and water go to the hole they sit beside, measured to the *line* and
    /// not to its endpoints — a bunker halfway down a 350 m hole is metres from the
    /// line and 175 m from either end of it.
    func testHazardsAttachToTheNearestHoleLineNotItsEndpoints() throws {
        var ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 350))
        ways.append(way(900, ["golf": "bunker"], ring(at(20, 175), 8)))
        ways.append(way(901, ["golf": "water_hazard"], ring(at(-25, 200), 10)))
        let els = try elements(ways)
        let c = try XCTUnwrap(OSMCourse.candidates(in: els).first)
        XCTAssertEqual(c.holes[0].hazards.count, 2)
        XCTAssertEqual(Set(c.holes[0].hazards.map(\.kind)), [.bunker, .water])
    }

    // MARK: - What a file from OSM must and must not contain

    /// OSM never supplies yardage — `dist` is on 0.3% of US hole ways. A tee must
    /// come out with a coordinate and **no** `distance`, so that `cardLength` reads
    /// as missing and the card import has something to fill in.
    func testOSMGivesCoordinatesAndNeverYardage() throws {
        let els = try elements(hole(id: 100, ref: "1", par: 4, handicap: 1,
                                    tee: at(0, 0), green: at(0, 300)))
        let course = try XCTUnwrap(OSMCourse.candidates(in: els).first).course(id: "x")
        XCTAssertEqual(course.source, .osm)
        XCTAssertNotNil(course.attribution)
        for t in course.holes[0].tees {
            XCTAssertNotNil(t.at)
            XCTAssertNil(t.distance, "OSM has no yardage; a tee must not invent one")
        }
        XCTAssertNil(course.holes[0].cardLength())
        XCTAssertNotNil(course.holes[0].geometry()?.measuredLength)
    }

    /// The ODbL stamp is the whole reason `Course.Source` exists, and a card
    /// imported over OSM geometry must not quietly relabel the file as `.card`.
    func testACardMergedOverOSMKeepsTheODbLStamp() throws {
        let els = try elements(hole(id: 100, ref: "1", par: 4, handicap: 1,
                                    tee: at(0, 0), green: at(0, 300)))
        let osm = try XCTUnwrap(OSMCourse.candidates(in: els).first).course(id: "x")
        let card = Course(id: "x", name: "X", source: .card, holes: [
            Hole(ref: "1", par: 4, handicap: 9,
                 tees: [TeeBox(name: "black", distance: 320)])
        ])
        let merged = osm.merging(card: card)
        XCTAssertEqual(merged.source, .osm)
        XCTAssertEqual(merged.holes[0].handicap, 9, "card handicap must win")
        let black = try XCTUnwrap(merged.holes[0].tee(named: "black"))
        XCTAssertEqual(black.distance, 320)
        XCTAssertNotNil(black.at, "the OSM coordinate must survive the card merge")
    }

    // MARK: - Geodesy support

    /// OSM greens are traced by hand and their vertices bunch up where the mapper
    /// slowed down, so a vertex mean drifts toward the fiddly edge. On a green that
    /// is the difference between a right centre distance and a wrong club.
    func testCentroidIsAreaWeightedNotAVertexMean() throws {
        let c = Coordinate(lat: 37.4, lon: 127.2)
        var poly = SampleCourse.ellipse(around: c, semiMajor: 20, semiMinor: 14)
        // Densify one edge — the same shape, ten more vertices along one side.
        let extra = (1...10).map { i in
            Geodesy.point(from: c, bearing: 90 + Double(i) * 0.5, distance: 20)
        }
        poly.insert(contentsOf: extra, at: 1)
        let centroid = try XCTUnwrap(Geodesy.centroid(poly))
        let n = Double(poly.count)
        let mean = Coordinate(lat: poly.reduce(0) { $0 + $1.lat } / n,
                              lon: poly.reduce(0) { $0 + $1.lon } / n)
        XCTAssertLessThan(Geodesy.distance(centroid, c), 1.0)
        XCTAssertGreaterThan(Geodesy.distance(mean, c), Geodesy.distance(centroid, c))
    }

    func testDistanceToPathMeasuresToSegmentsNotVertices() {
        let a = Coordinate(lat: 37.4, lon: 127.2)
        let b = SampleCourse.step(a, 0, 400)
        let beside = Geodesy.coordinate(from: a, east: 20, north: 200)
        XCTAssertEqual(Geodesy.distance(from: beside, toPath: [a, b]), 20, accuracy: 0.5)
        XCTAssertGreaterThan(min(Geodesy.distance(beside, a), Geodesy.distance(beside, b)), 150)
    }
}

extension OSMCourseTests {
    /// The defect that made `TeeBox.sameTee` exist. OSM tags tees `black`; an
    /// American card prints `BLACK` or `Black Tees`. Matched exactly, every card
    /// tee lands with no coordinate and the OSM tees pile up beside them — a merge
    /// that reports success and discards the geometry it exists to preserve.
    func testMergingATeeMatchesAcrossCasingAndTheWordTees() throws {
        let osm = Course(id: "x", name: "X", source: .osm, holes: [
            Hole(ref: "1", par: 4,
                 tees: [TeeBox(name: "black", at: Coordinate(lat: 37.4, lon: -122.2)),
                        TeeBox(name: "white", at: Coordinate(lat: 37.401, lon: -122.2))],
                 green: Green(center: Coordinate(lat: 37.404, lon: -122.2)))
        ])
        let card = Course(id: "x", name: "X", source: .card, holes: [
            Hole(ref: "1", par: 4, handicap: 5,
                 tees: [TeeBox(name: "BLACK", distance: 380),
                        TeeBox(name: "White Tees", distance: 340)])
        ])
        let merged = osm.merging(card: card)
        XCTAssertEqual(merged.holes[0].tees.count, 2, "casing split each tee into two")
        for t in merged.holes[0].tees {
            XCTAssertNotNil(t.at, "\(t.name) lost its OSM coordinate")
            XCTAssertNotNil(t.distance, "\(t.name) lost its card yardage")
        }
        XCTAssertTrue(merged.holes[0].hasGeometry)
    }
}

extension OSMCourseTests {
    /// Douglas–Peucker on a closed ring. The naive version runs DP from the first
    /// vertex to the last — which on a ring are the *same point*, so every vertex
    /// measures zero from the baseline and the whole outline collapses to a
    /// triangle. Splitting at the far vertex is what prevents that.
    func testSimplifyKeepsTheShapeOfARing() {
        let c = Coordinate(lat: 37.4, lon: -122.2)
        // A 20×14 m green traced at 120 vertices, as OSM greens actually are.
        let dense = (0..<120).map {
            Geodesy.coordinate(from: c,
                               east: 20 * cos(Double($0) / 120 * 2 * .pi),
                               north: 14 * sin(Double($0) / 120 * 2 * .pi))
        }
        let ring = dense + [dense[0]]
        let simple = OSMCourse.simplify(ring, tolerance: 1.0)

        XCTAssertLessThan(simple.count, ring.count / 2, "nothing was removed")
        XCTAssertGreaterThanOrEqual(simple.count, 8, "the ring collapsed")
        XCTAssertEqual(simple.first, simple.last, "the ring must stay closed")
        // Every original vertex must still sit within the tolerance of the kept
        // outline — that is what the tolerance means.
        for p in dense {
            XCTAssertLessThanOrEqual(Geodesy.distance(from: p, toPath: simple), 1.2,
                                     "the outline moved further than the tolerance")
        }
    }

    /// The centroid is taken from the full ring *before* simplification, so how
    /// much outline is kept can never move the green centre — the one number on
    /// the screen a golfer picks a club from.
    func testSimplifyingAGreenDoesNotMoveItsCentre() throws {
        let ways = hole(id: 100, ref: "1", par: 4, handicap: 1, tee: at(0, 0), green: at(0, 300))
        let els = try elements(ways)
        var coarse = OSMCourse.Reach(); coarse.simplify = 5
        var exact = OSMCourse.Reach(); exact.simplify = 0
        let a = try XCTUnwrap(OSMCourse.candidates(in: els, reach: coarse).first)
        let b = try XCTUnwrap(OSMCourse.candidates(in: els, reach: exact).first)
        XCTAssertLessThan(a.holes[0].green.polygon.count, b.holes[0].green.polygon.count)
        XCTAssertEqual(Geodesy.distance(try XCTUnwrap(a.holes[0].green.center),
                                        try XCTUnwrap(b.holes[0].green.center)),
                       0, accuracy: 0.001)
    }
}

extension OSMCourseTests {
    /// The one association error the length and permutation checks are blind to.
    ///
    /// Found on the first real import: at Corica Park `yellow` is the shortest tee
    /// on sixteen holes and the *longest* on 8 and 17, where a yellow polygon 64 m
    /// behind the black tee was the nearest yellow to that hole's tee end. The
    /// black-tee length still matched the raw OSM way to the metre and every
    /// structural check passed — only someone playing yellows would ever find out.
    func testATeeThatBreaksTheCourseColourOrderIsFlagged() throws {
        let green = Coordinate(lat: 37.4, lon: -122.2)
        func hole(_ ref: String, yellowAt yellow: Double) -> Hole {
            Hole(ref: ref, par: 4,
                 tees: [("black", 380.0), ("blue", 350), ("white", 320), ("yellow", yellow)]
                    .map { TeeBox(name: $0.0,
                                  at: Geodesy.point(from: green, bearing: 180, distance: $0.1)) },
                 green: Green(center: green))
        }
        // Ten normal holes; on the eleventh a stray polygon put yellow behind black.
        var holes = (1...10).map { hole("\($0)", yellowAt: 290) }
        holes.append(hole("11", yellowAt: 440))

        let flags = OSMCourse.teeAnomalies(in: holes)
        XCTAssertEqual(flags.count, 1, "expected exactly one flag, got: \(flags)")
        XCTAssertTrue(flags[0].hasPrefix("hole 11:"), flags[0])
        XCTAssertTrue(flags[0].contains("yellow"), flags[0])

        // And it must stay quiet on a clean course, including one where a par 3
        // compresses every tee and another where a hole has fewer tees.
        var clean = (1...10).map { hole("\($0)", yellowAt: 290) }
        clean.append(Hole(ref: "11", par: 3,
                          tees: [("black", 160.0), ("yellow", 120)].map {
                              TeeBox(name: $0.0, at: Geodesy.point(from: green, bearing: 180,
                                                                   distance: $0.1))
                          },
                          green: Green(center: green)))
        XCTAssertEqual(OSMCourse.teeAnomalies(in: clean), [], "false alarm on a clean course")
    }
}

// MARK: - Course ids

/// `slug` moved from `golfctl`'s `CourseImport` into `GolfCourse` on 2026-08-30, so
/// the app's course finder builds the *same* id the CLI does. Two copies would agree
/// until the day they did not, and the day they did not a card imported over an OSM
/// file would silently write a second course.
final class CourseSlugTests: XCTestCase {
    func testSlugIsFileNameSafeAndStable() {
        XCTAssertEqual(Course.slug("Corica Park South"), "corica-park-south")
        XCTAssertEqual(Course.slug("  Angeles National  "), "angeles-national")
        XCTAssertEqual(Course.slug("St. Andrews (Old)"), "st-andrews-old")
        // A Korean name slugs to nothing usable, and "course" is better than a file
        // name Finder and the Files app disagree about. The importer takes an
        // explicit id in that case.
        XCTAssertEqual(Course.slug("안성CC"), "cc")
        XCTAssertEqual(Course.slug("천룡"), "course")
    }
}

// MARK: - Multipolygons, course tags and named tees
//
// Everything below was written against the Coyote Creek response of 2026-08-30,
// where all 28 fairways are relations, every hole way carries `golf:course:name`,
// and five tee polygons name their own hole.

final class OSMMultipolygonTests: XCTestCase {

    private static let origin = Coordinate(lat: 37.19, lon: -121.70)

    private func at(_ east: Double, _ north: Double) -> Coordinate {
        Geodesy.coordinate(from: Self.origin, east: east, north: north)
    }

    private func ring(_ centre: Coordinate, _ r: Double) -> [Coordinate] {
        (0..<12).map { Geodesy.point(from: centre, bearing: Double($0) * 30, distance: r) }
    }

    private func pts(_ cs: [Coordinate]) -> [[String: Double]] {
        cs.map { ["lat": $0.lat, "lon": $0.lon] }
    }

    private func way(_ id: Int, _ tags: [String: String], _ cs: [Coordinate]) -> [String: Any] {
        ["type": "way", "id": id, "tags": tags, "geometry": pts(cs)]
    }

    /// One multipolygon, as `out geom;` delivers it: members with their own
    /// geometry and a role, and no top-level `geometry` at all.
    private func relation(_ id: Int, _ tags: [String: String],
                          outer: [[Coordinate]], inner: [[Coordinate]] = []) -> [String: Any] {
        let members = outer.map { ["type": "way", "role": "outer", "geometry": pts($0)] }
                    + inner.map { ["type": "way", "role": "inner", "geometry": pts($0)] }
        return ["type": "relation", "id": id, "tags": tags, "members": members]
    }

    private func elements(_ els: [[String: Any]]) throws -> [OSMCourse.Element] {
        let data = try JSONSerialization.data(withJSONObject: ["elements": els])
        return try OSMCourse.elements(from: data)
    }

    private func hole(id: Int, ref: String, course: String? = nil,
                      tee: Coordinate, green: Coordinate) -> [[String: Any]] {
        var tags = ["golf": "hole", "ref": ref, "par": "4"]
        if let course { tags["golf:course:name"] = course }
        return [way(id, tags, [tee, green]),
                way(id + 1, ["golf": "green"], ring(green, 12))]
    }

    // MARK: - Relations

    /// At Coyote Creek **every one of the 28 fairways is a relation** and at Corica
    /// 26 of 28 are, so a `filter { type == "way" }` left the fairway layer empty on
    /// both real courses there are.
    func testAFairwayDrawnAsAMultipolygonIsImported() throws {
        var els = hole(id: 100, ref: "1", tee: at(0, 0), green: at(0, 320))
        els.append(relation(900, ["golf": "fairway", "type": "multipolygon"],
                            outer: [ring(at(0, 160), 30)]))
        let c = OSMCourse.candidates(in: try elements(els))
        XCTAssertEqual(c.first?.holes.first?.fairway.isEmpty, false)
    }

    /// The inner rings are the bunkers and greens cut out of the fairway — 32 of
    /// them across Coyote Creek's 28 fairway relations. Concatenating every member
    /// draws a spike from the outer ring to the inner one and back.
    func testInnerRingsAreNotConcatenatedOntoTheOuterOne() throws {
        let outer = ring(at(0, 160), 40), inner = ring(at(0, 160), 8)
        let els = try elements([relation(900, ["golf": "fairway"],
                                         outer: [outer], inner: [inner])])
        let got = els[0].coordinates
        XCTAssertEqual(got.count, outer.count)
        for c in got {
            XCTAssertGreaterThan(Geodesy.distance(c, at(0, 160)), 20,
                                 "an inner-ring vertex reached the outline")
        }
    }

    /// OSM lets one ring be drawn as several ways, arriving in any order and either
    /// direction.
    func testOuterWaysAreChainedEndToEndWhicheverWayTheyRun() {
        let a = [at(0, 0), at(50, 0), at(50, 50)]
        let b = [at(0, 50), at(50, 50)]          // runs backwards relative to `a`
        let joined = OSMCourse.stitch([a, b])
        XCTAssertEqual(joined.count, 4)
        XCTAssertEqual(Geodesy.distance(joined.last!, at(0, 50)), 0, accuracy: 1)
    }

    /// A ring with a jump in it looks like a surveyed shape and is not, so the
    /// longest piece alone is the honest answer.
    func testAnUnchainableRingFallsBackToItsLongestPiece() {
        let a = [at(0, 0), at(50, 0), at(50, 50), at(0, 50)]
        let b = [at(900, 900), at(950, 900)]
        XCTAssertEqual(OSMCourse.stitch([a, b]).count, a.count)
    }

    // MARK: - golf:course:name

    /// The tag is a surveyor's statement; the minimum-walk assignment is an
    /// inference. At Coyote Creek the walk turned the ten clipped holes of a
    /// neighbouring course into two spurious candidates of 7 and 3.
    func testCourseNameTagPartitionsTheSiteAndTheWalkDoesNot() throws {
        var els: [[String: Any]] = []
        // Two courses whose holes interleave, so geometry alone cannot separate them.
        for i in 0..<4 {
            let x = Double(i) * 60
            els += hole(id: 100 + i * 10, ref: "\(i + 1)", course: "Tournament Course",
                        tee: at(x, 0), green: at(x, 300))
            els += hole(id: 500 + i * 10, ref: "\(i + 1)", course: "Valley Course",
                        tee: at(x + 25, 5), green: at(x + 25, 305))
        }
        let c = OSMCourse.candidates(in: try elements(els))
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(Set(c.compactMap(\.name)), ["Tournament Course", "Valley Course"])
        XCTAssertEqual(c.map(\.holes.count), [4, 4])
    }

    /// Partitioning on a partial tagging would put the tagged holes in named groups
    /// and quietly lose the rest.
    func testAPartiallyTaggedSiteFallsBackToTheWalk() throws {
        var els = hole(id: 100, ref: "1", course: "Tournament Course",
                       tee: at(0, 0), green: at(0, 300))
        els += hole(id: 200, ref: "2", tee: at(0, 330), green: at(0, 630))
        let c = OSMCourse.candidates(in: try elements(els))
        XCTAssertEqual(c.first?.holes.count, 2)
    }

    // MARK: - A tee that names its hole

    /// Proximity put four of Coyote Creek's five named tees on hole 1 and the red
    /// one on **hole 13** — an ordinary-looking file, a hole out for anyone playing
    /// the reds.
    func testATeeNamingItsHoleGoesToThatHoleAndNotToTheNearestOne() throws {
        var els = hole(id: 100, ref: "1", tee: at(0, 0), green: at(0, 300))
        els += hole(id: 200, ref: "2", tee: at(70, 0), green: at(70, 300))
        // Nearer hole 2's tee end than hole 1's, and labelled for hole 1.
        els.append(way(900, ["golf": "tee", "tee": "red", "name": "Hole 1 Red"],
                       ring(at(55, 0), 5)))
        let c = try XCTUnwrap(OSMCourse.candidates(in: try elements(els)).first)
        let one = try XCTUnwrap(c.holes.first { $0.ref == "1" })
        let two = try XCTUnwrap(c.holes.first { $0.ref == "2" })
        XCTAssertTrue(one.tees.contains { $0.name == "red" })
        XCTAssertFalse(two.tees.contains { $0.name == "red" })
    }

    /// `Holw 1 White` is real, tagged that way at Coyote Creek. A surveyor's typo
    /// must not cost the hole number sitting right beside it.
    func testTheHoleNumberSurvivesAMisspeltWordHole() {
        XCTAssertEqual(OSMCourse.holeNumber(in: "Holw 1 White"), 1)
        XCTAssertEqual(OSMCourse.holeNumber(in: "Hole 13 Black"), 13)
        XCTAssertEqual(OSMCourse.holeNumber(in: "South Course hole 7"), 7)
        XCTAssertNil(OSMCourse.holeNumber(in: "Championship Tee"))
        XCTAssertNil(OSMCourse.holeNumber(in: "Range 1998"))
    }

    // MARK: - Naming

    /// `Tournament Course` slugs to `tournament-course`, which would collide with
    /// the tournament course of every other facility on earth.
    func testAGroupNameIsQualifiedByTheSiteUnlessTheSiteAlreadySaysIt() {
        XCTAssertEqual(OSMCourse.displayName(course: "Tournament Course",
                                             site: "Coyote Creek Golf Club Tournament Course"),
                       "Coyote Creek Golf Club Tournament Course")
        XCTAssertEqual(OSMCourse.displayName(course: "South Course",
                                             site: "Corica Park Golf Course"),
                       "Corica Park South Course")
        XCTAssertEqual(OSMCourse.displayName(course: nil, site: "Corica Park"), "Corica Park")
        XCTAssertEqual(OSMCourse.displayName(course: "South Course", site: nil), "South Course")
    }

    // MARK: - Cart paths

    /// A cart path is one way running the length of several holes, so assigning the
    /// whole thing to its nearest hole draws a neighbour's path across this hole and
    /// loses this hole's own. Each vertex picks its own hole.
    func testACartPathIsClippedToTheHoleEachStretchServes() throws {
        var els = hole(id: 100, ref: "1", tee: at(0, 0), green: at(0, 300))
        els += hole(id: 200, ref: "2", tee: at(400, 0), green: at(400, 300))
        // One path down hole 1, across the gap, and down hole 2.
        let line = (0...20).map { at(Double($0) * 20, 150) }
        els.append(way(900, ["golf": "cartpath"], line))
        // The two holes are far enough apart that the walk calls them separate
        // courses, which is beside the point here — collect every hole either way.
        let holes = OSMCourse.candidates(in: try elements(els)).flatMap(\.holes)
        XCTAssertEqual(holes.count, 2)
        for h in holes { XCTAssertFalse(h.paths.isEmpty, "hole \(h.ref) lost its path") }
        // And no stretch landed on a hole it does not run along.
        for h in holes {
            let end = h.tees.first?.at ?? h.line.first!
            for pt in h.paths.flatMap({ $0 }) {
                XCTAssertLessThan(Geodesy.distance(pt, end), 250,
                                  "hole \(h.ref) took a stretch of another hole's path")
            }
        }
    }

    /// A run of one vertex is not a path — the same rule a `PlayerTrack` follows.
    func testASingleVertexNearAHoleIsNotAPath() {
        let d: [OSMCourse.Draft] = []
        XCTAssertTrue(OSMCourse.clip([at(0, 0)], to: d, within: 60).isEmpty)
    }

    /// Ray casting, used to keep a driving range's tee polygons out of a hole.
    func testPointInPolygon() {
        let square = [at(0, 0), at(100, 0), at(100, 100), at(0, 100)]
        XCTAssertTrue(OSMCourse.inside(at(50, 50), square))
        XCTAssertFalse(OSMCourse.inside(at(150, 50), square))
        XCTAssertFalse(OSMCourse.inside(at(50, 50), [at(0, 0), at(100, 0)]))
    }

    /// An open line keeps both of its ends. `simplify(_:tolerance:)` splits a ring at
    /// its far vertex because a ring has no ends; doing that to a path would move one.
    func testSimplifyingAPathKeepsItsEnds() {
        let line = (0...50).map { at(Double($0) * 4, sin(Double($0)) * 0.2) }
        let out = OSMCourse.simplify(open: line, tolerance: 1)
        XCTAssertLessThan(out.count, line.count)
        XCTAssertEqual(out.first, line.first)
        XCTAssertEqual(out.last, line.last)
    }

    // MARK: - What the report says about *this* course

    /// `report.lines` **is** the row a golfer reads in front of Save in
    /// `CourseFinder`, so a "no tee found" list naming holes that have tees — the
    /// other course at the site, whose refs repeat — takes the check below useless.
    func testHolesWithoutATeeAreCountedPerCourseAndNotPerSite() throws {
        var els: [[String: Any]] = []
        for i in 0..<3 {
            let x = Double(i) * 60
            els += hole(id: 100 + i * 10, ref: "\(i + 1)", course: "Tournament Course",
                        tee: at(x, 0), green: at(x, 300))
            els.append(way(700 + i, ["golf": "tee", "tee": "black"], ring(at(x, 0), 5)))
            // The other course's holes carry the same refs and no tees at all.
            els += hole(id: 500 + i * 10, ref: "\(i + 1)", course: "Valley Course",
                        tee: at(x + 25, 5), green: at(x + 25, 305))
        }
        let cands = OSMCourse.candidates(in: try elements(els))
        let tournament = try XCTUnwrap(cands.first { $0.name == "Tournament Course" })
        let valley = try XCTUnwrap(cands.first { $0.name == "Valley Course" })
        XCTAssertEqual(tournament.report.holesWithoutTee, [])
        XCTAssertEqual(valley.report.holesWithoutTee, ["1", "2", "3"])
        XCTAssertFalse(tournament.report.lines.contains { $0.contains("no tee found") })
    }

    /// The ramp is sized to **every tee on the widest hole that has an adopted one**.
    /// Both narrower sizings were tried against the two real files and both produced
    /// a `tee N`: the modal *total* gave `tee 5` on Coyote Creek's one five-tee hole,
    /// and the adopted count alone gave Corica a one-entry ramp whose single entry a
    /// tagged black tee had already taken. `TeePalette` reads `tee 2` as a
    /// non-colour name and blends its neighbours, and `marker.tee.<courseID>`
    /// persists the string.
    func testTheRampIsSizedToTheWidestHoleSoNoTeeIsCalledTeeN() throws {
        var els: [[String: Any]] = []
        // Three holes with two adopted tees each, one with four — and a tagged black
        // tee on the last, so the ramp has to be long enough to skip a taken name.
        for i in 0..<4 {
            let x = Double(i) * 500
            els += hole(id: 100 + i * 10, ref: "\(i + 1)", tee: at(x, 0), green: at(x, 300))
            for k in 0..<(i == 3 ? 4 : 2) {
                els.append(way(700 + i * 10 + k, ["golf": "tee"],
                               ring(at(x, Double(k) * 15), 4)))
            }
            if i == 3 {
                els.append(way(790, ["golf": "tee", "tee": "black"], ring(at(x, -12), 4)))
            }
        }
        let holes = OSMCourse.candidates(in: try elements(els)).flatMap(\.holes)
        let names = holes.flatMap { $0.tees.filter { $0.inferredName == true }.map(\.name) }
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.hasPrefix("tee ") }, "\(names)")
        // Rank means the same thing on every hole: the longest adopted tee is black
        // whether the hole carries two of them or four.
        for h in holes where !h.tees.contains(where: { $0.inferredName != true }) {
            let inferred = h.tees.filter { $0.inferredName == true }
            if let first = inferred.first { XCTAssertEqual(first.name, "black") }
        }
    }

    /// A card confirms that the course *has* a white tee. It says nothing about which
    /// polygon that is, and our name came from a rank in the length order — so the
    /// mark has to survive the merge or a printed yardage lands under an invented
    /// name with nothing on screen saying so.
    func testAnInferredTeeNameSurvivesACardMerge() {
        let osm = Course(id: "x", name: "X", source: .osm, holes: [
            Hole(ref: "1", par: 4,
                 tees: [TeeBox(name: "white", at: Coordinate(lat: 1, lon: 2),
                               inferredName: true)]),
        ])
        let card = Course(id: "x", name: "X", source: .card, holes: [
            Hole(ref: "1", par: 4, tees: [TeeBox(name: "WHITE", distance: 300)]),
        ])
        let merged = osm.merging(card: card)
        let tee = merged.holes[0].tees[0]
        XCTAssertEqual(tee.distance, 300)
        XCTAssertNotNil(tee.at)
        XCTAssertEqual(tee.inferredName, true)
    }
}
