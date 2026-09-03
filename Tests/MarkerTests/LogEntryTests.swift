import XCTest
@testable import GolfSessionFormat

final class LogEntryTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func folder() -> SessionFolder {
        SessionFolder(url: tmp.appendingPathComponent("session-test"))
    }

    // MARK: - The firewall

    /// The reason `LogEntry` is its own type rather than an `Event` with a third
    /// provenance. If a dictated log had landed on `Event`, either it would be
    /// `.user` (ground truth — and then extraction has nothing to read) or
    /// `Provenance` grows a case and `isGroundTruth` stops being a yes/no
    /// question. Neither happened, and this is the check that neither happened.
    func testAddingLogsDidNotWidenTheEventFirewall() {
        XCTAssertEqual(Event.Provenance.allCasesForTest.count, 2)

        let proposal = Event(id: "a", t: 1, kind: .shot, provenance: .model,
                             logs: ["log-1"])
        let correction = Event(id: "b", t: 1, kind: .shot, provenance: .user,
                               supersedes: "a")
        XCTAssertFalse(proposal.isGroundTruth)
        XCTAssertTrue(correction.isGroundTruth)
        XCTAssertEqual(Event.modelVisible([proposal, correction]).map(\.id), ["a"])
    }

    /// `log.jsonl` is model input, so it must be in **neither** firewall list.
    /// Being in `groundTruth` would starve extraction; being in `mixedProvenance`
    /// would tell a bundle builder to filter rows that never need filtering.
    func testLogFileIsNeitherGroundTruthNorMixed() {
        XCTAssertFalse(SessionFolder.File.log.isGroundTruth)
        XCTAssertFalse(SessionFolder.File.log.isMixedProvenance)
        XCTAssertTrue(SessionFolder.File.events.isMixedProvenance)
        XCTAssertTrue(SessionFolder.File.marks.isGroundTruth)
    }

    // MARK: - The type

    func testBlankTextIsRejected() {
        XCTAssertNil(LogEntry.make("   \n ", source: .spoken))
        XCTAssertNil(LogEntry.make("", source: .typed))
        XCTAssertEqual(LogEntry.make("  bogey  ", source: .spoken)?.text, "bogey")
    }

    /// A log with no fix is a real, expected row — not an error and not something
    /// to backfill from the last known position.
    func testALogWithoutAFixIsStillALog() {
        let log = LogEntry.make("in the bunker", source: .spoken)
        XCTAssertNotNil(log)
        XCTAssertFalse(log!.hasPosition)
        let placed = LogEntry.make("in the bunker", source: .spoken,
                                   lat: 37.7, lon: -122.2, hAcc: 5)
        XCTAssertTrue(placed!.hasPosition)
    }

    func testRoundTripsThroughTheFolder() throws {
        let f = folder()
        try f.create()
        let w = try f.writer(.log)
        try w.append(LogEntry(id: "l1", t: 1_000, text: "steve made a five",
                              lat: 37.7, lon: -122.2, hAcc: 4.5, hole: 7,
                              source: .spoken, locale: "en_US"))
        try w.append(LogEntry(id: "l2", t: 2_000, text: "벙커", source: .typed))
        try w.close()

        let read = f.readAll(.log, as: LogEntry.self)
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read[0].hole, 7)
        XCTAssertEqual(read[0].source, .spoken)
        XCTAssertEqual(read[1].text, "벙커")
        XCTAssertNil(read[1].lat)
    }

    /// `Event.logs` is optional so that an `events.jsonl` written before logs
    /// existed still decodes. A non-optional array would have made every stored
    /// round unreadable, silently, at the point the file is loaded.
    func testAnEventWrittenBeforeLogsExistedStillDecodes() throws {
        let old = """
        {"confidence":0.4,"evidence":[100],"id":"e1","kind":"shot","provenance":"model","t":100}
        """
        let event = try JSONDecoder().decode(Event.self, from: Data(old.utf8))
        XCTAssertEqual(event.id, "e1")
        XCTAssertNil(event.logs)
        XCTAssertEqual(event.evidence, [100])
    }

    // MARK: - Two processes, one file

    /// The Siri intent may run in a background-launched instance of the app while
    /// a foreground instance holds its own writer. Two `JSONLWriter`s on one file
    /// is therefore the normal case, not an edge case.
    ///
    /// This is what `seekToEnd()` could not do: it resolves the offset once, so
    /// the second writer overwrites the first from a stale position and rows
    /// vanish with nothing to show for it. `O_APPEND` re-resolves inside every
    /// write.
    func testTwoWritersOnOneFileLoseNothing() throws {
        let f = folder()
        try f.create()
        let a = try f.writer(.log)
        let b = try f.writer(.log)

        for i in 0..<200 {
            try a.append(LogEntry(id: "a\(i)", t: Millis(i), text: "from a",
                                  source: .typed))
            try b.append(LogEntry(id: "b\(i)", t: Millis(i), text: "from b",
                                  source: .spoken))
        }
        try a.close()
        try b.close()

        let read = f.readAll(.log, as: LogEntry.self)
        XCTAssertEqual(read.count, 400, "rows were overwritten, not appended")
        XCTAssertEqual(Set(read.map(\.id)).count, 400)
    }

    /// Concurrently, from several queues — the interleave `flock` exists to stop.
    /// A torn line is the one failure `JSONLReader` cannot recover from: it skips
    /// a bad *line*, and an interleaved write corrupts two.
    func testConcurrentAppendsProduceNoTornLines() throws {
        let f = folder()
        try f.create()
        let writers = try (0..<4).map { _ in try f.writer(.log) }
        let text = String(repeating: "long enough to straddle a buffer ", count: 12)

        DispatchQueue.concurrentPerform(iterations: 4) { w in
            for i in 0..<100 {
                try? writers[w].append(
                    LogEntry(id: "w\(w)-\(i)", t: Millis(i), text: text, source: .typed))
            }
        }
        for w in writers { try w.close() }

        let stats = JSONLReader<LogEntry>.Stats()
        let rows = Array(JSONLReader<LogEntry>(url: f.path(.log), stats: stats))
        XCTAssertEqual(stats.skipped, 0, "a line was torn by an interleaved write")
        XCTAssertEqual(rows.count, 400)
        XCTAssertEqual(Set(rows.map(\.id)).count, 400)
    }
}

extension Event.Provenance {
    /// Not `CaseIterable` in the shipping type — deliberately, so that adding a
    /// case is a conscious act. Mirrored here so the test above can count them.
    static var allCasesForTest: [Event.Provenance] { [.model, .user] }
}

/// Editing a log is appending a superseding row — `JSONLWriter` opens `O_APPEND`
/// and structurally cannot rewrite a line. One mechanism carries all four
/// mutations: the late coordinate, an edited sentence, a moved hole, a deletion.
final class LogAmendmentTests: XCTestCase {

    private func log(_ text: String, id: String, t: Millis = 1000,
                     hole: Int? = nil) -> LogEntry {
        LogEntry(id: id, t: t, text: text, hole: hole, source: .spoken)
    }

    func testTheLatestVersionWinsAndTheOriginalStaysOnDisk() {
        let a = log("steve birdy", id: "a")
        let b = a.edited(text: "steve birdie", id: "b")!
        let current = LogEntry.current([a, b])
        XCTAssertEqual(current.map(\.text), ["steve birdie"])
        XCTAssertEqual(LogEntry.byID([a, b]).count, 2, "both versions stay addressable")
    }

    /// The whole point of converging on a fix: a log that had nowhere to go gets
    /// placed. Carrying the old nil forward would leave it exactly as invisible.
    func testPlacingALogRecomputesTheHoleRatherThanKeepingTheOldOne() {
        let a = log("lost ball", id: "a", hole: nil)
        let b = a.placed(lat: 37.74, lon: -122.26, hAcc: 5, hole: 7, id: "b")
        XCTAssertEqual(b.hole, 7)
        XCTAssertTrue(b.hasPosition)
        XCTAssertEqual(b.supersedes, "a")
    }

    /// `t` is the moment the sentence was *said*. Restamping it when the fix lands
    /// would reorder the round by however long the GPS took to settle.
    func testPlacingALogDoesNotMoveItInTime() {
        let a = log("steve is away", id: "a", t: 12_345)
        XCTAssertEqual(a.placed(lat: 1, lon: 2, hAcc: 5, hole: 3, id: "b").t, 12_345)
    }

    func testMovingALogToAnotherHole() {
        let a = log("three putts", id: "a", hole: 3)
        let b = a.edited(hole: 4, id: "b")!
        XCTAssertEqual(b.hole, 4)
        XCTAssertEqual(b.text, "three putts", "text is untouched when only the hole moves")
    }

    /// Double-optional: `nil` means "leave it", `.some(nil)` means "unplace it".
    func testUnplacingALogIsDistinctFromLeavingTheHoleAlone() {
        let a = log("three putts", id: "a", hole: 3)
        XCTAssertEqual(a.edited(text: "two putts", id: "b")?.hole, 3)
        XCTAssertNil(a.edited(hole: .some(nil), id: "c")?.hole)
    }

    func testAnEmptyEditIsRefusedRatherThanWritingABlankRow() {
        XCTAssertNil(log("steve birdie", id: "a").edited(text: "   ", id: "b"))
    }

    /// A proposal that already cites a log has to keep rendering its evidence, so
    /// a delete is a tombstone rather than an absence.
    func testADeletedLogLeavesTheTimelineButStaysFindable() {
        let a = log("steve birdie", id: "a")
        let b = a.removed(id: "b")
        XCTAssertTrue(LogEntry.current([a, b]).isEmpty)
        XCTAssertEqual(LogEntry.byID([a, b])["a"]?.text, "steve birdie")
        XCTAssertTrue(b.isDeleted)
    }

    func testCurrentIsChronologicalByWhenItWasSaid() {
        let a = log("first", id: "a", t: 100)
        let b = log("second", id: "b", t: 50)
        XCTAssertEqual(LogEntry.current([a, b]).map(\.text), ["second", "first"])
    }

    /// A citation points at whichever version the model actually read, which may
    /// be several edits back.
    func testAChainWalksBackToTheOriginal() {
        let a = log("nielgal", id: "a")
        let b = a.edited(text: "naelgol", id: "b")!
        let c = b.edited(text: "Naelgol", id: "c")!
        let byID = LogEntry.byID([a, b, c])
        XCTAssertEqual(LogEntry.chainRoot(of: c, in: byID).id, "a")
        XCTAssertEqual(LogEntry.chainRoot(of: a, in: byID).id, "a")
    }

    /// **The infinite loop, in one assertion.** A good fix that resolves to no hole
    /// is *placed*; treating it as unplaced made the app converge, append a
    /// superseding row, see the nil hole again, and converge again — forever, with
    /// an Apple Intelligence pass each lap. `Course.nearestHole` declines beyond
    /// 250 m, so that is every log made anywhere but on a mapped hole.
    func testAGoodFixWithNoHoleIsPlaced() {
        let placed = LogEntry(id: "a", t: 1, text: "lost ball", lat: 37.7, lon: -122.2,
                              hAcc: 5, hole: nil, source: .spoken)
        XCTAssertTrue(placed.isPlaced(within: 25))
    }

    func testNoFixOrAPoorFixIsNotPlaced() {
        let none = LogEntry(id: "a", t: 1, text: "x", source: .spoken)
        XCTAssertFalse(none.isPlaced(within: 25))

        let poor = LogEntry(id: "b", t: 1, text: "x", lat: 37.7, lon: -122.2,
                            hAcc: 400, source: .spoken)
        XCTAssertFalse(poor.isPlaced(within: 25))

        // A coordinate with no stated accuracy is not a claim anything may be
        // placed from.
        let unknown = LogEntry(id: "c", t: 1, text: "x", lat: 37.7, lon: -122.2,
                               source: .spoken)
        XCTAssertFalse(unknown.isPlaced(within: 25))
    }

    /// Converging writes a position, so a converged log can never be a candidate
    /// again — which is what makes the loop structurally impossible rather than
    /// merely guarded against.
    func testConvergingMakesALogPlacedEvenWhenTheHoleStaysNil() {
        let before = LogEntry(id: "a", t: 1, text: "x", source: .spoken)
        let after = before.placed(lat: 37.7, lon: -122.2, hAcc: 6, hole: nil, id: "b")
        XCTAssertFalse(before.isPlaced(within: 25))
        XCTAssertTrue(after.isPlaced(within: 25))
    }

    /// The reason this is not a journal act: an edit the extraction pass cannot
    /// see is an edit that does not exist as far as the model is concerned.
    func testALogAndItsEditsAreBothModelVisible() {
        XCTAssertFalse(SessionFolder.File.log.isGroundTruth)
        XCTAssertFalse(SessionFolder.File.log.isMixedProvenance)
        XCTAssertTrue(SessionFolder.File.journal.isGroundTruth)
    }
    /// **A person may empty a sentence; a recogniser may not** — see
    /// `LogEntry.edited`. Every edit of a textless marker was dropped in silence
    /// until `allowingEmptyText` existed *(2026-09-03)*.
    func testEmptyingTheTextNeedsSayingSo() {
        let log = LogEntry(id: "a", t: 1, text: "steve made par", hole: 4,
                           source: .typed)
        XCTAssertNil(log.edited(text: "  "))
        let cleared = log.edited(text: "", allowingEmptyText: true)
        XCTAssertEqual(cleared?.text, "")
        XCTAssertEqual(cleared?.supersedes, "a")
        // The guard is only about the text: a fields-only edit was always fine.
        XCTAssertEqual(log.edited(shot: .some(2))?.text, "steve made par")
    }
    // MARK: - What may land on a row while its convergence is in flight

    private func waiting(_ id: String = "a") -> LogEntry {
        LogEntry(id: id, t: 1, text: "", hole: nil, source: .typed, mark: true)
    }

    /// A delete during the wait is final — the mark must not come back placed.
    func testAConvergenceWillNotResurrectADeletedRow() {
        let head = waiting().removed(id: "b")
        XCTAssertFalse(head.acceptsConvergedFix(accuracy: 5, startedFrom: "a"))
    }

    /// A drag during the wait wins, **even with no accuracy on it** — a moved row
    /// keeps whatever `hAcc` it had, which for a mark that never got a fix is nil,
    /// so the accuracy comparison alone cannot see it.
    func testAHandPlacedPositionBeatsALateFix() {
        let moved = waiting().placed(lat: 37, lon: -122, hAcc: nil, hole: nil, id: "b")
        XCTAssertFalse(moved.acceptsConvergedFix(accuracy: 5, startedFrom: "a"))
    }

    /// An edit that changed only fields is not a refusal: the caller writes off the
    /// head, so the edit survives being placed.
    func testAFieldEditDuringTheWaitStillAcceptsTheFix() {
        let edited = waiting().edited(player: .some("steve"), allowingEmptyText: true,
                                      id: "b")
        XCTAssertEqual(edited?.acceptsConvergedFix(accuracy: 5, startedFrom: "a"), true)
    }

    /// And a better fix is never replaced by a worse one.
    func testABetterFixIsKept() {
        let placed = waiting().placed(lat: 37, lon: -122, hAcc: 4, hole: nil, id: "a")
        XCTAssertFalse(placed.acceptsConvergedFix(accuracy: 9, startedFrom: "a"))
        XCTAssertTrue(placed.acceptsConvergedFix(accuracy: 2, startedFrom: "a"))
    }
}
