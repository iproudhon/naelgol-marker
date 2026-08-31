import XCTest
@testable import GolfSessionFormat

final class SessionFormatTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func session() -> SessionFolder {
        SessionFolder(url: tmp.appendingPathComponent("session-test"))
    }

    func testSessionFileNames() {
        XCTAssertEqual(SessionFolder.File.gps.rawValue, "gps.jsonl")
        XCTAssertEqual(SessionFolder.File.corrections.rawValue, "corrections.jsonl")
    }

    /// The firewall is a convention (CLAUDE.md, Known gaps), so the list a bundle
    /// builder checks against has to be right.
    func testGroundTruthFilesAreFlagged() {
        XCTAssertTrue(SessionFolder.File.marks.isGroundTruth)
        XCTAssertTrue(SessionFolder.File.corrections.isGroundTruth)
        XCTAssertTrue(SessionFolder.File.scorecard.isGroundTruth)
        for f in [SessionFolder.File.gps, .motion, .altitude, .audio, .transcript, .meta] {
            XCTAssertFalse(f.isGroundTruth, "\(f.rawValue) must be bundleable")
        }
    }

    func testJSONLRoundTrip() throws {
        let s = session()
        try s.create()
        let w = try s.writer(.gps)
        let fixes = (0..<500).map {
            GPSFix(t: Millis(1_700_000_000_000 + $0 * 1000),
                   lat: 37.5 + Double($0) * 1e-5, lon: 127.0, alt: 12,
                   hAcc: 5, vAcc: 8, speed: 1.2, course: 90)
        }
        for f in fixes { try w.append(f) }
        try w.close()

        let read = s.readAll(.gps, as: GPSFix.self)
        XCTAssertEqual(read.count, fixes.count)
        XCTAssertEqual(read.first?.t, fixes.first?.t)
        XCTAssertEqual(read.last?.lat ?? 0, fixes.last!.lat, accuracy: 1e-9)
    }

    /// A round can end by battery death mid-write. The last line is then torn,
    /// and everything before it must still load.
    func testTruncatedFinalLineIsSkippedNotFatal() throws {
        let s = session()
        try s.create()
        let w = try s.writer(.gps)
        for i in 0..<10 {
            try w.append(GPSFix(t: Millis(i), lat: 1, lon: 2, hAcc: 5))
        }
        try w.close()

        // Simulate a partial write of an 11th record.
        let h = try FileHandle(forWritingTo: s.path(.gps))
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"t":10,"lat":1,"lo"#.utf8))
        try h.close()

        let reader = s.stream(.gps, as: GPSFix.self)
        let read = Array(reader)
        XCTAssertEqual(read.count, 10)
        XCTAssertEqual(reader.stats.skipped, 1)
    }

    func testAppendReopensAndKeepsExistingLines() throws {
        let s = session()
        try s.create()
        let w1 = try s.writer(.marks)
        try w1.append(Mark(t: 1, player: "steve", lat: 37, lon: 127))
        try w1.close()

        let w2 = try s.writer(.marks)
        try w2.append(Mark(t: 2, player: "dave", lat: 37, lon: 127))
        try w2.close()

        let marks = s.readAll(.marks, as: Mark.self)
        XCTAssertEqual(marks.map(\.player), ["steve", "dave"])
    }

    func testMissingStreamReadsAsEmpty() {
        XCTAssertEqual(session().readAll(.gps, as: GPSFix.self).count, 0)
    }

    func testMetaAtomicWriteAndReread() throws {
        let s = session()
        try s.create()
        var meta = SessionMeta(sessionID: "abc", course: "Naelgol",
                               players: [Player(name: "steve"), Player(name: "dave")],
                               start: 1_700_000_000_000, end: nil,
                               device: "iPhone", audioFormat: "m4a-aac-32k-mono")
        try s.writeMeta(meta)
        XCTAssertNil(try s.readMeta().end)

        meta.end = 1_700_016_000_000
        try s.writeMeta(meta)                       // rewrite over an existing file
        XCTAssertEqual(try s.readMeta().end, 1_700_016_000_000)
        let reread = try s.readMeta().players
        XCTAssertEqual(reread.map(\.name), ["steve", "dave"])
        XCTAssertEqual(reread.map(\.id), ["steve", "dave"])
    }

    func testCorrectionRoundTrip() throws {
        let s = session()
        try s.create()
        let w = try s.writer(.corrections)
        try w.append(Correction(t: 100, kind: .addShot, hole: 7, shotT: 50,
                                player: "steve", club: "7i"))
        try w.append(Correction(t: 200, kind: .reattribute, shotID: "s-12", player: "dave"))
        try w.close()

        let cs = s.readAll(.corrections, as: Correction.self)
        XCTAssertEqual(cs.count, 2)
        XCTAssertEqual(cs[0].kind, .addShot)
        XCTAssertEqual(cs[0].club, "7i")
        XCTAssertEqual(cs[1].kind, .reattribute)
        XCTAssertEqual(cs[1].shotID, "s-12")
        XCTAssertNil(cs[1].club)
    }

    /// Attribution matches on the name as spoken, so a non-Latin name has to
    /// survive the round trip byte-for-byte — and so does the **id**, which
    /// defaults to it and is what `marks.jsonl` stores.
    func testNonLatinPlayerNamesRoundTrip() throws {
        let s = session()
        try s.create()
        let roster = [Player(name: "정성훈"), Player(name: "mike")]
        var meta = SessionMeta(sessionID: "abc", players: roster,
                               start: 1, device: "iPhone", audioFormat: "m4a")
        meta.course = "내골 CC"
        try s.writeMeta(meta)

        let back = try s.readMeta()
        XCTAssertEqual(back.course, "내골 CC")
        XCTAssertEqual(back.players, roster)
        XCTAssertEqual(back.players[0].id, "정성훈")
    }

    /// **A round recorded before 2026-08-31 still opens.** Aliases were removed
    /// that day; every `meta.json`, journal row and export written until then
    /// carries an `aliases` key, and a decoder that choked on it would make those
    /// rounds unreadable — the `Hole.paths` failure, from the other direction.
    func testAMetaFileWrittenWithAliasesStillDecodes() throws {
        let s = session()
        try s.create()
        let legacy = """
            {"sessionID":"abc","players":[{"id":"steve","name":"steve",\
            "aliases":["스티브","형"]}],"start":1,"device":"iPhone","audioFormat":"m4a"}
            """
        try Data(legacy.utf8).write(to: s.path(.meta))

        let back = try s.readMeta()
        XCTAssertEqual(back.players, [Player(id: "steve", name: "steve")])
    }

    func testClockIsMillisecondsSinceEpoch() {
        let d = Date(timeIntervalSince1970: 1_700_000_000.25)
        XCTAssertEqual(SessionClock.millis(from: d), 1_700_000_000_250)
        XCTAssertEqual(SessionClock.date(from: 1_700_000_000_250).timeIntervalSince1970,
                       1_700_000_000.25, accuracy: 1e-6)
    }

    func testFolderNameUsesLocalTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // 2023-11-14 22:13:20 UTC == 2023-11-15 07:13 KST
        XCTAssertEqual(SessionFolder.folderName(start: 1_700_000_000_000, calendar: cal),
                       "session-2023-11-15-0713")
    }
}

/// The trailing-slash trap that made a recording burst look like it recorded
/// nothing *(found on the simulator 2026-08-27)*.
final class SessionFolderIdentityTests: XCTestCase {

    /// **`URL.appendingPathComponent` consults the filesystem.** It appends a
    /// trailing slash when the component names an existing directory and does not
    /// when it does not — so the same path built before and after `create()`
    /// compares unequal with `==`. `RoundSession.create` builds its URL first and
    /// the round screen builds the same path later, so the round screen's
    /// `LogStore.didAppend` guard dropped every refresh: twenty-nine logs on disk
    /// and "Nothing on this hole" on screen.
    func testAppendingPathComponentAddsASlashOnceTheDirectoryExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-url-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = root.appendingPathComponent("session-x")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let after = root.appendingPathComponent("session-x")

        // The trap itself. If this ever stops holding the guard was still wrong to
        // use `==`, so the assertion below is the one that matters.
        XCTAssertTrue(SessionFolder.isSame(before, after),
                      "these name one folder however the URLs were built")
        XCTAssertTrue(SessionFolder(url: before).isSame(as: after))
        XCTAssertTrue(SessionFolder(url: after).isSame(as: before))
    }

    func testDifferentSessionsAreNotSame() {
        let root = URL(fileURLWithPath: "/tmp/Sessions", isDirectory: true)
        XCTAssertFalse(SessionFolder.isSame(root.appendingPathComponent("a"),
                                            root.appendingPathComponent("b")))
    }
}
