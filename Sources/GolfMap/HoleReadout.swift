#if canImport(SwiftUI)
import Foundation
import GolfCourse

/// Every number the hole view shows, worked out once, with no SwiftUI in sight.
///
/// The screen is a rendering of this. Keeping it a plain value means the two
/// things most likely to be quietly wrong — *what is this distance measured from*
/// and *what does a chain of targets add up to* — are testable without a simulator,
/// which matters here because gestures are not.
public struct HoleReadout: Sendable, Equatable {

    /// Where the distances are measured from.
    ///
    /// Not a cosmetic distinction. A number with no stated origin is worse than no
    /// number, so the screen always says which of these it is — but it says it the
    /// way the tee chip already does, not in a caption across the middle.
    public enum Origin: Sendable, Equatable {
        /// A real fix, near enough to this hole to be worth measuring from.
        case player(Coordinate)
        /// No fix, or a fix nowhere near this hole. Falls back to a tee, named so
        /// the screen can say which.
        case tee(name: String, at: Coordinate)

        public var coordinate: Coordinate {
            switch self {
            case .player(let c): return c
            case .tee(_, let c): return c
            }
        }
        public var isPlayer: Bool { if case .player = self { return true }; return false }
    }

    /// One measured hop in the plan: you → target, target → target, target → pin.
    public struct Leg: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case toTarget(Int), toGreen }
        public var kind: Kind
        public var from: Coordinate
        public var to: Coordinate
        public var metres: Double
        /// Metres of rise across **this leg**, when there is terrain under both
        /// ends. Per leg rather than one number for the hole *(user, 2026-08-30:
        /// plays-like on the main distance and on both target legs)* — a layup
        /// over a ridge and the approach down off it are two different shots, and
        /// one hole-wide rise would describe neither.
        public var rise: Double?
        public var id: String {
            switch kind {
            case .toTarget(let i): return "t\(i)"
            case .toGreen: return "green"
            }
        }
    }

    public var origin: Origin
    /// Front, centre and back **from the last waypoint** — the origin when there are
    /// no targets, otherwise the final target. That is the number a golfer wants
    /// once they have planned a layup: what is left from there, not from here.
    public var green: GreenDistances
    public var legs: [Leg]
    /// Metres of rise from the **last waypoint** to the flag, when there is
    /// terrain behind it. Nil is honest — a plays-like number with nothing behind
    /// it must disappear rather than read zero.
    ///
    /// From the last waypoint rather than from the origin, so that it matches
    /// `green.center`, which is also measured from there. A golfer who has planned
    /// a layup wants what is left *from there*; a rise measured from where they
    /// are standing and a distance measured from the target are two halves of two
    /// different shots.
    public var rise: Double?
    /// Where the rise came from, when it came from a stored grid. Nil means the
    /// course file's own altitudes — which is a surveyed profile interpolated
    /// along the hole line, not a measurement at the point asked about.
    public var riseSource: Elevation.Source?
    public var targets: [Coordinate]
    /// Today's flag, when somebody has placed it — see `Event.Kind.pin`.
    ///
    /// **The approach is measured to it, and the caption says so.** A pin is cut
    /// fresh every morning and the number a golfer clubs off is the one to the
    /// flag; measuring to the green's centre while a pin sits somewhere else on
    /// screen is a number that disagrees with the picture. Front and back stay
    /// measured against the green *outline*, which is geometry and does not move.
    public var pin: Coordinate?
    /// The phone's actual position, **whatever the numbers are measured from**.
    ///
    /// Separate from `origin` on purpose. `origin` answers "what is this distance
    /// measured from", and falls back to the tee when the fix is nowhere near this
    /// hole — but the golfer is still *somewhere*, and the map should say where.
    /// Deriving the marker from `origin` meant a fix off the hole drew no marker at
    /// all, so "go to my location" panned to an empty patch of rough.
    public var playerAt: Coordinate?

    /// How far from this hole a fix may be and still be worth measuring from.
    ///
    /// Generous on purpose. Standing on the next fairway over, the distance from
    /// where you actually are is still the useful one; it is *at home, or on a
    /// different course* that measuring from the tee starts being the honest answer.
    /// Tightening this to exclude the adjacent hole would trade a real improvement
    /// for a cosmetic one.
    public static let onHoleRadius: Double = 150

    public static func origin(geometry g: HoleGeometry, player: Coordinate?,
                              radius: Double = onHoleRadius) -> Origin {
        guard let p = player else { return .tee(name: g.tee.name, at: g.teeAt) }
        var path = g.hole.line
        if path.count < 2 { path = [g.teeAt, g.greenCenter] }
        guard Geodesy.distance(from: p, toPath: path) <= radius else {
            return .tee(name: g.tee.name, at: g.teeAt)
        }
        return .player(p)
    }

    /// - Parameter targets: at most two, in the order they were placed. Extras are
    ///   ignored rather than silently re-ordered.
    /// - Parameter terrain: the course's stored DEM, when it has one. **Both ends
    ///   of every elevation difference come out of it**, which is what makes the
    ///   datum cancel — research-elevation.md §4. Nil falls back to the course
    ///   file's own altitudes, which is every OSM-imported course.
    public init(geometry g: HoleGeometry, player: Coordinate?,
                targets: [Coordinate] = [],
                pin: Coordinate? = nil,
                terrain: Elevation? = nil,
                radius: Double = onHoleRadius) {
        let o = Self.origin(geometry: g, player: player, radius: radius)
        let ts = Array(targets.prefix(2))
        self.origin = o
        self.targets = ts
        self.playerAt = player
        self.pin = pin

        var legs: [Leg] = []
        var cursor = o.coordinate
        for (i, t) in ts.enumerated() {
            legs.append(Leg(kind: .toTarget(i), from: cursor, to: t,
                            metres: Geodesy.distance(cursor, t),
                            rise: terrain?.delta(from: cursor, to: t)))
            cursor = t
        }
        let flag = pin ?? g.greenCenter
        legs.append(Leg(kind: .toGreen, from: cursor, to: flag,
                        metres: Geodesy.distance(cursor, flag),
                        rise: terrain?.delta(from: cursor, to: flag)
                            ?? g.hole.elevationDelta(from: cursor)))
        self.legs = legs

        // Measured against the green *outline* from wherever the last waypoint is —
        // a stored front point is only correct from the angle it was surveyed from,
        // which is most of a green's width of error on an approach from the side.
        var green = g.distances(from: cursor)
        // Centre becomes the *pin* when there is one — front and back are the green
        // outline and are unaffected, so a pin cut at the front still reads a centre
        // number shorter than the back one, which is what is actually true.
        if let pin { green.center = Geodesy.distance(cursor, pin) }
        self.green = green
        // Measured from `cursor` — the last waypoint — to the same flag the big
        // number is measured to, so the two describe one shot. The approach leg
        // already resolved exactly this, so read it back rather than working it
        // out twice: two derivations of one number is two numbers that can differ.
        self.rise = legs.last?.rise
        self.riseSource = terrain?.delta(from: cursor, to: flag) == nil ? nil : terrain?.source
    }

    /// The leg that ends at the green — always present, and the one the big number
    /// on the screen comes from when there are no targets.
    public var approach: Leg { legs.last! }
    /// Whether the big number is a distance to the flag rather than to the middle
    /// of the green. The caption says which, because a number with no stated
    /// reference is worse than no number.
    public var measuringToPin: Bool { pin != nil }
    public var hasTargets: Bool { !targets.isEmpty }

    /// Plays-like for the approach, when there is elevation to apply.
    public func playsLike() -> Double? {
        rise.map { Geodesy.playsLike(distance: green.center, elevationDelta: $0) }
    }
}
#endif
