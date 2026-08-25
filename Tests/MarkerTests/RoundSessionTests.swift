import XCTest
import GolfSessionFormat
@testable import GolfCaptureCore

/// Exercises the Phase 1 gate: a round records and the folder round-trips.
/// Audio is off — the microphone needs TCC authorization that CI does not have,
/// and the point here is the session-folder contract, not the encoder.
final class RoundSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-round-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundRoundTripsThroughTheFolder() throws {
        let session = RoundSession.create(under: root,
                                          players: [Player(name: "steve", aliases: ["스티브"]), Player(name: "dave")],
                                          course: "Naelgol CC",
                                          recordAudio: false, recordLocation: false)
        try session.start()
        XCTAssertEqual(session.state, .recording)

        session.mark(player: "steve", hole: 1)
        session.mark(player: "dave", hole: 1, note: "in the bunker")
        session.record(Correction(t: SessionClock.now(), kind: .reattribute,
                                  shotID: "s-3", player: "steve"))
        session.stop()
        XCTAssertEqual(session.state, .ended)

        // Re-open cold, the way the Mac side does.
        let folder = SessionFolder(url: session.folder.url)
        let meta = try folder.readMeta()
        XCTAssertEqual(meta.players.map(\.name), ["steve", "dave"])
        XCTAssertEqual(meta.players[0].aliases, ["스티브"])
        XCTAssertEqual(meta.course, "Naelgol CC")
        XCTAssertNotNil(meta.end, "stop() must close meta.json")
        XCTAssertGreaterThanOrEqual(meta.end!, meta.start)

        let marks = folder.readAll(.marks, as: Mark.self)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.map(\.player), ["steve", "dave"])
        XCTAssertEqual(marks[1].note, "in the bunker")

        let corrections = folder.readAll(.corrections, as: Correction.self)
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].kind, .reattribute)
    }

    /// The behaviour that "capture everything, correct later" demands: a MARK
    /// with no GPS fix is still recorded, because the timestamp is the point.
    func testMarkIsRecordedWithoutAFix() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()

        let m = try XCTUnwrap(session.mark(player: "steve"))
        XCTAssertNil(m.lat)
        XCTAssertNil(m.fixAgeMs)
        XCTAssertGreaterThan(m.t, 0)
        session.stop()

        XCTAssertEqual(session.folder.readAll(.marks, as: Mark.self).count, 1)
        XCTAssertEqual(session.markCount, 1)
    }

    func testFolderIsIdentifiableBeforeTheRoundEnds() throws {
        let session = RoundSession.create(under: root, players: [Player(name: "steve")],
                                          recordAudio: false, recordLocation: false)
        try session.start()
        // meta.json is written before any stream starts, so a round that dies
        // thirty seconds in is still an identifiable session rather than debris.
        let meta = try session.folder.readMeta()
        XCTAssertNil(meta.end)
        XCTAssertEqual(meta.players.map(\.name), ["steve"])
        session.stop()
    }

    /// A mark taken after the round ends has nowhere to go. Returning nil beats
    /// counting it and silently writing nothing.
    func testMarkAfterStopIsRefusedNotSwallowed() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()
        session.stop()
        XCTAssertNil(session.mark(player: "steve"))
        XCTAssertEqual(session.markCount, 0)
        XCTAssertEqual(session.folder.readAll(.marks, as: Mark.self).count, 0)
    }

    func testMarkBeforeStartIsRefused() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        XCTAssertNil(session.mark(player: "steve"))
        XCTAssertEqual(session.markCount, 0)
    }

    /// stop() rewrites meta.json from its in-memory copy, so anything start()
    /// learned late (the audio route) has to survive to the end of the round.
    func testMetaFieldsLearnedAtStartSurviveStop() throws {
        let session = RoundSession.create(under: root, players: [Player(name: "steve")],
                                          course: "Naelgol CC",
                                          recordAudio: false, recordLocation: false)
        try session.start()
        let atStart = try session.folder.readMeta()
        session.stop()
        let atEnd = try session.folder.readMeta()

        XCTAssertEqual(atEnd.sessionID, atStart.sessionID)
        XCTAssertEqual(atEnd.players, atStart.players)
        XCTAssertEqual(atEnd.course, atStart.course)
        XCTAssertEqual(atEnd.audioFormat, atStart.audioFormat)
        XCTAssertEqual(atEnd.audioRoute, atStart.audioRoute)
        XCTAssertEqual(atEnd.start, atStart.start)
        XCTAssertNotNil(atEnd.end)
    }

    func testDoubleStartAndDoubleStopAreHarmless() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()
        try session.start()
        session.stop()
        session.stop()
        XCTAssertEqual(session.state, .ended)
        XCTAssertNotNil(try session.folder.readMeta().end)
    }
}
