import XCTest
@testable import GolfCourse

/// `unproject` is the inverse of `project`, and every touch interaction on the
/// vector layer depends on the two staying a matched pair — including under the
/// user's own pan and zoom.
final class HolePlaneTests: XCTestCase {

    var geo: HoleGeometry {
        SampleCourse.naelgol.hole("7")!.geometry()!
    }
    private let size = (width: 390.0, height: 780.0)

    func testUnprojectRoundTripsProject() {
        let plane = HolePlane(geometry: geo, size: size)
        for c in geo.hole.line + geo.hole.green.polygon + [geo.teeAt, geo.greenCenter] {
            let p = plane.project(c)
            let back = plane.unproject(x: p.x, y: p.y)
            XCTAssertEqual(Geodesy.distance(c, back), 0, accuracy: 0.05,
                           "round trip drifted at \(p)")
        }
    }

    /// The failure this whole design exists to prevent: a `.scaleEffect` on the
    /// Canvas would move the pixels while `project`/`unproject` still described the
    /// unzoomed layout, so a tap would land somewhere other than the finger — and
    /// it would look perfectly right until someone placed a target while zoomed.
    func testUnprojectStillInvertsProjectUnderPanAndZoom() {
        for view in [HolePlane.View(zoom: 2.5, panX: 40, panY: -80),
                     HolePlane.View(zoom: 0.7, panX: -25, panY: 60),
                     HolePlane.View(zoom: 6, panX: 0, panY: 0)] {
            let plane = HolePlane(geometry: geo, size: size, viewport: view)
            for c in [geo.teeAt, geo.greenCenter] + geo.hole.line {
                let p = plane.project(c)
                let back = plane.unproject(x: p.x, y: p.y)
                XCTAssertEqual(Geodesy.distance(c, back), 0, accuracy: 0.05,
                               "zoom \(view.zoom) pan \(view.panX),\(view.panY)")
            }
        }
    }

    /// A tap is a point on the ground, not a point in the air. Inheriting the tee's
    /// altitude — which `Geodesy.coordinate` does by default — would feed a
    /// plays-like number that nothing measured.
    func testUnprojectedPointsCarryNoAltitude() {
        let plane = HolePlane(geometry: geo, size: size)
        XCTAssertNotNil(geo.teeAt.alt, "fixture must have an altitude to make this meaningful")
        XCTAssertNil(plane.unproject(x: 195, y: 400).alt)
    }

    /// Zooming must not walk the hole toward a corner: the centre of the screen
    /// keeps showing the same place.
    func testZoomIsAboutTheCentreOfTheView() {
        let fitted = HolePlane(geometry: geo, size: size)
        let centre = fitted.unproject(x: size.width / 2, y: size.height / 2)
        for z in [1.5, 3.0, 6.0] {
            let zoomed = HolePlane(geometry: geo, size: size, viewport: .init(zoom: z))
            let c2 = zoomed.unproject(x: size.width / 2, y: size.height / 2)
            XCTAssertEqual(Geodesy.distance(centre, c2), 0, accuracy: 1.5, "zoom \(z) drifted")
        }
    }

    /// Zoom is clamped; **pan is not**. Holding pan to half a screen made "go to my
    /// location" impossible whenever the golfer was not standing on the hole they
    /// were looking at — which is most of the time, and exactly when they want to
    /// see where they are relative to it. `Fit hole to screen` is the way back.
    func testZoomIsClampedAndPanIsNot() {
        let v = HolePlane.View(zoom: 99, panX: 99_999, panY: -99_999).clamped(size: size)
        XCTAssertEqual(v.zoom, HolePlane.View.zoomRange.upperBound)
        XCTAssertEqual(v.panX, 99_999)
        XCTAssertEqual(v.panY, -99_999)
        XCTAssertEqual(HolePlane.View(zoom: 0.01).clamped(size: size).zoom,
                       HolePlane.View.zoomRange.lowerBound)
    }

    /// A pan big enough to put a fix in another county on screen has to survive the
    /// round trip, or the recentre silently lands somewhere else.
    func testAVeryLargePanStillProjectsAndUnprojectsConsistently() {
        let plane = HolePlane(geometry: geo, size: size,
                              viewport: .init(zoom: 1, panX: 40_000, panY: -25_000))
        let p = plane.project(geo.greenCenter)
        XCTAssertEqual(Geodesy.distance(plane.unproject(x: p.x, y: p.y), geo.greenCenter),
                       0, accuracy: 0.05)
    }

    /// Zooming in must magnify. Sounds tautological; it is the assertion that fails
    /// if the transform is ever folded in the wrong order.
    func testZoomingInIncreasesPointsPerMetre() {
        let a = HolePlane(geometry: geo, size: size)
        let b = HolePlane(geometry: geo, size: size, viewport: .init(zoom: 3))
        XCTAssertEqual(b.scale / a.scale, 3, accuracy: 0.001)
    }
}

extension HolePlaneTests {
    /// The vector layer scrolled the opposite way to the finger. `View.panY` is
    /// screen-oriented — positive moves the hole *down*, the way `y` grows — and the
    /// gesture was negating it.
    func testPositivePanYMovesTheHoleDownTheScreen() {
        let size = (width: 390.0, height: 780.0)
        let fitted = HolePlane(geometry: geo, size: size)
        let panned = HolePlane(geometry: geo, size: size, viewport: .init(panY: 60))
        XCTAssertEqual(panned.project(geo.teeAt).y - fitted.project(geo.teeAt).y, 60,
                       accuracy: 0.01)
        XCTAssertEqual(panned.project(geo.greenCenter).y - fitted.project(geo.greenCenter).y,
                       60, accuracy: 0.01)
    }

    func testPositivePanXMovesTheHoleRight() {
        let size = (width: 390.0, height: 780.0)
        let fitted = HolePlane(geometry: geo, size: size)
        let panned = HolePlane(geometry: geo, size: size, viewport: .init(panX: 45))
        XCTAssertEqual(panned.project(geo.teeAt).x - fitted.project(geo.teeAt).x, 45,
                       accuracy: 0.01)
    }

    /// **A pinch zooms about the fingers.** *(User, 2026-08-29: "zoom to 40x
    /// doesn't seem to work".)* Zooming about the middle of the layout throws the
    /// green being read off the screen long before 40×, which is indistinguishable
    /// from the zoom refusing to go there. The ground under the pinch point must
    /// still be under the pinch point afterwards.
    func testZoomingAboutAPointKeepsThatPointOverTheSameGround() {
        let start = HolePlane(geometry: geo, size: size)
        for anchor in [(x: 100.0, y: 200.0), (x: 300.0, y: 640.0), (x: 195.0, y: 390.0)] {
            let ground = start.unproject(x: anchor.x, y: anchor.y)
            var plane = start
            // Several steps, the way a real pinch arrives, so an error that only
            // shows up when compounded cannot hide.
            for z in [2.0, 8.0, 25.0, 40.0] {
                plane = HolePlane(geometry: geo, size: size,
                                  viewport: plane.zooming(to: z, about: anchor))
                let q = plane.project(ground)
                XCTAssertEqual(q.x, anchor.x, accuracy: 0.5, "zoom \(z) at \(anchor)")
                XCTAssertEqual(q.y, anchor.y, accuracy: 0.5, "zoom \(z) at \(anchor)")
            }
        }
    }

    /// The ceiling still holds, and past it the point stays pinned rather than
    /// drifting — a pinch that keeps going should stop scaling, not start sliding.
    func testZoomingAboutAPointIsClampedToTheZoomRange() {
        let plane = HolePlane(geometry: geo, size: size)
        let v = plane.zooming(to: 500, about: (x: 120, y: 300))
        XCTAssertEqual(v.zoom, HolePlane.View.zoomRange.upperBound)
        let ground = plane.unproject(x: 120, y: 300)
        let q = HolePlane(geometry: geo, size: size, viewport: v).project(ground)
        XCTAssertEqual(q.x, 120, accuracy: 0.5)
        XCTAssertEqual(q.y, 300, accuracy: 0.5)
    }

    /// **40× is a putting scale, and the number that matters is the span it gives.**
    /// The ceiling was raised from 8 for exactly one reason (user: "side span is
    /// about 45 yards, I want it to be around 10 yards"), so assert the yards
    /// rather than the factor — a later change to the fit could satisfy the factor
    /// and lose the reason for it.
    func testFullZoomReadsAPuttingScale() {
        let plane = HolePlane(geometry: geo, size: size,
                              viewport: .init(zoom: HolePlane.View.zoomRange.upperBound))
        let left = plane.unproject(x: 0, y: size.height / 2)
        let right = plane.unproject(x: size.width, y: size.height / 2)
        let yards = Geodesy.distance(left, right) * 1.09361
        XCTAssertLessThan(yards, 15, "side span at full zoom is \(yards) yd")
    }
}
