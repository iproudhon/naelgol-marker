#if canImport(SwiftUI)
import Foundation
import GolfCourse

/// What ground is on screen right now, reported **up** from whichever renderer is
/// drawing — the vector plane or MapKit's camera.
///
/// It exists for one question *(user, 2026-08-29: "simulate position initial
/// position — if tee is visible, at the given tee; if not, the center of screen",
/// restated the same day as "not geo positioning … this is what I want")*, and that
/// question cannot be answered by `HoleScreen` on its own: the vector layer's pan
/// and zoom live in a `HolePlane` built inside `VectorHoleView`, and the satellite
/// layer's camera is MapKit's. Re-deriving either in the screen would be a second
/// copy of the transform that can disagree with the one on screen — the same failure
/// `PlanLayout` exists to prevent one layer down.
///
/// **A quad, not a lat/lon box.** The vector layer rotates the hole so the tee is
/// at the bottom, so a screen rectangle is a *rotated* quadrilateral on the ground;
/// its bounding box would call a tee visible while it sat off the corner of the
/// display. The satellite layer does not rotate, so there its quad is the box.
public struct GroundView: Equatable, Sendable {
    /// The middle of the map area — where a simulated position goes when the tee is
    /// nowhere to be seen.
    public var center: Coordinate
    /// The four corners of the visible area, in order around the edge.
    public var corners: [Coordinate]

    public init(center: Coordinate, corners: [Coordinate]) {
        self.center = center
        self.corners = corners
    }

    /// Is this point on screen? A convex point-in-polygon test on lat/lon, which is
    /// exact enough at hole scale — the corners are metres apart, not degrees.
    public func contains(_ c: Coordinate) -> Bool {
        guard corners.count >= 3 else { return false }
        var sign = 0
        for (a, b) in zip(corners, corners.dropFirst() + corners.prefix(1)) {
            let cross = (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon)
            if abs(cross) < 1e-12 { continue }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if s != sign { return false }
        }
        return true
    }

    public static func == (a: GroundView, b: GroundView) -> Bool {
        a.center.lat == b.center.lat && a.center.lon == b.center.lon
            && a.corners.count == b.corners.count
            && zip(a.corners, b.corners).allSatisfy { $0.lat == $1.lat && $0.lon == $1.lon }
    }
}
#endif
