import XCTest
import AVFoundation
@testable import NaelvolCore

final class SwingMetaTests: XCTestCase {
    func testPayloadRoundTripsThroughItems() throws {
        let context = SwingContext(courseID: "corica-park-south", courseName: "Corica Park South",
                                   hole: 7, holeRef: "황룡/3", playerID: "p-3", playerName: "steve",
                                   roundID: "session-2026-08-31-0912", tags: ["driver", "fade"],
                                   note: "too steep")
        let meta = SwingMeta(context: context,
                             location: SwingLocation(latitude: 37.4056, longitude: -121.9481, altitude: 16))
        let items = SwingMetadata.items(for: meta)
        let read = SwingMetadata.parse(items)
        XCTAssertEqual(read.context, context)
        XCTAssertFalse(read.isForeign)
        XCTAssertEqual(read.location?.latitude ?? 0, 37.4056, accuracy: 0.0001)
        XCTAssertEqual(read.location?.longitude ?? 0, -121.9481, accuracy: 0.0001)
    }

    /// A file written by vipl carries free text in the description key and nothing
    /// else. It must read as tags, not as an error and not as an empty swing.
    func testViplDescriptionParsesAsForeign() {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyDescription as NSString
        item.value = "driver, fade slice" as NSString
        let meta = SwingMetadata.parse([item])
        XCTAssertTrue(meta.isForeign)
        XCTAssertEqual(meta.context.tags, ["driver", "fade", "slice"])
        XCTAssertEqual(meta.context.note, "driver, fade slice")
        XCTAssertNil(meta.context.courseID)
    }

    /// Both keys present: naelvol's payload is the record, the description is a
    /// rendering of it that either app may have edited.
    func testPayloadWinsOverDescription() {
        var items = SwingMetadata.items(for: SwingMeta(context: SwingContext(courseID: "c", hole: 4)))
        let stale = AVMutableMetadataItem()
        stale.keySpace = .quickTimeMetadata
        stale.key = AVMetadataKey.quickTimeMetadataKeyDescription as NSString
        stale.value = "somebody typed this" as NSString
        items.append(stale)
        let meta = SwingMetadata.parse(items)
        XCTAssertEqual(meta.context.courseID, "c")
        XCTAssertEqual(meta.context.hole, 4)
        XCTAssertFalse(meta.isForeign)
    }

    func testCaptionIsASentenceNotJSON() {
        let context = SwingContext(courseName: "Corica Park South", hole: 7, playerName: "steve",
                                   tags: ["driver"])
        XCTAssertEqual(context.caption, "Corica Park South · 7 · steve · driver")
        // A course whose holes are named uses the name, never the index.
        var named = context
        named.holeRef = "황룡/3"
        XCTAssertEqual(named.caption, "Corica Park South · 황룡/3 · steve · driver")
    }

    func testISO6709RoundTrip() {
        let l = SwingLocation(latitude: -33.8688, longitude: 151.2093, altitude: 58)
        let parsed = SwingMetadata.parseISO6709(SwingMetadata.iso6709(l))
        XCTAssertEqual(parsed?.latitude ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(parsed?.longitude ?? 0, 151.2093, accuracy: 0.0001)
        XCTAssertEqual(parsed?.altitude ?? 0, 58, accuracy: 1)
    }

    func testUnversionedPayloadDecodes() throws {
        // An added key is invisible to an older reader; a payload with no version
        // at all is still a payload and must not be thrown away.
        let json = #"{"context":{"tags":[],"hole":3}}"#
        let meta = try JSONDecoder().decode(SwingMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.context.hole, 3)
        XCTAssertEqual(meta.version, SwingMeta.currentVersion)
    }
}
