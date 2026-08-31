import XCTest
@testable import GolfCourse
@testable import GolfMap

/// A leg's label, and what the big number measures to — both decided in code that
/// a screenshot cannot check, because both failures render as an ordinary number.
final class TrackAndPinTests: XCTestCase {

    private func hole() -> HoleGeometry {
        let tee = Coordinate(lat: 37.0, lon: -122.0)
        let green = Geodesy.point(from: tee, bearing: 0, distance: 400)
        let h = Hole(ref: "1", par: 4,
                     tees: [TeeBox(name: "white", at: tee)],
                     green: Green(center: green))
        return HoleGeometry(hole: h, tee: h.tees[0], teeAt: tee, greenCenter: green)
    }

    private func at(_ metres: Double) -> Coordinate {
        Geodesy.point(from: Coordinate(lat: 37.0, lon: -122.0), bearing: 0, distance: metres)
    }

    // MARK: - Which leg gets a number

    /// **2 to 3 is a shot**, and its length is how far that shot went — so it is
    /// the leg that gets a number *(user, 2026-08-28, correcting the first reading
    /// of this rule)*.
    func testConsecutiveShotsAreLabelled() {
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [.init(number: 2, at: at(200)),
                                    .init(number: 3, at: at(320))])
        XCTAssertEqual(t.legs.count, 1)
        XCTAssertTrue(t.legs[0].consecutive)
    }

    /// 1 to 3 with no 2 measures nothing anybody played, so it says nothing.
    func testALegAcrossAMissingShotIsNotLabelled() {
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [.init(number: 1, at: at(200)),
                                    .init(number: 3, at: at(340))])
        XCTAssertFalse(t.legs[0].consecutive)
    }

    /// Positions with no numbering: nothing can be told about them, so nothing is
    /// claimed.
    func testUnnumberedShotsNeverLabel() {
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [at(200), at(320), at(360)])
        XCTAssertEqual(t.legs.count, 2)
        XCTAssertTrue(t.legs.allSatisfy { !$0.consecutive })
    }

    /// A mixed track labels only the legs that are a shot: 1→2 yes, 2→4 no.
    func testOnlyTheConsecutiveLegOfAMixedTrackIsLabelled() {
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [.init(number: 1, at: at(150)),
                                    .init(number: 2, at: at(300)),
                                    .init(number: 4, at: at(380))])
        XCTAssertEqual(t.legs.map(\.consecutive), [true, false])
    }

    func testOneShotHasNoLegs() {
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [.init(number: 1, at: at(200))])
        XCTAssertTrue(t.legs.isEmpty)
        XCTAssertEqual(t.points.count, 1)
    }

    // MARK: - What the big number measures to

    func testWithNoPinTheApproachEndsAtTheGreenCentre() {
        let g = hole()
        let r = HoleReadout(geometry: g, player: at(100))
        XCTAssertFalse(r.measuringToPin)
        XCTAssertEqual(r.approach.metres, 300, accuracy: 1)
        XCTAssertEqual(r.green.center, 300, accuracy: 1)
    }

    /// A flag cut 15 m short of the middle is 15 m nearer, and the caption has to
    /// be able to say so — a number measured to the pin under a "TO GREEN" label
    /// is the `defaultTee` failure in a different field.
    func testAPinMovesTheCentreNumberAndSaysSo() {
        let g = hole()
        let pin = at(385)
        let r = HoleReadout(geometry: g, player: at(100), pin: pin)
        XCTAssertTrue(r.measuringToPin)
        XCTAssertEqual(r.approach.metres, 285, accuracy: 1)
        XCTAssertEqual(r.green.center, 285, accuracy: 1)
        XCTAssertEqual(r.approach.to, pin)
    }

    /// Front and back are the green *outline* and do not move with the flag.
    func testAPinLeavesFrontAndBackAlone() {
        let g = hole()
        let plain = HoleReadout(geometry: g, player: at(100))
        let pinned = HoleReadout(geometry: g, player: at(100), pin: at(385))
        XCTAssertEqual(plain.green.front, pinned.green.front, accuracy: 0.001)
        XCTAssertEqual(plain.green.back, pinned.green.back, accuracy: 0.001)
    }

    /// With a target placed, the approach still starts at the target — the pin
    /// changes where a leg ends, never where it begins.
    func testAPinDoesNotChangeWhereTheApproachStarts() {
        let g = hole()
        let target = at(250)
        let r = HoleReadout(geometry: g, player: at(0), targets: [target], pin: at(390))
        XCTAssertEqual(r.approach.from, target)
        XCTAssertEqual(r.approach.metres, 140, accuracy: 1)
    }
}
