import XCTest
@testable import GolfSessionFormat

/// The journal is the record and the card is a view of it, so almost every test
/// here is really a test of `replay` — the card on screen is whatever this says.
final class JournalTests: XCTestCase {

    private func entry(_ act: JournalEntry.Act, id: String, t: Millis,
                       player: String? = nil, hole: Int? = nil,
                       strokes: Int? = nil, undoes: String? = nil,
                       eventID: String? = nil) -> JournalEntry {
        JournalEntry(id: id, t: t, act: act, player: player, hole: hole,
                     strokes: strokes, eventID: eventID, undoes: undoes)
    }

    // MARK: - Scores

    func testTheLastWriteWinsAndTheEarlierOneSurvivesOnDisk() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
        ]
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 7), 6)
        // The point of the journal: the 5 is still there to be read.
        XCTAssertEqual(rows.count, 2)
    }

    func testAZeroClearsAScoreRatherThanRecordingZeroStrokes() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: nil),
        ]
        XCTAssertNil(JournalReplay.replay(rows).score(player: "steve", hole: 7))
    }

    func testReplayIsOrderedByTimeNotByPositionInTheFile() {
        // Two processes append to one file; the intent's row can land after a row
        // stamped later. Position in the file is not the order things happened.
        let rows = [
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
        ]
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 7), 6)
    }

    // MARK: - Undo

    func testUndoRestoresThePreviousValueRatherThanClearingTheCell() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
            entry(.undo, id: "u1", t: 300, undoes: "b"),
        ]
        // Not nil — undoing the 6 leaves the 5, because replay simply never
        // applies the cancelled row.
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 7), 5)
    }

    func testAnUndoCanItselfBeUndoneAndThatIsRedo() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
            entry(.undo, id: "u1", t: 300, undoes: "b"),
            entry(.undo, id: "u2", t: 400, undoes: "u1"),
        ]
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 7), 6)
    }

    /// Three levels. A forward pass gets this wrong, which is why `live` walks
    /// backwards — every undo that could cancel a row is decided before that row
    /// is reached.
    func testUndoResolvesThroughAChainRatherThanOnePass() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
            entry(.undo, id: "u1", t: 300, undoes: "b"),
            entry(.undo, id: "u2", t: 400, undoes: "u1"),
            entry(.undo, id: "u3", t: 500, undoes: "u2"),
        ]
        // u3 kills u2, so u1 lives again, so b is cancelled: back to 5.
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 7), 5)
        let live = JournalReplay.live(rows).map(\.id)
        XCTAssertEqual(live, ["a"], "undo rows never survive `live`, and b is cancelled")
    }

    /// `live` drops undo rows so replay never applies one as an act; a history
    /// screen asks the *other* question and needs them. Using `live` for it struck
    /// through every undo and labelled it UNDONE — the opposite of what happened.
    func testInForceKeepsUndoRowsThatAreStillInForce() {
        let rows = [
            entry(.setScore, id: "a", t: 100, player: "steve", hole: 7, strokes: 5),
            entry(.undo, id: "u1", t: 200, undoes: "a"),
            entry(.undo, id: "u2", t: 300, undoes: "u1"),
        ]
        let force = JournalReplay.inForce(rows)
        XCTAssertTrue(force.contains("a"), "u1 was cancelled, so the score stands")
        XCTAssertFalse(force.contains("u1"))
        XCTAssertTrue(force.contains("u2"))
        XCTAssertFalse(JournalReplay.live(rows).contains { $0.act == .undo },
                       "replay must still never see an undo row")
    }

    func testInForceWithNoUndosKeepsEverything() {
        let rows = [entry(.setScore, id: "a", t: 100, player: "steve", hole: 1, strokes: 4)]
        XCTAssertEqual(JournalReplay.inForce(rows), ["a"])
    }

    func testAnUndoRowIsNeverAppliedAsAnAct() {
        // An `.undo` with a stray player/hole must not be mistaken for a setScore.
        var u = entry(.undo, id: "u", t: 300, player: "steve", hole: 7, strokes: 9)
        u.undoes = "nothing-here"
        XCTAssertNil(JournalReplay.replay([u]).score(player: "steve", hole: 7))
    }

    // MARK: - Seeding

    /// A round played before the journal existed has no journal at all, and its
    /// `scorecard.json` is the only record there is. Replaying from empty would
    /// hand the user a blank card and call it correct.
    func testAPreJournalRoundKeepsItsCard() {
        let seed = RoundState(scorecard: Scorecard(strokes: ["steve": [1: 4, 2: 5]]),
                              players: [Player(name: "steve")])
        let state = JournalReplay.replay([], seed: seed)
        XCTAssertEqual(state.score(player: "steve", hole: 1), 4)
        XCTAssertEqual(state.players.map(\.name), ["steve"])
    }

    func testAJournalRowOverridesTheSeededSnapshot() {
        let seed = RoundState(scorecard: Scorecard(strokes: ["steve": [1: 4]]))
        let rows = [entry(.setScore, id: "a", t: 100, player: "steve", hole: 1, strokes: 6)]
        XCTAssertEqual(JournalReplay.replay(rows, seed: seed).score(player: "steve", hole: 1), 6)
    }

    // MARK: - Stats

    func testStatsAreStoredPerPlayerPerHoleAndClearWithNil() {
        var a = entry(.setStat, id: "a", t: 100, player: "steve", hole: 3)
        a.stat = .putts; a.statValue = 3
        var b = entry(.setStat, id: "b", t: 200, player: "steve", hole: 3)
        b.stat = .gir; b.statValue = 0
        var c = entry(.setStat, id: "c", t: 300, player: "steve", hole: 3)
        c.stat = .putts; c.statValue = nil

        let state = JournalReplay.replay([a, b, c])
        XCTAssertNil(state.stat(.putts, player: "steve", hole: 3))
        XCTAssertEqual(state.stat(.gir, player: "steve", hole: 3), 0)
    }

    func testAStatIsNotAScore() {
        var a = entry(.setStat, id: "a", t: 100, player: "steve", hole: 3)
        a.stat = .putts; a.statValue = 3
        XCTAssertNil(JournalReplay.replay([a]).score(player: "steve", hole: 3))
    }

    // MARK: - Roster

    func testAddingRenamingAndRemovingAPlayer() {
        var add = entry(.addPlayer, id: "a", t: 100, player: "steve")
        add.name = "steve"
        var edit = entry(.editPlayer, id: "b", t: 200, player: "steve")
        edit.name = "Steve J"
        let remove = entry(.removePlayer, id: "c", t: 300, player: "steve")

        let after = JournalReplay.replay([add, edit])
        XCTAssertEqual(after.players.first?.name, "Steve J")
        XCTAssertEqual(after.players.first?.id, "steve",
                       "the id survives a rename — it is what scores are keyed on")

        XCTAssertTrue(JournalReplay.replay([add, edit, remove]).players.isEmpty)
    }

    /// A player removed by mistake and added back must not come back to an empty
    /// card. The journal exists to make mistakes recoverable.
    func testRemovingAPlayerKeepsTheirScores() {
        let rows = [
            entry(.setScore, id: "s", t: 100, player: "steve", hole: 1, strokes: 4),
            entry(.removePlayer, id: "r", t: 200, player: "steve"),
        ]
        XCTAssertEqual(JournalReplay.replay(rows).score(player: "steve", hole: 1), 4)
    }

    // MARK: - Handicap index and the frozen tee

    func testTheTeeFreezesItsRatingAndSlope() {
        var t = entry(.setTee, id: "t", t: 100, player: "steve")
        t.tee = "white"; t.rating = 71.2; t.slope = 128; t.par = 72
        var i = entry(.setIndex, id: "i", t: 200, player: "steve")
        i.index = 14.2

        let state = JournalReplay.replay([t, i])
        XCTAssertEqual(state.tees["steve"],
                       PlayerTee(name: "white", rating: 71.2, slope: 128, par: 72))
        XCTAssertEqual(state.indexes["steve"], 14.2)
    }

    // MARK: - Proposals

    func testAcceptingThenRejectingLeavesOnlyTheRejection() {
        let rows = [
            entry(.acceptEvent, id: "a", t: 100, eventID: "e1"),
            entry(.rejectEvent, id: "b", t: 200, eventID: "e1"),
        ]
        let state = JournalReplay.replay(rows)
        XCTAssertTrue(state.rejected.contains("e1"))
        XCTAssertFalse(state.accepted.contains("e1"),
                       "an event cannot be both, or the card and the list disagree")
    }

    /// **One act is one row.** Accepting used to `record(.acceptEvent)` and then
    /// `setScore`, so a single acceptance wrote two entries — one Undo reversed
    /// half of it, leaving the card showing the score with the proposal marked
    /// un-accepted, and the history listed every acceptance twice.
    func testAcceptingAScoreProposalIsOneRowAndOneUndoTakesItBack() {
        let proposal = Event(id: "e1", t: 50, kind: .score, provenance: .model,
                             player: "steve", hole: 7, strokes: 5, confidence: 0.7)
        let accept = entry(.acceptEvent, id: "a", t: 100, eventID: "e1")

        let after = JournalReplay.replay([accept], events: [proposal])
        XCTAssertEqual(after.score(player: "steve", hole: 7), 5)
        XCTAssertTrue(after.accepted.contains("e1"))

        let undone = JournalReplay.replay([accept, entry(.undo, id: "u", t: 200,
                                                         undoes: "a")],
                                          events: [proposal])
        XCTAssertNil(undone.score(player: "steve", hole: 7),
                     "one undo takes back the whole act, not half of it")
        XCTAssertFalse(undone.accepted.contains("e1"),
                       "the card and the proposal list must not disagree")
    }

    func testAHandTypedScoreAfterAnAcceptanceStillWins() {
        let proposal = Event(id: "e1", t: 50, kind: .score, provenance: .model,
                             player: "steve", hole: 7, strokes: 5)
        let rows = [
            entry(.acceptEvent, id: "a", t: 100, eventID: "e1"),
            entry(.setScore, id: "b", t: 200, player: "steve", hole: 7, strokes: 6),
        ]
        XCTAssertEqual(JournalReplay.replay(rows, events: [proposal])
                        .score(player: "steve", hole: 7), 6)
    }

    /// Accepting a shot or a note claims nothing about the card.
    func testAcceptingANonScoreProposalDoesNotTouchTheCard() {
        let proposal = Event(id: "e1", t: 50, kind: .shot, provenance: .model,
                             player: "steve", hole: 7, strokes: 3)
        let after = JournalReplay.replay([entry(.acceptEvent, id: "a", t: 100,
                                                eventID: "e1")],
                                         events: [proposal])
        XCTAssertNil(after.score(player: "steve", hole: 7))
        XCTAssertTrue(after.accepted.contains("e1"))
    }

    func testAnEventInNeitherSetIsStillADraft() {
        let state = JournalReplay.replay([entry(.acceptEvent, id: "a", t: 1, eventID: "e1")])
        XCTAssertFalse(state.accepted.contains("e2"))
        XCTAssertFalse(state.rejected.contains("e2"))
    }

    // MARK: - Format

    /// The reason this is a flat struct with optionals rather than an enum with
    /// associated values: these files are the user's own scores, and a row written
    /// before a field existed still has to decode.
    func testARowWrittenBeforeTheNewerFieldsExistedStillDecodes() throws {
        let old = #"{"act":"setScore","hole":7,"id":"a","player":"steve","strokes":5,"t":100}"#
        let e = try JSONDecoder().decode(JournalEntry.self, from: Data(old.utf8))
        XCTAssertEqual(e.act, .setScore)
        XCTAssertEqual(e.strokes, 5)
        XCTAssertNil(e.stat)
        XCTAssertNil(e.rating)
    }

    func testTheJournalIsGroundTruthAndTheCardIsDerived() {
        XCTAssertTrue(SessionFolder.File.journal.isGroundTruth)
        XCTAssertFalse(SessionFolder.File.journal.isMixedProvenance)
        // The snapshot stays ground truth too — it is a cache of a ground-truth file.
        XCTAssertTrue(SessionFolder.File.scorecard.isGroundTruth)
        // And the observation stream is still neither. See LogEntry.
        XCTAssertFalse(SessionFolder.File.log.isGroundTruth)
    }
}
