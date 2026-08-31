#if canImport(SwiftUI)
import Foundation
import GolfCourse

/// A two-ended ruler laid on the hole.
///
/// *(X6, user 2026-08-28: "place two points (or line segment) horizontally with the
/// first target as center … show distance between two points in the middle of the
/// line … clicking again create a new line segment".)*
///
/// **Separate from a target, because it answers a different question.** A target is
/// a point a shot is aimed at, and every distance on the hole is measured *to* it
/// from the player or from the previous target. A measure is a distance between two
/// arbitrary points that has nothing to do with where the golfer is standing — how
/// wide the fairway is at the corner, how far the bunker carries. Folding it into
/// the target chain would put a point in the shot sequence that is not a shot.
public struct MeasureSegment: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var a: Coordinate
    public var b: Coordinate
    /// Which colour of `HoleStyle.measureColors` this one is drawn in.
    ///
    /// **Carried on the segment, not derived from its position in the array**
    /// *(X10, user 2026-08-28: "assign new colors, but set, to a new line
    /// segment")*. Indexing by array position recolours every surviving segment
    /// the moment an earlier one is dismissed — the ruler you are reading changes
    /// colour because of something you did to a different ruler.
    public var colorIndex: Int

    public init(id: UUID = UUID(), a: Coordinate, b: Coordinate, colorIndex: Int = 0) {
        self.id = id; self.a = a; self.b = b; self.colorIndex = colorIndex
    }

    public var length: Double { Geodesy.distance(a, b) }

    /// The label's anchor: the middle of the line.
    public var midpoint: Coordinate { Geodesy.interpolate(a, b, 0.5) }

    /// A ruler laid **across** the hole, centred on `centre`.
    ///
    /// Horizontal in the golfer's frame, not the world's: the hole is drawn with the
    /// tee at the bottom and the green at the top, so "horizontal" means square to
    /// the line of play. A ruler laid along true east–west would sit at a different
    /// angle on every hole of the course and look like a mistake on most of them.
    public static func across(_ centre: Coordinate, bearing: Double,
                              span: Double = 60,
                              colorIndex: Int = 0) -> MeasureSegment {
        let perpendicular = bearing + 90
        return MeasureSegment(
            a: Geodesy.point(from: centre, bearing: perpendicular, distance: span / 2),
            b: Geodesy.point(from: centre, bearing: perpendicular + 180, distance: span / 2),
            colorIndex: colorIndex)
    }

    /// Move the whole ruler, both ends together, so its midpoint lands on `c`.
    ///
    /// **This is what the distance box drags** *(X10, user 2026-08-28: "cannot drag
    /// by distance box right now")*. The documented objection to a distance box as a
    /// drag handle — "the box is repositioned as its number changes, so the handle
    /// crawls out from under the thumb mid-drag" — is about a *target*, whose
    /// distance changes as it moves. A rigid translation holds the length, so the
    /// number and the box are exactly as wide at the end of the drag as at the
    /// start and the handle stays under the finger. Do not delete this citing that
    /// invariant.
    public mutating func center(on c: Coordinate) {
        let mid = midpoint
        let d = Geodesy.distance(mid, c)
        guard d > 0 else { return }
        let bearing = Geodesy.bearing(from: mid, to: c)
        a = Geodesy.point(from: a, bearing: bearing, distance: d)
        b = Geodesy.point(from: b, bearing: bearing, distance: d)
    }

    public mutating func move(end: End, to c: Coordinate) {
        switch end {
        case .a: a = c
        case .b: b = c
        }
    }

    public enum End: Sendable, Hashable { case a, b }
}
#endif
