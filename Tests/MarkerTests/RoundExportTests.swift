import XCTest
@testable import GolfSessionFormat

/// The clipboard is an interface: a round pasted into a model or another tool is
/// only as good as what the copy kept.
final class RoundExportTests: XCTestCase {

    private let start: Millis = 1_700_000_000_000
    private var roster: [Player] { [Player(id: "steve", name: "Steve")] }

    private func sampleLog() -> LogEntry {
        LogEntry(id: "L1", t: start + 124_000, text: "7: 2 drive into the left bunker",
                 lat: 37.7402, lon: -122.2661, hAcc: 4.5, hole: 7, holeSource: .user,
                 player: "steve", shot: 2, source: .spoken)
    }

    /// The whole complaint, in one assertion: the text form threw away everything
    /// the round turns on and kept the sentence.
    func testALogCarriesPositionPlayerHoleAndTime() throws {
        let o = RoundExport.log(sampleLog(), players: roster, start: start, holeRef: "7")
        XCTAssertEqual(o["text"] as? String, "7: 2 drive into the left bunker")
        XCTAssertEqual(o["hole"] as? Int, 7)
        XCTAssertEqual(o["holeRef"] as? String, "7")
        XCTAssertEqual(o["holeSource"] as? String, "user")
        XCTAssertEqual(o["player"] as? String, "steve")
        XCTAssertEqual(o["shot"] as? Int, 2)
        XCTAssertEqual(o["elapsed"] as? String, "0:02:04")
        let pos = try XCTUnwrap(o["position"] as? [String: Any])
        XCTAssertEqual(pos["lat"] as? Double, 37.7402)
        XCTAssertEqual(pos["accuracy"] as? Double, 4.5)
    }

    /// **The display name *and* the id.** A reader expects a name; a rename changes
    /// the name and not the id, so dropping the id would break the join back to the
    /// round it came from — the same reason `LogEntry.player` stores an id at all.
    func testPlayerIsResolvedToANameWithoutLosingTheID() {
        let o = RoundExport.log(sampleLog(), players: roster, start: start)
        XCTAssertEqual(o["player"] as? String, "steve")
        XCTAssertEqual(o["playerName"] as? String, "Steve")
    }

    /// An unknown id is reported as itself rather than dropped: a roster edit must
    /// not make an old row look like it belonged to nobody.
    func testAnUnknownPlayerIDIsItsOwnName() {
        let o = RoundExport.log(sampleLog(), players: [], start: start)
        XCTAssertEqual(o["playerName"] as? String, "steve")
    }

    /// A log with no fix has **no** position key — not a null island, and not a
    /// zero. `LogEntry.hasPosition` treats the absence as a real answer and so does
    /// this.
    func testAnUnplacedLogHasNoPosition() {
        let l = LogEntry(id: "L2", t: start, text: "we're on the ninth", source: .typed)
        let o = RoundExport.log(l, start: start)
        XCTAssertNil(o["position"])
        XCTAssertNil(o["hole"])
    }

    /// The hole filter follows the screen: **a row with no hole belongs to every
    /// hole.** Excluding it would make a copy silently shorter than the list it was
    /// copied from.
    func testAHoleCopyKeepsTheRowsWithNoHole() throws {
        let placed = sampleLog()
        let nowhere = LogEntry(id: "L3", t: start + 1, text: "nice", source: .typed)
        let elsewhere = LogEntry(id: "L4", t: start + 2, text: "on the 9th",
                                 hole: 9, source: .typed)
        let o = RoundExport.round(logs: [placed, nowhere, elsewhere], players: roster,
                                  start: start, hole: 7)
        let ids = try XCTUnwrap(o["logs"] as? [[String: Any]]).map { $0["id"] as? String }
        // Sorted by the session clock, so the copy reads in the order things
        // happened — "nice" was said two minutes before the drive was logged.
        XCTAssertEqual(ids, ["L3", "L1"])
    }

    /// Events come with the round — the pin is an event, and X19 asked for exactly
    /// that: "copy of events should include this info".
    func testTheRoundCarriesItsEventsIncludingThePin() throws {
        let pin = Event(id: "E1", t: start + 60_000, kind: .pin, provenance: .user,
                        hole: 7, lat: 37.7, lon: -122.2)
        let o = RoundExport.round(logs: [sampleLog()], events: [pin], players: roster,
                                  course: "Corica Park South", start: start)
        let events = try XCTUnwrap(o["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["kind"] as? String, "pin")
        XCTAssertEqual(events[0]["provenance"] as? String, "user")
        XCTAssertNotNil(events[0]["position"])
        XCTAssertEqual(o["course"] as? String, "Corica Park South")
    }

    /// It has to be parseable, and it has to be **stable**: a clipboard gets diffed,
    /// and a dictionary's iteration order is not stable between runs.
    func testTheStringIsValidAndDeterministicJSON() throws {
        let o = RoundExport.round(logs: [sampleLog()], players: roster, start: start)
        let s = RoundExport.string(o)
        XCTAssertEqual(s, RoundExport.string(o))
        let back = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        XCTAssertEqual((back?["logs"] as? [[String: Any]])?.count, 1)
    }
}
