import XCTest
import GolfSessionFormat
@testable import GolfTranscription

final class TranscriptionContextTests: XCTestCase {

    /// A player called "형" by one friend and "스티브" by another is attributable
    /// by those names and by nothing else, so the recognizer has to be told all of
    /// them — `allNames`, never `name`.
    func testRoundContextCarriesEveryNameThePlayerIsCalled() {
        let ctx = TranscriptionContext.forRound(players: [
            Player(name: "steve", aliases: ["스티브", "형"]),
            Player(name: "dave"),
        ])
        for expected in ["steve", "스티브", "형", "dave"] {
            XCTAssertTrue(ctx.contextualStrings.contains(expected), "missing \(expected)")
        }
    }

    func testGolfVocabularyIsIncludedAndDeduped() {
        let ctx = TranscriptionContext.forRound(players: [Player(name: "par")],
                                                extra: ["Par", "  ", "Vokey"])
        XCTAssertTrue(ctx.contextualStrings.contains("birdie"))
        XCTAssertTrue(ctx.contextualStrings.contains("pitching wedge"))
        XCTAssertTrue(ctx.contextualStrings.contains("Vokey"))
        XCTAssertFalse(ctx.contextualStrings.contains(""))
        let lowered = ctx.contextualStrings.map { $0.lowercased() }
        XCTAssertEqual(Set(lowered).count, lowered.count, "case-insensitive duplicates")
    }

    /// The names that actually carry attribution come first, ahead of the generic
    /// golf words — the roster is the part that cannot be recovered from context.
    func testPlayerNamesComeFirst() {
        let ctx = TranscriptionContext.forRound(players: [Player(name: "chungmin")])
        XCTAssertEqual(ctx.contextualStrings.first, "chungmin")
    }

    func testEmptyRosterStillSuppliesTheGolfVocabulary() {
        let ctx = TranscriptionContext.forRound(players: [])
        XCTAssertFalse(ctx.contextualStrings.isEmpty)
        XCTAssertTrue(ctx.contextualStrings.contains("you're away"))
    }
}

final class TranscriberMappingTests: XCTestCase {

    /// The comment on `meanConfidence` claims an unweighted mean lets one unsure
    /// word drag a confident sentence down. This is that claim, asserted.
    @available(iOS 26, macOS 26, *)
    func testConfidenceIsWeightedByHowMuchTextEachRunCovers() throws {
        var long = AttributedString("a confident sentence of some length")
        long.transcriptionConfidence = 0.9
        var short = AttributedString(" no")
        short.transcriptionConfidence = 0.1
        let combined = long + short

        let mean = try XCTUnwrap(AppleTranscriber.meanConfidence(of: combined))
        let unweighted = (0.9 + 0.1) / 2
        XCTAssertGreaterThan(mean, unweighted,
                             "a three-character doubt must not halve a long confident run")
        XCTAssertLessThan(mean, 0.9)
    }

    @available(iOS 26, macOS 26, *)
    func testConfidenceIsNilWhenTheRecognizerReportedNone() {
        XCTAssertNil(AppleTranscriber.meanConfidence(of: AttributedString("no attributes")))
    }

    @available(iOS 26, macOS 26, *)
    func testSingleRunConfidenceIsItsOwnValue() throws {
        var only = AttributedString("bogey")
        only.transcriptionConfidence = 0.64
        XCTAssertEqual(try XCTUnwrap(AppleTranscriber.meanConfidence(of: only)),
                       0.64, accuracy: 0.0001)
    }
}

final class SegmentWindowTests: XCTestCase {
    private let start: Millis = 1_000_000

    /// An unclosed segment must not swallow every later segment's utterances.
    func testUnclosedSegmentIsBoundedByTheNextSegmentsStart() {
        let segments = [
            AudioSegment(index: 0, file: "a", t0: start, t1: nil),      // never closed
            AudioSegment(index: 1, file: "b", t0: start + 300_000, t1: start + 310_000),
        ]
        let w = SessionTranscriber.windows(of: segments)
        XCTAssertEqual(w[0].end, start + 299_999)
        XCTAssertEqual(w[1].start, start + 300_000)
        XCTAssertEqual(w[1].end, start + 310_000)
    }

    /// The last segment of a crashed round genuinely has no upper bound.
    func testTrailingUnclosedSegmentIsOpenEnded() {
        let w = SessionTranscriber.windows(of: [
            AudioSegment(index: 0, file: "a", t0: start, t1: start + 5_000),
            AudioSegment(index: 1, file: "b", t0: start + 6_000, t1: nil),
        ])
        XCTAssertEqual(w[0].end, start + 5_000)
        XCTAssertEqual(w[1].end, Millis.max)
    }
}
