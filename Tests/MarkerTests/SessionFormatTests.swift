import XCTest
@testable import GolfSessionFormat

final class SessionFormatTests: XCTestCase {
    func testSessionFileNames() {
        XCTAssertEqual(SessionFolder.File.gps.rawValue, "gps.jsonl")
    }
    // TODO(phase-1): round-trip every Codable type; assert one clock across streams.
}
