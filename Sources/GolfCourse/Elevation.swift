import Foundation

/// A course's terrain, as a stored grid of ground heights.
///
/// **The third acquisition.** A card gives par and yardage, OSM gives geometry,
/// and neither gives elevation — but elevation behaves like geometry rather than
/// like imagery: it is ours to store, it does not change between rounds, and it
/// must work with no signal, because a course has none. research-elevation.md §6.
///
/// **Why a stored grid rather than the phone.** GNSS vertical error is two to
/// three times the horizontal error and correlated over minutes, so a phone
/// cannot measure an 8 m rise. USGS 3DEP 1 m is lidar-derived bare earth,
/// specified at 10 cm (1σ), and public domain. Measured here 2026-08-30 against
/// the USGS point service at two courses: **3 cm at Corica, 10 cm at Coyote
/// Creek**. research-elevation.md §1, §3.
///
/// ## The datum rule, and why it is enforced by the type
///
/// A plays-like number is a *difference*, so the datum cancels — **but only when
/// both ends come from the same source.** 3DEP is NAVD88 orthometric;
/// `CLLocation.altitude` is above mean sea level and `ellipsoidalAltitude` is
/// above the WGS84 ellipsoid, and those differ by roughly **−30 m in
/// California**. One end from the DEM and one from the phone is a plays-like
/// number thirty metres wrong that reads like an ordinary large number.
/// research-elevation.md §4.
///
/// So there is no public `Double` height. `sample(at:)` returns a `Sample`
/// carrying its own `datum` and `source`, and `Sample.delta(_:_:)` **returns nil
/// when the two disagree**. A future GLO-30 grid over a Korean course is a
/// different datum and a different quality, and nothing downstream can subtract
/// across the two by accident.
///
/// ## Storage
///
/// Row-major, **north to south**, west to east — the order a GeoTIFF arrives in.
/// Heights are `Int16` **decimetres**, which spans ±3276.7 m (Everest is 8849)
/// and halves the file against `Float`. Corica is 300 × 800 at ~3 m posts: 480 KB.
/// Coyote Creek is 700 × 600: 840 KB. Both are nothing beside half a gigabyte of
/// CoreML, and both are one request under the service's 8000-pixel cap.
///
/// Georeferencing is in **degrees**, not metres, and that is deliberate: it keeps
/// every projection out of `GolfCourse` and makes sampling two divisions. The
/// posts are not square on the ground — 2.2 m east–west against 2.8 m
/// north–south at Coyote's latitude — which a bilinear sample does not care
/// about. `nativePosts` reports the ground spacing for anyone who does.
public struct Elevation: Codable, Sendable, Equatable {

    /// Where the heights came from. Never inferred from the data — a fetcher
    /// states it, the same rule `Course.Source` follows, and for the same reason:
    /// a guessed provenance is indistinguishable from a surveyed one.
    public enum Source: String, Codable, Sendable {
        /// USGS 3D Elevation Program. Public domain, bare earth, US only.
        case usgs3DEP
        /// Copernicus GLO-30. Global, 30 m, and a **surface** model — it carries
        /// canopy and clubhouse roofs as though they were ground, which is the
        /// opposite of what a golf number needs. Marked coarse wherever it shows.
        case copernicusGLO30
        /// Walked with the MARK button, or otherwise measured by us.
        case survey
        /// Built in code, for previews and tests.
        case sample
    }

    /// The vertical reference. **Not readable from a 3DEP GeoTIFF** — its geokeys
    /// describe the *horizontal* CRS and its GDAL metadata says only "Generic" —
    /// so the fetcher asserts it from the product it asked for, and it is written
    /// into the file rather than assumed at read time.
    public enum Datum: String, Codable, Sendable {
        /// North American Vertical Datum of 1988. What 3DEP publishes.
        case navd88
        /// EGM2008 geoid. What Copernicus publishes.
        case egm2008
        /// Height above the WGS84 ellipsoid. What `CLLocation.ellipsoidalAltitude`
        /// is, and roughly 30 m from either of the above in California.
        case wgs84Ellipsoid
    }

    /// One height, and everything needed to know whether it may be subtracted
    /// from another one.
    public struct Sample: Sendable, Equatable {
        /// Metres above `datum`.
        public var height: Double
        public var datum: Datum
        public var source: Source
        /// The source product's own post spacing in metres — 1 for 3DEP 1 m, 10
        /// for 1/3 arc-second, 30 for GLO-30. **Not** this grid's spacing, which
        /// is a resampling choice; this is what the terrain was actually measured
        /// at, and it is what decides whether a green's own contour is even
        /// present in the data.
        public var nativeResolution: Double

        public init(height: Double, datum: Datum, source: Source,
                    nativeResolution: Double) {
            self.height = height; self.datum = datum
            self.source = source; self.nativeResolution = nativeResolution
        }

        /// `b - a`, in metres, **or nil when the two are not comparable**.
        ///
        /// This is research-elevation.md §4's invariant, made structural: the
        /// datum cancels over a difference only if both ends share it. Returning
        /// nil is the honest answer — a plays-like number with nothing behind it
        /// must disappear rather than read a plausible thirty metres.
        public static func delta(from a: Sample, to b: Sample) -> Double? {
            guard a.datum == b.datum else { return nil }
            return b.height - a.height
        }
    }

    /// A height no source produced — outside the DEM's coverage, or a void in it.
    /// Stored rather than dropped: a hole that runs off the edge of the grid has
    /// to read *unknown*, not zero.
    static let noData: Int16 = .min

    public var source: Source
    public var datum: Datum
    /// See `Sample.nativeResolution`.
    public var nativeResolution: Double

    /// Centre of sample `[0][0]` — the **north-west** corner of the grid.
    ///
    /// The centre, not the corner. A GeoTIFF tiepoint under the default
    /// `RasterPixelIsArea` maps raster (0, 0) to the corner of the first pixel,
    /// so the fetcher shifts it half a post; storing the centre keeps sampling
    /// from having to know which convention the file it came from used.
    public var lat0: Double, lon0: Double
    /// Post spacing in degrees. Both positive; **rows run south** and columns run
    /// east, so row `r` is at `lat0 - r * dLat`.
    public var dLat: Double, dLon: Double
    public var width: Int, height: Int

    /// Row-major decimetres, north to south. `noData` where nothing is known.
    /// Encoded as base64 rather than a JSON array of a quarter-million numbers.
    var samples: [Int16]

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case source, datum, nativeResolution, lat0, lon0, dLat, dLon, width, height
        case samples
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(Source.self, forKey: .source)
        datum = try c.decode(Datum.self, forKey: .datum)
        nativeResolution = try c.decode(Double.self, forKey: .nativeResolution)
        lat0 = try c.decode(Double.self, forKey: .lat0)
        lon0 = try c.decode(Double.self, forKey: .lon0)
        dLat = try c.decode(Double.self, forKey: .dLat)
        dLon = try c.decode(Double.self, forKey: .dLon)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        let blob = try c.decode(String.self, forKey: .samples)
        guard let data = Data(base64Encoded: blob), data.count == width * height * 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .samples, in: c,
                debugDescription: "expected \(width * height * 2) bytes of samples")
        }
        samples = Self.decode(data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(datum, forKey: .datum)
        try c.encode(nativeResolution, forKey: .nativeResolution)
        try c.encode(lat0, forKey: .lat0)
        try c.encode(lon0, forKey: .lon0)
        try c.encode(dLat, forKey: .dLat)
        try c.encode(dLon, forKey: .dLon)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(Self.encode(samples).base64EncodedString(), forKey: .samples)
    }

    /// Little-endian on both sides, explicitly, so a file written on one
    /// architecture reads on another.
    static func encode(_ v: [Int16]) -> Data {
        var out = Data(capacity: v.count * 2)
        for s in v {
            let u = UInt16(bitPattern: s)
            out.append(UInt8(u & 0xff)); out.append(UInt8(u >> 8))
        }
        return out
    }

    static func decode(_ d: Data) -> [Int16] {
        var out = [Int16](); out.reserveCapacity(d.count / 2)
        d.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count - 1, by: 2) {
                out.append(Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)))
            }
        }
        return out
    }

    // MARK: - Building

    /// - Parameter metres: row-major, north to south. `nil` for a void.
    public init(source: Source, datum: Datum, nativeResolution: Double,
                lat0: Double, lon0: Double, dLat: Double, dLon: Double,
                width: Int, height: Int, metres: [Double?]) {
        self.source = source; self.datum = datum
        self.nativeResolution = nativeResolution
        self.lat0 = lat0; self.lon0 = lon0
        self.dLat = dLat; self.dLon = dLon
        self.width = width; self.height = height
        self.samples = metres.map { m in
            guard let m, m.isFinite, m > -3276, m < 3276 else { return Self.noData }
            return Int16((m * 10).rounded())
        }
    }

    // MARK: - Reading

    /// North-west and south-east corners of the covered ground.
    public var bounds: (north: Double, west: Double, south: Double, east: Double) {
        (north: lat0, west: lon0,
         south: lat0 - Double(height - 1) * dLat,
         east: lon0 + Double(width - 1) * dLon)
    }

    /// Ground post spacing in metres, east–west and north–south. The two differ
    /// because the grid is stored in degrees.
    public var nativePosts: (east: Double, north: Double) {
        let mPerDegLat = .pi * Geodesy.earthRadius / 180
        let midLat = lat0 - Double(height - 1) * dLat / 2
        return (east: dLon * mPerDegLat * cos(midLat * .pi / 180),
                north: dLat * mPerDegLat)
    }

    public func contains(_ c: Coordinate) -> Bool {
        let b = bounds
        return c.lat <= b.north && c.lat >= b.south && c.lon >= b.west && c.lon <= b.east
    }

    /// Bilinearly interpolated ground height at `c`, or nil outside the grid or
    /// over a void.
    ///
    /// **Bilinear rather than nearest** because the posts are metres apart and a
    /// nearest-post answer steps by a whole post as the golfer walks — which on a
    /// sloping fairway makes the plays-like number jump while they stand still.
    /// A void anywhere in the four corners makes the whole sample nil: averaging
    /// a known height with an unknown one produces a number nothing measured.
    public func sample(at c: Coordinate) -> Sample? {
        guard width > 0, height > 0, dLat > 0, dLon > 0 else { return nil }
        var fx = (c.lon - lon0) / dLon
        var fy = (lat0 - c.lat) / dLat
        // **Clamped inside a post's-width of tolerance**, not tested exactly. A
        // point derived arithmetically from the grid's own corner lands a few ulps
        // outside it — measured, the last row of an 8 x 6 grid came out at
        // 5.0000000001 — and a green sitting on the edge post would then have no
        // height at all, for no reason visible from anywhere. `epsilon` is a
        // millionth of a post: far below what any coordinate here resolves.
        let epsilon = 1e-6
        guard fx >= -epsilon, fy >= -epsilon,
              fx <= Double(width - 1) + epsilon,
              fy <= Double(height - 1) + epsilon else { return nil }
        fx = min(max(fx, 0), Double(width - 1))
        fy = min(max(fy, 0), Double(height - 1))
        let x0 = min(Int(fx), width - 1), y0 = min(Int(fy), height - 1)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        // **A corner with no weight is not consulted.** The obvious version reads
        // all four unconditionally, which makes a point sitting *exactly* on a
        // known post return nil whenever the post diagonally next to it is a void —
        // a hole beside a water body losing its number for no reason the golfer
        // could see. Zero weight means the value cannot affect the answer, so
        // requiring it is a refusal with nothing behind it.
        var total = 0.0
        for (x, y, w) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)),
                          (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] where w > 0 {
            guard let v = at(x, y) else { return nil }
            total += v * w
        }
        return Sample(height: total, datum: datum, source: source,
                      nativeResolution: nativeResolution)
    }

    /// Raw post, metres, or nil for a void. Row 0 is the northernmost.
    public func at(_ x: Int, _ y: Int) -> Double? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = samples[y * width + x]
        guard v != Self.noData else { return nil }
        return Double(v) / 10
    }

    /// Metres of rise from `a` to `b`. Both ends come from this grid, so the
    /// datum cancels by construction. Nil when either end is off the grid.
    public func delta(from a: Coordinate, to b: Coordinate) -> Double? {
        guard let s = sample(at: a), let e = sample(at: b) else { return nil }
        return Sample.delta(from: s, to: e)
    }

    /// `count` evenly spaced heights from `a` to `b` inclusive — the terrain
    /// profile under a shot. A void along the way is a nil in the list rather
    /// than a gap, so the caller can draw the break instead of joining across it.
    public func profile(from a: Coordinate, to b: Coordinate, count: Int = 64) -> [Double?] {
        guard count > 1 else { return [sample(at: a)?.height] }
        return (0..<count).map { i in
            sample(at: Geodesy.interpolate(a, b, Double(i) / Double(count - 1)))?.height
        }
    }

    /// How much of `polygon`'s bounding span the grid actually covers, 0…1.
    /// Reported at import: a grid that misses a corner of the course produces
    /// holes whose plays-like silently disappears, which looks like a feature
    /// that does not work rather than a file that is too small.
    public func coverage(of points: [Coordinate]) -> Double {
        guard !points.isEmpty else { return 0 }
        let inside = points.filter { sample(at: $0) != nil }.count
        return Double(inside) / Double(points.count)
    }
}
