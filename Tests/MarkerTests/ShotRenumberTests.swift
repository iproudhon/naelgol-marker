import XCTest
@testable import GolfSessionFormat

/// The user's three worked examples, 2026-09-03, written in **display** terms in
/// the request and in **stored** terms here: the tee shot is stored 1 and reads
/// `T`, so display `1` is stored 2 and display `2` is stored 3.
final class ShotRenumberTests: XCTestCase {

    private func log(_ id: String, shot: Int?, player: String = "steve",
                     hole: Int? = 1) -> LogEntry {
        LogEntry(id: id, t: 1, text: "x", hole: hole, player: player, shot: shot,
                 source: .typed)
    }

    /// `(T, 1, 1, 2)` — the duplicate `1` renumbered to `2` pushes the old `2` to
    /// `3`, and nothing else moves.
    func testRenumberingOntoADuplicatePushesTheOccupant() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 2),
                    log("c", shot: 3)]
        let shifts = ShotRenumber.assigning(3, to: "a", player: "steve", hole: 1,
                                            in: logs)
        XCTAssertEqual(shifts, ["c": 4])
    }

    /// `(T, 1, 2)` with a `2` added — same rule arriving from a row that had no
    /// number at all, which is what claiming an Action Button mark does.
    func testClaimingAMarkOntoAnOccupiedNumberPushes() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 3),
                    log("mk", shot: nil)]
        XCTAssertEqual(ShotRenumber.assigning(3, to: "mk", player: "steve", hole: 1,
                                              in: logs), ["b": 4])
    }

    /// **The cascade stops at the first gap.** A run of occupied numbers moves; the
    /// shot above the gap is somebody's missing stroke and stays where it is.
    func testTheCascadeStopsAtTheFirstFreeNumber() {
        let logs = [log("a", shot: 2), log("b", shot: 3), log("d", shot: 6)]
        XCTAssertEqual(ShotRenumber.assigning(2, to: "new", player: "steve", hole: 1,
                                              in: logs), ["a": 3, "b": 4])
    }

    /// A number nobody holds renumbers nothing — filing a shot at the end of the
    /// hole is the ordinary case and must not touch a row.
    func testAFreeNumberMovesNothing() {
        let logs = [log("t", shot: 1), log("a", shot: 2)]
        XCTAssertTrue(ShotRenumber.assigning(3, to: "new", player: "steve", hole: 1,
                                             in: logs).isEmpty)
    }

    /// `(T, 1, 2, 4)` — removing the `2` brings the `4` down to `3`, **across the
    /// gap**. A removal takes a stroke out of the hole, so every later shot really
    /// is one earlier than it was.
    func testRemovingDecrementsEveryLaterShotAcrossAGap() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 3),
                    log("d", shot: 5)]
        XCTAssertEqual(ShotRenumber.removing(3, id: "b", player: "steve", hole: 1,
                                             in: logs), ["d": 4])
    }

    // MARK: - The examples as sequences

    /// The shift *maps* above are one inference away from what the user wrote. These
    /// apply them and read the hole back the way it is drawn — `T, 1, 2, 3` — which
    /// is the form the three examples are stated in.
    private func sequence(_ logs: [LogEntry], shifts: [String: Int],
                          dropping gone: String? = nil) -> [String] {
        logs.filter { $0.id != gone }
            .map { log -> Int in shifts[log.id] ?? log.shot ?? 0 }
            .sorted()
            .map { $0 == 1 ? "T" : "\($0 - 1)" }
    }

    /// `(T, 1, 1, 2)` → renumber the first `1` to `2` → `(T, 1, 2, 3)`.
    func testExampleOneEndsTidy() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 2),
                    log("c", shot: 3)]
        var shifts = ShotRenumber.assigning(3, to: "a", player: "steve", hole: 1,
                                            in: logs)
        shifts["a"] = 3
        XCTAssertEqual(sequence(logs, shifts: shifts), ["T", "1", "2", "3"])
    }

    /// `(T, 1, 2)` + a `2` added → `(T, 1, 2, 3)`.
    func testExampleTwoEndsTidy() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 3),
                    log("mk", shot: nil)]
        var shifts = ShotRenumber.assigning(3, to: "mk", player: "steve", hole: 1,
                                            in: logs)
        shifts["mk"] = 3
        XCTAssertEqual(sequence(logs, shifts: shifts), ["T", "1", "2", "3"])
    }

    /// `(T, 1, 2, 4)` − the `2` → `(T, 1, 3)`. **Everything above comes down one;
    /// the pre-existing gap is not closed** — the user asked for "(4) becomes (3)",
    /// which is one stroke off each later shot, not a resequencing. The `2` that is
    /// now missing is the shot that was removed.
    func testExampleThreeEndsTidy() {
        let logs = [log("t", shot: 1), log("a", shot: 2), log("b", shot: 3),
                    log("d", shot: 5)]
        let shifts = ShotRenumber.removing(3, id: "b", player: "steve", hole: 1,
                                           in: logs)
        XCTAssertEqual(sequence(logs, shifts: shifts, dropping: "b"),
                       ["T", "1", "3"])
    }

    /// Another player, another hole, and a deleted row are all somebody else's
    /// sequence. The hole is matched as it is, `nil` included.
    func testOnlyTheSamePlayerAndHoleMove() {
        let gone = LogEntry(id: "x", t: 1, text: "x", hole: 1, player: "steve",
                            shot: 4, source: .typed, deleted: true)
        let logs = [log("a", shot: 3),
                    log("other", shot: 3, player: "dave"),
                    log("next", shot: 3, hole: 2),
                    log("nohole", shot: 3, hole: nil),
                    gone]
        XCTAssertEqual(ShotRenumber.removing(2, id: "z", player: "steve", hole: 1,
                                             in: logs), ["a": 2])
        XCTAssertEqual(ShotRenumber.assigning(3, to: "z", player: "steve", hole: nil,
                                              in: logs), ["nohole": 4])
    }
}
