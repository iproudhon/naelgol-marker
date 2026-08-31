import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import GolfCourse
@testable import GolfMap
@testable import GolfTerrain

/// The grid, its sampling, and the datum rule that is the whole reason it is a
/// type rather than an array of doubles. research-elevation.md §4.
final class ElevationTests: XCTestCase {

    /// A 5 x 5 grid over a plane rising 1 m per post eastward, at 0.0001° posts —
    /// small numbers, so an arithmetic slip is visible rather than plausible.
    private func ramp(source: Elevation.Source = .usgs3DEP,
                      datum: Elevation.Datum = .navd88) -> Elevation {
        var metres: [Double?] = []
        for _ in 0..<5 { for x in 0..<5 { metres.append(Double(x)) } }
        return Elevation(source: source, datum: datum, nativeResolution: 1,
                         lat0: 37.2004, lon0: -121.7008,
                         dLat: 0.0001, dLon: 0.0001,
                         width: 5, height: 5, metres: metres)
    }

    // MARK: - Sampling

    func testASampleAtAPostIsThatPost() throws {
        let g = ramp()
        let s = try XCTUnwrap(g.sample(at: Coordinate(lat: 37.2004, lon: -121.7005)))
        XCTAssertEqual(s.height, 3, accuracy: 0.001)
        XCTAssertEqual(s.datum, .navd88)
        XCTAssertEqual(s.nativeResolution, 1)
    }

    /// Bilinear, not nearest. A nearest-post answer steps by a whole post as the
    /// golfer walks, which on a sloping fairway makes the number jump while they
    /// stand still.
    func testASampleBetweenPostsIsInterpolated() throws {
        let g = ramp()
        let mid = try XCTUnwrap(g.sample(at: Coordinate(lat: 37.20035, lon: -121.70055)))
        XCTAssertEqual(mid.height, 2.5, accuracy: 0.001)
    }

    func testASampleOffTheGridIsNilRatherThanTheNearestEdge() {
        let g = ramp()
        XCTAssertNil(g.sample(at: Coordinate(lat: 37.2004, lon: -121.6900)))
        XCTAssertNil(g.sample(at: Coordinate(lat: 37.5000, lon: -121.7005)))
        XCTAssertFalse(g.contains(Coordinate(lat: 37.5, lon: -121.7005)))
    }

    /// A void anywhere in the four corners makes the whole sample nil: averaging a
    /// known height with an unknown one produces a number nothing measured.
    func testAVoidPoisonsTheWholeInterpolation() throws {
        var metres: [Double?] = Array(repeating: 10, count: 9)
        metres[4] = nil                       // the centre post of a 3 x 3
        let g = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                          lat0: 37.2, lon0: -121.7, dLat: 0.0001, dLon: 0.0001,
                          width: 3, height: 3, metres: metres)
        XCTAssertNil(g.at(1, 1))
        XCTAssertNil(g.sample(at: Coordinate(lat: 37.19995, lon: -121.69995)))
        // A corner well away from the void still answers.
        XCTAssertEqual(try XCTUnwrap(g.sample(at: Coordinate(lat: 37.2, lon: -121.7))).height,
                       10, accuracy: 0.001)
    }

    // MARK: - The datum rule

    /// research-elevation.md §4, made structural. Ellipsoid and geoid differ by
    /// roughly −30 m in California, and a difference across the two is out by that
    /// much while reading like an ordinary large number.
    func testADeltaAcrossTwoDatumsIsNilRatherThanThirtyMetresWrong() {
        let dem = Elevation.Sample(height: 107.2, datum: .navd88,
                                   source: .usgs3DEP, nativeResolution: 1)
        let phone = Elevation.Sample(height: 75.1, datum: .wgs84Ellipsoid,
                                     source: .survey, nativeResolution: 5)
        XCTAssertNil(Elevation.Sample.delta(from: dem, to: phone))
        XCTAssertNil(Elevation.Sample.delta(from: phone, to: dem))
        // Same datum from two different sources is still a legitimate difference —
        // it is the *reference* that has to match, not the provenance.
        let other = Elevation.Sample(height: 110.0, datum: .navd88,
                                     source: .survey, nativeResolution: 30)
        XCTAssertEqual(try XCTUnwrap(Elevation.Sample.delta(from: dem, to: other)),
                       2.8, accuracy: 0.001)
    }

    func testADeltaWithinOneGridCancelsTheDatumByConstruction() throws {
        let g = ramp()
        let d = try XCTUnwrap(g.delta(from: Coordinate(lat: 37.2004, lon: -121.7008),
                                      to: Coordinate(lat: 37.2004, lon: -121.7004)))
        XCTAssertEqual(d, 4, accuracy: 0.001)
        XCTAssertNil(g.delta(from: Coordinate(lat: 37.2004, lon: -121.7008),
                             to: Coordinate(lat: 37.2004, lon: -121.6000)))
    }

    /// The leak this closed: `Hole.elevationDelta(from:)` used to prefer the
    /// point's *own* altitude, so a coordinate carrying a GPS height silently
    /// became one end of a subtraction whose other end came from the file.
    func testHoleElevationDeltaIgnoresAPointsOwnAltitude() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let tee = try XCTUnwrap(hole.geometry()).teeAt
        let honest = try XCTUnwrap(hole.elevationDelta(from: tee))
        // The same point, carrying a wildly different "altitude" — as an
        // ellipsoidal height from a phone would.
        var poisoned = tee; poisoned.alt = (tee.alt ?? 0) - 32
        XCTAssertEqual(try XCTUnwrap(hole.elevationDelta(from: poisoned)), honest,
                       accuracy: 0.001, "a point's own altitude must not reach the subtraction")
    }

    func testAGridOverridesTheFilesOwnAltitudes() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let fromFile = try XCTUnwrap(hole.elevationDelta(from: g.teeAt))
        // A flat grid covering the hole: the DEM says nothing rises, and the DEM wins.
        let flat = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                             lat0: g.teeAt.lat + 0.02, lon0: g.teeAt.lon - 0.02,
                             dLat: 0.004, dLon: 0.004, width: 11, height: 11,
                             metres: Array(repeating: 50, count: 121))
        XCTAssertEqual(try XCTUnwrap(hole.elevationDelta(from: g.teeAt, using: flat)), 0,
                       accuracy: 0.001)
        // Off the grid, it falls back rather than losing the number altogether.
        let elsewhere = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                                  lat0: 10, lon0: 10, dLat: 0.001, dLon: 0.001,
                                  width: 3, height: 3, metres: Array(repeating: 5, count: 9))
        XCTAssertEqual(try XCTUnwrap(hole.elevationDelta(from: g.teeAt, using: elsewhere)),
                       fromFile, accuracy: 0.001)
    }

    // MARK: - Storage

    func testTheGridSurvivesARoundTripThroughJSON() throws {
        var metres: [Double?] = (0..<40).map { Double($0) / 10 }
        metres[7] = nil
        metres[9] = -12.5
        let g = Elevation(source: .copernicusGLO30, datum: .egm2008, nativeResolution: 30,
                          lat0: 37.5, lon0: 127.1, dLat: 0.0003, dLon: 0.0002,
                          width: 8, height: 5, metres: metres)
        let back = try JSONDecoder().decode(Elevation.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
        XCTAssertEqual(back.datum, .egm2008)
        XCTAssertEqual(back.source, .copernicusGLO30)
        XCTAssertNil(back.at(7, 0))
        XCTAssertEqual(try XCTUnwrap(back.at(1, 1)), -12.5, accuracy: 0.001)
    }

    /// Little-endian on both sides, explicitly — a file written on one machine has
    /// to read on another, and `Int16` in a `Data` is a byte order decision either
    /// way.
    func testSamplesAreEncodedLittleEndian() {
        let d = Elevation.encode([1, -1, 258])
        XCTAssertEqual([UInt8](d), [0x01, 0x00, 0xff, 0xff, 0x02, 0x01])
        XCTAssertEqual(Elevation.decode(d), [1, -1, 258])
    }

    func testASamplesBlobOfTheWrongLengthIsADecodeFailure() throws {
        let g = ramp()
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(g)) as! [String: Any]
        json["width"] = 6
        let bad = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(Elevation.self, from: bad))
    }

    // MARK: - Geometry of the grid itself

    /// Stored in degrees, so the posts are **not square on the ground** — 2.2 m
    /// east against 2.8 m north at Coyote Creek's latitude. Storing a single
    /// "metres per post" is what a Web Mercator request would have tempted; it is
    /// wrong by 1/cos(latitude) and puts a sample hundreds of metres out at the
    /// far corner of a course.
    func testGroundPostSpacingDiffersEastAndNorth() {
        let g = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                          lat0: 37.2, lon0: -121.7,
                          dLat: 0.0000248, dLon: 0.0000248,
                          width: 10, height: 10, metres: Array(repeating: 100, count: 100))
        let posts = g.nativePosts
        XCTAssertEqual(posts.north, 2.76, accuracy: 0.02)
        XCTAssertEqual(posts.east, 2.20, accuracy: 0.02)
        XCTAssertLessThan(posts.east, posts.north)
    }

    func testCoverageCountsPointsThatActuallySample() {
        let g = ramp()
        let on = Coordinate(lat: 37.2004, lon: -121.7006)
        let off = Coordinate(lat: 37.2004, lon: -121.6000)
        XCTAssertEqual(g.coverage(of: [on, on, on, on]), 1, accuracy: 0.001)
        XCTAssertEqual(g.coverage(of: [on, off]), 0.5, accuracy: 0.001)
        XCTAssertEqual(g.coverage(of: []), 0, accuracy: 0.001)
    }

    func testAProfileReportsAVoidRatherThanJoiningAcrossIt() {
        var metres: [Double?] = Array(repeating: 10, count: 25)
        metres[12] = nil
        let g = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                          lat0: 37.2004, lon0: -121.7008, dLat: 0.0001, dLon: 0.0001,
                          width: 5, height: 5, metres: metres)
        let p = g.profile(from: Coordinate(lat: 37.2002, lon: -121.7008),
                          to: Coordinate(lat: 37.2002, lon: -121.7004), count: 9)
        XCTAssertEqual(p.count, 9)
        XCTAssertTrue(p.contains(where: { $0 == nil }), "the void must survive as a gap")
        XCTAssertTrue(p.contains(where: { $0 != nil }))
    }
}

/// The readout's half: which two points the rise is measured between, and what
/// happens when there is no terrain.
final class ElevationReadoutTests: XCTestCase {

    private func grid(over g: HoleGeometry, rise: Double) -> Elevation {
        // A north–south ramp covering the hole: the green end is `rise` above the
        // tee end, whatever the hole's bearing.
        let n = 41
        let lat0 = max(g.teeAt.lat, g.greenCenter.lat) + 0.01
        let lon0 = min(g.teeAt.lon, g.greenCenter.lon) - 0.01
        let step = 0.02 / Double(n - 1)
        var metres: [Double?] = []
        for y in 0..<n {
            for _ in 0..<n { metres.append(100 + Double(y) * rise) }
        }
        return Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                         lat0: lat0, lon0: lon0, dLat: step, dLon: step,
                         width: n, height: n, metres: metres)
    }

    func testWithNoTerrainTheRiseFallsBackToTheFileAndSaysSo() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let r = HoleReadout(geometry: g, player: nil)
        XCTAssertEqual(try XCTUnwrap(r.rise), 8, accuracy: 0.5)
        XCTAssertNil(r.riseSource, "a file's own altitudes are not a stored source")
    }

    func testTerrainSuppliesTheRiseAndItsSource() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let r = HoleReadout(geometry: g, player: nil, terrain: grid(over: g, rise: 0))
        XCTAssertEqual(try XCTUnwrap(r.rise), 0, accuracy: 0.01,
                       "the DEM answers, not the file")
        XCTAssertEqual(r.riseSource, .usgs3DEP)
        XCTAssertEqual(try XCTUnwrap(r.playsLike()), r.green.center, accuracy: 0.01)
    }

    /// The rise and the big number describe **one shot**, so both are measured
    /// from the last waypoint. Measuring the rise from where the golfer stands
    /// while the distance is measured from their layup target is two halves of two
    /// different shots.
    func testTheRiseIsMeasuredFromTheLastTargetNotFromTheOrigin() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let terrain = grid(over: g, rise: 0.5)
        let plain = HoleReadout(geometry: g, player: nil, terrain: terrain)
        let target = Geodesy.interpolate(g.teeAt, g.greenCenter, 0.5)
        let layup = HoleReadout(geometry: g, player: nil, targets: [target], terrain: terrain)
        let a = try XCTUnwrap(plain.rise), b = try XCTUnwrap(layup.rise)
        XCTAssertNotEqual(a, b, accuracy: 0.001)
        XCTAssertEqual(b, a / 2, accuracy: 0.2, "half the hole is half the rise")
        XCTAssertEqual(layup.approach.from.lat, target.lat, accuracy: 1e-9)
    }
}

/// The one formatter every plays-like number on screen goes through, and the
/// per-leg rise that feeds it. *(User, 2026-08-30: the main distance, both target
/// legs, and the leg between shot markers.)*
final class PlaysLikeDisplayTests: XCTestCase {

    private let yards = DistanceDisplay(unit: .yards)

    /// **1:1 is the popular rule and this is it.** Uphill adds, downhill subtracts,
    /// one unit per unit — the answer three independent sources give and the one a
    /// ballistics model brackets (20 yd up costs 21, 20 yd down gains 18).
    func testPlaysLikeIsDistancePlusRise() {
        XCTAssertEqual(Geodesy.playsLike(distance: 300, elevationDelta: 12), 312, accuracy: 1e-9)
        XCTAssertEqual(Geodesy.playsLike(distance: 300, elevationDelta: -12), 288, accuracy: 1e-9)
    }

    /// `<dist>.<plays like><arrow><elevation>` *(user, 2026-08-30)*. The adjusted
    /// distance leads and the rise trails it as the reason.
    func testTheSuffixIsPlaysLikeThenTheArrowAndRise() throws {
        // 300 m ≈ 328 yd, 12 m ≈ 13 yd, so it plays 341.
        XCTAssertEqual(try XCTUnwrap(yards.plays(rise: 12, distance: 300)), ".~341▲13")
        XCTAssertEqual(try XCTUnwrap(yards.plays(rise: -12, distance: 300)), ".~315▼13")
        XCTAssertEqual(yards.withPlays(300, rise: 12), "328.~341▲13")
    }

    /// **No unit anywhere in these numbers** *(user, 2026-08-30: "No YD")*. It is
    /// stated once, in the caption under the big distance.
    func testNoNumberOnTheHoleCarriesItsUnit() {
        XCTAssertFalse(yards.withPlays(300, rise: 12).contains(yards.symbol))
        XCTAssertFalse(yards.withPlays(300, rise: nil).contains(yards.symbol))
        XCTAssertFalse(yards.number(300).contains(yards.symbol))
    }

    /// `~` marks the modelled half and the rise is printed bare, because the rise
    /// is *measured* — lidar, 10 cm spec — and the plays-like number is not.
    func testOnlyThePlaysLikeNumberIsMarkedAsAnEstimate() throws {
        let s = try XCTUnwrap(yards.plays(rise: 12, distance: 300))
        XCTAssertEqual(s.filter { $0 == "~" }.count, 1)
        XCTAssertTrue(s.hasSuffix("▲13"), "the measured rise carries no mark")
        XCTAssertTrue(s.hasPrefix(".~"), "the estimate mark sits on the modelled number")
    }

    /// Nil rather than `▲0 · ~353`: three claims that all say the same thing, and
    /// the number it offers is the one it is sitting next to.
    /// **The three numbers on screen add up, always.** Found by screenshot on
    /// Corica hole 1: a 0.49 m rise over 164 m rendered `180 ▲1 · ~180`, because
    /// the rise rounded up to a yard while the plays-like distance rounded down to
    /// the same 180. Rounding to display units *before* the addition makes it exact.
    func testTheDisplayedNumbersAddUp() throws {
        for metres in stride(from: 20.0, through: 400, by: 3.7) {
            for rise in stride(from: -25.0, through: 25, by: 0.37) {
                guard let s = yards.plays(rise: rise, distance: metres) else { continue }
                // ".~341▲13" → plays 341, rise +13.
                let up = s.contains("▲")
                let body = s.dropFirst(2)                       // past ".~"
                let split = body.split(whereSeparator: { $0 == "▲" || $0 == "▼" })
                let plays = Int(split[0])!, shown = Int(split[1])!
                XCTAssertEqual(Int(yards.number(metres))! + (up ? shown : -shown), plays,
                               "\(yards.number(metres))\(s) does not add up")
            }
        }
    }

    func testAFlatShotGetsNoSuffixAtAll() {
        XCTAssertNil(yards.plays(rise: nil, distance: 300))
        XCTAssertNil(yards.plays(rise: 0, distance: 300))
        XCTAssertNil(yards.plays(rise: 0.4, distance: 300), "under half a yard")
        XCTAssertEqual(yards.withPlays(300, rise: nil), yards.number(300))
    }

    func testTheUnitFollowsTheDisplayNotTheStorage() throws {
        let metres = DistanceDisplay(unit: .metres)
        XCTAssertEqual(try XCTUnwrap(metres.plays(rise: 12, distance: 300)), ".~312▲12")
        XCTAssertEqual(try XCTUnwrap(yards.plays(rise: 12, distance: 300)), ".~341▲13")
    }

    /// Per leg, not per hole: a layup over a ridge and the approach down off it are
    /// two different shots, and one hole-wide rise would describe neither.
    func testEachLegCarriesItsOwnRise() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        // A north–south ramp over the hole, 0.5 m per row.
        let n = 41
        let lat0 = max(g.teeAt.lat, g.greenCenter.lat) + 0.01
        let lon0 = min(g.teeAt.lon, g.greenCenter.lon) - 0.01
        let step = 0.02 / Double(n - 1)
        var metres: [Double?] = []
        for y in 0..<n { for _ in 0..<n { metres.append(100 + Double(y) * 0.5) } }
        let terrain = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                                lat0: lat0, lon0: lon0, dLat: step, dLon: step,
                                width: n, height: n, metres: metres)

        let t1 = Geodesy.interpolate(g.teeAt, g.greenCenter, 0.35)
        let t2 = Geodesy.interpolate(g.teeAt, g.greenCenter, 0.7)
        let r = HoleReadout(geometry: g, player: nil, targets: [t1, t2], terrain: terrain)
        XCTAssertEqual(r.legs.count, 3)
        let rises = try r.legs.map { try XCTUnwrap($0.rise) }
        // The legs partition the hole: each rise is its own stretch, and together
        // they are the whole tee-to-green climb.
        XCTAssertEqual(rises.reduce(0, +),
                       try XCTUnwrap(terrain.delta(from: g.teeAt, to: g.greenCenter)),
                       accuracy: 0.05, "the legs partition the hole's rise")
        for r in rises { XCTAssertNotEqual(r, 0, accuracy: 0.001) }
    }

    /// `HoleReadout.rise` is the approach leg's, read back rather than derived a
    /// second time — two derivations of one number is two numbers that can differ.
    func testTheHoleRiseIsTheApproachLegsRise() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let r = HoleReadout(geometry: g, player: nil)
        XCTAssertEqual(try XCTUnwrap(r.rise), try XCTUnwrap(r.approach.rise), accuracy: 1e-9)
    }

    /// The box drawn is the box the drag gesture tests, so a suffix that widened
    /// the text has to widen the rectangle with it.
    func testALegLabelBoxGrowsToHoldTheSuffix() throws {
        let flat = PlanLayout.size(main: "353", sub: nil)
        let sloped = PlanLayout.size(main: "353.~341▲13", sub: nil)
        XCTAssertGreaterThan(sloped.width, flat.width)
    }
}

/// The leg label boxes, now that the elevation suffix has roughly tripled their
/// width. **The box is the target's drag handle** — the rectangle filled and the
/// rectangle hit-tested are the same one — so a wider label is not only a visual
/// change.
final class PlanLayoutWithPlaysLikeTests: XCTestCase {

    private func readout(rise: Double) throws -> HoleReadout {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let n = 41
        let lat0 = max(g.teeAt.lat, g.greenCenter.lat) + 0.01
        let lon0 = min(g.teeAt.lon, g.greenCenter.lon) - 0.01
        let step = 0.02 / Double(n - 1)
        var metres: [Double?] = []
        for y in 0..<n { for _ in 0..<n { metres.append(100 + Double(y) * rise) } }
        let terrain = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                                lat0: lat0, lon0: lon0, dLat: step, dLon: step,
                                width: n, height: n, metres: metres)
        return HoleReadout(geometry: g, player: nil,
                           targets: [Geodesy.interpolate(g.teeAt, g.greenCenter, 0.35),
                                     Geodesy.interpolate(g.teeAt, g.greenCenter, 0.7)],
                           terrain: terrain)
    }

    /// A projection standing in for the renderer's: metres east/north from the tee,
    /// scaled to something screen-sized.
    private func project(_ g: HoleGeometry) -> (Coordinate) -> CGPoint {
        { c in
            let o = Geodesy.offset(of: c, from: g.teeAt)
            return CGPoint(x: 200 + o.east * 1.1, y: 700 - o.north * 1.1)
        }
    }

    func testTheBoxesStillDoNotOverlapOnceTheSuffixWidensThem() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let labels = PlanLayout.labels(try readout(rise: 0.5), display: .default,
                                       project: project(g))
        XCTAssertEqual(labels.count, 3)
        for a in labels.indices {
            for b in (a + 1)..<labels.count {
                XCTAssertFalse(labels[a].rect.intersects(labels[b].rect),
                               "\(labels[a].main) overlaps \(labels[b].main)")
            }
        }
    }

    /// Each box drags the target it is *about*, and the suffix must not have
    /// changed which. Legs 0 and 1 drag targets 0 and 1; the approach drags the
    /// last target it starts from.
    func testEachWiderBoxStillDragsItsOwnTarget() throws {
        let hole = try XCTUnwrap(SampleCourse.naelgol.holes.first { $0.ref == "7" })
        let g = try XCTUnwrap(hole.geometry())
        let labels = PlanLayout.labels(try readout(rise: 0.5), display: .default,
                                       project: project(g))
        XCTAssertEqual(labels.map(\.dragsTarget), [0, 1, 1])
        XCTAssertTrue(labels.allSatisfy { $0.main.contains("~") },
                      "every leg of a sloping hole carries the suffix")
    }

    /// `HoleScreen.bigDistance` offsets the suffix by the same arithmetic, at 68
    /// and 20 points, and a wrong offset there does not fail a build — it silently
    /// overlaps, which is the failure that already happened once and was caught by
    /// screenshot. So pin the estimate against the real face wherever it can be
    /// measured.
    func testTheAdvanceEstimateMatchesTheRealMonospacedFace() throws {
        #if canImport(AppKit)
        for size in [14.0, 20.0, 68.0] {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            for text in ["333", "101", "118.~109▼9", ".~334▲1"] {
                let real = NSAttributedString(string: text, attributes: [.font: font])
                    .size().width
                let estimate = Double(text.count) * PlanLayout.advance * size
                XCTAssertEqual(estimate, real, accuracy: max(1, real * 0.01),
                               "\(text) at \(size)pt")
            }
        }
        #else
        throw XCTSkip("text metrics need AppKit")
        #endif
    }

    /// The rectangle has to hold the text it is drawn with. Measured against
    /// `NSFont.monospacedSystemFont`, which reports 0.618 em for every glyph these
    /// labels use — `▲`, `▼`, `·` and `~` included, so none of them falls back to a
    /// proportional face.
    func testTheEstimatedBoxHoldsTheRealTextWidth() {
        // 0.618 em is the measured advance; the estimate must not sit under it.
        XCTAssertGreaterThanOrEqual(PlanLayout.advance, 0.618)
        for main in ["118", "118.~109▼9", "353.~341▲13"] {
            let sz = PlanLayout.size(main: main, sub: nil)
            let real = Double(main.count) * 0.618 * PlanLayout.mainSize
            XCTAssertGreaterThanOrEqual(sz.width, real,
                                        "\(main) is drawn wider than its box")
        }
    }
}
