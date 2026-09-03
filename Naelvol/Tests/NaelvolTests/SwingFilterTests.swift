import XCTest
@testable import NaelvolCore

final class SwingFilterTests: XCTestCase {
    private func swing(_ context: SwingContext, source: String = "s", name: String = "swing-0001.mov") -> Swing {
        Swing(sourceID: source, url: URL(fileURLWithPath: "/tmp/\(name)"), relativePath: name,
              fileSize: 1, modified: Date(), meta: SwingMeta(context: context))
    }

    func testCourseAndHoleAreIndependent() {
        let s = swing(SwingContext(courseID: "corica", hole: 7))
        XCTAssertTrue(SwingFilter(courseID: "corica").matches(s))
        XCTAssertTrue(SwingFilter(courseID: "corica", hole: 7).matches(s))
        XCTAssertFalse(SwingFilter(courseID: "corica", hole: 8).matches(s))
        XCTAssertFalse(SwingFilter(courseID: "coyote").matches(s))
    }

    /// The hole view seeds course *and* hole; the scorecard seeds course only.
    func testSeedingFromContext() {
        let context = SwingContext(courseID: "corica", hole: 7)
        XCTAssertEqual(SwingFilter.from(context, includeHole: true).hole, 7)
        XCTAssertNil(SwingFilter.from(context, includeHole: false).hole)
        XCTAssertEqual(SwingFilter.from(context, includeHole: false).courseID, "corica")
    }

    func testEmptyFilterMatchesEverything() {
        XCTAssertTrue(SwingFilter.none.matches(swing(SwingContext())))
        XCTAssertTrue(SwingFilter.none.isEmpty)
    }

    func testTagsMatchAsSubstringsAndAllMustMatch() {
        let s = swing(SwingContext(tags: ["Driver", "fade"]))
        XCTAssertTrue(SwingFilter(tags: ["dri"]).matches(s))
        XCTAssertTrue(SwingFilter(tags: ["driver", "fade"]).matches(s))
        XCTAssertFalse(SwingFilter(tags: ["driver", "hook"]).matches(s))
    }

    func testTextSearchesCaptionAndFileName() {
        let s = swing(SwingContext(courseName: "Corica Park South", playerName: "steve"), name: "wedge-01.mov")
        XCTAssertTrue(SwingFilter(text: "corica").matches(s))
        XCTAssertTrue(SwingFilter(text: "wedge").matches(s))
        XCTAssertFalse(SwingFilter(text: "coyote").matches(s))
    }

    func testSourceFilter() {
        let s = swing(SwingContext(), source: "vipl")
        XCTAssertTrue(SwingFilter(sourceIDs: ["vipl"]).matches(s))
        XCTAssertFalse(SwingFilter(sourceIDs: [SwingSource.appSourceID]).matches(s))
    }

    func testSortUsesCreationDateNotModification() {
        let old = Swing(sourceID: "s", url: URL(fileURLWithPath: "/tmp/a.mov"), relativePath: "a.mov",
                        fileSize: 1, modified: Date(), created: Date(timeIntervalSince1970: 1000))
        let new = Swing(sourceID: "s", url: URL(fileURLWithPath: "/tmp/b.mov"), relativePath: "b.mov",
                        fileSize: 1, modified: Date(timeIntervalSince1970: 0), created: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(SwingSort.newest.sorted([old, new]).first?.name, "b")
    }
}
