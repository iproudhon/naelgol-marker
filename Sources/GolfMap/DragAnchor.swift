#if canImport(SwiftUI)
import Foundation
import CoreGraphics

/// Holds the gap between a finger and the thing it picked up.
///
/// **This is what makes a drag a drag.** Without it, the first event of a gesture
/// moves the object's centre to the fingertip — so grabbing anything at all shifts
/// it, and nudging a target by ten yards is impossible because touching it has
/// already moved it further than that. The gap is measured once, when the finger
/// goes down, and every later position is derived from it.
public struct DragAnchor: Sendable, Equatable {
    public var dx: Double
    public var dy: Double

    /// - Parameters:
    ///   - object: where the thing being dragged is, in screen points.
    ///   - finger: where the finger went down.
    public init(object: CGPoint, finger: CGPoint) {
        dx = object.x - finger.x
        dy = object.y - finger.y
    }

    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }

    /// Where the object belongs now that the finger is here.
    public func object(forFinger finger: CGPoint) -> CGPoint {
        CGPoint(x: finger.x + dx, y: finger.y + dy)
    }
}
#endif
