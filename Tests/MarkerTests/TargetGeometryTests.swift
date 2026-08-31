import XCTest
@testable import GolfCourse
@testable import GolfMap

/// Where a target goes when a **button** places it — X6.
///
/// Pure arithmetic, so it is tested here rather than looked at: the failure mode is
/// a target that lands somewhere plausible and wrong, which a screenshot cannot tell
/// from a target that landed somewhere plausible and right.
final class TargetGeometryTests: XCTestCase {

    /// A straight 400 m hole running due north.
    private func straight(par: Int, metres: Double = 400) -> HoleGeometry {
        let tee = Coordinate(lat: 37.0, lon: -122.0)
        let green = Geodesy.point(from: tee, bearing: 0, distance: metres)
        let hole = Hole(ref: "1", par: par,
                        tees: [TeeBox(name: "white", at: tee)],
                        green: Green(center: green))
        return HoleGeometry(hole: hole, tee: hole.tees[0], teeAt: tee, greenCenter: green)
    }

    /// A dogleg: the line turns hard right half way, so a point 200 m *along the
    /// line* is nowhere near a point 200 m as the crow flies.
    private func dogleg() -> HoleGeometry {
        let tee = Coordinate(lat: 37.0, lon: -122.0)
        let corner = Geodesy.point(from: tee, bearing: 0, distance: 200)
        let green = Geodesy.point(from: corner, bearing: 90, distance: 200)
        var hole = Hole(ref: "1", par: 4,
                        tees: [TeeBox(name: "white", at: tee)],
                        green: Green(center: green))
        hole.line = [tee, corner, green]
        return HoleGeometry(hole: hole, tee: hole.tees[0], teeAt: tee, greenCenter: green)
    }

    func testAPointAlongTheLineIsMeasuredAlongTheLine() {
        let g = dogleg()
        XCTAssertEqual(g.measuredLength, 400, accuracy: 1)
        // 200 m along is exactly the corner, not 200 m toward the green.
        let p = g.point(along: 200)
        XCTAssertEqual(Geodesy.distance(p, g.hole.line[1]), 0, accuracy: 1)
        // …and it is emphatically *not* where a straight line would put it.
        let straightLine = Geodesy.interpolate(g.teeAt, g.greenCenter, 200 / 400)
        XCTAssertGreaterThan(Geodesy.distance(p, straightLine), 50,
                             "a dogleg is the whole reason this walks the line")
    }

    func testWalkingPastTheEndStopsAtTheGreen() {
        let g = straight(par: 4)
        XCTAssertEqual(Geodesy.distance(g.point(along: 9_999), g.greenCenter), 0, accuracy: 1)
    }

    func testZeroAndNegativeStayOnTheTee() {
        let g = straight(par: 4)
        XCTAssertEqual(Geodesy.distance(g.point(along: 0), g.teeAt), 0, accuracy: 1)
        XCTAssertEqual(Geodesy.distance(g.point(along: -50), g.teeAt), 0, accuracy: 1)
    }

    /// A par 3 is one shot, so the reference is a fraction of the way in.
    func testAParThreeTargetIsTwoThirdsOfTheWay() {
        let g = straight(par: 3, metres: 150)
        XCTAssertEqual(Geodesy.distance(g.teeAt, g.suggestedTarget), 100, accuracy: 2)
    }

    /// A par 4 or 5 is a drive first — 250 yards, where the fairway marker would be.
    func testALongHoleTargetIsADriveOut() {
        let g = straight(par: 5, metres: 500)
        XCTAssertEqual(Geodesy.distance(g.teeAt, g.suggestedTarget),
                       250 * DistanceUnit.yards.toMetres, accuracy: 2)
    }

    /// **Clamped short of the green.** A 250-yard default on a 260-yard par 4 would
    /// put the target on the putting surface, which is not a thing anyone aims at.
    func testAShortParFourKeepsTheTargetOffTheGreen() {
        let g = straight(par: 4, metres: 220)
        let d = Geodesy.distance(g.teeAt, g.suggestedTarget)
        XCTAssertLessThan(d, 220, "a target past the green is not a target")
        XCTAssertEqual(d, 220 * 0.85, accuracy: 2)
    }

    func testTheSecondTargetIsTwoThirdsOfWhatIsLeft() {
        let g = straight(par: 5, metres: 450)
        let first = g.suggestedTarget
        let second = g.towardGreen(from: first)
        let remaining = Geodesy.distance(first, g.greenCenter)
        XCTAssertEqual(Geodesy.distance(first, second), remaining * 2 / 3, accuracy: 2)
        XCTAssertLessThan(Geodesy.distance(second, g.greenCenter), remaining)
    }

    // MARK: - The ruler

    /// Square to the line of play, not to true north: the hole is drawn tee-at-the-
    /// bottom, so a ruler laid east–west would sit at a different angle on every
    /// hole and read as a mistake on most of them.
    func testAMeasureIsLaidSquareToTheLineOfPlay() {
        let g = straight(par: 4)
        let centre = g.suggestedTarget
        let m = MeasureSegment.across(centre, bearing: g.bearing, span: 60)
        XCTAssertEqual(m.length, 60, accuracy: 1)
        XCTAssertEqual(Geodesy.distance(m.midpoint, centre), 0, accuracy: 1)
        // Perpendicular: both ends are the same distance from the tee.
        XCTAssertEqual(Geodesy.distance(g.teeAt, m.a),
                       Geodesy.distance(g.teeAt, m.b), accuracy: 1)
    }

    /// X10 — the distance box drags the **whole** ruler. Rigid, so the number it
    /// is labelled with does not change under the thumb; that is the whole reason
    /// the documented "a box is a bad handle" objection does not apply here.
    func testDraggingTheBoxMovesBothEndsAndKeepsTheLength() {
        let g = straight(par: 4)
        var m = MeasureSegment.across(g.suggestedTarget, bearing: g.bearing, span: 60)
        let before = m.length
        let a0 = m.a, b0 = m.b
        m.center(on: g.greenCenter)
        XCTAssertEqual(m.length, before, accuracy: 0.5, "a rigid move cannot change the length")
        XCTAssertEqual(Geodesy.distance(m.midpoint, g.greenCenter), 0, accuracy: 1)
        XCTAssertGreaterThan(Geodesy.distance(a0, m.a), 1)
        XCTAssertGreaterThan(Geodesy.distance(b0, m.b), 1)
        // Both ends moved the same way, so the ruler is parallel to where it was.
        XCTAssertEqual(Geodesy.distance(a0, m.a), Geodesy.distance(b0, m.b), accuracy: 1)
    }

    func testCenteringOnItsOwnMidpointIsANoOp() {
        let g = straight(par: 4)
        var m = MeasureSegment.across(g.greenCenter, bearing: g.bearing)
        let a0 = m.a, b0 = m.b
        m.center(on: m.midpoint)
        XCTAssertEqual(m.a, a0)
        XCTAssertEqual(m.b, b0)
    }

    /// X10 — "assign new colors, but set". The colour is carried on the segment,
    /// so dismissing one must not recolour the ones that outlive it.
    func testAColourIsCarriedOnTheSegmentNotItsPosition() {
        var ms = [MeasureSegment.across(Coordinate(lat: 37, lon: -122), bearing: 0, colorIndex: 0),
                  MeasureSegment.across(Coordinate(lat: 37, lon: -122), bearing: 0, colorIndex: 1),
                  MeasureSegment.across(Coordinate(lat: 37, lon: -122), bearing: 0, colorIndex: 2)]
        ms.remove(at: 0)
        XCTAssertEqual(ms.map(\.colorIndex), [1, 2],
                       "dismissing the first ruler must not repaint the others")
    }

    func testThePaletteWrapsAndNeverTrapsOnANegativeIndex() {
        XCTAssertEqual(HoleStyle.measureColor(0), HoleStyle.measureColor(HoleStyle.measureColors.count))
        XCTAssertEqual(HoleStyle.measureColor(-1), HoleStyle.measureColor(HoleStyle.measureColors.count - 1))
    }

    /// A ruler must not read as a player's track. Different question, different set.
    func testRulerColoursAreNotPlayerColours() {
        for c in HoleStyle.measureColors {
            XCTAssertFalse(HoleStyle.playerColors.contains(c))
        }
    }

    func testMovingOneEndLeavesTheOtherAlone() {
        let g = straight(par: 4)
        var m = MeasureSegment.across(g.greenCenter, bearing: g.bearing)
        let b = m.b
        m.move(end: .a, to: g.teeAt)
        XCTAssertEqual(m.b, b)
        XCTAssertEqual(m.a, g.teeAt)
    }

    // MARK: - Marker labels

    func testAShortLabelIsLeftAlone() {
        XCTAssertEqual(HoleMarker.abbreviate("steve birdie"), "steve birdie")
    }

    /// **Cut at a word, never mid-word.** A hard character cut reads as corrupted
    /// text; a word boundary reads as a beginning.
    func testALongLabelIsCutAtAWord() {
        let out = HoleMarker.abbreviate("steve hit driver into the left bunker off the tee",
                                            limit: 22)
        XCTAssertTrue(out.hasSuffix("…"))
        XCTAssertFalse(out.dropLast().hasSuffix(" "))
        XCTAssertLessThanOrEqual(out.count, 24)
        XCTAssertTrue("steve hit driver into the left bunker off the tee".hasPrefix(String(out.dropLast())))
    }

    func testAOneLongWordStillGetsCut() {
        let out = HoleMarker.abbreviate(String(repeating: "a", count: 60), limit: 10)
        XCTAssertEqual(out.count, 11)
    }
}
