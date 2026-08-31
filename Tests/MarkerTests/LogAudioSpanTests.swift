import XCTest
@testable import GolfSessionFormat

/// `LogEntry.tEnd` — the field that makes one entry re-transcribable.
final class LogAudioSpanTests: XCTestCase {

    func testATypedLogHasNoAudioToReadAgain() {
        let typed = LogEntry(t: 1_000, text: "steve made par", source: .typed, tEnd: 5_000)
        XCTAssertFalse(typed.hasAudioSpan, "there is nothing recorded behind a typed sentence")
    }

    /// Every spoken log written before this field existed. The button must not
    /// appear for them rather than appearing and failing.
    func testASpokenLogWithNoEndHasNoSpan() {
        let old = LogEntry(t: 1_000, text: "steve made par", source: .spoken)
        XCTAssertFalse(old.hasAudioSpan)
    }

    func testASpokenLogWithARealEndHasASpan() {
        let entry = LogEntry(t: 1_000, text: "steve made par", source: .spoken, tEnd: 6_400)
        XCTAssertTrue(entry.hasAudioSpan)
    }

    func testAZeroLengthSpanIsNotASpan() {
        let entry = LogEntry(t: 1_000, text: "hm", source: .spoken, tEnd: 1_000)
        XCTAssertFalse(entry.hasAudioSpan, "a decode pass over no audio is what makes Whisper invent")
    }

    /// A round recorded before `tEnd` existed must keep decoding. These are the
    /// user's own rounds and there is no migration.
    func testARowWithoutTEndStillDecodes() throws {
        let json = #"{"id":"a","t":1000,"text":"steve made par","source":"siri"}"#
        let entry = try JSONDecoder().decode(LogEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.tEnd)
        XCTAssertEqual(entry.text, "steve made par")
    }

    /// A burst grows by superseding, and the span has to grow with it — `t` is
    /// when the golfer started talking, `tEnd` is where they have got to.
    func testEditingCarriesTheSpanSoAGrowingBurstKeepsItsAudio() throws {
        let first = LogEntry(t: 1_000, text: "steve", source: .spoken, tEnd: 3_000)
        var grown = try XCTUnwrap(first.edited(text: "steve made par"))
        XCTAssertEqual(grown.t, 1_000)
        XCTAssertEqual(grown.tEnd, 3_000)
        grown.tEnd = 9_000
        XCTAssertEqual(grown.t, 1_000, "the entry still begins where the golfer began talking")
        XCTAssertTrue(grown.hasAudioSpan)
    }

    /// The late coordinate must not disturb the audio span — they are two
    /// different writers growing the same chain.
    func testConvergingOnAFixKeepsTheSpan() {
        let entry = LogEntry(t: 1_000, text: "steve made par", source: .spoken, tEnd: 6_400)
        let placed = entry.placed(lat: 37.4, lon: 127.2, hAcc: 4, hole: 7)
        XCTAssertEqual(placed.tEnd, 6_400)
        XCTAssertEqual(placed.t, 1_000)
    }
}
