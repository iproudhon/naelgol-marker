import Foundation

/// A hand-authored course so both renderers, the previews and `golfctl course`
/// have something real to draw before any round has been recorded.
///
/// Built **in code rather than as a bundled JSON resource**: declaring `resources:`
/// on a target generates `Bundle.module`, which `Package.swift` deliberately avoids.
/// Real courses load from `Documents/Courses/*.json` (see `CourseStore`).
///
/// Geometry is synthesised from bearings and distances, so the numbers a golfer
/// reads off it are internally consistent — hole 7 really is 380 m and really does
/// climb 8 m.
public enum SampleCourse {

    public static let naelgol: Course = build()

    // MARK: - Construction helpers

    /// A closed ellipse in metres around `c`. `rotation` is degrees clockwise from
    /// north for the long axis.
    public static func ellipse(around c: Coordinate, semiMajor a: Double, semiMinor b: Double,
                        rotation: Double = 0, points: Int = 16) -> [Coordinate] {
        let θ = rotation * .pi / 180
        return (0..<points).map { i in
            let t = 2 * .pi * Double(i) / Double(points)
            let u = a * cos(t), v = b * sin(t)
            // rotate (along-axis u, cross-axis v) into (east, north)
            let north = u * cos(θ) - v * sin(θ)
            let east = u * sin(θ) + v * cos(θ)
            return Geodesy.coordinate(from: c, east: east, north: north, alt: c.alt)
        }
    }

    /// `distance` metres from `from` along `bearing`, keeping/overriding altitude.
    public static func step(_ from: Coordinate, _ bearing: Double, _ distance: Double,
                            alt: Double? = nil) -> Coordinate {
        Geodesy.point(from: from, bearing: bearing, distance: distance, alt: alt ?? from.alt)
    }

    static func hole(ref: String, par: Int, handicap: Int,
                     tee teeAt: Coordinate,
                     legs: [(bearing: Double, distance: Double)],
                     greenAlt: Double,
                     greenSize: (Double, Double) = (17, 13),
                     bunkers: [(leg: Int, along: Double, offset: Double, size: Double)]) -> Hole {
        // Walk the legs to build the hole line, interpolating altitude linearly.
        var pts: [Coordinate] = [teeAt]
        let total = legs.reduce(0) { $0 + $1.distance }
        var walked = 0.0
        for leg in legs {
            walked += leg.distance
            let frac = total > 0 ? walked / total : 1
            let alt = (teeAt.alt ?? 0) + ((greenAlt - (teeAt.alt ?? 0)) * frac)
            pts.append(step(pts[pts.count - 1], leg.bearing, leg.distance, alt: alt))
        }
        let centre = pts[pts.count - 1]
        let approach = Geodesy.bearing(from: pts[pts.count - 2], to: centre)
        let green = Green(center: centre,
                          polygon: ellipse(around: centre,
                                           semiMajor: greenSize.0, semiMinor: greenSize.1,
                                           rotation: approach))

        let hazards: [Hazard] = bunkers.map { b in
            let a = pts[b.leg], z = pts[b.leg + 1]
            let brg = Geodesy.bearing(from: a, to: z)
            let on = step(a, brg, b.along)
            let beside = step(on, brg + 90, b.offset)
            return Hazard(kind: .bunker,
                          polygon: ellipse(around: beside, semiMajor: b.size,
                                           semiMinor: b.size * 0.55, rotation: brg + 25, points: 12))
        }

        let white = teeAt
        let blue = step(teeAt, Geodesy.bearing(from: pts[1], to: teeAt), 26, alt: teeAt.alt)
        // Card distances alongside the coordinates, so the sample exercises the
        // normal case — a card from one source, geometry from another — and not
        // just the geometry-only one.
        return Hole(ref: ref, par: par, handicap: handicap,
                    tees: [TeeBox(name: "white", at: white, distance: total.rounded()),
                           TeeBox(name: "blue", at: blue, distance: (total + 26).rounded())],
                    green: green, line: pts, hazards: hazards, confidence: 1.0)
    }

    // MARK: - The course

    static func build() -> Course {
        let clubhouse = Coordinate(lat: 37.4000, lon: 127.2000, alt: 112)

        // 7 — par 4, 380 m, dogleg RIGHT, climbing 8 m. The hole in the mockups.
        let h7 = hole(ref: "7", par: 4, handicap: 7,
                      tee: clubhouse,
                      legs: [(bearing: 5, distance: 210), (bearing: 38, distance: 170)],
                      greenAlt: 120,
                      bunkers: [(leg: 0, along: 195, offset: -22, size: 9),
                                (leg: 1, along: 140, offset: 20, size: 7)])

        // 8 — par 3, 165 m, straight, dropping 6 m. Bearing ~250° so a mirrored
        // renderer cannot pass by accident on hole 7 alone.
        let t8 = step(h7.green.center!, 300, 60, alt: 120)
        let h8 = hole(ref: "8", par: 3, handicap: 15,
                      tee: t8,
                      legs: [(bearing: 250, distance: 165)],
                      greenAlt: 114, greenSize: (15, 12),
                      bunkers: [(leg: 0, along: 150, offset: -16, size: 8)])

        // 9 — par 5, 490 m, dogleg LEFT, back up to the clubhouse.
        let t9 = step(h8.green.center!, 200, 45, alt: 114)
        let h9 = hole(ref: "9", par: 5, handicap: 3,
                      tee: t9,
                      legs: [(bearing: 120, distance: 250), (bearing: 78, distance: 240)],
                      greenAlt: 118, greenSize: (19, 14),
                      bunkers: [(leg: 0, along: 235, offset: 24, size: 10),
                                (leg: 1, along: 205, offset: -18, size: 8)])

        return Course(id: "naelgol-cc", name: "내골 CC", aliases: ["Naelgol CC"],
                      source: .sample,
                      attribution: "Synthesised sample geometry — not a real course",
                      holes: [h7, h8, h9])
    }
}
