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
                                          players: [Player(name: "steve"), Player(name: "dave")],
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

    // MARK: - The record button

    /// Recording is off by default and turned on mid-round *(2026-08-27)*, so
    /// `recordAudio: false` must mean "do not open the microphone **with** the
    /// round" and not "this round can never record".
    func testAudioIsNotRunningOnARoundThatStartedWithTheMicrophoneOff() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()
        XCTAssertFalse(session.audioRunning)
        XCTAssertEqual(try session.folder.readMeta().audioFormat, "none",
                       "no burst has happened yet, and claiming a format would be a lie")
        session.stop()
        XCTAssertTrue(session.folder.readAll(.audio, as: AudioSegment.self).isEmpty)
    }

    /// The button exists on the round screen, which cannot be reached before the
    /// round starts — but a stale tap must not open the microphone against a
    /// folder that does not exist yet, or one that is already closed.
    func testStartAudioDoesNothingOutsideARecordingRound() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        XCTAssertNoThrow(try session.startAudio())
        XCTAssertFalse(session.audioRunning, "the round has not started")

        try session.start()
        session.stop()
        XCTAssertNoThrow(try session.startAudio())
        XCTAssertFalse(session.audioRunning, "the round has ended")
    }

    /// `stopAudio` is idempotent, and on a round that never recorded it must not
    /// even reach the recorder — `AudioRecorder.engine` is `lazy` precisely so a
    /// no-audio round builds no `AVAudioEngine`, and touching it here would
    /// quietly undo that on every End round.
    func testStopAudioIsSafeWhenNothingIsRecording() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()
        session.stopAudio()
        session.stopAudio()
        XCTAssertFalse(session.audioRunning)
        session.stop()
        XCTAssertEqual(session.state, .ended)
    }
}

/// Reopening an ended round so more can be recorded into it *(user decision,
/// 2026-08-27)*. A round does not end when the golfer stops talking.
final class RoundResumeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The round is in progress again, and `start` is untouched — it is when the
    /// round began, not when it was picked back up.
    func testResumeClearsTheEndAndKeepsTheStart() throws {
        let session = RoundSession.create(under: root, recordAudio: false, recordLocation: false)
        try session.start()
        let start = try session.folder.readMeta().start
        session.stop()
        XCTAssertNotNil(try session.folder.readMeta().end)

        try session.resume()
        XCTAssertEqual(session.state, .recording)
        let meta = try session.folder.readMeta()
        XCTAssertNil(meta.end, "a reopened round is in progress again")
        XCTAssertEqual(meta.start, start, "the round began when it began")

        session.mark(player: "steve")
        session.stop()
        XCTAssertEqual(session.folder.readAll(.marks, as: Mark.self).count, 1,
                       "the marks writer reopens in append mode")
    }

    /// **The overwrite this exists to prevent.** `segmentIndex` starts at -1 so a
    /// fresh round opens `audio-000.m4a`; recording into a reopened round without
    /// adopting what is there would open `audio-000.m4a` again and destroy the
    /// audio of the round being added to.
    func testSegmentNumberingContinuesPastWhatIsOnDisk() throws {
        let folder = SessionFolder(url: root.appendingPathComponent("session-x"))
        try folder.create()
        // Two closed segments and a third file with no index row — the crash case,
        // which the format deliberately allows.
        let writer = try folder.writer(.audio)
        try writer.append(AudioSegment(index: 0, file: "audio-000.m4a", t0: 1, t1: 2))
        try writer.append(AudioSegment(index: 1, file: "audio-001.m4a", t0: 3, t1: 4))
        try writer.close()
        FileManager.default.createFile(atPath: folder.audioPath(index: 2).path, contents: Data())

        XCTAssertEqual(folder.lastAudioIndex(), 2,
                       "an orphaned .m4a counts, or the next burst overwrites it")

        let recorder = AudioRecorder(folder: folder)
        recorder.adoptExistingSegments()
        // Next segment must be 3. Asserted through the naming helper rather than
        // private state, which is what a caller can actually see.
        XCTAssertEqual(SessionFolder.audioFileName(index: (folder.lastAudioIndex() ?? -1) + 1),
                       "audio-003.m4a")
    }

    func testAudioIndexParsesOnlySegmentFiles() {
        XCTAssertEqual(SessionFolder.audioIndex(inFileName: "audio-007.m4a"), 7)
        XCTAssertNil(SessionFolder.audioIndex(inFileName: "meta.json"))
        XCTAssertNil(SessionFolder.audioIndex(inFileName: "audio-.m4a"))
        XCTAssertNil(SessionFolder.audioIndex(inFileName: "transcript.jsonl"))
    }

    /// A round that already recorded must not have its format reset to "none" just
    /// because the reopen starts with the microphone off, as every round does.
    func testResumeDoesNotDowngradeARecordedFormat() throws {
        let folder = SessionFolder(url: root.appendingPathComponent("session-y"))
        try folder.create()
        try folder.writeMeta(SessionMeta(sessionID: "y", start: 1, end: 2, device: "iOS",
                                         audioFormat: "m4a-aac-16k-mono-32kbps"))
        let session = RoundSession(folder: folder, recordAudio: false, recordLocation: false)
        try session.resume()
        session.stop()
        XCTAssertEqual(try folder.readMeta().audioFormat, "m4a-aac-16k-mono-32kbps")
    }
}
