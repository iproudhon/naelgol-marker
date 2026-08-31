import XCTest
@testable import GolfCourse
@testable import GolfSessionFormat

final class HandicapTests: XCTestCase {

    /// Eighteen holes whose stroke index is the *reverse* of playing order, so any
    /// implementation that allocates by position instead of by difficulty is
    /// visibly wrong rather than accidentally right.
    private func reversedIndexCourse(_ n: Int = 18) -> [Hole] {
        (1...n).map { i in
            Hole(ref: "\(i)", par: 4, handicap: n - i + 1)
        }
    }

    // MARK: - Course handicap

    func testCourseHandicapUsesSlopeAndTheRatingMinusParTerm() {
        // 14.2 × 128/113 = 16.085, + (71.2 − 72) = 15.285 → 15.
        // The 0.8 the rating term takes off is what a slope-only formula misses.
        XCTAssertEqual(Handicap.course(index: 14.2, rating: 71.2, slope: 128, par: 72), 15)
    }

    /// The whole reason `rating` is frozen in the journal: it moves the answer.
    func testTheRatingTermIsNotDecorative() {
        let withRating = Handicap.course(index: 14.2, rating: 74.5, slope: 128, par: 72)
        let without = Handicap.course(index: 14.2, rating: 72.0, slope: 128, par: 72)
        XCTAssertNotEqual(withRating, without)
    }

    /// Most course files here have no rating and no slope — OSM never supplies
    /// them and only an American card prints them. An invented number would be an
    /// ordinary-looking answer several shots wrong.
    func testAMissingRatingOrSlopeYieldsNoHandicapRatherThanAGuess() {
        XCTAssertNil(Handicap.course(index: 14.2, rating: nil, slope: 128, par: 72))
        XCTAssertNil(Handicap.course(index: 14.2, rating: 71.2, slope: nil, par: 72))
        XCTAssertNil(Handicap.course(index: nil, rating: 71.2, slope: 128, par: 72))
        XCTAssertNil(Handicap.course(index: 14.2, rating: 71.2, slope: 128, par: nil))
        XCTAssertNil(Handicap.course(index: 14.2, rating: 71.2, slope: 0, par: 72))
    }

    func testItReadsAFrozenPlayerTee() {
        let tee = PlayerTee(name: "white", rating: 71.2, slope: 128, par: 72)
        XCTAssertEqual(Handicap.course(index: 14.2, tee: tee), 15)
        XCTAssertNil(Handicap.course(index: 14.2, tee: PlayerTee(name: "white")))
    }

    // MARK: - Strokes received

    func testStrokesGoToTheHardestHolesNotTheFirstOnes() {
        let got = Handicap.strokesReceived(courseHandicap: 3, holes: reversedIndexCourse())
        // Stroke index 1, 2, 3 are holes 18, 17, 16 in playing order.
        XCTAssertEqual(got, [18: 1, 17: 1, 16: 1])
        XCTAssertNil(got[1], "hole 1 is the easiest here and must receive nothing")
    }

    func testAHandicapAboveTheHoleCountWraps() {
        let got = Handicap.strokesReceived(courseHandicap: 22, holes: reversedIndexCourse())
        XCTAssertEqual(got.count, 18)
        XCTAssertEqual(got.values.reduce(0, +), 22)
        // Every hole one, the four hardest a second.
        XCTAssertEqual(got[18], 2)
        XCTAssertEqual(got[15], 2)
        XCTAssertEqual(got[14], 1)
    }

    func testAPlusHandicapTakesStrokesBackFromTheEasiestHoles() {
        let got = Handicap.strokesReceived(courseHandicap: -2, holes: reversedIndexCourse())
        // Easiest holes here are 1 and 2 (stroke index 18 and 17).
        XCTAssertEqual(got, [1: -1, 2: -1])
    }

    func testScratchReceivesNothingAtAll() {
        XCTAssertTrue(Handicap.strokesReceived(courseHandicap: 0,
                                               holes: reversedIndexCourse()).isEmpty)
    }

    /// `Hole.ref` is not a key: a Korean 27 has three holes numbered "3". Keying
    /// allocation off `ref` silently piles two holes' strokes onto one column.
    func testAllocationIsByPlayingOrderNotByHoleRef() {
        let holes = [
            Hole(ref: "1", nine: "황룡", par: 4, handicap: 5),
            Hole(ref: "2", nine: "황룡", par: 4, handicap: 3),
            Hole(ref: "1", nine: "청룡", par: 4, handicap: 1),
            Hole(ref: "2", nine: "청룡", par: 4, handicap: 2),
        ]
        let got = Handicap.strokesReceived(courseHandicap: 2, holes: holes)
        XCTAssertEqual(got, [3: 1, 4: 1],
                       "the two hardest are the third and fourth holes played")
    }

    /// Both stroke-index rows on an American card are valid 1…18 permutations and
    /// nothing downstream can tell which column it was handed.
    func testTheWomensRowIsADifferentAllocation() {
        let holes = [
            Hole(ref: "1", par: 4, handicap: 1, handicapWomen: 3),
            Hole(ref: "2", par: 4, handicap: 2, handicapWomen: 2),
            Hole(ref: "3", par: 4, handicap: 3, handicapWomen: 1),
        ]
        XCTAssertEqual(Handicap.strokesReceived(courseHandicap: 1, holes: holes), [1: 1])
        XCTAssertEqual(Handicap.strokesReceived(courseHandicap: 1, holes: holes,
                                                women: true), [3: 1])
    }

    /// A hole with no stroke index sorts last and is allocated last. Dropping it
    /// would lose the strokes it should have carried.
    func testHolesWithNoStrokeIndexStillReceiveOnALargeHandicap() {
        let holes = [
            Hole(ref: "1", par: 4, handicap: 1),
            Hole(ref: "2", par: 4),
            Hole(ref: "3", par: 4, handicap: 2),
        ]
        let got = Handicap.strokesReceived(courseHandicap: 3, holes: holes)
        XCTAssertEqual(got.values.reduce(0, +), 3)
        XCTAssertEqual(got[2], 1)
    }

    func testNoHolesIsEmptyRatherThanACrash() {
        XCTAssertTrue(Handicap.strokesReceived(courseHandicap: 9, holes: []).isEmpty)
    }

    func testNetIsGrossMinusWhatWasReceived() {
        XCTAssertEqual(Handicap.net(gross: 6, received: 1), 5)
    }
}
