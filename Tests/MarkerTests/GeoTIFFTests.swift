import XCTest
@testable import GolfTerrain
@testable import GolfCourse

/// The elevation raster reader.
///
/// **Every fixture here is synthesised.** A real 3DEP response is 1.4 MB, and the
/// point of a test is to pin the shapes the service is *allowed* to send — tiled
/// and stripped, either byte order — not to re-record one response and call it
/// coverage. The live path is verified in `golfctl course elevation`, whose output
/// is checked against the USGS point service.
final class GeoTIFFTests: XCTestCase {

    // MARK: - A TIFF writer, so the reader has something to read

    private struct Tag { var id: Int; var type: Int; var values: [Int] }

    /// Writes a single-band, uncompressed, F32 TIFF. `tile` picks the layout.
    private func tiff(width: Int, height: Int, pixels: [Float],
                      tile: (w: Int, h: Int)? = nil,
                      little: Bool = true,
                      scale: (Double, Double) = (0.001, 0.001),
                      tiepoint: (Double, Double) = (-121.7, 37.2),
                      rasterType: Int = 1,
                      epsg: Int = 4326,
                      noData: String? = nil) -> Data {
        func u16(_ v: Int) -> [UInt8] {
            little ? [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
                   : [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        func u32(_ v: Int) -> [UInt8] {
            let b = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                     UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
            return little ? b : b.reversed()
        }
        func f64(_ v: Double) -> [UInt8] {
            let bits = v.bitPattern
            let b = (0..<8).map { UInt8((bits >> (8 * UInt64($0))) & 0xff) }
            return little ? b : b.reversed()
        }
        func f32(_ v: Float) -> [UInt8] {
            let bits = v.bitPattern
            let b = (0..<4).map { UInt8((bits >> (8 * UInt32($0))) & 0xff) }
            return little ? b : b.reversed()
        }

        // --- Pixel data first, so its offsets are known before the IFD is laid out.
        var body: [UInt8] = []
        var offsets: [Int] = [], counts: [Int] = []
        let dataStart = 8
        if let tile {
            let across = (width + tile.w - 1) / tile.w
            let down = (height + tile.h - 1) / tile.h
            for ty in 0..<down {
                for tx in 0..<across {
                    offsets.append(dataStart + body.count)
                    for r in 0..<tile.h {
                        for c in 0..<tile.w {
                            let x = tx * tile.w + c, y = ty * tile.h + r
                            // Padding pixels beyond the image are written and ignored.
                            let v = (x < width && y < height) ? pixels[y * width + x] : 0
                            body += f32(v)
                        }
                    }
                    counts.append(tile.w * tile.h * 4)
                }
            }
        } else {
            offsets.append(dataStart)
            for p in pixels { body += f32(p) }
            counts.append(pixels.count * 4)
        }

        var tags: [Tag] = [
            Tag(id: 256, type: 3, values: [width]),
            Tag(id: 257, type: 3, values: [height]),
            Tag(id: 258, type: 3, values: [32]),
            Tag(id: 259, type: 3, values: [1]),
            Tag(id: 262, type: 3, values: [1]),
            Tag(id: 277, type: 3, values: [1]),
            Tag(id: 339, type: 3, values: [3]),
        ]
        if let tile {
            tags += [Tag(id: 322, type: 3, values: [tile.w]),
                     Tag(id: 323, type: 3, values: [tile.h]),
                     Tag(id: 324, type: 4, values: offsets),
                     Tag(id: 325, type: 4, values: counts)]
        } else {
            tags += [Tag(id: 273, type: 4, values: offsets),
                     Tag(id: 278, type: 3, values: [height]),
                     Tag(id: 279, type: 4, values: counts)]
        }
        tags.sort { $0.id < $1.id }

        // --- Out-of-line values (and the doubles) go after the IFD. The size has
        // to count the three geo tags added below, or every offset placed here
        // lands *inside* the IFD.
        let ifdStart = dataStart + body.count
        let ifdSize = 2 + (tags.count + 3 + (noData == nil ? 0 : 1)) * 12 + 4
        var extra: [UInt8] = []
        func place(_ bytes: [UInt8]) -> Int {
            let at = ifdStart + ifdSize + extra.count
            extra += bytes
            return at
        }
        let scaleAt = place(f64(scale.0) + f64(scale.1) + f64(0))
        let tieAt = place(f64(0) + f64(0) + f64(0)
                          + f64(tiepoint.0) + f64(tiepoint.1) + f64(0))
        var geoKeys = [1, 1, 0, 2] + [1025, 0, 1, rasterType] + [2048, 0, 1, epsg]
        let keysAt = place(geoKeys.flatMap { u16($0) })
        var ndAt = 0, ndLen = 0
        if let noData {
            let bytes = Array(noData.utf8) + [0]
            ndLen = bytes.count
            ndAt = place(bytes)
        }
        tags += [Tag(id: 33550, type: 12, values: [scaleAt]),
                 Tag(id: 33922, type: 12, values: [tieAt]),
                 Tag(id: 34735, type: 3, values: [keysAt])]
        if ndLen > 0 { tags.append(Tag(id: 42113, type: 2, values: [ndAt])) }
        // The three above are written by hand below, since their `values` hold an
        // offset rather than the data itself.
        let counted: [Int: Int] = [33550: 3, 33922: 6, 34735: geoKeys.count, 42113: ndLen]
        tags.sort { $0.id < $1.id }

        var out: [UInt8] = (little ? [0x49, 0x49] : [0x4d, 0x4d]) + u16(42) + u32(ifdStart)
        out += body
        out += u16(tags.count)
        for t in tags {
            out += u16(t.id) + u16(t.type)
            if let n = counted[t.id] {
                out += u32(n) + u32(t.values[0])
                continue
            }
            out += u32(t.values.count)
            let size = t.type == 3 ? 2 : 4
            if size * t.values.count <= 4 {
                var inline: [UInt8] = t.values.flatMap { t.type == 3 ? u16($0) : u32($0) }
                while inline.count < 4 { inline.append(0) }
                out += inline
            } else {
                out += u32(place(t.values.flatMap { t.type == 3 ? u16($0) : u32($0) }))
            }
        }
        out += u32(0)
        out += extra
        _ = geoKeys
        return Data(out)
    }

    private func ramp(_ w: Int, _ h: Int) -> [Float] {
        (0..<(w * h)).map { Float($0 % w) + Float($0 / w) * 100 }
    }

    // MARK: - Layouts

    /// **Tiled is the shape 3DEP actually returns** — measured 2026-08-30, 128 x 128
    /// tiles on every request made here.
    func testATiledRasterDecodesInRasterOrder() throws {
        let px = ramp(10, 7)
        let t = try GeoTIFF(tiff(width: 10, height: 7, pixels: px, tile: (4, 4)))
        XCTAssertEqual(t.width, 10)
        XCTAssertEqual(t.height, 7)
        for y in 0..<7 {
            for x in 0..<10 {
                XCTAssertEqual(try XCTUnwrap(t.value(x, y)),
                               Double(px[y * 10 + x]), accuracy: 0.001,
                               "tile padding must not leak into the image at \(x),\(y)")
            }
        }
    }

    /// A stripped file would otherwise decode as an empty grid rather than as an
    /// error — the service's choice of layout is not ours.
    func testAStrippedRasterDecodesToTheSamePixels() throws {
        let px = ramp(6, 5)
        let tiled = try GeoTIFF(tiff(width: 6, height: 5, pixels: px, tile: (2, 3)))
        let stripped = try GeoTIFF(tiff(width: 6, height: 5, pixels: px))
        XCTAssertEqual(tiled.samples, stripped.samples)
    }

    func testABigEndianFileReadsTheSameAsALittleEndianOne() throws {
        let px = ramp(5, 4)
        let le = try GeoTIFF(tiff(width: 5, height: 4, pixels: px, tile: (2, 2)))
        let be = try GeoTIFF(tiff(width: 5, height: 4, pixels: px, tile: (2, 2), little: false))
        XCTAssertEqual(le.samples, be.samples)
        XCTAssertEqual(be.scaleX, le.scaleX, accuracy: 1e-12)
        XCTAssertEqual(be.originY, le.originY, accuracy: 1e-12)
    }

    // MARK: - Georeferencing

    /// **Read from the file, never from the request.** Measured 2026-08-30, the
    /// service snaps a requested bbox outward to whole posts — by 146 m at Coyote
    /// Creek in one call — so a grid georeferenced from what was asked for is
    /// offset by up to that much.
    func testGeoreferencingComesFromTheTiepointAndPixelScale() throws {
        let t = try GeoTIFF(tiff(width: 4, height: 4, pixels: ramp(4, 4),
                                 scale: (0.002, 0.003), tiepoint: (-121.75, 37.25)))
        XCTAssertEqual(t.scaleX, 0.002, accuracy: 1e-12)
        XCTAssertEqual(t.scaleY, 0.003, accuracy: 1e-12)
        XCTAssertEqual(t.originX, -121.75, accuracy: 1e-12)
        XCTAssertEqual(t.originY, 37.25, accuracy: 1e-12)
        XCTAssertEqual(t.epsg, 4326)
    }

    /// `GTRasterTypeGeoKey` = 1 (PixelIsArea) is what 3DEP sets, verified against a
    /// live response: the tiepoint is the **corner** of the first pixel, so the
    /// first sample's centre is half a post in. Getting this wrong displaces the
    /// whole grid by half a post — 1.5 m at the spacing used here, which is small
    /// enough to look correct and is a systematic error in every number.
    func testPixelIsAreaShiftsTheFirstSampleByHalfAPost() throws {
        let area = try GeoTIFF(tiff(width: 3, height: 3, pixels: ramp(3, 3),
                                    scale: (0.002, 0.004), tiepoint: (-121.75, 37.25),
                                    rasterType: 1))
        XCTAssertEqual(area.rasterType, 1)
        XCTAssertEqual(area.firstSampleCentre.x, -121.749, accuracy: 1e-9)
        XCTAssertEqual(area.firstSampleCentre.y, 37.248, accuracy: 1e-9)

        let point = try GeoTIFF(tiff(width: 3, height: 3, pixels: ramp(3, 3),
                                     scale: (0.002, 0.004), tiepoint: (-121.75, 37.25),
                                     rasterType: 2))
        XCTAssertEqual(point.firstSampleCentre.x, -121.75, accuracy: 1e-12)
        XCTAssertEqual(point.firstSampleCentre.y, 37.25, accuracy: 1e-12)
    }

    // MARK: - Voids and refusals

    func testNoDataAndNonFiniteSamplesReadAsVoids() throws {
        var px = ramp(3, 3)
        px[1] = -9999
        px[4] = .nan
        px[7] = -3.4e38          // the sentinel a raster service uses off-coverage
        let t = try GeoTIFF(tiff(width: 3, height: 3, pixels: px, noData: "-9999"))
        XCTAssertNil(t.value(1, 0))
        XCTAssertNil(t.value(1, 1))
        XCTAssertNil(t.value(1, 2))
        XCTAssertNotNil(t.value(0, 0))
    }

    func testSomethingThatIsNotATIFFIsRefusedRatherThanDecodedAsNoise() {
        // The shape that matters: an ArcGIS service reports an error as a 200 with
        // a JSON body, and reading that as a raster would produce a grid of noise.
        let json = Data(#"{"error":{"code":400,"message":"Invalid bounding box"}}"#.utf8)
        XCTAssertThrowsError(try GeoTIFF(json)) { e in
            XCTAssertEqual(e as? GeoTIFF.Failure, .notATIFF)
        }
        XCTAssertThrowsError(try GeoTIFF(Data()))
    }

    func testACompressedRasterIsRefusedRatherThanMisread() {
        var d = [UInt8](tiff(width: 3, height: 3, pixels: ramp(3, 3)))
        // Find the compression tag (259) in the IFD and set it to LZW (5).
        let ifd = Int(d[4]) | Int(d[5]) << 8 | Int(d[6]) << 16 | Int(d[7]) << 24
        let n = Int(d[ifd]) | Int(d[ifd + 1]) << 8
        for i in 0..<n where Int(d[ifd + 2 + i * 12]) | Int(d[ifd + 3 + i * 12]) << 8 == 259 {
            d[ifd + 2 + i * 12 + 8] = 5
        }
        XCTAssertThrowsError(try GeoTIFF(Data(d))) { e in
            guard case .unsupported = (e as? GeoTIFF.Failure) else {
                return XCTFail("expected .unsupported, got \(e)")
            }
        }
    }

    // MARK: - The whole pipeline, minus the socket

    /// What `Elevation3DEP.fetch` does after the bytes arrive: half-pixel shift,
    /// north-to-south rows, decimetre storage, and a sample that lands where the
    /// raster says it should.
    func testARasterBecomesAGridThatSamplesBackToTheSamePixels() throws {
        let w = 8, h = 6
        let px: [Float] = (0..<(w * h)).map { Float($0) / 4 }
        let t = try GeoTIFF(tiff(width: w, height: h, pixels: px, tile: (4, 4),
                                 scale: (0.0001, 0.0001), tiepoint: (-121.7, 37.2)))
        let centre = t.firstSampleCentre
        let grid = Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                             lat0: centre.y, lon0: centre.x,
                             dLat: t.scaleY, dLon: t.scaleX,
                             width: w, height: h,
                             metres: (0..<(w * h)).map { t.value($0 % w, $0 / w) })
        for y in 0..<h {
            for x in 0..<w {
                let at = Coordinate(lat: centre.y - Double(y) * t.scaleY,
                                    lon: centre.x + Double(x) * t.scaleX)
                // 0.06 rather than 0.05: heights are stored as decimetres, so a
                // quarter-metre pixel comes back rounded to the nearest 0.1. That
                // is the storage decision, not slack in the arithmetic.
                XCTAssertEqual(try XCTUnwrap(grid.sample(at: at)).height,
                               Double(px[y * w + x]), accuracy: 0.06,
                               "row \(y) must be \(y) posts *south* of the first")
            }
        }
    }
}
