import Foundation

/// Just enough GeoTIFF to read an elevation raster.
///
/// **Why hand-rolled rather than a library.** The only thing this reads is what
/// USGS 3DEP's ArcGIS image service returns: single-band, uncompressed, 32-bit
/// float, tiled, EPSG:4326. That is a bounded and testable subset, and the whole
/// alternative was a C dependency (GDAL, libtiff) in a package that currently has
/// exactly one and builds for iOS.
///
/// **Why not the service's raw formats.** `format=bsq` is a headerless dump of
/// the pixels, which is smaller and simpler — and **measured 2026-08-30 it came
/// back with a different number of pixels than the request and the `f=json`
/// metadata both said**: 990,000 bytes for a 300 × 800 request, which is 247,500
/// floats, not 240,000. A raster whose dimensions have to be inferred from the
/// byte count is one transposed grid away from a course file that is silently a
/// hole out of place. TIFF states its own width, height, tiling and
/// georeferencing, and every one of those is read from the file rather than from
/// what was asked for. `lerc` is compressed and would need the codec.
public struct GeoTIFF: Sendable {
    public var width: Int
    public var height: Int
    /// Row-major, top row first. The service returns north at the top.
    public var samples: [Double]
    /// Model space position of raster point (0, 0). Under the default
    /// `RasterPixelIsArea` — which 3DEP sets, geokey 1025 = 1, verified — that is
    /// the **outer corner** of the first pixel, not its centre.
    public var originX: Double, originY: Double
    /// Model units per pixel. Both positive; `y` runs *down*, so row `r` sits at
    /// `originY - r * scaleY`.
    public var scaleX: Double, scaleY: Double
    /// `GTRasterTypeGeoKey`. 1 = PixelIsArea (the default), 2 = PixelIsPoint.
    public var rasterType: Int
    /// `GeographicTypeGeoKey` / `ProjectedCSTypeGeoKey` — 4326 for the geographic
    /// request this makes. Checked rather than assumed: asking for one projection
    /// and being handed another is how a grid ends up 20% out of scale.
    public var epsg: Int?
    /// `GDAL_NODATA`, when the writer set it.
    public var noData: Double?

    /// Centre of the first sample, in model units. The half-pixel shift the
    /// `RasterPixelIsArea` convention requires, applied once, here — so nothing
    /// downstream has to remember which convention the file used.
    public var firstSampleCentre: (x: Double, y: Double) {
        rasterType == 2 ? (originX, originY)
                        : (originX + scaleX / 2, originY - scaleY / 2)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notATIFF
        case unsupported(String)
        case truncated

        public var description: String {
            switch self {
            case .notATIFF: return "not a TIFF"
            case .unsupported(let what): return "unsupported TIFF: \(what)"
            case .truncated: return "TIFF ended mid-raster"
            }
        }
    }

    // MARK: - Parsing

    private struct Entry { var type: Int; var count: Int; var valueOffset: Int; var inline: Int }

    public init(_ data: Data) throws {
        let d = [UInt8](data)
        guard d.count >= 8 else { throw Failure.notATIFF }
        let little: Bool
        switch (d[0], d[1]) {
        case (0x49, 0x49): little = true
        case (0x4d, 0x4d): little = false
        default: throw Failure.notATIFF
        }
        func u16(_ at: Int) throws -> Int {
            guard at + 1 < d.count else { throw Failure.truncated }
            return little ? Int(d[at]) | Int(d[at + 1]) << 8
                          : Int(d[at]) << 8 | Int(d[at + 1])
        }
        func u32(_ at: Int) throws -> Int {
            guard at + 3 < d.count else { throw Failure.truncated }
            return little
                ? Int(d[at]) | Int(d[at+1]) << 8 | Int(d[at+2]) << 16 | Int(d[at+3]) << 24
                : Int(d[at]) << 24 | Int(d[at+1]) << 16 | Int(d[at+2]) << 8 | Int(d[at+3])
        }
        func f64(_ at: Int) throws -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 {
                guard at + i < d.count else { throw Failure.truncated }
                bits |= UInt64(d[at + (little ? i : 7 - i)]) << (8 * UInt64(i))
            }
            return Double(bitPattern: bits)
        }
        func f32(_ at: Int) throws -> Double {
            var bits: UInt32 = 0
            for i in 0..<4 {
                guard at + i < d.count else { throw Failure.truncated }
                bits |= UInt32(d[at + (little ? i : 3 - i)]) << (8 * UInt32(i))
            }
            return Double(Float(bitPattern: bits))
        }
        guard try u16(2) == 42 else { throw Failure.unsupported("BigTIFF or bad magic") }

        // --- The first IFD. Later ones are overviews; this reads the full image only.
        let ifd = try u32(4)
        let count = try u16(ifd)
        var tags: [Int: Entry] = [:]
        for i in 0..<count {
            let p = ifd + 2 + i * 12
            let tag = try u16(p), type = try u16(p + 2), n = try u32(p + 4)
            tags[tag] = Entry(type: type, count: n, valueOffset: try u32(p + 8),
                              inline: p + 8)
        }
        /// A TIFF entry stores its value inline when it fits in four bytes.
        func values(_ e: Entry) throws -> [Int] {
            let size = [0: 0, 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 12: 8][e.type] ?? 0
            let base = size * e.count <= 4 ? e.inline : e.valueOffset
            return try (0..<e.count).map { i -> Int in
                switch e.type {
                case 3: return try u16(base + i * 2)
                case 4: return try u32(base + i * 4)
                case 1: return Int(d[base + i])
                default: throw Failure.unsupported("tag type \(e.type)")
                }
            }
        }
        func doubles(_ e: Entry) throws -> [Double] {
            try (0..<e.count).map { try f64(e.valueOffset + $0 * 8) }
        }
        func first(_ tag: Int) throws -> Int? {
            guard let e = tags[tag] else { return nil }
            return try values(e).first
        }

        guard let w = try first(256), let h = try first(257) else {
            throw Failure.unsupported("no image dimensions")
        }
        width = w; height = h
        let bits = try first(258) ?? 8
        let compression = try first(259) ?? 1
        let bands = try first(277) ?? 1
        // 1 = unsigned int, 2 = signed int, 3 = IEEE float.
        let format = try first(339) ?? 1
        guard compression == 1 else { throw Failure.unsupported("compression \(compression)") }
        guard bands == 1 else { throw Failure.unsupported("\(bands) bands") }
        guard (bits == 32 && (format == 3 || format == 2))
                || (bits == 16 && format == 2) else {
            throw Failure.unsupported("\(bits)-bit sample format \(format)")
        }

        // --- Georeferencing. Read from the file, never from the request that
        // produced it: measured 2026-08-30, the service snaps a requested bbox
        // outward to whole posts — by 146 m at Coyote Creek in one call.
        var sx = 1.0, sy = 1.0, ox = 0.0, oy = 0.0
        if let e = tags[33550] {
            let s = try doubles(e)
            if s.count >= 2 { sx = s[0]; sy = s[1] }
        }
        if let e = tags[33922] {
            let t = try doubles(e)
            // (i, j, k, x, y, z): raster point (i, j) is at model (x, y). Only the
            // ordinary (0, 0) case is handled — anything else is a rotated or
            // multi-tiepoint file this does not claim to read.
            if t.count >= 6, t[0] == 0, t[1] == 0 { ox = t[3]; oy = t[4] }
            else if t.count >= 6 { throw Failure.unsupported("tiepoint at raster \(t[0]),\(t[1])") }
        }
        scaleX = sx; scaleY = sy; originX = ox; originY = oy

        var rt = 1, code: Int?
        if let e = tags[34735] {
            let keys = try values(e)
            if keys.count >= 4 {
                for k in 0..<keys[3] {
                    let base = 4 + k * 4
                    guard base + 3 < keys.count else { break }
                    let id = keys[base], loc = keys[base + 1], value = keys[base + 3]
                    guard loc == 0 else { continue }   // only immediate SHORT values
                    if id == 1025 { rt = value }
                    if id == 2048 || id == 3072 { code = value }
                }
            }
        }
        rasterType = rt; epsg = code

        var nd: Double?
        if let e = tags[42113], e.type == 2 {
            let base = e.count <= 4 ? e.inline : e.valueOffset
            let bytes = (0..<e.count).compactMap { i -> UInt8? in
                base + i < d.count ? d[base + i] : nil
            }
            nd = Double(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        }
        noData = nd

        // --- Pixels. Tiled and stripped layouts both, because which one the
        // service emits is its choice: it returned *tiled* 128 x 128 for every
        // request measured here, and a stripped file would otherwise decode as an
        // empty grid rather than as an error.
        var out = [Double](repeating: .nan, count: w * h)
        func read(_ offset: Int, _ index: Int) throws -> Double {
            switch (bits, format) {
            case (32, 3): return try f32(offset + index * 4)
            case (32, 2): return Double(Int32(truncatingIfNeeded: try u32(offset + index * 4)))
            default:      return Double(Int16(truncatingIfNeeded: try u16(offset + index * 2)))
            }
        }
        if let tw = try first(322), let th = try first(323), let offsets = tags[324] {
            guard tw > 0, th > 0 else { throw Failure.unsupported("zero tile size") }
            let offs = try values(offsets)
            let across = (w + tw - 1) / tw
            for (i, o) in offs.enumerated() {
                let tx = (i % across) * tw, ty = (i / across) * th
                for r in 0..<th where ty + r < h {
                    for c in 0..<tw where tx + c < w {
                        out[(ty + r) * w + tx + c] = try read(o, r * tw + c)
                    }
                }
            }
        } else if let offsets = tags[273] {
            let rows = try first(278) ?? h
            let offs = try values(offsets)
            guard rows > 0 else { throw Failure.unsupported("zero rows per strip") }
            for (i, o) in offs.enumerated() {
                for r in 0..<rows where i * rows + r < h {
                    for c in 0..<w { out[(i * rows + r) * w + c] = try read(o, r * w + c) }
                }
            }
        } else {
            throw Failure.unsupported("neither tiles nor strips")
        }
        samples = out
    }

    /// Height at `(x, y)`, or nil for a void — the writer's `GDAL_NODATA`, a NaN,
    /// or one of the enormous sentinels raster services use off-coverage.
    public func value(_ x: Int, _ y: Int) -> Double? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = samples[y * width + x]
        guard v.isFinite, abs(v) < 1e6 else { return nil }
        if let noData, abs(v - noData) < 1e-6 { return nil }
        return v
    }
}
