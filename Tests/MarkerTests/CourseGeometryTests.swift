import XCTest
@testable import GolfCourse

final class CourseGeometryTests: XCTestCase {

    // MARK: - Geodesy

    func testDistanceAndBearingAgreeWithConstruction() {
        let a = Coordinate(lat: 37.4, lon: 127.2, alt: 100)
        let b = SampleCourse.step(a, 38, 250)
        XCTAssertEqual(Geodesy.distance(a, b), 250, accuracy: 0.5)
        XCTAssertEqual(Geodesy.bearing(from: a, to: b), 38, accuracy: 0.2)
    }

    func testOffsetRoundTrips() {
        let a = Coordinate(lat: 37.4, lon: 127.2)
        let b = Geodesy.coordinate(from: a, east: 120, north: -80)
        let o = Geodesy.offset(of: b, from: a)
        XCTAssertEqual(o.east, 120, accuracy: 0.01)
        XCTAssertEqual(o.north, -80, accuracy: 0.01)
    }

    func testSideIsNegativeToTheRight() {
        let tee = Coordinate(lat: 37.4, lon: 127.2)
        // Green due north; a point due east of the tee is to the RIGHT of the line.
        let green = SampleCourse.step(tee, 0, 300)
        let right = SampleCourse.step(tee, 90, 50)
        let left = SampleCourse.step(tee, 270, 50)
        XCTAssertLessThan(Geodesy.side(of: right, tee: tee, green: green), 0)
        XCTAssertGreaterThan(Geodesy.side(of: left, tee: tee, green: green), 0)
    }

    func testPlaysLikeAddsElevationOneToOne() {
        XCTAssertEqual(Geodesy.playsLike(distance: 147, elevationDelta: 8), 155, accuracy: 0.001)
        XCTAssertEqual(Geodesy.playsLike(distance: 165, elevationDelta: -6), 159, accuracy: 0.001)
    }

    func testPolygonContainment() {
        let c = Coordinate(lat: 37.4, lon: 127.2)
        let poly = SampleCourse.ellipse(around: c, semiMajor: 20, semiMinor: 14)
        XCTAssertTrue(Geodesy.contains(poly, c))
        XCTAssertFalse(Geodesy.contains(poly, SampleCourse.step(c, 90, 60)))
    }

    // MARK: - Hole

    func testSampleHoleLengthsAndElevation() throws {
        let course = SampleCourse.naelgol
        let h7 = try XCTUnwrap(course.hole("7"))
        XCTAssertEqual(h7.par, 4)
        XCTAssertEqual(try XCTUnwrap(h7.geometry()).measuredLength, 380, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(h7.elevationDelta(from: h7.geometry()!.teeAt)), 8, accuracy: 0.01)

        let h8 = try XCTUnwrap(course.hole("8"))
        XCTAssertEqual(try XCTUnwrap(h8.geometry()).measuredLength, 165, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(h8.elevationDelta(from: h8.geometry()!.teeAt)), -6, accuracy: 0.01)
    }

    /// Front/back must be measured against the outline from where the player
    /// stands, not read from a stored point — that is the whole reason
    /// `distances(from:)` exists.
    func testGreenDistancesAreMeasuredFromThePlayer() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        let fromTee = try XCTUnwrap(h.distances(from: h.geometry()!.teeAt))
        XCTAssertLessThan(fromTee.front, fromTee.center)
        XCTAssertLessThan(fromTee.center, fromTee.back)

        // Approach the same green from the far side. The *stored* front point
        // would still read as "front"; a measured one must not — the nearest edge
        // of the outline has to become the opposite edge.
        let behind = SampleCourse.step(h.green.center!, h.bearing()!, 120)
        let fromBehind = try XCTUnwrap(h.distances(from: behind))
        XCTAssertEqual(fromBehind.center, 120, accuracy: 1)
        XCTAssertLessThan(fromBehind.front, fromBehind.center)
        XCTAssertLessThan(fromBehind.center, fromBehind.back)

        func nearestVertex(to p: Coordinate) -> Int {
            h.green.polygon.indices.min {
                Geodesy.distance(p, h.green.polygon[$0]) < Geodesy.distance(p, h.green.polygon[$1])
            }!
        }
        XCTAssertNotEqual(nearestVertex(to: h.geometry()!.teeAt), nearestVertex(to: behind),
                          "front must be measured from the player, not stored")
    }

    func testOnGreen() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        XCTAssertTrue(h.isOnGreen(h.green.center!))
        XCTAssertFalse(h.isOnGreen(h.geometry()!.teeAt))
    }

    /// The phone cannot supply an altitude comparable with a course file, so the
    /// profile has to be interpolated from geometry or plays-like never appears.
    func testElevationIsInterpolatedWhenThePointHasNoAltitude() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        let tee = h.geometry()!.teeAt
        XCTAssertEqual(try XCTUnwrap(h.estimatedAltitude(at: tee)), 112, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(h.estimatedAltitude(at: h.green.center!)), 120, accuracy: 0.2)

        // Halfway up the first leg: about halfway up the climb.
        let mid = Coordinate(lat: h.line[1].lat, lon: h.line[1].lon)   // no alt of its own
        let alt = try XCTUnwrap(h.estimatedAltitude(at: mid))
        XCTAssertGreaterThan(alt, 112)
        XCTAssertLessThan(alt, 120)
        XCTAssertNotNil(h.elevationDelta(from: mid))
    }

    // MARK: - Projection handedness (the mirrored-render trap)

    /// A dogleg right that renders as a dogleg left still looks like a golf hole.
    /// Two holes with bearings ~90° apart pin the rotation, not just the flip.
    func testProjectionPutsRightOfTheLineAtLargerX() throws {
        for ref in ["7", "8", "9"] {
            let h = try XCTUnwrap(SampleCourse.naelgol.hole(ref))
            let tee = h.defaultTee
            let plane = HolePlane(geometry: h.geometry(tee: tee)!, size: (width: 320, height: 560))

            let right = SampleCourse.step(tee.at!, h.bearing(from: tee)! + 90, 40)
            let left = SampleCourse.step(tee.at!, h.bearing(from: tee)! - 90, 40)
            XCTAssertLessThan(Geodesy.side(of: right, tee: tee.at!, green: h.green.center!), 0,
                              "hole \(ref): fixture wrong, +90° must be the right side")

            let pr = plane.project(right), pl = plane.project(left), pt = plane.project(tee.at!)
            XCTAssertGreaterThan(pr.x, pt.x, "hole \(ref): right of the line must render at larger x")
            XCTAssertLessThan(pl.x, pt.x, "hole \(ref): left of the line must render at smaller x")
        }
    }

    func testProjectionPutsTeeBelowGreen() throws {
        for ref in ["7", "8", "9"] {
            let h = try XCTUnwrap(SampleCourse.naelgol.hole(ref))
            let plane = HolePlane(geometry: h.geometry()!, size: (width: 320, height: 560))
            let tee = plane.project(h.geometry()!.teeAt), green = plane.project(h.green.center!)
            XCTAssertGreaterThan(tee.y, green.y, "hole \(ref): tee must be below the green")
        }
    }

    func testProjectionFitsEverythingInsideTheView() throws {
        let h = try XCTUnwrap(SampleCourse.naelgol.hole("7"))
        let plane = HolePlane(geometry: h.geometry()!, size: (width: 320, height: 560), insets: .uniform(20))
        var pts = h.line + h.green.polygon
        for z in h.hazards { pts += z.polygon }
        for p in pts {
            let q = plane.project(p)
            XCTAssertTrue((0...320).contains(q.x), "x \(q.x) escaped the view")
            XCTAssertTrue((0...560).contains(q.y), "y \(q.y) escaped the view")
        }
    }

    // MARK: - Store

    func testCourseFileRoundTrips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("courses-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CourseStore(directory: dir)
        try store.save(SampleCourse.naelgol)

        let back = try store.load(id: "naelgol-cc")
        XCTAssertEqual(back.name, "내골 CC")
        XCTAssertEqual(back.holes.count, 3)
        XCTAssertEqual(back.holes[0].green.polygon.count, 16)
        XCTAssertEqual(store.loadAll().count, 1)
    }
}

/// `Course.nearestHole` — which hole a log belongs to.
final class NearestHoleTests: XCTestCase {

    /// The answer is the **1-based playing-order index, not `Hole.ref`** — and
    /// the sample course is exactly the case that separates them: it holds three
    /// holes whose refs are "7", "8" and "9". Standing on the first one is
    /// *column 1*, and anything that returned 7 here would put every log on the
    /// wrong scorecard column of a partial course.
    func testTheAnswerIsTheColumnIndexNotTheHoleRef() throws {
        let course = SampleCourse.naelgol
        let first = course.holes[0]
        XCTAssertEqual(first.ref, "7", "sample course changed; this test's point is moot")
        let tee = try XCTUnwrap(first.tees.compactMap(\.at).first)
        let found = try XCTUnwrap(course.nearestHole(to: tee))
        XCTAssertEqual(found.index, 1)
        XCTAssertEqual(found.hole.id, first.id)
        XCTAssertLessThan(found.distance, 1)
    }

    /// Somewhere off the property is **nil, not hole 1**. A log made in the car
    /// park, or before the phone had a real fix, must not be filed onto a hole —
    /// the user moves it, and a confident wrong answer is harder to notice than
    /// a blank.
    func testAPointOffTheCourseIsNil() {
        let course = SampleCourse.naelgol
        let miles = Coordinate(lat: 40.0, lon: -100.0)
        XCTAssertNil(course.nearestHole(to: miles))
    }

    /// A card-only course has no coordinates at all, so there is no answer to
    /// give. Skipped holes must not read as "infinitely far but still nearest".
    func testACourseWithNoGeometryHasNoNearestHole() {
        let card = Course(id: "card-only", name: "Card Only", source: .card,
                          holes: [Hole(ref: "1", par: 4), Hole(ref: "2", par: 3)])
        XCTAssertNil(card.nearestHole(to: Coordinate(lat: 37.7, lon: -122.2)))
    }

    /// The centre line is measured perpendicular to its segments. A hole is drawn
    /// in a handful of points, and a golfer halfway down a straight leg is nearest
    /// to the *segment* — measuring only to vertices puts them hundreds of metres
    /// away and hands the log to a neighbouring hole.
    func testMidFairwayIsMeasuredToTheLineNotItsVertices() throws {
        let a = Coordinate(lat: 37.7000, lon: -122.2000)
        let b = Coordinate(lat: 37.7040, lon: -122.2000)
        let hole = Hole(ref: "1", par: 4, line: [a, b])
        let course = Course(id: "c", name: "C", source: .survey, holes: [hole])
        let middle = Coordinate(lat: 37.7020, lon: -122.2000)
        let found = try XCTUnwrap(course.nearestHole(to: middle))
        XCTAssertLessThan(found.distance, 1, "measured to a vertex, not the segment")
    }
}

// MARK: - A hole with no tee

/// **A traced hole is drawable with no tee and no green point** *(user, 2026-08-30:
/// "if tees are not in the data, we're not showing anything right now. We should show
/// the hole as long as any locatable data is there")*. Real: `golfctl course osm`
/// reports "no tee found for hole(s) 1…9" on the one real site there is, and those
/// holes were rendering as "No map for this hole yet".
final class InferredHoleGeometryTests: XCTestCase {
    private let a = Coordinate(lat: 37.7385, lon: -122.2322)
    private let b = Coordinate(lat: 37.7352, lon: -122.2307)

    func testACentreLineIsEnough() {
        let h = Hole(ref: "1", par: 4, line: [a, b])
        XCTAssertTrue(h.hasGeometry)
        let g = h.geometry()
        XCTAssertEqual(g?.teeAt, a)
        XCTAssertEqual(g?.greenCenter, b)
        XCTAssertEqual(g?.teeInferred, true)
        XCTAssertEqual(g?.greenInferred, true)
    }

    /// A placed green wins over the line's far end; the tee end still comes from the
    /// line, and says so.
    func testAPlacedGreenWinsAndOnlyTheTeeIsInferred() {
        let centre = Coordinate(lat: 37.7351, lon: -122.2308)
        let h = Hole(ref: "1", par: 4, green: Green(center: centre), line: [a, b])
        let g = h.geometry()
        XCTAssertEqual(g?.greenCenter, centre)
        XCTAssertEqual(g?.teeInferred, true)
        XCTAssertEqual(g?.greenInferred, false)
    }

    /// **No tee may answer with another tee's numbers, and the centre line is not an
    /// exception.** Once *any* tee on the hole is placed, an unplaced one still
    /// returns nil rather than quietly reporting the line's start under its name.
    func testAnUnplacedTeeStaysNilWhenAnotherIsPlaced() {
        let h = Hole(ref: "1", par: 4,
                     tees: [TeeBox(name: "black", at: a), TeeBox(name: "red")],
                     green: Green(center: b), line: [a, b])
        XCTAssertNotNil(h.geometry(tee: h.tee(named: "black")))
        XCTAssertNil(h.geometry(tee: h.tee(named: "red")))
    }

    /// One point is not a hole — and neither is a degenerate line, which would put
    /// the tee and the green in the same place and make every bearing meaningless.
    func testOnePointIsNotAHole() {
        XCTAssertNil(Hole(ref: "1", par: 4, line: [a]).geometry())
        XCTAssertNil(Hole(ref: "1", par: 4, line: [a, a]).geometry())
        XCTAssertFalse(Hole(ref: "1", par: 4).hasGeometry)
    }
}
