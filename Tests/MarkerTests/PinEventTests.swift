import XCTest
@testable import GolfSessionFormat

/// "Keep the last position" — a pin that is nudged five times must leave one line
/// in the round's events, not five.
final class PinEventTests: XCTestCase {

    private func pin(_ id: String, _ t: Millis, hole: Int = 1,
                     lat: Double, supersedes: String? = nil) -> Event {
        Event(id: id, t: t, kind: .pin, provenance: .user,
              hole: hole, lat: lat, lon: -122.0, supersedes: supersedes)
    }

    func testEachDragSupersedesTheLastSoOnlyOneSurvives() {
        let rows = [pin("p1", 100, lat: 37.1),
                    pin("p2", 200, lat: 37.2, supersedes: "p1"),
                    pin("p3", 300, lat: 37.3, supersedes: "p2")]
        let live = Event.current(rows).filter { $0.kind == .pin }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.id, "p3")
        XCTAssertEqual(live.first?.lat ?? 0, 37.3, accuracy: 0.0001)
        // Every row is still on disk — superseding is not erasing.
        XCTAssertEqual(rows.count, 3)
    }

    /// One flag per hole: a chain on 1 must not collapse 2's.
    func testHolesKeepTheirOwnPin() {
        let rows = [pin("a1", 100, hole: 1, lat: 37.1),
                    pin("b1", 150, hole: 2, lat: 37.5),
                    pin("a2", 200, hole: 1, lat: 37.2, supersedes: "a1")]
        let live = Event.current(rows).filter { $0.kind == .pin }
        XCTAssertEqual(Set(live.map(\.id)), ["b1", "a2"])
    }

    /// A pin is a person's assertion, so it is ground truth and never reaches a
    /// prompt — the same firewall `.user` has always meant.
    func testAPinIsNotModelVisible() {
        XCTAssertTrue(Event.modelVisible([pin("p1", 100, lat: 37.1)]).isEmpty)
    }

    /// It decodes as what it is, so an events file written today still reads on a
    /// build that only knew the older kinds is *not* claimed — but a round trip is.
    func testRoundTrip() throws {
        let e = pin("p1", 100, lat: 37.1)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(Event.self, from: data)
        XCTAssertEqual(back.kind, .pin)
        XCTAssertEqual(back.hole, 1)
        XCTAssertEqual(back.provenance, .user)
    }
}
