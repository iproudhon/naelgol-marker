import XCTest
@testable import GolfCourseOSM

/// The search and transport half of the OSM import — everything that can be checked
/// without a network. Written on 2026-08-30 against the reported failure: *"search is
/// failing: I was looking for Coyote Creek Tournament Course in Morgan Hill, CA"*.
final class CourseOSMClientTests: XCTestCase {

    // MARK: - What the golfer typed

    /// Free-form `q` returned **nothing at all** for both of these, because the
    /// parser has to guess which words are the name and which are the place and it
    /// guesses wrong on a course name ending in a common noun. Structured search
    /// does not guess.
    func testAPlaceIsSplitOffFromTheCourseName() {
        let a = Nominatim.Query("Coyote Creek Tournament Course in Morgan Hill, CA")
        XCTAssertEqual(a.name, "Coyote Creek Tournament Course")
        XCTAssertEqual(a.city, "Morgan Hill")
        XCTAssertEqual(a.state, "CA")

        let b = Nominatim.Query("Coyote Creek Tournament Course, Morgan Hill, CA")
        XCTAssertEqual(b.name, "Coyote Creek Tournament Course")
        XCTAssertEqual(b.city, "Morgan Hill")
        XCTAssertEqual(b.state, "CA")
    }

    /// Most searches are a bare name and must stay one — putting "Corica Park" in a
    /// `city` slot finds a town.
    func testABareNameStaysABareName() {
        let q = Nominatim.Query("  Corica Park  ")
        XCTAssertEqual(q.name, "Corica Park")
        XCTAssertNil(q.city)
        XCTAssertNil(q.state)
        XCTAssertEqual(q.place, "")
    }

    /// The "in" split wins over the comma split, because a course name can contain a
    /// comma and the word is the stronger signal.
    func testTheWordInWinsOverACommaAndIsMatchedWholeWordOnly() {
        XCTAssertEqual(Nominatim.Query("Pebble Beach in Monterey").city, "Monterey")
        // "Links" contains "in"; a substring match would cut the name in half.
        XCTAssertEqual(Nominatim.Query("Bandon Dunes Links").name, "Bandon Dunes Links")
    }

    // MARK: - Overpass transport

    /// A 504 is two different faults wearing one status code and the advice for them
    /// is opposite. **Measured 2026-08-30:** four of seven identical requests for one
    /// 1.4 km box came back 504 with the dispatcher body, and a plain retry worked —
    /// so telling the golfer to narrow the area was advice for a fault they did not
    /// have, about a box that was already small.
    func testABusyDispatcherIsNotAQueryThatIsTooBig() {
        let busy = CourseOSM.classify(
            "Error: runtime error: open64: 0 Success /osm3s_osm_base "
            + "Dispatcher_Client::request_read_and_idx::timeout. The server is "
            + "probably too busy to handle your request.")
        XCTAssertEqual(busy, .overpassBusy)
        XCTAssertTrue(busy.isTransient)
        XCTAssertFalse("\(busy)".contains("Narrow"))

        let big = CourseOSM.classify("Error: runtime error: Query timed out in \"recurse\"")
        XCTAssertEqual(big, .overpassTimeout)
        XCTAssertFalse(big.isTransient)
        XCTAssertTrue("\(big)".contains("Narrow"))
    }

    /// Only a fault that goes away on its own is worth sending again.
    func testOnlyTransientFailuresAreRetried() {
        XCTAssertTrue(CourseOSM.Failure.rateLimited.isTransient)
        XCTAssertFalse(CourseOSM.Failure.http(500, "").isTransient)
        XCTAssertFalse(CourseOSM.Failure.noSite("x").isTransient)
        XCTAssertGreaterThan(CourseOSM.attempts, 1)
    }

    /// `out tags geom` is a print mode in which a relation arrives with **no members
    /// at all** — measured, 28 relations and zero members between them — so every
    /// multipolygon was unreadable whatever the parser did.
    func testTheFeatureQueryAsksForGeometryAndNotJustTags() {
        let q = CourseOSM.featuresQuery((s: 0, w: 0, n: 1, e: 1))
        XCTAssertTrue(q.contains("out geom;"))
        XCTAssertFalse(q.contains("out tags geom;"))
    }
}
