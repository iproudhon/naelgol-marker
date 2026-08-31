import XCTest
@testable import GolfSessionFormat

final class SessionIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeSession(_ name: String, start: Millis, end: Millis? = nil,
                             course: String? = "Corica Park South") throws -> SessionFolder {
        let f = SessionFolder(url: root.appendingPathComponent(name))
        try f.create()
        try f.writeMeta(SessionMeta(sessionID: name, course: course,
                                    players: [Player(name: "steve")],
                                    start: start, end: end,
                                    device: "test", audioFormat: "m4a"))
        return f
    }

    func testClassifiesRecordingUnfinishedAndFinished() throws {
        try makeSession("session-a", start: 1_000, end: 2_000)
        try makeSession("session-b", start: 3_000)              // never ended
        try makeSession("session-c", start: 5_000)              // the live one

        let all = SessionIndex.summaries(in: root, recordingID: "session-c")
        XCTAssertEqual(all.map(\.id), ["session-c", "session-b", "session-a"],
                       "newest first")
        XCTAssertEqual(all.map(\.state), [.recording, .unfinished, .finished])
    }

    /// A folder with `end == nil` that this process is *not* recording is the
    /// app-was-killed case. Before the rounds list existed it was orphaned in
    /// silence — this is the whole reason `unfinished` is a state.
    func testKilledRoundIsUnfinishedNotRecording() throws {
        try makeSession("session-dead", start: 1_000)
        let s = SessionIndex.summaries(in: root, recordingID: nil)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].state, .unfinished)
        XCTAssertEqual(SessionIndex.unfinished(in: root).map(\.id), ["session-dead"])
    }

    /// A duration of "now minus start" on a round killed days ago reads as a
    /// three-day round, which looks exactly like a bug.
    func testUnfinishedRoundHasNoDuration() throws {
        try makeSession("session-open", start: 1_000)
        try makeSession("session-shut", start: 1_000, end: 1_000 + 90 * 60 * 1_000)
        let byID = Dictionary(uniqueKeysWithValues:
            SessionIndex.summaries(in: root).map { ($0.id, $0) })
        XCTAssertNil(byID["session-open"]!.duration)
        XCTAssertEqual(byID["session-shut"]!.duration!, 5_400, accuracy: 0.001)
    }

    func testSkipsDirectoriesThatAreNotSessions() throws {
        try makeSession("session-ok", start: 1_000, end: 2_000)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Courses"), withIntermediateDirectories: true)
        // A session folder whose meta was lost is skipped, not fatal.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("session-broken"), withIntermediateDirectories: true)
        XCTAssertEqual(SessionIndex.summaries(in: root).map(\.id), ["session-ok"])
    }

    func testCountsBytesAudioSegmentsAndStreams() throws {
        let f = try makeSession("session-x", start: 1_000, end: 2_000)
        try Data(repeating: 0, count: 4_096).write(to: f.audioPath(index: 0))
        try Data(repeating: 0, count: 2_048).write(to: f.audioPath(index: 1))
        let w = try f.writer(.events)
        try w.append(Event(id: "e1", t: 1_500, kind: .note, provenance: .user, text: "hi"))
        try w.close()

        let s = SessionIndex.summary(of: f)!
        XCTAssertEqual(s.audioSegments, 2)
        XCTAssertGreaterThan(s.bytes, 6_000)
        XCTAssertTrue(s.hasEvents)
        XCTAssertFalse(s.hasTranscript)
    }

    /// Closing out stamps the last thing actually recorded, not the wall clock —
    /// otherwise every hour between the crash and the tap becomes round time.
    func testCloseOutUsesLastEvidenceNotNow() throws {
        let f = try makeSession("session-crash", start: 1_000)
        let w = try f.writer(.gps)
        try w.append(GPSFix(t: 60_000, lat: 37.7, lon: -122.2, hAcc: 5))
        try w.append(GPSFix(t: 120_000, lat: 37.7, lon: -122.2, hAcc: 5))
        try w.close()

        let meta = try SessionIndex.closeOut(f, fallback: 9_999_999)
        XCTAssertEqual(meta.end, 120_000)
        XCTAssertEqual(SessionIndex.summary(of: f)!.state, .finished)
    }

    func testCloseOutFallsBackWhenNothingWasRecorded() throws {
        let f = try makeSession("session-empty", start: 1_000)
        let meta = try SessionIndex.closeOut(f, fallback: 7_000)
        XCTAssertEqual(meta.end, 7_000)
    }

    func testCloseOutLeavesAFinishedRoundAlone() throws {
        let f = try makeSession("session-done", start: 1_000, end: 2_000)
        let meta = try SessionIndex.closeOut(f, fallback: 9_999_999)
        XCTAssertEqual(meta.end, 2_000)
    }
}

final class EventProvenanceTests: XCTestCase {
    /// The firewall in one assertion: what a person typed must not be in the set
    /// the model is shown.
    func testModelVisibleExcludesUserAuthoredEvents() {
        let events = [
            Event(id: "m1", t: 10, kind: .shot, provenance: .model, player: "steve",
                  club: "7 iron", confidence: 0.6),
            Event(id: "u1", t: 20, kind: .score, provenance: .user, player: "steve",
                  hole: 7, strokes: 5),
        ]
        XCTAssertEqual(Event.modelVisible(events).map(\.id), ["m1"])
        XCTAssertTrue(events[1].isGroundTruth)
        XCTAssertFalse(events[0].isGroundTruth)
    }

    /// A person who typed a score is not expressing a probability. Storing one
    /// invites code that averages it with the model's.
    func testUserEventsCarryNoConfidence() {
        let e = Event(id: "u", t: 1, kind: .score, provenance: .user, confidence: 0.99)
        XCTAssertNil(e.confidence)
    }

    func testCurrentHidesSupersededButDiskKeepsThem() {
        let all = [
            Event(id: "m1", t: 10, kind: .shot, provenance: .model, player: "steve"),
            Event(id: "m2", t: 20, kind: .shot, provenance: .model, player: "dave"),
            Event(id: "u1", t: 10, kind: .shot, provenance: .user, player: "dave",
                  supersedes: "m1"),
        ]
        XCTAssertEqual(Event.current(all).map(\.id), ["u1", "m2"])
        XCTAssertEqual(all.count, 3, "the sequence is the labelled error set")
    }

    /// The input box, end to end through the file — the one path in the round
    /// screen where a failure would be silent (the append catches and logs).
    func testTypedEventRoundTripsThroughEventsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typed-\(UUID().uuidString)")
        let folder = SessionFolder(url: dir)
        try folder.create()
        defer { try? FileManager.default.removeItem(at: dir) }

        let typed = Event.typed("  min hit it in the water off the tee  ", hole: 2, at: 4_242)
        let w = try folder.writer(.events)
        try w.append(XCTUnwrap(typed))
        try w.close()

        let back = folder.readAll(.events, as: Event.self)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].text, "min hit it in the water off the tee", "trimmed")
        XCTAssertEqual(back[0].provenance, .user)
        XCTAssertEqual(back[0].kind, .note)
        XCTAssertEqual(back[0].hole, 2)
        XCTAssertEqual(back[0].t, 4_242)
        XCTAssertTrue(back[0].isGroundTruth)
        XCTAssertTrue(Event.modelVisible(back).isEmpty, "typed text must never reach a prompt")
    }

    func testTypedRejectsWhitespaceOnly() {
        XCTAssertNil(Event.typed("   \n  "))
        XCTAssertNotNil(Event.typed("bogey"))
    }

    /// Deleting a proposal appends an amendment; it never removes the line.
    func testDeletionSupersedesRatherThanRemoves() {
        let proposal = Event(id: "m1", t: 99, kind: .shot, provenance: .model,
                             player: "dave", hole: 3, club: "3 wood", confidence: 0.4)
        let deletion = Event.deletion(of: proposal, at: 500)
        XCTAssertEqual(deletion.supersedes, "m1")
        XCTAssertEqual(deletion.provenance, .user)
        XCTAssertEqual(deletion.t, 99, "the shot's time, not the tap's")
        XCTAssertTrue(Event.current([proposal, deletion]).map(\.id) == [deletion.id])
    }

    /// `isGroundTruth == false` is the wrong question for events.jsonl, and it is
    /// wrong in the direction that leaks.
    func testEventsFileIsMarkedMixedRatherThanSafe() {
        XCTAssertFalse(SessionFolder.File.events.isGroundTruth)
        XCTAssertTrue(SessionFolder.File.events.isMixedProvenance)
        XCTAssertTrue(SessionFolder.File.marks.isGroundTruth)
        XCTAssertFalse(SessionFolder.File.transcript.isMixedProvenance)
    }
}
