import XCTest
import GolfSessionFormat
@testable import GolfCaptureCore

/// Audio is segmented so that a call or Siri mid-round cannot silently shift
/// every later sample behind a whole-file offset. These pin the index format
/// and the stop/restart path that produces it, without needing a real
/// interruption or a microphone.
final class AudioSegmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSegmentFileNamesAreZeroPaddedAndOrder() {
        XCTAssertEqual(SessionFolder.audioFileName(index: 0), "audio-000.m4a")
        XCTAssertEqual(SessionFolder.audioFileName(index: 7), "audio-007.m4a")
        XCTAssertEqual(SessionFolder.audioFileName(index: 123), "audio-123.m4a")
        // Zero-padding so a directory listing sorts the way the round played.
        XCTAssertLessThan(SessionFolder.audioFileName(index: 9),
                          SessionFolder.audioFileName(index: 10))
    }

    /// The index is what makes segments usable: each row must say which file
    /// covers which span, so a transcript offset can be computed per segment.
    func testSegmentIndexRoundTripsAndCoversTheGaps() throws {
        let folder = SessionFolder(url: root.appendingPathComponent("session-x"))
        try folder.create()
        let w = try folder.writer(.audio)
        try w.append(AudioSegment(index: 0, file: SessionFolder.audioFileName(index: 0),
                                  t0: 1_000, t1: 5_000, endReason: "interruption"))
        try w.append(AudioSegment(index: 1, file: SessionFolder.audioFileName(index: 1),
                                  t0: 9_000, t1: 12_000, endReason: "stop"))
        try w.close()

        let segments = folder.readAll(.audio, as: AudioSegment.self)
        XCTAssertEqual(segments.map(\.index), [0, 1])
        XCTAssertEqual(segments[0].endReason, "interruption")
        XCTAssertEqual(segments[1].file, "audio-001.m4a")

        // The 4-second hole between them is explicit, not hidden — which is the
        // whole reason for segmenting rather than concatenating.
        let gap = segments[1].t0 - (segments[0].t1 ?? 0)
        XCTAssertEqual(gap, 4_000)

        let recorded = segments.compactMap { s in s.t1.map { $0 - s.t0 } }.reduce(0, +)
        let wall = segments.last!.t1! - segments.first!.t0
        XCTAssertEqual(wall, 11_000)
        XCTAssertEqual(recorded, 7_000, "recorded audio is shorter than wall clock by the gap")
    }

    func testAudioPathResolvesInsideTheSessionFolder() {
        let folder = SessionFolder(url: root.appendingPathComponent("session-y"))
        XCTAssertEqual(folder.audioPath(index: 2).lastPathComponent, "audio-002.m4a")
        XCTAssertEqual(folder.audioPath(index: 2).deletingLastPathComponent().standardizedFileURL.path,
                       folder.url.standardizedFileURL.path)
    }

    /// The recorder must refuse rather than block: an unauthorized
    /// AVAudioRecorder.record() hangs on the TCC prompt, which on a tee box
    /// looks like a frozen app.
    func testStartWithoutPermissionThrowsRatherThanHanging() throws {
        guard AudioRecorder.permission != .granted else {
            throw XCTSkip("microphone already authorized in this process")
        }
        let folder = SessionFolder(url: root.appendingPathComponent("session-z"))
        let recorder = AudioRecorder(folder: folder)
        XCTAssertThrowsError(try recorder.start()) { error in
            guard case AudioRecorderError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testDescribedFormatRecordsWhatTheMacWillDecode() {
        var config = AudioRecorder.Config()
        config.sampleRate = 16_000
        config.channels = 1
        config.bitRate = 32_000
        XCTAssertEqual(config.describedFormat, "m4a-aac-16k-mono-32kbps")
    }
}
