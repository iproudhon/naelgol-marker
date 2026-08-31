import XCTest
import SwiftUI
@testable import GolfCourse
@testable import GolfMap

final class DistanceDisplayTests: XCTestCase {

    /// The whole point of this type: storage stays metres and the unit is applied
    /// where a number becomes text. Yards by default, matching
    /// `DistanceUnit.assumedWhenUnstated` and the American courses this is aimed at.
    func testDefaultIsYardsAndConvertsFromMetres() {
        let d = DistanceDisplay.default
        XCTAssertEqual(d.unit, .yards)
        XCTAssertEqual(d.value(270), 295.27, accuracy: 0.01)
        XCTAssertEqual(d.number(270), "295")
        XCTAssertEqual(d.text(270), "295 YD")
    }

    func testMetresPassThroughUntouched() {
        let d = DistanceDisplay(unit: .metres)
        XCTAssertEqual(d.text(270), "270 M")
        XCTAssertEqual(d.value(270), 270)
    }

    /// Whole units only. A decimal implies a precision no GPS fix has — ±3–5 m is
    /// ±3–5 yd — and nobody clubs off a tenth of a yard.
    func testRoundsToWholeUnits() {
        XCTAssertEqual(DistanceDisplay(unit: .yards).number(100.6), "110")
        XCTAssertEqual(DistanceDisplay(unit: .metres).number(100.4), "100")
        XCTAssertEqual(DistanceDisplay(unit: .metres).number(100.5), "101")
    }

    /// A missing distance must read as missing, not as zero. A tee with no card
    /// number is the normal case, not an error.
    func testNilReadsAsMissingNotZero() {
        XCTAssertEqual(DistanceDisplay(unit: .yards).text(nil as Double?), "— YD")
        XCTAssertNotEqual(DistanceDisplay(unit: .yards).text(nil as Double?), "0 YD")
    }
}

final class TeePaletteTests: XCTestCase {

    private func tees(_ spec: [(String, Double)]) -> [TeeBox] {
        spec.map { TeeBox(name: $0.0, distance: $0.1) }
    }
    private func hex(_ c: Color) -> String {
        let (r, g, b) = TeePalette.components(c)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Rule 1 — a name that is a colour resolves to that colour, through casing and
    /// through the trailing word a card prints.
    func testColourNamesResolveDirectly() {
        let c = TeePalette.colors(for: tees([("BLACK", 400), ("Blue Tees", 370),
                                             ("white", 340), ("red", 300)]),
                                  greenCenter: nil)
        XCTAssertEqual(hex(c["BLACK"]!), hex(TeePalette.named["black"]!))
        XCTAssertEqual(hex(c["Blue Tees"]!), hex(TeePalette.named["blue"]!))
        XCTAssertEqual(hex(c["red"]!), hex(TeePalette.named["red"]!))
    }

    /// `yellow` is what OSM tags at Corica Park; `gold` is what the card prints.
    /// They are the same tee.
    func testYellowIsGold() {
        XCTAssertEqual(hex(TeePalette.directColor("yellow")!),
                       hex(TeePalette.directColor("gold")!))
    }

    /// Rule 2 — nothing is a colour, so the standard ramp is laid over the set,
    /// darkest at the back and red at the front.
    func testNoColourNamesGetTheStandardRamp() {
        let names = ["Championship", "Members", "Regular", "Senior", "Forward"]
        let c = TeePalette.colors(for: tees(names.enumerated().map { ($0.element, 420.0 - Double($0.offset) * 30) }),
                                  greenCenter: nil)
        XCTAssertEqual(c.count, names.count)
        XCTAssertEqual(hex(c["Championship"]!), hex(TeePalette.standard.first!.color),
                       "the longest tee must be black")
        XCTAssertEqual(hex(c["Forward"]!), hex(TeePalette.standard.last!.color),
                       "the shortest tee must be red")
        XCTAssertEqual(Set(names.map { hex(c[$0]!) }).count, names.count,
                       "two tees came out the same colour")
    }

    /// Rule 3 — a non-colour tee blends its neighbours, so it is distinct from both
    /// and reads as sitting between them in length.
    func testANonColourTeeBlendsItsNeighbours() {
        let c = TeePalette.colors(for: tees([("black", 420), ("blue", 390),
                                             ("Members", 360), ("white", 330), ("red", 290)]),
                                  greenCenter: nil)
        let m = c["Members"]!
        XCTAssertEqual(hex(m), hex(TeePalette.blend(TeePalette.named["blue"]!,
                                                    TeePalette.named["white"]!, 0.5)))
        XCTAssertNotEqual(hex(m), hex(TeePalette.named["blue"]!))
        XCTAssertNotEqual(hex(m), hex(TeePalette.named["white"]!))
    }

    /// Ordering is by *length*, not by the order the tees happen to sit in the file
    /// — a tee's colour is a statement about how far back it plays.
    func testOrderingIsByLengthNotFileOrder() {
        let c = TeePalette.colors(for: tees([("Short one", 300), ("Long one", 430)]),
                                  greenCenter: nil)
        XCTAssertEqual(hex(c["Long one"]!), hex(TeePalette.standard.first!.color))
        XCTAssertEqual(hex(c["Short one"]!), hex(TeePalette.standard.last!.color))
    }

    /// Measured geometry beats the card number, because geometry is what is being
    /// drawn and a card can be absent — which it always is straight out of OSM.
    func testMeasuredLengthWinsOverTheCard() {
        let green = Coordinate(lat: 37.4, lon: -122.2)
        let near = Geodesy.point(from: green, bearing: 180, distance: 200)
        let far = Geodesy.point(from: green, bearing: 180, distance: 400)
        // Card numbers deliberately contradict the geometry.
        let t = [TeeBox(name: "a", at: near, distance: 999),
                 TeeBox(name: "b", at: far, distance: 1)]
        let c = TeePalette.colors(for: t, greenCenter: green)
        XCTAssertEqual(hex(c["b"]!), hex(TeePalette.standard.first!.color),
                       "the geometrically longest tee must be the back one")
    }

    /// `white` on a light green and `black` in the rough both vanish without one.
    func testOutlineFlipsWithFillLuminance() {
        XCTAssertEqual(hex(TeePalette.outline(for: TeePalette.named["white"]!)),
                       hex(Color.black.opacity(0.65)))
        XCTAssertEqual(hex(TeePalette.outline(for: TeePalette.named["black"]!)),
                       hex(Color.white.opacity(0.8)))
    }

    /// A tee with neither a coordinate nor a card number has no place in the
    /// ordering and must not silently claim one — but it must still get a colour.
    func testATeeWithNoLengthStillGetsAColour() {
        let t = [TeeBox(name: "black", distance: 400),
                 TeeBox(name: "mystery"),
                 TeeBox(name: "red", distance: 300)]
        let c = TeePalette.colors(for: t, greenCenter: nil)
        XCTAssertEqual(c.count, 3)
        XCTAssertNotNil(c["mystery"])
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(TeePalette.colors(for: [], greenCenter: nil).isEmpty)
    }
}
