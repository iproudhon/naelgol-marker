import Foundation
import GolfCourse

/// USGS 3DEP → an `Elevation` grid, over the network, once per course.
///
/// **Measured 2026-08-30 against the live service**, which is why this exists in
/// this shape rather than the shape research-elevation.md §7 sketched:
///
/// | | Corica Park South | Coyote Creek Tournament |
/// |---|---|---|
/// | native resolution reported | **1 m** | **1 m** |
/// | grid against the point service | 1.375 m vs **1.345** | 107.31 m vs **107.21** |
/// | relief across the site | 10 m | **133 m** |
/// | one request | 6.5 s, 1.4 MB | 15.5 s, 1.7 MB |
///
/// So **3DEP 1 m covers both courses this group has files for** — open question
/// E1, answered — and a single `exportImage` call fetches a whole course well
/// under the service's 8000-pixel cap. There is no tiler and there is no need
/// for one.
///
/// **Corica cannot verify a plays-like number and Coyote can.** research-elevation
/// §7 names Corica for step 2 because it was the only course file that existed
/// when the doc was written; at 10 m of relief across the entire property every
/// tee-to-green delta there is a yard or two, which no plays-like error would
/// show up against. Coyote Creek's 133 m is the one to check against.
public enum Elevation3DEP {

    /// The seamless dynamic 3DEP image service. 1 m where lidar has been flown,
    /// coarser where it has not, and it reports which per pixel through the
    /// companion point service.
    public static let imageService =
        "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer"
    /// The point service — one elevation, and crucially the **resolution of the
    /// raster that answered**. `exportImage` will happily resample 10 m data to a
    /// 3 m grid and say nothing, which is a file that looks like lidar and is not.
    public static let pointService = "https://epqs.nationalmap.gov/v1/json"

    /// Named after the product, not after this grid's spacing. See
    /// `Elevation.Sample.nativeResolution`.
    public static let datum: Elevation.Datum = .navd88

    /// `Public domain, courtesy of the U.S. Geological Survey.` USGS asks for
    /// attribution rather than requiring it; carrying it costs a string.
    public static let attribution = "Elevation: USGS 3D Elevation Program (3DEP), public domain"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case http(Int, String)
        case service(String)
        case tooLarge(Int, Int)
        case notGeographic(Int?)
        case empty

        public var description: String {
            switch self {
            case .http(let code, let body):
                return "3DEP returned HTTP \(code): \(body.prefix(200))"
            case .service(let m): return "3DEP: \(m)"
            case .tooLarge(let w, let h):
                return """
                    \(w)x\(h) exceeds the service's 8000-pixel limit — \
                    use a coarser --spacing
                    """
            case .notGeographic(let epsg):
                return "3DEP returned EPSG \(epsg.map(String.init) ?? "?"), expected 4326"
            case .empty: return "3DEP returned no usable elevations for that area"
            }
        }
    }

    /// The service's own cap on a single `exportImage`, read from its metadata.
    public static let maxPixels = 8000

    public struct Report: Sendable {
        public var width: Int, height: Int
        public var postsEast: Double, postsNorth: Double
        public var minimum: Double, maximum: Double
        public var voids: Int
        /// What the point service says the underlying raster's resolution is at
        /// the centre of the course, in metres. 1 means lidar.
        public var nativeResolution: Double
        public var bytes: Int
    }

    // MARK: - Fetch

    /// One grid covering `bounds`, at roughly `spacing` metres between posts.
    ///
    /// - Parameters:
    ///   - bounds: south, west, north, east in degrees. Pad it before calling —
    ///     a course's own extent clips the tees just outside it, the same reason
    ///     the OSM feature query widens its box.
    ///   - spacing: **target** ground spacing. The service snaps to whole posts
    ///     and the result is stored in degrees, so the delivered spacing differs
    ///     east–west from north–south. 3 m is the default: it is well inside 3DEP
    ///     1 m's own detail, it keeps a whole course under a megabyte, and a golf
    ///     number does not resolve a metre of terrain. A green's own contour would
    ///     need 1 m, and that is E5 — a different feature.
    public static func fetch(bounds: (south: Double, west: Double,
                                      north: Double, east: Double),
                             spacing: Double = 3,
                             session: URLSession = .shared)
        async throws -> (grid: Elevation, report: Report) {

        let mPerDegLat = .pi * Geodesy.earthRadius / 180
        let midLat = (bounds.south + bounds.north) / 2
        let metresNorth = (bounds.north - bounds.south) * mPerDegLat
        let metresEast = (bounds.east - bounds.west) * mPerDegLat * cos(midLat * .pi / 180)
        let w = max(2, Int((metresEast / spacing).rounded()))
        let h = max(2, Int((metresNorth / spacing).rounded()))
        guard w <= maxPixels, h <= maxPixels else { throw Failure.tooLarge(w, h) }

        // Asked for and returned in **EPSG:4326**, deliberately. The obvious
        // request is Web Mercator, and it hands back a pixel scale in *Mercator*
        // units: at Coyote's latitude that is 1/cos(37.2°) = 1.26x the ground
        // metre, so a grid stored as if it were metres puts a sample 270 m from
        // where it belongs at the far corner — a plausible file reading several
        // clubs wrong. Degrees also keep every projection out of `GolfCourse`.
        var c = URLComponents(string: imageService + "/exportImage")!
        c.queryItems = [
            URLQueryItem(name: "bbox", value:
                "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"),
            URLQueryItem(name: "bboxSR", value: "4326"),
            URLQueryItem(name: "imageSR", value: "4326"),
            URLQueryItem(name: "size", value: "\(w),\(h)"),
            URLQueryItem(name: "format", value: "tiff"),
            URLQueryItem(name: "pixelType", value: "F32"),
            URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
            URLQueryItem(name: "f", value: "image"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        // An ArcGIS service reports an error as a 200 with a JSON body. Reading
        // that as a raster would produce a grid of noise rather than a failure.
        if data.count < 8 || (data.first == 0x7b /* { */) {
            throw Failure.service(String(decoding: data.prefix(300), as: UTF8.self))
        }

        let tiff = try GeoTIFF(data)
        guard tiff.epsg == nil || tiff.epsg == 4326 else {
            throw Failure.notGeographic(tiff.epsg)
        }
        let native = (try? await resolution(atLat: midLat,
                                            lon: (bounds.west + bounds.east) / 2,
                                            session: session)) ?? 0

        let centre = tiff.firstSampleCentre
        var metres = [Double?](); metres.reserveCapacity(tiff.width * tiff.height)
        var lo = Double.infinity, hi = -Double.infinity, voids = 0
        for y in 0..<tiff.height {
            for x in 0..<tiff.width {
                if let v = tiff.value(x, y) {
                    metres.append(v); lo = min(lo, v); hi = max(hi, v)
                } else {
                    metres.append(nil); voids += 1
                }
            }
        }
        guard voids < metres.count else { throw Failure.empty }

        let grid = Elevation(source: .usgs3DEP, datum: datum,
                             nativeResolution: native > 0 ? native : spacing,
                             lat0: centre.y, lon0: centre.x,
                             dLat: tiff.scaleY, dLon: tiff.scaleX,
                             width: tiff.width, height: tiff.height, metres: metres)
        let posts = grid.nativePosts
        return (grid, Report(width: tiff.width, height: tiff.height,
                             postsEast: posts.east, postsNorth: posts.north,
                             minimum: lo, maximum: hi, voids: voids,
                             nativeResolution: native, bytes: data.count))
    }

    /// The resolution of the raster that actually answers at one point, in metres.
    ///
    /// **The one thing `exportImage` will not tell you.** It resamples whatever
    /// it has to whatever grid was asked for, so a 3 m grid built over 1/3
    /// arc-second data is byte-identical in shape to one built over lidar. The
    /// difference is a metre of vertical error against ten centimetres, and it
    /// belongs in the file — the same rule as a guessed par being
    /// indistinguishable from a surveyed one.
    public static func resolution(atLat lat: Double, lon: Double,
                                  session: URLSession = .shared) async throws -> Double {
        var c = URLComponents(string: pointService)!
        c.queryItems = [
            URLQueryItem(name: "x", value: "\(lon)"),
            URLQueryItem(name: "y", value: "\(lat)"),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
        ]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 60
        let (data, _) = try await session.data(for: req)
        struct Answer: Decodable { let resolution: Double? }
        return try JSONDecoder().decode(Answer.self, from: data).resolution ?? 0
    }
}
