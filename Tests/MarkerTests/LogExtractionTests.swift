import XCTest
@testable import GolfReconstruction
import GolfSessionFormat

final class LogExtractionTests: XCTestCase {

    private func log(_ id: String, _ t: Millis, _ text: String,
                     hole: Int? = 7, lat: Double? = nil) -> LogEntry {
        LogEntry(id: id, t: t, text: text, lat: lat, lon: lat.map { _ in -122.2 },
                 hole: hole, source: .spoken)
    }

    // MARK: - The firewall

    /// Everything that leaves this type is a proposal, **by construction** — there
    /// is no argument to pass `.user` to. That is the whole reason `Proposal` is a
    /// separate type from `Event`: a value decoded straight out of a model response
    /// must not be able to arrive claiming to be ground truth.
    func testEverythingExtractedIsAProposal() {
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "shot", player: "steve", logs: ["a"])],
            logs: [log("a", 1_000, "steve hit a seven iron")], hole: 7)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].provenance, .model)
        XCTAssertFalse(events[0].isGroundTruth)
        XCTAssertEqual(LogExtraction.events(from: [], logs: [], hole: nil).count, 0)
    }

    /// The roster reaches the model, because a spoken name is the only attribution
    /// signal there is — diarization was cut and `contextualStrings` does nothing.
    /// The instruction to match it *phonetically* is the load-bearing half: Siri
    /// mangles names and there is no knob to tell it otherwise.
    func testInstructionsCarryTheRosterAndDemandFuzzyMatching() {
        let text = LogExtraction.instructions(players: [
            Player(name: "steve"),
            Player(name: "dave"),
        ])
        XCTAssertTrue(text.contains("steve"))
        XCTAssertTrue(text.contains("스티브"))
        XCTAssertTrue(text.contains("dave"))
        XCTAssertTrue(text.lowercased().contains("phonetical"))
    }

    // MARK: - Timing

    /// An event is timed from the **first log it cites**, not from when extraction
    /// ran. Stamping "now" would put every shot on a hole at the same instant, in
    /// whatever order the model happened to list them — and the session clock is
    /// the one thing every other stream is joined on.
    func testAnEventIsTimedFromTheLogItCitesNotFromNow() {
        let logs = [log("a", 10_000, "seven iron"), log("b", 40_000, "on in two")]
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "shot", logs: ["b"])],
            logs: logs, hole: 7, fallbackTime: 999_999)
        XCTAssertEqual(events[0].t, 40_000)
    }

    /// A proposal citing nothing still becomes an event — it is a claim the user
    /// can delete — but it has no evidence to show, and `logs` says so rather than
    /// pointing at an unrelated line.
    func testAProposalCitingNothingHasNoEvidence() {
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "note", text: "windy", logs: [])],
            logs: [log("a", 1_000, "seven iron")], hole: 7, fallbackTime: 5_000)
        XCTAssertNil(events[0].logs)
        XCTAssertEqual(events[0].t, 5_000)
    }

    /// A coordinate comes from the cited log or not at all. Borrowing the nearest
    /// other log's position would place a shot where a different sentence was
    /// spoken, and it would look exactly like a real measurement.
    func testAPositionIsNeverBorrowedFromAnotherLog() {
        let logs = [log("a", 1_000, "in the bunker", lat: nil),
                    log("b", 2_000, "out", lat: 37.7)]
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "shot", logs: ["a"])],
            logs: logs, hole: 7)
        XCTAssertNil(events[0].lat)
    }

    // MARK: - Robustness

    /// A kind the model invented becomes a `.note`, not a dropped row. The sentence
    /// is real and it is in `text`; discarding it would lose the log's only trace on
    /// the events list, which is the invisible-missing-shot failure the whole
    /// propose-don't-omit rule exists to avoid.
    func testAnUnknownKindBecomesANoteRatherThanVanishing() {
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "approach", text: "wedge to 10 feet",
                                          logs: ["a"])],
            logs: [log("a", 1_000, "wedge to ten feet")], hole: 7)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .note)
        XCTAssertEqual(events[0].text, "wedge to 10 feet")
    }

    func testConfidenceIsClamped() {
        let events = LogExtraction.events(
            from: [LogExtraction.Proposal(kind: "shot", confidence: 4.2, logs: []),
                   LogExtraction.Proposal(kind: "shot", confidence: -1, logs: [])],
            logs: [], hole: 1)
        XCTAssertEqual(events[0].confidence, 1)
        XCTAssertEqual(events[1].confidence, 0)
    }

    // MARK: - Chunking

    /// Extraction runs per hole because the on-device model's context is ~4,096
    /// tokens *including its own output*. Logs with no hole are a real bucket, not
    /// an error — they sort last so they are the leftovers rather than hole zero.
    func testLogsGroupByHoleWithUnattributedLast() {
        let logs = [log("a", 1, "x", hole: 3), log("b", 2, "y", hole: nil),
                    log("c", 3, "z", hole: 1), log("d", 4, "w", hole: 3)]
        let groups = LogExtraction.byHole(logs)
        XCTAssertEqual(groups.map(\.hole), [1, 3, nil])
        XCTAssertEqual(groups[1].logs.map(\.id), ["a", "d"])
    }

    /// The prompt uses seconds since the first log of the hole, not epoch millis.
    /// Order and spacing are what carry meaning; 13-digit numbers are pure token
    /// cost against a window this small.
    func testThePromptIsRelativeToTheHoleNotTheEpoch() {
        let logs = [log("a", 1_700_000_000_000, "tee shot"),
                    log("b", 1_700_000_090_000, "on the green")]
        let text = LogExtraction.prompt(logs: logs, hole: 7, par: 4)
        XCTAssertTrue(text.contains("[a @0s] tee shot"))
        XCTAssertTrue(text.contains("[b @90s] on the green"))
        XCTAssertFalse(text.contains("1700000000000"))
        XCTAssertTrue(text.contains("Hole 7, par 4"))
    }
}
