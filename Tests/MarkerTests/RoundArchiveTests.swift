import XCTest
@testable import GolfExchange
import GolfSessionFormat
import GolfCourse

/// Round-tripping a whole round: out to one document, back into a folder.
///
/// The interesting assertions are all about **not losing and not overwriting**,
/// because those are the two ways an archive fails while reporting success.
final class RoundArchiveTests: XCTestCase {

    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marker-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Fixtures

    private let t: Millis = 1_756_600_000_000

    /// A round with the two things a naive exporter drops: a supersede chain and a
    /// tombstone.
    private func makeRound(at url: URL, course: String? = "Test Links") throws -> SessionFolder {
        let folder = SessionFolder(url: url)
        try folder.create()
        try folder.writeMeta(SessionMeta(
            sessionID: "SESSION-1", course: course,
            players: [Player(name: "steve"), Player(name: "dave")],
            start: t, end: t + 200_000, device: "test", audioFormat: "none"))

        let logs = [
            LogEntry(id: "a1", t: t, text: "7: 2 drive", source: .spoken, tEnd: t + 4_000),
            LogEntry(id: "a2", t: t, text: "7: 2 drive", lat: 37.1, lon: -121.6, hAcc: 4,
                     hole: 7, holeSource: .fix, source: .spoken,
                     supersedes: "a1", tEnd: t + 4_000),
            LogEntry(id: "a3", t: t, text: "7: 2 drive into the bunker",
                     lat: 37.1, lon: -121.6, hAcc: 4, hole: 7, holeSource: .user,
                     player: "steve", shot: 2, source: .spoken,
                     supersedes: "a2", tEnd: t + 4_000),
            LogEntry(id: "b1", t: t + 60_000, text: "스티브가 버디를 했어요",
                     hole: 7, holeSource: .fix, source: .spoken, locale: "ko"),
            LogEntry(id: "c1", t: t + 90_000, text: "nonsense", source: .typed),
            LogEntry(id: "c2", t: t + 95_000, text: "nonsense", source: .typed,
                     supersedes: "c1", deleted: true),
        ]
        try write(logs, .log, folder)
        try write([
            Event(id: "e1", t: t + 5_000, kind: .shot, provenance: .model,
                  player: "steve", hole: 7, confidence: 0.7, logs: ["a3"]),
            Event(id: "e2", t: t + 61_000, kind: .score, provenance: .user,
                  player: "steve", hole: 7, strokes: 3),
        ], .events, folder)
        try write([
            JournalEntry(id: "j1", t: t + 120_000, act: .setScore, player: "steve",
                         hole: 7, strokes: 4),
            JournalEntry(id: "j2", t: t + 130_000, act: .setScore, player: "steve",
                         hole: 7, strokes: 3, prevStrokes: 4),
        ], .journal, folder)
        try write([Mark(t: t + 30_000, player: "steve", lat: 37.1, lon: -121.6, hole: 7)],
                  .marks, folder)
        try write([GPSFix(t: t + 1_000, lat: 37.1, lon: -121.6, hAcc: 5)], .gps, folder)
        try write([AudioSegment(index: 0, file: "audio-000.m4a", t0: t - 1_000, t1: t + 10_000)],
                  .audio, folder)
        try folder.writeJSON(Scorecard(strokes: ["steve": [7: 3]]), to: .scorecard)
        return folder
    }

    private func write<T: Encodable>(_ rows: [T], _ f: SessionFolder.File,
                                     _ folder: SessionFolder) throws {
        let w = try folder.writer(f)
        for r in rows { try w.append(r) }
        try w.close()
    }

    /// A course with real coordinates, placed where the caller says.
    private func makeCourse(id: String, name: String, near: Coordinate) -> Course {
        let holes = (1...9).map { i -> Hole in
            let tee = Geodesy.point(from: near, bearing: Double(i) * 20, distance: Double(i) * 60)
            let green = Geodesy.point(from: tee, bearing: 0, distance: 340)
            return Hole(ref: "\(i)", par: 4, handicap: i,
                        tees: [TeeBox(name: "White", at: tee, distance: 340)],
                        green: Green(center: green, polygon: []),
                        line: [tee, green])
        }
        return Course(id: id, name: name, source: .osm, holes: holes)
    }

    private func makeElevation(near: Coordinate) -> Elevation {
        Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                  lat0: near.lat + 0.01, lon0: near.lon - 0.01,
                  dLat: 0.0001, dLon: 0.0001, width: 8, height: 6,
                  metres: (0..<48).map { Double($0) })
    }

    // MARK: - The round survives, chains and tombstones included

    func testEveryRowComesBackIncludingSupersededAndDeletedOnes() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, unreadable) = try RoundArchive.bundle(from: source)
        XCTAssertTrue(unreadable.isEmpty)

        let text = try BundleText.encode(bundle)
        let back = try BundleText.decode(text)
        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(back, into: into, courses: nil)

        let imported = SessionFolder(url: report.folder)
        // **Element-wise, against the raw file** — not against `LogEntry.current`.
        // A collapsed comparison passes for an exporter that threw the whole
        // correction history away, which is the failure this is written to catch.
        XCTAssertEqual(imported.readAll(.log, as: LogEntry.self),
                       source.readAll(.log, as: LogEntry.self))
        XCTAssertEqual(imported.readAll(.log, as: LogEntry.self).count, 6)
        XCTAssertTrue(imported.readAll(.log, as: LogEntry.self).contains { $0.isDeleted })
        XCTAssertEqual(imported.readAll(.events, as: Event.self).count, 2)
        XCTAssertEqual(imported.readAll(.journal, as: JournalEntry.self).count, 2)
        XCTAssertEqual(imported.readAll(.marks, as: Mark.self).count, 1)
        XCTAssertEqual(imported.readAll(.gps, as: GPSFix.self).count, 1)
        XCTAssertEqual(imported.readAll(.audio, as: AudioSegment.self).count, 1)
        XCTAssertEqual(try imported.readJSON(.scorecard, as: Scorecard.self).strokes["steve"]?[7], 3)
        XCTAssertEqual(try imported.readMeta().sessionID, "SESSION-1")
        XCTAssertEqual(try imported.readMeta().players.map(\.id), ["steve", "dave"])
    }

    /// The journal is what the card is derived from, so a round that loses it comes
    /// back with no scores at all.
    func testTheScoresSurvive() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(try BundleText.decode(BundleText.encode(bundle)),
                                              into: into, courses: nil)
        let journal = SessionFolder(url: report.folder).readAll(.journal, as: JournalEntry.self)
        let state = JournalReplay.replay(journal)
        XCTAssertEqual(state.score(player: "steve", hole: 7), 3)
    }

    // MARK: - The firewall

    func testGroundTruthIsNestedAndStrippableInOneStep() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        XCTAssertFalse(bundle.round.groundTruth.isEmpty)

        let safe = bundle.modelVisible
        XCTAssertTrue(safe.round.groundTruth.isEmpty)
        XCTAssertTrue(safe.round.groundTruth.marks.isEmpty)
        XCTAssertNil(safe.round.groundTruth.scorecard)
        // `events.jsonl` is mixed provenance, so the per-row filter has to run too.
        XCTAssertEqual(safe.round.events.map(\.id), ["e1"])
        // Logs are model-visible by design and must NOT be stripped — doing so
        // would leave extraction with nothing to read.
        XCTAssertEqual(safe.round.logs.count, 6)
    }

    // MARK: - A row that cannot be read is reported, not dropped in silence

    func testAnUnreadableRowIsCountedAndReported() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        // A syntactically fine line that is not a `LogEntry` — exactly what
        // `JSONLReader` skips when opening a round that ended badly.
        let handle = try FileHandle(forWritingTo: source.path(.log))
        handle.seekToEndOfFile()
        handle.write(Data(#"{"id":"x","t":1,"text":"x","source":"not-an-engine"}"#.utf8))
        handle.write(Data("\n".utf8))
        try handle.close()

        let (bundle, unreadable) = try RoundArchive.bundle(from: source)
        XCTAssertEqual(bundle.round.logs.count, 6)
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.file, "log.jsonl")
        XCTAssertEqual(unreadable.first?.onDisk, 7)
        XCTAssertEqual(unreadable.first?.lost, 1)
    }

    // MARK: - Wire format

    func testASmallRoundIsPlainJSONAndABigOneIsCompressed() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (small, _) = try RoundArchive.bundle(from: source)
        XCTAssertTrue(try BundleText.encode(small).hasPrefix("{"),
                      "a round with no terrain is small enough to stay readable")

        let here = Coordinate(lat: 37.1, lon: -121.6)
        var big = small
        big.course = RoundBundle.CourseData(
            course: makeCourse(id: "test-links", name: "Test Links", near: here),
            elevation: Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                                 lat0: here.lat, lon0: here.lon, dLat: 1e-4, dLon: 1e-4,
                                 width: 400, height: 400,
                                 metres: (0..<160_000).map { Double($0 % 900) }))
        let text = try BundleText.encode(big)
        XCTAssertTrue(text.hasPrefix(BundleText.marker))
        XCTAssertEqual(try BundleText.decode(text).course?.elevation?.width, 400)
    }

    func testBothFormsRoundTrip() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        for forced in [true, false] {
            let back = try BundleText.decode(BundleText.encode(bundle, compressed: forced))
            XCTAssertEqual(back.round.logs.map(\.id), bundle.round.logs.map(\.id),
                           "form compressed=\(forced)")
        }
    }

    /// The whole point of the compact form is that it survives a clipboard, and a
    /// clipboard goes through clients that re-wrap and change line endings.
    /// **`"\r\n"` is one Swift `Character`**, so a CRLF document contains no `"\n"`
    /// at all — splitting on it yields a single line and the header fails to parse.
    func testACompressedExportSurvivesBeingMangledInTransit() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        let text = try BundleText.encode(bundle, compressed: true)

        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let head = lines.removeFirst()
        let comment = lines.removeFirst()
        let payload = lines.joined()
        let rewrapped = stride(from: 0, to: payload.count, by: 31).map { i -> String in
            let a = payload.index(payload.startIndex, offsetBy: i)
            let b = payload.index(a, offsetBy: 31, limitedBy: payload.endIndex) ?? payload.endIndex
            return "   " + payload[a..<b]           // indented, too
        }
        let mangled = ([head, comment, ""] + rewrapped + ["", ""]).joined(separator: "\r\n")

        XCTAssertEqual(try BundleText.decode(mangled).round.logs.map(\.id),
                       bundle.round.logs.map(\.id))
    }

    func testGarbageAndForeignJSONAreRefusedWithASentence() throws {
        XCTAssertThrowsError(try BundleText.decode("hello")) {
            XCTAssertEqual($0 as? BundleText.Failure, .notABundle)
        }
        // Valid JSON that is not ours must say so, rather than naming whichever of
        // OUR fields it happens to be missing.
        XCTAssertThrowsError(try BundleText.decode(#"{"format":"something.else"}"#)) {
            XCTAssertEqual($0 as? BundleText.Failure, .notABundle)
        }
        XCTAssertThrowsError(try BundleText.decode("MARKER-ROUND v99 zlib 10\nAAAA")) {
            XCTAssertEqual($0 as? BundleText.Failure, .unsupportedVersion(99))
        }
        // Not base64 at all: the paste was truncated or mauled.
        XCTAssertThrowsError(try BundleText.decode("MARKER-ROUND v1 zlib 10\n!!!!not base64!!!!")) {
            XCTAssertEqual($0 as? BundleText.Failure, .badBase64)
        }
        // Valid base64 that is not a deflate stream, and a header whose promised
        // size cannot be met: damage, never "that is not valid JSON" — nobody
        // hand-writes this form, so pointing at JSON points at the wrong fix.
        XCTAssertThrowsError(try BundleText.decode("MARKER-ROUND v1 zlib 4096\nAAAAAAAAAAAA")) {
            XCTAssertEqual($0 as? BundleText.Failure, .corrupt)
        }
    }

    // MARK: - Nothing is ever overwritten

    func testAReimportLandsInItsOwnFolderAndIsReportedAsADuplicate() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)

        let first = try RoundArchive.restore(bundle, into: into, courses: nil)
        let second = try RoundArchive.restore(bundle, into: into, courses: nil)
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertNil(first.duplicateOfSessionID)
        XCTAssertEqual(second.duplicateOfSessionID, "SESSION-1")
        XCTAssertEqual(SessionIndex.summaries(in: into).count, 2)
    }

    func testAnExistingCourseIsKeptAndItsPlacedCoordinatesSurvive() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let store = CourseStore(directory: root.appendingPathComponent("Courses"))
        // The local file has a hand-placed tee the incoming one does not.
        var local = makeCourse(id: "test-links", name: "Test Links", near: here)
        local.holes[0].tees.append(TeeBox(name: "Gold",
                                          at: Coordinate(lat: 37.1005, lon: -121.6005),
                                          distance: 300))
        try store.save(local)

        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.course = RoundBundle.CourseData(
            course: makeCourse(id: "test-links", name: "Test Links", near: here),
            elevation: makeElevation(near: here))

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: store)

        XCTAssertEqual(report.courseOutcome, .kept(id: "test-links"))
        XCTAssertEqual(try store.load(id: "test-links").holes[0].tees.count, 2,
                       "the hand-placed Gold tee must still be there")
        // Terrain is the one thing an import may ADD to a course it kept: a DEM has
        // nobody's hand-placed work in it.
        XCTAssertEqual(report.terrainOutcome, .written(id: "test-links"))
        XCTAssertNotNil(store.loadElevation(id: "test-links"))
    }

    func testAnExistingTerrainFileIsNeverReplaced() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let store = CourseStore(directory: root.appendingPathComponent("Courses"))
        try store.save(makeCourse(id: "test-links", name: "Test Links", near: here))
        try store.save(Elevation(source: .usgs3DEP, datum: .navd88, nativeResolution: 1,
                                 lat0: here.lat, lon0: here.lon, dLat: 1e-4, dLon: 1e-4,
                                 width: 2, height: 2, metres: [1, 2, 3, 4]), for: "test-links")

        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.course = RoundBundle.CourseData(
            course: makeCourse(id: "test-links", name: "Test Links", near: here),
            elevation: makeElevation(near: here))

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: store)
        XCTAssertEqual(report.terrainOutcome, .kept(id: "test-links"))
        XCTAssertEqual(store.loadElevation(id: "test-links")?.width, 2, "ours, not theirs")
    }

    /// A `.dem` that is present and does not decode is still **not overwritten**. It
    /// may be a grid a newer build wrote, and nothing can tell that from junk.
    func testAnUndecodableTerrainFileIsLeftAloneRatherThanReplaced() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let store = CourseStore(directory: root.appendingPathComponent("Courses"))
        let course = makeCourse(id: "test-links", name: "Test Links", near: here)
        try store.save(course)
        try Data("not a grid".utf8).write(to: store.elevationURL(for: "test-links"))

        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.course = RoundBundle.CourseData(course: course,
                                               elevation: makeElevation(near: here))

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: store)
        XCTAssertEqual(report.terrainOutcome, .kept(id: "test-links"))
        XCTAssertEqual(try Data(contentsOf: store.elevationURL(for: "test-links")),
                       Data("not a grid".utf8))
    }

    // MARK: - Terrain is optional

    /// The flag is **additive and absent when false**, so it did not move the format
    /// version. Both halves matter: a bundle written before the field existed must
    /// still decode (the `Hole.paths` failure — one added non-optional key made every
    /// course file on disk unreadable), and an ordinary export must still encode
    /// exactly as it did, so an older build does not refuse a perfectly readable
    /// document with "update the app". Contrast `RoundBundle.currentVersion`, which
    /// *did* move when `Player.aliases` was removed — an added key is invisible to an
    /// old reader, a removed non-optional one is a hard break.
    func testAnExportWithoutTheFlagDecodesAndAnOrdinaryOneDoesNotWriteIt() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(
            from: source, course: makeCourse(id: "test-links", name: "Test Links", near: here),
            elevation: makeElevation(near: here))

        let json = try BundleText.encode(bundle, compressed: false)
        XCTAssertFalse(json.contains("terrainOmitted"),
                       "an ordinary export must be byte-compatible with format 1")
        XCTAssertEqual(bundle.version, RoundBundle.currentVersion)

        // The same document read back: no key, and the answer is false rather than a
        // decode failure.
        let back = try BundleText.decode(json)
        XCTAssertNotNil(back.course?.elevation)
        XCTAssertEqual(back.course?.terrainOmitted, false)
    }

    /// **A v1 export still reads here, and a v2 one is refused by a v1 reader with a
    /// sentence about the version rather than about a missing field of ours.**
    func testAnOlderFormatVersionIsStillAccepted() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.version = 1
        let back = try BundleText.decode(try BundleText.encode(bundle, compressed: false))
        XCTAssertEqual(back.version, 1)
        XCTAssertTrue(back.isSupported)
        XCTAssertEqual(back.round.logs.count, bundle.round.logs.count)

        bundle.version = RoundBundle.currentVersion + 1
        XCTAssertThrowsError(
            try BundleText.decode(try BundleText.encode(bundle, compressed: false))) {
            XCTAssertEqual($0 as? BundleText.Failure,
                           .unsupportedVersion(RoundBundle.currentVersion + 1))
        }
    }

    func testLeavingTerrainOutSaysSoAndCarriesEverythingElse() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let course = makeCourse(id: "test-links", name: "Test Links", near: here)
        let (full, _) = try RoundArchive.bundle(from: source, course: course,
                                                elevation: makeElevation(near: here))
        let (lean, _) = try RoundArchive.bundle(from: source, course: course,
                                                elevation: makeElevation(near: here),
                                                includeTerrain: false)

        XCTAssertNil(lean.course?.elevation)
        XCTAssertEqual(lean.course?.terrainOmitted, true)
        XCTAssertEqual(lean.course?.course.holes.count, full.course?.course.holes.count,
                       "the map itself still travels")
        XCTAssertEqual(lean.round.logs.count, full.round.logs.count)
        XCTAssertTrue(lean.summary.contains("terrain left out"))

        // And it survives the wire, which is the only thing that matters about a
        // flag nobody reads until the other end.
        let back = try BundleText.decode(try BundleText.encode(lean, compressed: false))
        XCTAssertEqual(back.course?.terrainOmitted, true)
        XCTAssertNil(back.course?.elevation)

        XCTAssertLessThan(try BundleText.encode(lean, compressed: false).count,
                          try BundleText.encode(full, compressed: false).count)
    }

    /// A course that simply has no terrain is **not** an omission, and must not be
    /// reported as one. Nothing outside the United States has any.
    func testACourseWithNoTerrainIsNotReportedAsAnOmission() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (b, _) = try RoundArchive.bundle(
            from: source, course: makeCourse(id: "test-links", name: "Test Links", near: here),
            elevation: nil, includeTerrain: false)
        XCTAssertEqual(b.course?.terrainOmitted, false)
        XCTAssertFalse(b.summary.contains("terrain"))
    }

    /// `terrainOmitted` cannot contradict `elevation`: it is derived, never set.
    func testTheFlagCannotBeSetOnABundleThatCarriesAGrid() {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let data = RoundBundle.CourseData(
            course: makeCourse(id: "x", name: "X", near: here),
            elevation: makeElevation(near: here), terrainOmitted: true)
        XCTAssertFalse(data.terrainOmitted)
    }

    /// **`.omitted` fires only when this phone ends up with no grid.** All four
    /// cases, because `place()` has three return sites and getting one right and
    /// another wrong is the easy mistake.
    func testAnOmittedGridIsReportedOnlyWhenThereIsNoneHereEither() throws {
        let here = Coordinate(lat: 37.1, lon: -121.6)
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let course = makeCourse(id: "test-links", name: "Test Links", near: here)
        let (lean, _) = try RoundArchive.bundle(from: source, course: course,
                                                elevation: makeElevation(near: here),
                                                includeTerrain: false)

        func restore(into name: String, seed: (CourseStore) throws -> Void)
            throws -> RoundArchive.Report {
            let store = CourseStore(directory: root.appendingPathComponent("\(name)/Courses"))
            try seed(store)
            let into = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            return try RoundArchive.restore(lean, into: into, courses: store)
        }

        // Nothing here at all — the course is written, and the missing grid is the
        // one line worth printing.
        XCTAssertEqual(try restore(into: "a") { _ in }.terrainOutcome,
                       .omitted(id: "test-links"))

        // The course is here and already has terrain: the omission cost nothing, and
        // saying otherwise is crying wolf.
        XCTAssertEqual(try restore(into: "b") { store in
            try store.save(course)
            try store.save(self.makeElevation(near: here), for: "test-links")
        }.terrainOutcome, .kept(id: "test-links"))

        // The course is here with no terrain — same as (a), by a different road.
        XCTAssertEqual(try restore(into: "c") { store in try store.save(course) }.terrainOutcome,
                       .omitted(id: "test-links"))

        // A different course under the same id: stored beside it, and the grid it
        // was stored without is still an omission.
        XCTAssertEqual(try restore(into: "d") { store in
            try store.save(self.makeCourse(id: "test-links", name: "Elsewhere",
                                           near: Coordinate(lat: 37.7, lon: -122.2)))
        }.terrainOutcome, .omitted(id: "test-links-imported"))

        // And it is said out loud, with the thing to do about it.
        let lines = try restore(into: "e") { _ in }.lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("LEFT OUT"))
        XCTAssertTrue(lines.contains("BEFORE the round"))
    }

    // MARK: - Two different courses, one id

    /// `Course.slug` is ASCII-only, so every Korean course name slugs to `"course"`
    /// and unrelated courses collide on the first import. Keeping the local file and
    /// letting the round point at it would hand the round another course's geometry.
    func testADifferentCourseUnderTheSameIdIsStoredBesideItAndTheRoundRepointed() throws {
        let store = CourseStore(directory: root.appendingPathComponent("Courses"))
        let mine = Coordinate(lat: 37.7, lon: -122.2)
        let theirs = Coordinate(lat: 37.1, lon: -121.6)          // ~80 km away
        try store.save(makeCourse(id: "course", name: "천룡", near: mine))

        let source = try makeRound(at: root.appendingPathComponent("out/session-a"),
                                   course: "천룡")
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.course = RoundBundle.CourseData(
            course: makeCourse(id: "course", name: "천룡", near: theirs),
            elevation: makeElevation(near: theirs))

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: store)

        guard case .storedSeparately(let id, let name, let was, _) = report.courseOutcome else {
            return XCTFail("expected the incoming course to be stored separately, got \(report.courseOutcome)")
        }
        XCTAssertEqual(was, "course")
        XCTAssertNotEqual(id, "course")
        // Mine is untouched, at my coordinates.
        let kept = try store.load(id: "course")
        XCTAssertEqual(kept.name, "천룡")
        XCTAssertLessThan(Geodesy.distance(CourseIdentity.centroid(kept)!, mine), 1_000)
        // Theirs is beside it, with the original name kept as an alias.
        let stored = try store.load(id: id)
        XCTAssertEqual(stored.name, name)
        XCTAssertTrue(stored.aliases.contains("천룡"))
        // **And the round now names the one it was played on.** `meta.course` is a
        // name and the app resolves a round's course by matching it, so without this
        // the round would silently draw the local course's geometry.
        XCTAssertEqual(try SessionFolder(url: report.folder).readMeta().course, name)
        XCTAssertNotNil(store.loadElevation(id: id))
        XCTAssertNil(store.loadElevation(id: "course"))
    }

    func testCourseIdentityUsesGeographyAndFallsBackToTheCardWhenThereIsNone() {
        let a = Coordinate(lat: 37.1, lon: -121.6)
        let near = makeCourse(id: "x", name: "X", near: Coordinate(lat: 37.1005, lon: -121.6005))
        XCTAssertTrue(CourseIdentity.compare(makeCourse(id: "x", name: "X", near: a), near).isSame)

        let far = makeCourse(id: "x", name: "X", near: Coordinate(lat: 37.7, lon: -122.2))
        let m = CourseIdentity.compare(makeCourse(id: "x", name: "X", near: a), far)
        XCTAssertFalse(m.isSame)
        XCTAssertNotNil(m.metresApart)
        XCTAssertNotNil(m.reason)

        // Card-only files have no coordinates to compare.
        let card9 = Course(id: "c", name: "C", source: .card,
                           holes: (1...9).map { Hole(ref: "\($0)", par: 4, green: Green()) })
        let card18 = Course(id: "c", name: "C", source: .card,
                            holes: (1...18).map { Hole(ref: "\($0)", par: 4, green: Green()) })
        XCTAssertTrue(CourseIdentity.compare(card9, card9).isSame)
        XCTAssertFalse(CourseIdentity.compare(card9, card18).isSame)
        XCTAssertNil(CourseIdentity.compare(card9, card18).metresApart)
    }

    /// The one outcome that used to print nothing at all: a bundle carrying a course
    /// into an import that was given nowhere to put it.
    func testACarriedCourseWithNoStoreIsReportedRatherThanDroppedInSilence() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        var (bundle, _) = try RoundArchive.bundle(from: source)
        bundle.course = RoundBundle.CourseData(
            course: makeCourse(id: "test-links", name: "Test Links",
                               near: Coordinate(lat: 37.1, lon: -121.6)))

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: nil)
        XCTAssertEqual(report.courseOutcome, .notOffered)
        XCTAssertTrue(report.lines.contains { $0.contains("NOT imported") },
                      "an outcome nothing prints is an outcome nobody can act on")
    }

    // MARK: - Audio

    func testTheAudioIndexTravelsAndSaysTheRecordingsDidNot() throws {
        let source = try makeRound(at: root.appendingPathComponent("out/session-a"))
        let (bundle, _) = try RoundArchive.bundle(from: source)
        XCTAssertEqual(bundle.round.audio.segments.count, 1)
        XCTAssertFalse(bundle.round.audio.filesIncluded)

        let into = root.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        let report = try RoundArchive.restore(bundle, into: into, courses: nil)
        XCTAssertEqual(report.audioSegments, 1)
        XCTAssertFalse(report.audioFilesIncluded)
        // The index is what `AudioSpans` resolves a log's `tEnd` against, so it has
        // to be on disk even though no `.m4a` is.
        XCTAssertEqual(SessionFolder(url: report.folder)
            .readAll(.audio, as: AudioSegment.self).first?.t0, t - 1_000)
        XCTAssertTrue(report.lines.contains { $0.contains("not included") })
    }
}
