import XCTest
@testable import GolfSessionFormat

/// Resolving a log's `[t, tEnd]` back onto the files that hold it — the gate on
/// re-transcribing one entry with a bigger model.
final class AudioSpanTests: XCTestCase {

    /// Two segments with a **five-minute gap** between them: the microphone was
    /// shut for a phone call. Same fixture shape as `AudioTimelineTests`, because
    /// it is the same trap seen from the other side.
    private let first = AudioSegment(index: 0, file: "audio-000.m4a",
                                     t0: 1_000_000, t1: 1_600_000)      // 600 s
    private let second = AudioSegment(index: 1, file: "audio-001.m4a",
                                      t0: 1_900_000, t1: 2_200_000)     // 300 s

    func testASpanInsideOneSegmentIsOffsetFromThatSegmentsOwnStart() {
        let spans = AudioSpans.resolve(from: 1_010_000, to: 1_025_000, in: [first, second])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].segment.file, "audio-000.m4a")
        XCTAssertEqual(spans[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(spans[0].end, 25, accuracy: 0.001)
    }

    /// The whole reason this returns a list. A burst rotated by the stall watchdog
    /// or closed by an interruption spans two files, and the audio between them
    /// **does not exist**.
    func testABurstCrossingASegmentBoundaryComesBackAsTwoPieces() {
        let spans = AudioSpans.resolve(from: 1_590_000, to: 1_910_000, in: [first, second])
        XCTAssertEqual(spans.map(\.segment.file), ["audio-000.m4a", "audio-001.m4a"])
        XCTAssertEqual(spans[0].start, 590, accuracy: 0.001)
        XCTAssertEqual(spans[0].end, 600, accuracy: 0.001)   // clamped to the file
        XCTAssertEqual(spans[1].start, 0, accuracy: 0.001)
        XCTAssertEqual(spans[1].end, 10, accuracy: 0.001)
    }

    /// The bug this shape exists to make impossible: 320 s of wall clock holding
    /// 20 s of sound. A caller that concatenated the samples would hand the
    /// decoder a join that never happened.
    func testRecordedTimeIsNotWallClockTimeAcrossAGap() {
        let recorded = AudioSpans.recordedSeconds(from: 1_590_000, to: 1_910_000,
                                                  in: [first, second])
        XCTAssertEqual(recorded, 20, accuracy: 0.001)
    }

    /// An `.m4a` still being written cannot be opened at all — measured
    /// 2026-08-27. A log spoken into the burst that is still running therefore has
    /// nothing readable behind it yet, which is a real answer, not a failure.
    func testASegmentThatNeverClosedIsSkipped() {
        let open = AudioSegment(index: 2, file: "audio-002.m4a", t0: 2_300_000, t1: nil)
        XCTAssertTrue(AudioSpans.resolve(from: 2_310_000, to: 2_320_000,
                                         in: [first, second, open]).isEmpty)
    }

    func testAWindowTouchingNoRecordedAudioResolvesToNothing() {
        XCTAssertTrue(AudioSpans.resolve(from: 1_700_000, to: 1_800_000,
                                         in: [first, second]).isEmpty)
    }

    /// Zero-length overlaps are dropped rather than returned as empty spans — a
    /// span of no audio is a decode pass over nothing, which is precisely what
    /// makes Whisper fabricate.
    func testAnInstantaneousTouchIsNotASpan() {
        XCTAssertTrue(AudioSpans.resolve(from: 1_600_000, to: 1_600_000,
                                         in: [first, second]).isEmpty)
    }

    func testSpansComeBackInRecordingOrderWhateverOrderTheIndexIsRead() {
        let spans = AudioSpans.resolve(from: 1_000_000, to: 2_200_000, in: [second, first])
        XCTAssertEqual(spans.map(\.segment.index), [0, 1])
    }
}
