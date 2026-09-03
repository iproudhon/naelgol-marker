import XCTest
@testable import GolfSessionFormat
#if canImport(SwiftUI)
@testable import GolfCourse
@testable import GolfMap
#endif

/// X13–X15: an entry that names a shot, and the hole that stops moving.
final class MarkerShotTests: XCTestCase {

    private func log(_ id: String, hole: Int?, source: LogEntry.HoleSource? = nil,
                     player: String? = nil, shot: Int? = nil,
                     lat: Double? = 37.0, lon: Double? = -122.0,
                     hAcc: Double? = 5) -> LogEntry {
        LogEntry(id: id, t: 1_000, text: "x", lat: lat, lon: lon, hAcc: hAcc,
                 hole: hole, holeSource: source, player: player, shot: shot,
                 source: .typed)
    }

    // MARK: - X14 / the flip

    /// **The reported bug.** `LogPlacement.converge` derives the hole from the fix
    /// and appends a superseding row, and `Course.nearestHole` is a coin toss
    /// between two fairways forty metres apart — so a hole set by hand was replaced
    /// by a guess a few seconds later.
    func testAUserAssignedHoleSurvivesPlacement() {
        let mine = log("a", hole: 7, source: .user)
        let placed = mine.placed(lat: 37.5, lon: -122.5, hAcc: 3, hole: 12)
        XCTAssertEqual(placed.hole, 7, "placement must not overrule a person")
        XCTAssertEqual(placed.lat, 37.5, "the position is measured and still updates")
        XCTAssertEqual(placed.hAcc, 3)
    }

    func testADerivedHoleIsStillReplacedByABetterFix() {
        let derived = log("a", hole: 7)          // no holeSource: a proposal
        XCTAssertEqual(derived.placed(lat: 37.5, lon: -122.5, hAcc: 3, hole: 12).hole, 12)
    }

    /// A row written before the field existed decodes, and reads as derived — the
    /// old meaning, which is what every row on disk actually is.
    func testAnOldRowDecodesAsDerived() throws {
        let json = #"{"id":"a","t":1000,"text":"x","source":"typed","hole":4}"#
        let old = try JSONDecoder().decode(LogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(old.hole, 4)
        XCTAssertNil(old.holeSource)
        XCTAssertFalse(old.holeIsUserAssigned)
        XCTAssertNil(old.player)
        XCTAssertNil(old.shot)
    }

    /// Editing a row's hole is a person doing it, so it is marked as one — which is
    /// what stops the next convergence undoing the edit.
    func testEditingTheHoleMarksItUserAssigned() throws {
        let edited = try XCTUnwrap(log("a", hole: nil).edited(hole: .some(9)))
        XCTAssertEqual(edited.hole, 9)
        XCTAssertTrue(edited.holeIsUserAssigned)
        XCTAssertEqual(edited.supersedes, "a")
    }

    func testEditingOnlyTheTextLeavesTheHoleAlone() throws {
        let edited = try XCTUnwrap(log("a", hole: 3).edited(text: "y"))
        XCTAssertEqual(edited.hole, 3)
        XCTAssertFalse(edited.holeIsUserAssigned, "the hole was not touched")
    }

    // MARK: - X15 / shot numbering

    func testTheNextShotIsOneMoreThanThisPlayersLastOnThisHole() {
        let logs = [log("a", hole: 7, player: "steve", shot: 1),
                    log("b", hole: 7, player: "steve", shot: 2),
                    log("c", hole: 7, player: "dave", shot: 1),
                    log("d", hole: 8, player: "steve", shot: 5)]
        XCTAssertEqual(LogEntry.nextShot(for: "steve", hole: 7, in: logs), 3)
        XCTAssertEqual(LogEntry.nextShot(for: "dave", hole: 7, in: logs), 2)
        XCTAssertEqual(LogEntry.nextShot(for: "min", hole: 7, in: logs), 1)
    }

    /// **Counted from the current rows, never the raw file.** A burst entry grows by
    /// superseding and an edit is a new row, so counting every row on disk would
    /// jump the number every time somebody fixed a typo.
    func testASupersededRowDoesNotInflateTheNextShot() {
        var first = log("a", hole: 7, player: "steve", shot: 1)
        var second = first
        second.id = "b"; second.supersedes = "a"; second.shot = 1
        first.text = "old"
        XCTAssertEqual(LogEntry.nextShot(for: "steve", hole: 7, in: [first, second]), 2)
    }

    func testAShotNeedsBothAPlayerAndANumber() {
        XCTAssertTrue(log("a", hole: 7, player: "steve", shot: 1).isShot)
        XCTAssertFalse(log("b", hole: 7, player: "steve").isShot)
        XCTAssertFalse(log("c", hole: 7, shot: 1).isShot)
    }

    #if canImport(SwiftUI)
    // MARK: - X13 / what the pill says

    /// **The name and nothing else** — stored shot 2 is called `1`, because the
    /// stored 1 is the tee shot and reads `T` *(user, 2026-08-29)*. `ShotName` owns
    /// the offset; see `MarkerLayerTests`. The player's name was dropped on
    /// 2026-08-30 ("no club icon or name … color is good enough to distinguish") —
    /// what is left is the number, the circle it sits in, and the colour.
    func testAShotReadsAsNameOnly() {
        let m = HoleMarker(id: "a", at: Coordinate(lat: 37, lon: -122),
                           label: "ignored",
                           shot: 2, player: "steve", colorIndex: 0)
        XCTAssertEqual(m.title, "1")
        XCTAssertTrue(m.isShot)
        XCTAssertNotNil(m.tint)
    }

    /// An entry that is not a shot keeps its sentence and gets **no icon** — how it
    /// was captured is a fact about the app, not about the round.
    func testAPlainEntryKeepsItsTextAndHasNoIcon() {
        let m = HoleMarker(id: "a", at: Coordinate(lat: 37, lon: -122),
                           label: "lost ball in the trees")
        XCTAssertEqual(m.title, "lost ball in the trees")
        XCTAssertNil(m.symbol)
        XCTAssertNil(m.tint)
    }

    // MARK: - The line between unassigned marks (user, 2026-09-03)

    private func mark(_ id: String, _ lat: Double) -> HoleMarker {
        HoleMarker(id: id, at: Coordinate(lat: lat, lon: -122), label: "mark",
                   isMark: true)
    }

    /// The caller's order is the line's order — the ids say which marks and in
    /// which sequence, because `HoleMarker` carries no clock.
    func testTheLineFollowsTheOrderTheIdsAreGivenIn() {
        let marks = [mark("c", 37.2), mark("a", 37.0), mark("b", 37.1)]
        let line = HoleMarker.line(["a", "b", "c"], in: marks)
        XCTAssertEqual(line.map(\.lat), [37.0, 37.1, 37.2])
    }

    /// A dragged mark's leg follows the finger, the way a shot's track does —
    /// **keyed by id**, which a mark has and a `PlayerTrack.Shot` does not.
    func testADraggedMarkCarriesItsLine() {
        let marks = [mark("a", 37.0), mark("b", 37.1)]
        let line = HoleMarker.line(["a", "b"], in: marks,
                                   moving: ("b", Coordinate(lat: 37.5, lon: -122)))
        XCTAssertEqual(line.map(\.lat), [37.0, 37.5])
    }

    /// A mark not on screen closes the line up rather than breaking it in two —
    /// two lines would read as two runs of presses, which is a different claim.
    /// And fewer than two points is no line at all.
    func testAMissingMarkIsSkippedAndOnePointDrawsNothing() {
        let marks = [mark("a", 37.0), mark("c", 37.2)]
        XCTAssertEqual(HoleMarker.line(["a", "b", "c"], in: marks).count, 2)
        XCTAssertTrue(HoleMarker.line(["a", "b"], in: [mark("a", 37.0)]).isEmpty)
        XCTAssertTrue(HoleMarker.line(["a"], in: marks).isEmpty)
    }
    #endif
}
