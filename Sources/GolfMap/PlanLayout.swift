#if canImport(SwiftUI)
import Foundation
import CoreGraphics
import GolfCourse

/// Where each leg's distance box goes on screen.
///
/// **Pure, and shared by drawing and hit-testing.** The box is the drag handle for
/// its target — a 28-point ring is a poor thing to catch with a gloved thumb, and
/// the number beside it is the biggest thing on the hole — so the rectangle the
/// renderer fills and the rectangle the gesture tests *must* be the same rectangle.
/// Computing it once here is the only way to guarantee that; measuring text inside
/// `Canvas` and re-deriving it in the gesture is how they drift apart.
///
/// Text is measured arithmetically rather than through `GraphicsContext.resolve`
/// for the same reason: the gesture has no context, and a monospaced face has a
/// fixed advance, so the estimate is exact enough to be the definition.
public enum PlanLayout {

    /// Advance width of one character as a fraction of point size, for
    /// `.system(design: .monospaced)`.
    ///
    /// **0.618, measured, not 0.6 estimated.** `NSFont.monospacedSystemFont` reports
    /// exactly 0.618 em for every glyph these labels use — digits, space, `▲`, `▼`,
    /// `·` and `~` alike, which also settles the question the elevation suffix
    /// raised: those four are inside the monospaced face and do **not** fall back
    /// to a proportional one. At 0.6 the estimate ran 3% narrow, which `padX`
    /// absorbed at three characters and would not have at thirty. The box is the
    /// drag handle, so the rectangle has to hold the text it is drawn with.
    static let advance: Double = 0.618
    static let mainSize: Double = 14
    static let subSize: Double = 10
    static let padX: Double = 7
    static let padY: Double = 4

    public struct Label: Sendable, Equatable {
        /// Which leg this belongs to, and therefore which target it drags.
        public var leg: HoleReadout.Leg.Kind
        /// The target this box moves when dragged, or nil for a box that drags
        /// nothing (the approach leg's box belongs to the last target already, so
        /// only the final leg is nil when there are no targets).
        public var dragsTarget: Int?
        public var rect: CGRect
        public var main: String
        public var sub: String?
    }

    static func size(main: String, sub: String?) -> CGSize {
        let w = max(Double(main.count) * mainSize * advance,
                    Double(sub?.count ?? 0) * subSize * advance)
        let h = mainSize * 1.25 + (sub == nil ? 0 : subSize * 1.35)
        return CGSize(width: w + padX * 2, height: h + padY * 2)
    }

    /// - Parameter project: a coordinate to a screen point. Passed in rather than a
    ///   `HolePlane` so the satellite layer, which projects through `MapProxy`, can
    ///   use the identical placement rule.
    public static func labels(_ readout: HoleReadout,
                              display: DistanceDisplay,
                              project: (Coordinate) -> CGPoint) -> [Label] {
        guard readout.hasTargets else { return [] }

        // Rings and their badges are placed first so the boxes can dodge them.
        var occupied: [CGRect] = []
        for (i, t) in readout.targets.enumerated() {
            let q = project(t)
            occupied.append(CGRect(x: q.x - 18, y: q.y - 18, width: 36, height: 36))
            if readout.targets.count > 1 {
                occupied.append(CGRect(x: q.x + 13, y: q.y - 23, width: 18, height: 18))
                _ = i
            }
        }

        var out: [Label] = []
        for leg in readout.legs {
            let a = project(leg.from), b = project(leg.to)
            // Just the number, plus the elevation suffix when this leg is not
            // flat *(user, 2026-08-30)*. The unit is stated once under the big
            // distance at the top of the screen; repeating `YD` on every leg is
            // three more characters of box over the hole for nothing.
            //
            // **The box grows with it, and that is required rather than tolerated**
            // — the rectangle drawn is the rectangle the drag gesture tests, so a
            // suffix drawn outside the measured box would be a label the finger
            // falls through. The arrow is counted as one character like the rest;
            // `▲` is not a monospaced advance, so the estimate is a little narrow
            // there and `padX` absorbs it.
            let main = display.withPlays(leg.metres, rise: leg.rise)
            let sub: String? = leg.kind == .toGreen
                ? "F \(display.number(readout.green.front))   B \(display.number(readout.green.back))"
                : nil
            let sz = size(main: main, sub: sub)

            // **Always near the target, never near the flag.** For a leg that *ends*
            // at a target that means the far end; for the approach leg, which
            // *starts* at the last target, it means the near end. Anchoring both at
            // the far end put the approach number against the pin, where it reads as
            // a label on the green rather than on the shot.
            let anchors: [Double] = leg.kind == .toGreen ? [0.28, 0.4, 0.18, 0.52]
                                                         : [0.72, 0.6, 0.84, 0.48]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len, ny = dx / len

            var chosen: CGRect?
            outer: for t in anchors {
                for push in [24.0, -24, 38, -38, 54, -54] {
                    let c = CGPoint(x: a.x + dx * t + nx * push, y: a.y + dy * t + ny * push)
                    let r = CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2,
                                   width: sz.width, height: sz.height)
                    if !occupied.contains(where: { $0.intersects(r) }) { chosen = r; break outer }
                }
            }
            let rect = chosen ?? CGRect(
                x: a.x + dx * anchors[0] + nx * 68 - sz.width / 2,
                y: a.y + dy * anchors[0] + ny * 68 - sz.height / 2,
                width: sz.width, height: sz.height)
            occupied.append(rect)

            // Which target does dragging this box move? The one the leg is *about*:
            // the target it ends at, or for the approach leg the target it starts
            // from. That way every box on screen drags the target it is next to.
            let drags: Int? = {
                switch leg.kind {
                case .toTarget(let i): return i
                case .toGreen: return readout.targets.isEmpty ? nil : readout.targets.count - 1
                }
            }()
            out.append(Label(leg: leg.kind, dragsTarget: drags, rect: rect,
                             main: main, sub: sub))
        }
        return out
    }
}
#endif
