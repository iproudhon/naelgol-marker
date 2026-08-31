import Foundation

/// A point on the course. `alt` is metres, and where it exists it comes from the
/// barometer (`CMAltimeter`, ~0.3–1 m) rather than GNSS (±10–20 m) — elevation is
/// the whole justification for P3, and GNSS altitude cannot see an 8 m rise.
public struct Coordinate: Codable, Sendable, Hashable {
    public var lat: Double
    public var lon: Double
    public var alt: Double?

    public init(lat: Double, lon: Double, alt: Double? = nil) {
        self.lat = lat; self.lon = lon; self.alt = alt
    }
}

/// Distances, bearings and the local plane every hole is drawn on.
///
/// A hole is under a kilometre end to end, so a local equirectangular plane
/// tangent at the tee is accurate to well under a metre — far below GPS noise —
/// and it keeps the renderer to plain arithmetic. Distances themselves use
/// haversine so they stay honest at any separation.
public enum Geodesy {
    /// IUGG mean Earth radius.
    public static let earthRadius = 6_371_008.8

    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = (b.lat - a.lat) * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2)
            + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees, 0 = north, clockwise.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Metres east and north of `origin`. The local plane the hole is drawn on.
    public static func offset(of p: Coordinate, from origin: Coordinate)
        -> (east: Double, north: Double) {
        let mPerDegLat = .pi * earthRadius / 180
        let mPerDegLon = mPerDegLat * cos(origin.lat * .pi / 180)
        return (east: (p.lon - origin.lon) * mPerDegLon,
                north: (p.lat - origin.lat) * mPerDegLat)
    }

    /// Inverse of `offset` — used to synthesise geometry (sample courses, green
    /// polygons) without hand-computing coordinates.
    public static func coordinate(from origin: Coordinate,
                                  east: Double, north: Double,
                                  alt: Double? = nil) -> Coordinate {
        let mPerDegLat = .pi * earthRadius / 180
        let mPerDegLon = mPerDegLat * cos(origin.lat * .pi / 180)
        return Coordinate(lat: origin.lat + north / mPerDegLat,
                          lon: origin.lon + east / mPerDegLon,
                          alt: alt ?? origin.alt)
    }

    /// `distance` metres from `origin` along `bearing` degrees. The inverse of
    /// `bearing(from:to:)` + `distance(_:_:)`, and how synthetic geometry is built.
    public static func point(from origin: Coordinate, bearing: Double,
                             distance: Double, alt: Double? = nil) -> Coordinate {
        let θ = bearing * .pi / 180
        return coordinate(from: origin,
                          east: distance * sin(θ), north: distance * cos(θ), alt: alt)
    }

    /// A point `t` of the way from `a` to `b`, `t` in 0…1.
    ///
    /// **Altitude is deliberately not interpolated — it is dropped.** Same rule as
    /// `HolePlane.unproject`: `coordinate(from:east:north:alt:)` defaults a nil
    /// altitude to the *origin's*, which would stamp the tee's elevation on a point
    /// up the fairway and feed a plays-like number nothing measured.
    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        let k = min(1, max(0, t))
        let o = offset(of: b, from: a)
        return coordinate(from: Coordinate(lat: a.lat, lon: a.lon),
                          east: o.east * k, north: o.north * k)
    }

    /// Which side of the tee→green line `p` falls on, as a signed area.
    ///
    /// **Negative means right of the line** looking from tee to green, positive
    /// means left. This is the one assertion that pins the renderer's handedness:
    /// a hole that draws mirrored still puts the green above the tee, so "green is
    /// up" proves nothing. See `HoleProjection`.
    public static func side(of p: Coordinate, tee: Coordinate, green: Coordinate) -> Double {
        let v = offset(of: green, from: tee)
        let w = offset(of: p, from: tee)
        return v.east * w.north - v.north * w.east
    }

    /// Ray casting. Used for "is the ball on the green" and hazard lies.
    public static func contains(_ polygon: [Coordinate], _ p: Coordinate) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.lat > p.lat) != (b.lat > p.lat) {
                let x = (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon
                if p.lon < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Elevation-adjusted "plays like" distance.
    ///
    /// The industry rule of thumb, and what GolfLogix and 골프버디 both sell: add
    /// the elevation delta to the horizontal distance roughly **1:1** — 8 m uphill
    /// plays about 8 m longer, which is a club.
    ///
    /// This is a **tuning knob, not physics.** Real carry loss depends on club,
    /// ball speed and apex height. It lives in one named function precisely so it
    /// can be replaced by a measured model once `GolfEval` has rounds to fit
    /// against, instead of being inlined into a view and lost.
    public static func playsLike(distance: Double, elevationDelta: Double,
                                 factor: Double = 1.0) -> Double {
        distance + elevationDelta * factor
    }
}

extension Geodesy {
    /// Area-weighted centroid of a polygon, computed on the local plane.
    ///
    /// **Not the mean of the vertices.** OSM greens are traced by hand and their
    /// vertices bunch up wherever the mapper slowed down, so a vertex mean drifts
    /// toward the fiddly edge — several metres on a green, which is the difference
    /// between a correct centre distance and a club. Falls back to the vertex mean
    /// only for a degenerate (zero-area) ring, where the shoelace centroid is 0/0.
    public static func centroid(_ polygon: [Coordinate]) -> Coordinate? {
        var ring = polygon
        if let f = ring.first, let l = ring.last, ring.count > 1,
           f.lat == l.lat, f.lon == l.lon { ring.removeLast() }
        guard let origin = ring.first else { return nil }
        guard ring.count >= 3 else {
            let n = Double(ring.count)
            return Coordinate(lat: ring.reduce(0) { $0 + $1.lat } / n,
                              lon: ring.reduce(0) { $0 + $1.lon } / n)
        }
        let pts = ring.map { offset(of: $0, from: origin) }
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let cross = p.east * q.north - q.east * p.north
            a += cross
            cx += (p.east + q.east) * cross
            cy += (p.north + q.north) * cross
        }
        guard abs(a) > 1e-9 else {
            let n = Double(pts.count)
            return coordinate(from: origin,
                              east: pts.reduce(0) { $0 + $1.east } / n,
                              north: pts.reduce(0) { $0 + $1.north } / n)
        }
        return coordinate(from: origin, east: cx / (3 * a), north: cy / (3 * a))
    }

    /// Shortest distance from `p` to a polyline, measured to the segments and not
    /// just the vertices. A bunker beside the middle of a 400 m hole is metres from
    /// the line and hundreds of metres from either end of it.
    public static func distance(from p: Coordinate, toPath path: [Coordinate]) -> Double {
        guard let first = path.first else { return .infinity }
        guard path.count > 1 else { return distance(p, first) }
        let o = first
        let q = offset(of: p, from: o)
        var best = Double.infinity
        for i in 0..<(path.count - 1) {
            let a = offset(of: path[i], from: o), b = offset(of: path[i + 1], from: o)
            let dx = b.east - a.east, dy = b.north - a.north
            let len2 = dx * dx + dy * dy
            let t = len2 > 0
                ? max(0, min(1, ((q.east - a.east) * dx + (q.north - a.north) * dy) / len2))
                : 0
            let ex = a.east + t * dx - q.east, ey = a.north + t * dy - q.north
            best = min(best, (ex * ex + ey * ey).squareRoot())
        }
        return best
    }
}
