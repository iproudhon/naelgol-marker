import XCTest
@testable import GolfCourse
import GolfSessionFormat

final class CardLayoutTests: XCTestCase {

    private func hole(_ ref: String, nine: String? = nil, par: Int = 4,
                      tees: [TeeBox] = [], line: [Coordinate] = [],
                      green: Green = Green()) -> Hole {
        Hole(ref: ref, nine: nine, par: par, tees: tees, green: green, line: line)
    }

    private func course(_ holes: [Hole]) -> Course {
        Course(id: "c", name: "C", source: .card, holes: holes)
    }

    // MARK: - Columns

    func testAStraight18GetsOutAndIn() {
        let c = course((1...18).map { hole("\($0)") })
        let layout = CardLayout(course: c)
        XCTAssertEqual(layout.subtotals, ["Out", "In"])
        XCTAssertEqual(layout.columns.count, 18 + 2 + 1)
        XCTAssertEqual(layout.columns[9], .subtotal(name: "Out", holes: Array(1...9)))
        XCTAssertEqual(layout.columns.last, .total)
        XCTAssertEqual(layout.holeIndices, Array(1...18))
    }

    /// **Out/In assumes holes numbered 1–18, which `Hole.ref` is not.** A Korean 18
    /// is two of three named nines, each numbered 1–9 — printing OUT and IN over
    /// them labels the card with words it does not use, and the second nine's
    /// holes are all called 1–9 again so a ref cannot even address a column.
    func testNamedNinesBeatOutAndIn() {
        let front = (1...9).map { hole("\($0)", nine: "황룡") }
        let back = (1...9).map { hole("\($0)", nine: "청룡") }
        let layout = CardLayout(course: course(front + back))
        XCTAssertEqual(layout.subtotals, ["황룡", "청룡"])
        XCTAssertEqual(layout.columns[9], .subtotal(name: "황룡", holes: Array(1...9)))
        XCTAssertEqual(layout.columns[19], .subtotal(name: "청룡", holes: Array(10...18)))
        // Columns are playing-order indices, not refs — both nines have a "3".
        XCTAssertEqual(layout.holeIndices, Array(1...18))
    }

    /// Nine holes or fewer get no subtotal: a single "Out" beside an identical
    /// "Total" is two columns saying one thing.
    func testANineHoleCourseHasNoSubtotal() {
        let layout = CardLayout(course: course((1...9).map { hole("\($0)") }))
        XCTAssertEqual(layout.subtotals, [])
        XCTAssertEqual(layout.columns.count, 10)
        XCTAssertEqual(layout.columns.last, .total)
    }

    func testNoCourseIsNoColumns() {
        XCTAssertTrue(CardLayout(course: nil).columns.isEmpty)
    }

    // MARK: - Yardage

    /// The case that will actually be on screen: the only real course file that
    /// exists came from OSM, and **OSM never supplies yardage in any region.**
    /// A measured centre line is offered instead, and it must announce itself —
    /// it is a different quantity, not a substitute.
    func testAnOSMHoleYieldsAMeasuredLengthNotACardOne() {
        let tee = TeeBox(name: "Black", at: Coordinate(lat: 37.7000, lon: -122.2000))
        let green = Green(center: Coordinate(lat: 37.7036, lon: -122.2000))
        let h = hole("1", tees: [tee], green: green)
        let y = CardYardage.of(h, teeName: "Black")
        XCTAssertTrue(y.isApproximate)
        XCTAssertNotNil(y.metres)
        XCTAssertEqual(y.metres!, 400, accuracy: 20)
    }

    /// **No tee may answer with another tee's numbers.** A hole that has no White
    /// tee must not print Black's yardage under the White heading — the number
    /// would look perfectly ordinary and be a club and a half wrong.
    func testAMissingTeeNeverBorrowsAnotherTeesYardage() {
        let black = TeeBox(name: "Black", distance: 420)
        let h = hole("1", tees: [black])
        XCTAssertEqual(CardYardage.of(h, teeName: "Black"), .card(420))
        XCTAssertEqual(CardYardage.of(h, teeName: "White"), .none,
                       "printed a tee's distance under another tee's name")
    }

    func testACardTeeWins() {
        let tee = TeeBox(name: "Black", at: Coordinate(lat: 37.7000, lon: -122.2000),
                         distance: 429)
        let green = Green(center: Coordinate(lat: 37.7036, lon: -122.2000))
        let h = hole("1", tees: [tee], green: green)
        XCTAssertEqual(CardYardage.of(h, teeName: "Black"), .card(429))
    }

    func testACardOnlyHoleWithNoTeeHasNothingToShow() {
        XCTAssertEqual(CardYardage.of(hole("1"), teeName: nil), .none)
    }

    /// OSM tags `black`, an American card prints `BLACK`, the editor writes
    /// `Black`. Listing them separately would offer the same tee three times and
    /// let the picker choose a set covering a third of the holes.
    func testTeeNamesAreCaseInsensitiveAndLongestFirst() {
        let c = course([
            hole("1", tees: [TeeBox(name: "black", distance: 400),
                             TeeBox(name: "White", distance: 300)]),
            hole("2", tees: [TeeBox(name: "BLACK", distance: 400),
                             TeeBox(name: "white", distance: 300)]),
        ])
        XCTAssertEqual(c.teeNames.count, 2)
        XCTAssertEqual(c.teeNames.first?.lowercased(), "black")
    }
}

/// `nil` must mean **one** tee.
final class DefaultTeeTests: XCTestCase {

    /// The fault this exists to stop, found on real Corica geometry: `defaultTee`
    /// preferred a tee *named* white, `geometry(tee:)` independently preferred the
    /// first tee with *coordinates*, and hole 1 has black, blue and white all
    /// placed. So `cardLength(from: nil)` meant white and `geometry(tee: nil)`
    /// meant black, and `length(from: nil)` returned **black's 483 m under white's
    /// name** — 59 yards, four clubs.
    func testNilResolvesToTheSameTeeEverywhere() throws {
        let placed = { (name: String, lat: Double) in
            TeeBox(name: name, at: Coordinate(lat: lat, lon: -122.2))
        }
        let hole = Hole(ref: "1", par: 5,
                        tees: [placed("black", 37.7000),
                               placed("blue", 37.7002),
                               placed("white", 37.7005)],
                        green: Green(center: Coordinate(lat: 37.7043, lon: -122.2)))
        let viaDefault = try XCTUnwrap(hole.geometry(tee: hole.defaultTee)).measuredLength
        let viaNil = try XCTUnwrap(hole.geometry(tee: nil)).measuredLength
        XCTAssertEqual(hole.defaultTee.name, "white")
        XCTAssertEqual(viaNil, viaDefault, accuracy: 0.001,
                       "nil means a different tee here than defaultTee does")
    }

    /// Placed tees win the pool, so a course whose white tee has never been placed
    /// still draws a hole view rather than resolving `nil` to a coordinate-less tee
    /// and returning no geometry at all.
    func testAnUnplacedWhiteDoesNotCostTheHoleItsGeometry() {
        let hole = Hole(ref: "1", par: 4,
                        tees: [TeeBox(name: "white", distance: 350),
                               TeeBox(name: "black", at: Coordinate(lat: 37.70, lon: -122.2))],
                        green: Green(center: Coordinate(lat: 37.7036, lon: -122.2)))
        XCTAssertEqual(hole.defaultTee.name, "black")
        XCTAssertNotNil(hole.geometry(tee: nil))
    }

    /// A card-only course has no placed tees at all, so the pool is every tee and
    /// white still wins — the card's own default column.
    func testACardOnlyHoleStillPrefersWhite() {
        let hole = Hole(ref: "1", par: 4,
                        tees: [TeeBox(name: "black", distance: 420),
                               TeeBox(name: "white", distance: 350)])
        XCTAssertEqual(hole.defaultTee.name, "white")
        XCTAssertEqual(hole.cardLength(from: nil), 350)
    }
}
