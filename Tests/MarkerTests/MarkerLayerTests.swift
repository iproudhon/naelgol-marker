import XCTest
import GolfCourse
@testable import GolfMap

/// The markers layer's own state, `GroundView`, and the legend's numbers.
final class MarkerLayerTests: XCTestCase {

    /// Three states, and the cycle the button walks *(user, 2026-08-29)*. The middle
    /// one is the point: **drawn, and not touchable**.
    func testTheDisplayCyclesOnGhostOff() {
        XCTAssertEqual(MarkerDisplay.on.next, .ghost)
        XCTAssertEqual(MarkerDisplay.ghost.next, .off)
        XCTAssertEqual(MarkerDisplay.off.next, .on)

        XCTAssertTrue(MarkerDisplay.on.isVisible)
        XCTAssertTrue(MarkerDisplay.on.isInteractive)
        XCTAssertTrue(MarkerDisplay.ghost.isVisible)
        XCTAssertFalse(MarkerDisplay.ghost.isInteractive)
        XCTAssertFalse(MarkerDisplay.off.isVisible)
        XCTAssertFalse(MarkerDisplay.off.isInteractive)

        // Half transparent is the only signal the layer has stopped responding, so
        // it has to be visibly less than on and visibly more than gone.
        XCTAssertLessThan(MarkerDisplay.ghost.opacity, MarkerDisplay.on.opacity)
        XCTAssertGreaterThan(MarkerDisplay.ghost.opacity, 0)
    }

    /// **The legend counts shots *taken*, so a player on the tee reads 0** *(user,
    /// 2026-08-29: "it should be shots taken, so it should start with 0, not 1")* —
    /// while the button still files the *next* number. The two differ by one on
    /// purpose: the number answers "where am I in this hole", not "what will this
    /// write".
    func testTheLegendCountsShotsTakenAndTheButtonFilesTheNextOne() {
        let none: [PlayerTrack.Shot] = []
        let onTheTee = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                                   shots: none, nextShot: 1)
        XCTAssertEqual(onTheTee.shotsTaken, 0)
        XCTAssertEqual(onTheTee.nextShot, 1)

        let at = Coordinate(lat: 37.74, lon: -122.26)
        let playing = PlayerTrack(id: "dave", name: "dave", colorIndex: 1,
                                  shots: [.init(number: 1, at: at), .init(number: 2, at: at)],
                                  nextShot: 3)
        XCTAssertEqual(playing.shotsTaken, 2)

        // Never negative, whatever a caller passes.
        XCTAssertEqual(PlayerTrack(id: "x", name: "x", colorIndex: 0, shots: none,
                                   nextShot: 0).shotsTaken, 0)
        // No numbering at all is still no answer, not zero.
        XCTAssertNil(PlayerTrack(id: "y", name: "y", colorIndex: 0, shots: none).shotsTaken)
    }

    /// **Holed out is having a score, and the sign is what says so** *(user,
    /// 2026-08-29: "# shown is delta from par, e.g. -1, +0, +1")*.
    ///
    /// `+0` literally — a bare `0` in this cell is indistinguishable from "no shots
    /// logged yet", which is the other thing the same glyph means.
    func testAClosedHolePrintsTheScoreToParWithASign() {
        let none: [PlayerTrack.Shot] = []
        var t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: none, nextShot: 4)
        XCTAssertFalse(t.holedOut)
        XCTAssertNil(t.toPar(4), "an open hole has nothing to print to par")
        XCTAssertEqual(t.shotsTaken, 3)

        t.score = 3
        XCTAssertTrue(t.holedOut)
        XCTAssertEqual(t.toPar(4), "-1")
        t.score = 4
        XCTAssertEqual(t.toPar(4), "+0")
        t.score = 6
        XCTAssertEqual(t.toPar(4), "+2")
        t.score = 2
        XCTAssertEqual(t.toPar(5), "-3")
    }

    /// A score and the shots logged are **different numbers**, and the legend can
    /// show either — so neither may be derived from the other. Closing out commits
    /// the number already on screen (`shotsTaken`, because the holing-out stroke is
    /// the last marker the golfer filed), and a score corrected by hand afterwards
    /// can differ from it by any amount.
    func testAScoreIsNotDerivedFromTheShotsLogged() {
        let at = Coordinate(lat: 37.74, lon: -122.26)
        let t = PlayerTrack(id: "dave", name: "dave", colorIndex: 1,
                            shots: [.init(number: 1, at: at), .init(number: 2, at: at)],
                            nextShot: 3, score: 4)
        XCTAssertEqual(t.shotsTaken, 2)
        XCTAssertEqual(t.score, 4)
        XCTAssertEqual(t.toPar(4), "+0")
    }

    /// **A shot is named, not numbered, on screen** *(user, 2026-08-29: "tee off:
    /// T, #1: 1, #2: 2, #3/holeout: 3")*. Stored numbering is untouched; this is
    /// the one place the offset lives.
    func testAShotIsNamedTFirstAndThenNumberedFromOne() {
        XCTAssertEqual(ShotName.of(1), "T")
        XCTAssertEqual(ShotName.of(2), "1")
        XCTAssertEqual(ShotName.of(5), "4")
        // Nothing should ever ask, but a zero or a negative must not print "-1".
        XCTAssertEqual(ShotName.of(0), "T")

        // **The name and nothing else** *(user, 2026-08-30: "no club icon or name.
        // Just show shot # in circle. Color is good enough to distinguish.")* The
        // player's name used to follow it; the colour already says whose it is and
        // the legend already names the colours.
        let at = Coordinate(lat: 37.74, lon: -122.26)
        XCTAssertEqual(HoleMarker(id: "a", at: at, label: "x", shot: 1,
                                  player: "steve").title, "T")
        XCTAssertEqual(HoleMarker(id: "b", at: at, label: "x", shot: 3,
                                  player: "steve").title, "2")
        // And a shot draws as a circle rather than a pill.
        XCTAssertTrue(HoleMarker(id: "a", at: at, label: "x", shot: 1).isShot)
        XCTAssertFalse(HoleMarker(id: "c", at: at, label: "in the water").isShot)
        // Not a shot at all — the sentence, untouched.
        XCTAssertEqual(HoleMarker(id: "c", at: at, label: "in the water").title,
                       "in the water")
    }

    /// **A closed-out hole runs its track into the flag** *(user, 2026-08-29:
    /// "when holed out, line segment extends to the pin")*, and the number on that
    /// leg is gated the same way every other leg is: only when it spans exactly one
    /// shot.
    func testAClosedHoleRunsItsTrackIntoTheFlag() {
        let tee = Coordinate(lat: 37.7374, lon: -122.2317)
        let up = Coordinate(lat: 37.7362, lon: -122.2306)
        let pin = Coordinate(lat: 37.7357, lon: -122.2299)

        // Open: nothing says the ball ever reached the hole.
        var t = PlayerTrack(id: "min", name: "min", colorIndex: 2,
                            shots: [.init(number: 1, at: tee), .init(number: 2, at: up)],
                            nextShot: 3)
        XCTAssertNil(t.closingLeg(to: pin))

        // Closed, and the last marker *is* the holing-out stroke: one shot spans
        // marker to cup, so the leg carries its length.
        t.score = 2
        let leg = t.closingLeg(to: pin)
        XCTAssertEqual(leg?.from, up)
        XCTAssertEqual(leg?.to, pin)
        XCTAssertEqual(leg?.labelled, true)

        // Closed with strokes nobody logged in between — a line across a gap in
        // the record measures nothing anybody played.
        t.score = 6
        XCTAssertEqual(t.closingLeg(to: pin)?.labelled, false)
    }

    /// **A hole in one is one marker and a closing leg**, which is the case the
    /// floorless swipe made reachable — and the case an early `guard shots.count
    /// >= 2` in the vector renderer used to throw away whole.
    func testAHoleInOneStillHasATrack() {
        let tee = Coordinate(lat: 37.7374, lon: -122.2317)
        let pin = Coordinate(lat: 37.7357, lon: -122.2299)
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: [.init(number: 1, at: tee)], nextShot: 2, score: 1)
        XCTAssertEqual(t.shotsTaken, 1)
        XCTAssertTrue(t.legs.isEmpty, "one shot is one end of a line, so no legs")
        XCTAssertEqual(t.closingLeg(to: pin)?.labelled, true)
        XCTAssertEqual(t.toPar(3), "-2")
        // The pin is never fed to the framing fit.
        XCTAssertEqual(t.allPoints, [tee])
    }

    /// A delta measured against a par of zero is an ordinary-looking number that is
    /// wrong — the same shape as a tee answering with another tee's yardage. The
    /// cell falls back to the shot count instead.
    func testAParOfZeroPrintsNoDelta() {
        let none: [PlayerTrack.Shot] = []
        let t = PlayerTrack(id: "steve", name: "steve", colorIndex: 0,
                            shots: none, nextShot: 5, score: 4)
        XCTAssertNil(t.toPar(0))
        XCTAssertEqual(t.toPar(4), "+0")
    }

    private var geo: HoleGeometry { SampleCourse.naelgol.hole("7")!.geometry()! }
    private let size = (width: 390.0, height: 780.0)

    private func groundView(_ plane: HolePlane) -> GroundView {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            .map { plane.unproject(x: $0.x, y: $0.y) }
        return GroundView(center: plane.unproject(x: size.width / 2, y: size.height / 2),
                          corners: corners)
    }

    /// **A quad, not a bounding box.** The hole is rotated so the tee is at the
    /// bottom, so a lat/lon box around the screen sticks out past its corners — and
    /// would call a tee visible while it sat off the edge of the display, which is
    /// the one question this type exists to answer.
    func testTheVisibleQuadFollowsTheScreenNotItsBoundingBox() {
        let view = groundView(HolePlane(geometry: geo, size: size))
        XCTAssertTrue(view.contains(view.center))
        XCTAssertTrue(view.contains(geo.teeAt), "the tee is on screen when the hole is fitted")

        // A point well outside, in the direction the box would have swallowed.
        let far = Geodesy.coordinate(from: geo.teeAt, east: 4_000, north: 4_000, alt: nil)
        XCTAssertFalse(view.contains(Coordinate(lat: far.lat, lon: far.lon)))
    }

    /// Zoomed in on the green, the tee is no longer on screen — which is exactly
    /// when a simulated position must be seeded from the middle of the view instead.
    func testAZoomedViewNoLongerContainsTheTee() {
        let view = groundView(HolePlane(geometry: geo, size: size,
                                        viewport: .init(zoom: 20, panX: 0, panY: 0)))
        XCTAssertFalse(view.contains(geo.teeAt))
        XCTAssertTrue(view.contains(view.center))
    }
}
