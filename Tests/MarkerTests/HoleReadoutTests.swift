import XCTest
@testable import GolfCourse
@testable import GolfMap

/// The numbers on the hole screen, without a simulator. These are the two things
/// most likely to be quietly wrong — what a distance is measured *from*, and what a
/// chain of targets adds up to — and neither is checkable by looking at a render.
final class HoleReadoutTests: XCTestCase {

    private var geo: HoleGeometry { SampleCourse.naelgol.hole("7")!.geometry()! }

    // MARK: - Where the number is measured from

    func testNoFixMeasuresFromTheChosenTee() {
        let r = HoleReadout(geometry: geo, player: nil)
        guard case .tee(let name, let at) = r.origin else { return XCTFail("expected tee origin") }
        XCTAssertEqual(name, geo.tee.name)
        XCTAssertEqual(Geodesy.distance(at, geo.teeAt), 0, accuracy: 0.1)
        XCTAssertFalse(r.origin.isPlayer)
    }

    func testAFixOnTheHoleMeasuresFromThePlayer() {
        let p = SampleCourse.step(geo.teeAt, geo.bearing, 180)
        let r = HoleReadout(geometry: geo, player: p)
        XCTAssertTrue(r.origin.isPlayer)
        XCTAssertEqual(Geodesy.distance(r.origin.coordinate, p), 0, accuracy: 0.1)
    }

    /// The case the fallback exists for: the phone has a fix, but it is at home or
    /// on another course. Measuring from there is not wrong so much as useless, and
    /// a huge number is how a golfer finds out the app is confused.
    func testAFixNowhereNearTheHoleFallsBackToTheTee() {
        let far = SampleCourse.step(geo.teeAt, 90, 4_000)
        XCTAssertFalse(HoleReadout(geometry: geo, player: far).origin.isPlayer)
    }

    /// Generous on purpose — standing on the next fairway over, the distance from
    /// where you actually are is still the useful one.
    func testAFixOnTheAdjacentHoleStillMeasuresFromThePlayer() {
        let beside = SampleCourse.step(SampleCourse.step(geo.teeAt, geo.bearing, 150),
                                       geo.bearing + 90, 80)
        XCTAssertTrue(HoleReadout(geometry: geo, player: beside).origin.isPlayer)
    }

    // MARK: - Targets

    func testWithNoTargetsThereIsOneLegAndItEndsAtTheGreen() {
        let r = HoleReadout(geometry: geo, player: nil)
        XCTAssertEqual(r.legs.count, 1)
        XCTAssertEqual(r.legs[0].kind, .toGreen)
        XCTAssertFalse(r.hasTargets)
        // A leg is a **shot**, so it is straight-line. `measuredLength` walks the
        // dogleg and is the card's hole length — a different number on purpose, and
        // on this hole a 15 m difference. Nobody carries the corner of a dogleg.
        XCTAssertEqual(r.approach.metres,
                       Geodesy.distance(geo.teeAt, geo.greenCenter), accuracy: 0.1)
        XCTAssertLessThan(r.approach.metres, geo.measuredLength - 10)
    }

    func testOneTargetSplitsTheHoleIntoTwoLegs() {
        let t = SampleCourse.step(geo.teeAt, geo.bearing, 200)
        let r = HoleReadout(geometry: geo, player: nil, targets: [t])
        XCTAssertEqual(r.legs.map(\.kind), [.toTarget(0), .toGreen])
        XCTAssertEqual(r.legs[0].metres, 200, accuracy: 1)
        XCTAssertEqual(r.legs[1].metres, Geodesy.distance(t, geo.greenCenter), accuracy: 0.1)
    }

    /// The feature no app in the category ships (research-course-display.md §9.3):
    /// lay up, then carry, then what is left.
    func testTwoTargetsChainOriginToT1ToT2ToPin() {
        let t1 = SampleCourse.step(geo.teeAt, geo.bearing, 180)
        let t2 = SampleCourse.step(geo.teeAt, geo.bearing, 300)
        let r = HoleReadout(geometry: geo, player: nil, targets: [t1, t2])
        XCTAssertEqual(r.legs.map(\.kind), [.toTarget(0), .toTarget(1), .toGreen])
        XCTAssertEqual(r.legs[0].metres, 180, accuracy: 1)
        XCTAssertEqual(r.legs[1].metres, 120, accuracy: 1)
        // The legs must chain: each starts where the last one ended.
        for (a, b) in zip(r.legs, r.legs.dropFirst()) {
            XCTAssertEqual(Geodesy.distance(a.to, b.from), 0, accuracy: 0.01)
        }
    }

    /// Once a layup is planned, front/centre/back must be *what is left from there*,
    /// not from where the golfer is standing. Measuring from the origin would make
    /// the target purely decorative.
    func testGreenDistancesAreMeasuredFromTheLastTargetNotTheOrigin() {
        let t = SampleCourse.step(geo.teeAt, geo.bearing, 250)
        let plain = HoleReadout(geometry: geo, player: nil)
        let planned = HoleReadout(geometry: geo, player: nil, targets: [t])
        XCTAssertLessThan(planned.green.center, plain.green.center - 200)
        XCTAssertEqual(planned.green.center,
                       Geodesy.distance(t, geo.greenCenter), accuracy: 4)
        XCTAssertLessThan(planned.green.front, planned.green.center)
        XCTAssertLessThan(planned.green.center, planned.green.back)
    }

    /// Two is the cap. A third target is ignored rather than silently re-ordered or
    /// dropped from the middle.
    func testAThirdTargetIsIgnored() {
        let ts = (1...3).map { SampleCourse.step(geo.teeAt, geo.bearing, Double($0) * 90) }
        let r = HoleReadout(geometry: geo, player: nil, targets: ts)
        XCTAssertEqual(r.targets.count, 2)
        XCTAssertEqual(r.legs.count, 3)
        XCTAssertEqual(Geodesy.distance(r.targets[0], ts[0]), 0, accuracy: 0.01)
        XCTAssertEqual(Geodesy.distance(r.targets[1], ts[1]), 0, accuracy: 0.01)
    }

    // MARK: - Elevation

    func testPlaysLikeAppearsOnlyWhenThereIsElevation() throws {
        let r = HoleReadout(geometry: geo, player: nil)
        let rise = try XCTUnwrap(r.rise)
        XCTAssertEqual(rise, 8, accuracy: 0.5, "sample hole 7 climbs 8 m")
        XCTAssertEqual(try XCTUnwrap(r.playsLike()), r.green.center + rise, accuracy: 0.01)

        // A hole with no altitudes anywhere must produce no plays-like number
        // rather than one that reads as "flat".
        var flat = geo.hole
        flat.line = flat.line.map { Coordinate(lat: $0.lat, lon: $0.lon) }
        flat.green.center = Coordinate(lat: flat.green.center!.lat, lon: flat.green.center!.lon)
        flat.tees = flat.tees.map {
            var t = $0
            if let a = t.at { t.at = Coordinate(lat: a.lat, lon: a.lon) }
            return t
        }
        let flatReadout = HoleReadout(geometry: try XCTUnwrap(flat.geometry()), player: nil)
        XCTAssertNil(flatReadout.rise)
        XCTAssertNil(flatReadout.playsLike())
    }
}

extension HoleReadoutTests {
    /// `origin` answers "what is this distance measured from"; `playerAt` answers
    /// "where is the golfer". They diverge exactly when the fix is off this hole —
    /// and deriving the map marker from `origin` meant that case drew no marker at
    /// all, so "go to my location" panned to an empty patch of rough.
    func testPlayerAtSurvivesEvenWhenTheNumbersFallBackToTheTee() {
        let far = SampleCourse.step(geo.teeAt, 90, 40_000)
        let r = HoleReadout(geometry: geo, player: far)
        XCTAssertFalse(r.origin.isPlayer, "the numbers must still come off the tee")
        let at = r.playerAt
        XCTAssertNotNil(at, "the golfer is still somewhere")
        XCTAssertEqual(Geodesy.distance(at!, far), 0, accuracy: 0.1)
    }

    func testPlayerAtIsNilOnlyWhenThereIsNoFixAtAll() {
        XCTAssertNil(HoleReadout(geometry: geo, player: nil).playerAt)
        let on = SampleCourse.step(geo.teeAt, geo.bearing, 100)
        XCTAssertNotNil(HoleReadout(geometry: geo, player: on).playerAt)
    }
}
