import XCTest
import AVFoundation
import CoreGraphics
@testable import NaelvolCore

/// Tests that go through a real file, because the metadata codec's whole job is
/// what survives being written to one.
final class SwingFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("naelvol-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWriteThenReadOverARealFile() async throws {
        let url = dir.appendingPathComponent("swing-0001.mov")
        try await makeMovie(at: url, frames: 12)

        let context = SwingContext(courseID: "corica-park-south", courseName: "Corica Park South",
                                   hole: 7, playerID: "p-1", playerName: "steve", tags: ["driver"])
        try await SwingMetadata.write(SwingMeta(context: context), to: url)

        let probe = try await SwingMetadata.probe(url: url)
        XCTAssertEqual(probe.meta.context, context)
        XCTAssertFalse(probe.meta.isForeign)
        XCTAssertEqual(probe.duration ?? 0, 0.4, accuracy: 0.2)
        XCTAssertEqual(probe.dimensions?.width, 64)
        XCTAssertNotNil(probe.frameRate)
    }

    /// A metadata edit is a whole-file rewrite, so the dates it must not restamp
    /// are the ones the grid sorts on.
    func testWritePreservesCreationDate() async throws {
        let url = dir.appendingPathComponent("swing-0002.mov")
        try await makeMovie(at: url, frames: 6)
        let then = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.creationDate: then], ofItemAtPath: url.path)

        try await SwingMetadata.write(SwingMeta(context: SwingContext(hole: 3)), to: url)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        XCTAssertEqual(after?.timeIntervalSince1970 ?? 0, then.timeIntervalSince1970, accuracy: 1)
    }

    /// Writing twice must leave one payload, not two — a duplicate key means the
    /// reader picks one at random.
    func testWritingTwiceLeavesOnePayload() async throws {
        let url = dir.appendingPathComponent("swing-0003.mov")
        try await makeMovie(at: url, frames: 6)
        try await SwingMetadata.write(SwingMeta(context: SwingContext(hole: 1)), to: url)
        try await SwingMetadata.write(SwingMeta(context: SwingContext(hole: 2)), to: url)

        let items = try await AVURLAsset(url: url).load(.metadata)
        let payloads = items.filter { $0.identifier == SwingMetadata.payloadIdentifier }
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(SwingMetadata.parse(items).context.hole, 2)
    }

    @MainActor
    func testLibraryScansFiltersAndUpdates() async throws {
        let root = dir.appendingPathComponent("Swings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await makeMovie(at: root.appendingPathComponent("swing-0001.mov"), frames: 6)
        try await makeMovie(at: root.appendingPathComponent("swing-0002.mov"), frames: 6)
        // A file that is not a video, and a zero-byte one: neither may appear, and
        // the empty one is counted rather than rendered.
        try Data().write(to: root.appendingPathComponent("swing-0003.mov"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let defaults = UserDefaults(suiteName: "naelvol-test-\(UUID().uuidString)")!
        let library = SwingLibrary(appRoot: root, cacheDirectory: dir.appendingPathComponent("cache"),
                                   defaults: defaults)
        await library.scan()
        XCTAssertEqual(library.swings.count, 2)
        XCTAssertEqual(library.unreadable, 1)

        let first = try XCTUnwrap(library.swings.first { $0.relativePath == "swing-0001.mov" })
        try await library.update(first, context: SwingContext(courseID: "corica", hole: 7, tags: ["driver"]))

        library.filter = SwingFilter(courseID: "corica", hole: 7)
        XCTAssertEqual(library.visible.count, 1)
        library.filter = SwingFilter(courseID: "corica", hole: 8)
        XCTAssertEqual(library.visible.count, 0)

        // The next capture takes the next free number, skipping what is there.
        let next = try library.uniqueURL()
        XCTAssertEqual(next.lastPathComponent, "swing-0004.mov")

        library.filter = .none
        let doomed = try XCTUnwrap(library.swings.first { $0.relativePath == "swing-0002.mov" })
        try library.delete(doomed)
        XCTAssertEqual(library.swings.count, 1)
    }

    @MainActor
    func testSecondScanIsServedFromTheCacheAndInvalidatesOnEdit() async throws {
        let root = dir.appendingPathComponent("Swings2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("swing-0001.mov")
        try await makeMovie(at: url, frames: 6)

        let cacheDir = dir.appendingPathComponent("cache2")
        let defaults = UserDefaults(suiteName: "naelvol-test-\(UUID().uuidString)")!
        let library = SwingLibrary(appRoot: root, cacheDirectory: cacheDir, defaults: defaults)
        await library.scan()
        XCTAssertNotNil(library.swings.first?.thumbnailPath)

        let cache = SwingCache(directory: cacheDir)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let entry = SwingSourceResolver.Entry(url: url, relativePath: "swing-0001.mov",
                                              size: Int64(values.fileSize!),
                                              modified: values.contentModificationDate!, created: nil)
        XCTAssertNotNil(cache.swing(for: entry, sourceID: SwingSource.appSourceID))

        // Same path, different size and date — somebody else wrote to it, so the
        // cached row is not an answer.
        let moved = SwingSourceResolver.Entry(url: url, relativePath: "swing-0001.mov",
                                              size: entry.size + 1,
                                              modified: entry.modified.addingTimeInterval(60), created: nil)
        XCTAssertNil(cache.swing(for: moved, sourceID: SwingSource.appSourceID))
    }

    /// The N3 gate: **a trim must not throw the course and hole away.** There is
    /// no index to recover them from — the file is the record — so a clip that
    /// loses them is a clip nobody finds again.
    func testTrimKeepsTheRecordAndTheLocation() async throws {
        let url = dir.appendingPathComponent("swing-0010.mov")
        try await makeMovie(at: url, frames: 30)
        let context = SwingContext(courseID: "corica-park-south", courseName: "Corica Park South",
                                   hole: 7, playerName: "steve", tags: ["driver"])
        try await SwingMetadata.write(
            SwingMeta(context: context,
                      location: SwingLocation(latitude: 37.4056, longitude: -121.9481, altitude: 16)),
            to: url)

        let out = dir.appendingPathComponent("swing-0011.mov")
        try await SwingExport.trim(url, range: 0.2...0.8, to: out)

        let probe = try await SwingMetadata.probe(url: out)
        XCTAssertEqual(probe.meta.context, context)
        XCTAssertEqual(probe.meta.location?.latitude ?? 0, 37.4056, accuracy: 0.001)
        XCTAssertEqual(probe.duration ?? 0, 0.6, accuracy: 0.25)
        XCTAssertLessThan(probe.duration ?? 99, 1.0)
    }

    // MARK: - Fixture

    /// A real, tiny `.mov`. Written rather than checked in: a fixture video in git
    /// is a binary nobody can review, and this one is four lines of AVFoundation.
    func makeMovie(at url: URL, frames: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(20 + i * 10), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
