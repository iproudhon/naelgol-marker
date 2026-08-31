import Foundation
import GolfCourse
import GolfTerrain

/// `golfctl course elevation <course.json> [--spacing 3] [--out Courses]`
///
/// The third acquisition, after the card and the geometry — and the same shape as
/// both: fetch once, verify out loud, write a file beside `Courses/<id>.json` that
/// works with no signal for ever afterwards. research-elevation.md §6.
///
/// **What it prints is the point.** A grid that is silently over 10 m data instead
/// of lidar, or that misses a corner of the course, produces holes whose plays-like
/// number quietly disappears or reads a club wrong — and both look exactly like
/// success. So the command reports the native resolution the service actually
/// answered at, the coverage over every point in the course file, and the
/// tee-to-green rise of every hole, which is the number a golfer can check against
/// the ground they walked.
func cmdCourseElevation(_ args: Args) {
    guard args.positionals.count > 1 else {
        fail("""
            usage: golfctl course elevation <course.json> [--spacing 3] [--out Courses]

              --spacing  target metres between posts (default 3). 3DEP's own data is
                         1 m; a golf number does not resolve a metre of terrain, and
                         3 m keeps a whole course under a megabyte.
              --pad      metres of margin around the course (default 150)
              --out      where to write <id>.dem (default: beside the course file)
            """)
    }
    let url = URL(fileURLWithPath: args.positionals[1])
    guard let data = try? Data(contentsOf: url),
          let course = try? JSONDecoder().decode(Course.self, from: data)
    else { fail("could not read a course from \(url.path)") }

    let points = course.holes.flatMap { h -> [Coordinate] in
        h.line + h.fairway + h.green.polygon + h.tees.compactMap(\.at)
            + [h.green.center].compactMap { $0 }
    }
    guard !points.isEmpty else {
        fail("""
            \(course.name) has no coordinates — a card-only course has nothing to
            fetch terrain for. Import geometry first (golfctl course osm).
            """)
    }
    let lats = points.map(\.lat), lons = points.map(\.lon)
    // Padded, for the same reason the OSM feature query is: a golfer standing on
    // the tee of the next hole is still measuring from where they are, and a grid
    // clipped to the course's own extent returns nil for exactly those shots.
    let pad = Double(args.string("pad", default: "150")!) ?? 150
    let mPerDeg = .pi * Geodesy.earthRadius / 180
    let dLat = pad / mPerDeg
    let dLon = pad / (mPerDeg * cos((lats.min()! + lats.max()!) / 2 * .pi / 180))
    let bounds = (south: lats.min()! - dLat, west: lons.min()! - dLon,
                  north: lats.max()! + dLat, east: lons.max()! + dLon)
    let spacing = Double(args.string("spacing", default: "3")!) ?? 3

    print("course     \(course.name)  [\(course.id)]")
    print(String(format: "bbox       %.5f, %.5f  to  %.5f, %.5f  (+%.0f m)",
                 bounds.south, bounds.west, bounds.north, bounds.east, pad))
    print("source     USGS 3DEP seamless — public domain, bare earth, US only")
    print("fetching   \(Elevation3DEP.imageService)")

    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<(Elevation, Elevation3DEP.Report), Error>?
    Task {
        do { result = .success(try await Elevation3DEP.fetch(bounds: bounds, spacing: spacing)) }
        catch { result = .failure(error) }
        done.signal()
    }
    done.wait()

    guard case .success(let (grid, report)) = result else {
        if case .failure(let e) = result { fail("\(e)") }
        fail("3DEP returned nothing")
        return
    }

    print("")
    print(String(format: "grid       %d x %d posts, %.2f m east x %.2f m north  (%.0f KB)",
                 report.width, report.height, report.postsEast, report.postsNorth,
                 Double(report.width * report.height * 2) / 1024))
    // The one thing exportImage will not tell you, and the difference between
    // 10 cm of vertical error and a metre of it.
    if report.nativeResolution > 0 {
        let lidar = report.nativeResolution <= 1.5
        print(String(format: "native     %.0f m posts — %@", report.nativeResolution,
                     (lidar ? "lidar, 10 cm (1σ) spec" : "NOT lidar; metre-scale error, mark it coarse") as NSString))
    } else {
        print("native     unknown — the point service did not answer; assume the worst")
    }
    print(String(format: "relief     %.1f m to %.1f m  (%.1f m across the site)",
                 report.minimum, report.maximum, report.maximum - report.minimum))
    if report.voids > 0 {
        let pct = Double(report.voids) / Double(report.width * report.height) * 100
        print(String(format: "voids      %d posts (%.1f%%) with no data — holes over them read no rise",
                     report.voids, pct))
    }

    // Coverage over the course's own points, not over its bounding box: a grid
    // that clips one corner leaves a handful of holes with no plays-like at all,
    // which reads as a broken feature rather than as a file that is too small.
    let coverage = grid.coverage(of: points)
    print(String(format: "coverage   %.1f%% of %d course points", coverage * 100, points.count))
    if coverage < 0.999 {
        print("  warning: the grid does not cover the whole course. Increase --pad.")
    }

    // Per hole, tee to green. This is the row a golfer checks against the ground
    // they actually walked, and the only check available from a desk.
    print("")
    print("  hole     par   rise   plays like   (from the default tee)")
    var missing = 0
    for h in course.holes {
        guard let g = h.geometry() else { continue }
        let d = g.distances(from: g.teeAt)
        guard let rise = grid.delta(from: g.teeAt, to: g.greenCenter) else {
            missing += 1
            print("  \(h.id.padding(toLength: max(7, h.id.count), withPad: " ", startingAt: 0))  \(h.par)      ?   off the grid")
            continue
        }
        let plays = Geodesy.playsLike(distance: d.center, elevationDelta: rise)
        print(String(format: "  %@  %3d  %+5.1f   %5.0f -> %5.0f m",
                     h.id.padding(toLength: max(7, h.id.count), withPad: " ", startingAt: 0) as NSString,
                     h.par, rise, d.center, plays))
    }
    if missing > 0 { print("  \(missing) hole(s) fell outside the grid.") }

    let dir = args.string("out").map { URL(fileURLWithPath: $0) }
        ?? url.deletingLastPathComponent()
    let store = CourseStore(directory: dir)
    do { try store.save(grid, for: course.id) }
    catch { fail("could not write the elevation file: \(error)") }
    let path = store.elevationURL(for: course.id)
    let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
    print("")
    print(String(format: "wrote %@  (%.0f KB)", path.path as NSString, Double(size ?? 0) / 1024))
    print(Elevation3DEP.attribution)
}
