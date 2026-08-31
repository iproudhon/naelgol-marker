import XCTest
import CoreGraphics
@testable import GolfCourse
@testable import GolfMap

/// The difference between dragging something and placing it under your finger.
final class DragAnchorTests: XCTestCase {

    /// Grabbing an object off-centre must not move it. This is the bug: the first
    /// event of the gesture used to set the object's centre to the fingertip, so
    /// picking a target up shifted it before the drag had begun.
    func testGrabbingOffCentreDoesNotMoveTheObject() {
        let object = CGPoint(x: 200, y: 300)
        let finger = CGPoint(x: 228, y: 276)
        let a = DragAnchor(object: object, finger: finger)
        XCTAssertEqual(a.object(forFinger: finger).x, object.x, accuracy: 0.001)
        XCTAssertEqual(a.object(forFinger: finger).y, object.y, accuracy: 0.001)
    }

    /// The gap is constant for the whole drag: the object travels exactly as far as
    /// the finger does, in the same direction.
    func testTheObjectTracksTheFingerOneToOne() {
        let a = DragAnchor(object: CGPoint(x: 200, y: 300), finger: CGPoint(x: 228, y: 276))
        let moved = a.object(forFinger: CGPoint(x: 228 + 60, y: 276 - 45))
        XCTAssertEqual(moved.x, 260, accuracy: 0.001)
        XCTAssertEqual(moved.y, 255, accuracy: 0.001)
    }

    func testGrabbingDeadCentreIsTheIdentity() {
        let c = CGPoint(x: 111, y: 222)
        let a = DragAnchor(object: c, finger: c)
        XCTAssertEqual(a.dx, 0); XCTAssertEqual(a.dy, 0)
        XCTAssertEqual(a.object(forFinger: CGPoint(x: 50, y: 60)), CGPoint(x: 50, y: 60))
    }

    /// End to end through the projection the vector layer actually uses: grab a
    /// target near the edge of its handle, drag, and the coordinate must move by the
    /// same ground distance the finger moved — not jump by the grab offset.
    func testThroughTheHolePlaneTheGroundMoveMatchesTheFingerMove() throws {
        let geo = try XCTUnwrap(SampleCourse.naelgol.hole("7")?.geometry())
        let plane = HolePlane(geometry: geo, size: (width: 390, height: 800))
        let target = SampleCourse.step(geo.teeAt, geo.bearing, 180)
        let q = plane.project(target)
        // Finger lands 30 points up-left of the target's centre, inside the handle.
        let finger = CGPoint(x: q.x - 21, y: q.y - 21)
        let a = DragAnchor(object: CGPoint(x: q.x, y: q.y), finger: finger)

        let atGrab = a.object(forFinger: finger)
        XCTAssertEqual(Geodesy.distance(plane.unproject(x: atGrab.x, y: atGrab.y), target),
                       0, accuracy: 0.05, "the grab itself moved the target")

        let moved = a.object(forFinger: CGPoint(x: finger.x + 40, y: finger.y))
        let movedGround = plane.unproject(x: moved.x, y: moved.y)
        XCTAssertEqual(Geodesy.distance(movedGround, target), 40 / plane.scale, accuracy: 0.2)
    }
}
