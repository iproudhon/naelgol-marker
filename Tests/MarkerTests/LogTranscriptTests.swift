import XCTest
@testable import GolfSessionFormat

final class LogTranscriptTests: XCTestCase {

    private func log(_ text: String, t: Millis, hole: Int?, id: String) -> LogEntry {
        LogEntry(id: id, t: t, text: text, hole: hole, source: .spoken)
    }

    /// The same rule the screen follows: a log whose hole is nil appears on
    /// **every** hole, because `hole` is a proposal and nil is what
    /// `Course.nearestHole` returns for a fix more than 250 m from anything
    /// mapped. Excluding those rows would make a copied transcript quietly shorter
    /// than the list it was copied from.
    func testALogWithNoHoleIsCopiedWithEveryHole() {
        let logs = [log("on seven", t: 10, hole: 7, id: "a"),
                    log("nowhere", t: 20, hole: nil, id: "b"),
                    log("on eight", t: 30, hole: 8, id: "c")]
        XCTAssertEqual(LogTranscript.onHole(logs, hole: 7).map(\.id), ["a", "b"])
        XCTAssertEqual(LogTranscript.onHole(logs, hole: 8).map(\.id), ["b", "c"])
    }

    func testNilHoleMeansTheWholeRound() {
        let logs = [log("a", t: 10, hole: 7, id: "a"), log("b", t: 20, hole: 8, id: "b")]
        XCTAssertEqual(LogTranscript.onHole(logs, hole: nil).count, 2)
    }

    func testTextIsElapsedFromTheRoundsOwnStart() {
        let start: Millis = 1_000_000
        let logs = [log("second", t: start + 3_725_000, hole: nil, id: "b"),
                    log("first", t: start + 64_000, hole: nil, id: "a")]
        XCTAssertEqual(LogTranscript.text(logs, start: start),
                       "0:01:04  first\n1:02:05  second")
    }

    /// A phrase can commit a few milliseconds before `meta.start` is stamped, and
    /// a negative clock on screen reads as corruption rather than as rounding.
    func testAClockBeforeTheStartIsZeroNotNegative() {
        XCTAssertEqual(LogTranscript.elapsed(900, from: 1_000), "0:00:00")
    }

    func testEmptyLogsGiveEmptyText() {
        XCTAssertEqual(LogTranscript.text([], start: 0), "")
    }
}
