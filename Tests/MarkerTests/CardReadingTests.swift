import XCTest
@testable import GolfReconstruction
@testable import GolfSessionFormat

final class CardReadingTests: XCTestCase {

    private let roster = [
        Player(name: "steve"),
        Player(name: "dave"),
        Player(name: "min"),
    ]

    // MARK: - Name matching

    func testAnExactNameMatches() {
        XCTAssertEqual(CardReading.match("dave", in: roster)?.id, "dave")
    }

    func testCaseAndSpacingAreIgnored() {
        XCTAssertEqual(CardReading.match("  DAVE ", in: roster)?.id, "dave")
    }

    /// **A name in the other script matches nobody, and is returned unmatched
    /// rather than guessed at.** Aliases were removed on 2026-08-31, so a card
    /// written "스티브" against a roster that says "steve" no longer resolves. The
    /// row survives with a nil `player` — a card read that silently loses a person
    /// looks like a card with three players on it.
    func testANameInAnotherScriptMatchesNobodyRatherThanTheWrongPerson() {
        XCTAssertNil(CardReading.match("스티브", in: roster))
        XCTAssertNil(CardReading.match("형", in: roster))
    }

    func testAPartialNameMatchesInEitherDirection() {
        XCTAssertEqual(CardReading.match("Steve J", in: roster)?.id, "steve")
        XCTAssertEqual(CardReading.match("ste", in: roster)?.id, "steve")
    }

    /// Deliberately not edit distance: at these lengths it pairs "min" with "kim",
    /// and a wrong pairing files a whole round under the wrong person.
    func testAStrangerMatchesNobodyRatherThanTheNearestPlayer() {
        XCTAssertNil(CardReading.match("kim", in: roster))
        XCTAssertNil(CardReading.match("", in: roster))
    }

    // MARK: - Resolution

    func testAnUnmatchedRowIsKeptWithNoPlayerRatherThanDropped() {
        let lines = [CardReading.Line(name: "kim", strokes: [1: 5])]
        let out = CardReading.resolve(lines, players: roster, holeCount: 18)
        XCTAssertEqual(out.count, 1, "a card read must not silently lose a person")
        XCTAssertNil(out[0].player)
        XCTAssertEqual(out[0].name, "kim")
    }

    func testHolesOutsideTheCourseAreDroppedRatherThanApplied() {
        let lines = [CardReading.Line(name: "steve", strokes: [0: 4, 1: 5, 19: 6])]
        let out = CardReading.resolve(lines, players: roster, holeCount: 18)
        XCTAssertEqual(out[0].strokes, [1: 5])
    }

    /// A photograph read of a blank cell can come back as 0, and a smudge as 40.
    /// Neither is a score anyone took.
    func testImplausibleStrokeCountsAreDropped() {
        let lines = [CardReading.Line(name: "steve", strokes: [1: 0, 2: 4, 3: 40])]
        let out = CardReading.resolve(lines, players: roster, holeCount: 18)
        XCTAssertEqual(out[0].strokes, [2: 4])
    }

    func testNineHoleCourseRejectsTheBackNine() {
        let lines = [CardReading.Line(name: "steve", strokes: [9: 4, 10: 5])]
        let out = CardReading.resolve(lines, players: roster, holeCount: 9)
        XCTAssertEqual(out[0].strokes, [9: 4])
    }

    func testTotalIsTheSumOfWhatSurvived() {
        let lines = [CardReading.Line(name: "steve", strokes: [1: 5, 2: 4, 99: 3])]
        XCTAssertEqual(CardReading.resolve(lines, players: roster, holeCount: 18)[0].total, 9)
    }

    // MARK: - Instructions

    /// Each rule closes a failure that looks like success: an invented score reads
    /// like a real one, the PAR row is a set of plausible strokes, and a card of
    /// named nines does not number its holes 1–18.
    func testTheInstructionsCarryTheThreeRulesAndTheRoster() {
        let text = CardReading.instructions(players: roster, holeCount: 18)
        XCTAssertTrue(text.contains("steve"), "the roster goes to the model")
        XCTAssertTrue(text.contains("PAR"))
        XCTAssertTrue(text.contains("Never estimate"))
        XCTAssertTrue(text.contains("is 10"), "the second nine starts at 10 on an 18")
    }

    func testTheSecondNineIsCountedThroughOnANineHoleCard() {
        // A 9-hole card has no second nine; the sentence must not claim one starts
        // at 5.5 or some other nonsense.
        XCTAssertTrue(CardReading.instructions(players: roster, holeCount: 9)
                        .contains("1 to 9"))
    }
}
