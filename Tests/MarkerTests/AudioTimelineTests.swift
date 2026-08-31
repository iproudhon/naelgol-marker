import XCTest
@testable import GolfSessionFormat

final class AudioTimelineTests: XCTestCase {
    private let start: Millis = 1_756_300_000_000

    private func segment(_ i: Int, at t0: Millis, length ms: Millis?) -> AudioSegment {
        AudioSegment(index: i, file: String(format: "audio-%03d.m4a", i),
                     t0: t0, t1: ms.map { t0 + $0 })
    }

    func testOffsetMapsOntoTheSegmentsOwnStart() {
        let s = segment(0, at: start, length: 60_000)
        XCTAssertEqual(AudioTimeline.sessionTime(0, in: s), start)
        XCTAssertEqual(AudioTimeline.sessionTime(12.5, in: s), start + 12_500)
    }

    /// **The bug this whole type exists to prevent.** A segment boundary is a real
    /// gap — the mic was shut for the length of an interruption — so the second
    /// segment's times come from *its own* `t0`, never from the first's length.
    func testSegmentGapIsPreservedNotAccumulated() {
        let first = segment(0, at: start, length: 5_320)
        // Five minutes of phone call between them.
        let second = segment(1, at: start + 305_320, length: 4_832)

        let a = AudioTimeline.window(from: 0, to: 3.3, in: first)
        let b = AudioTimeline.window(from: 0, to: 1.5, in: second)

        XCTAssertEqual(a.t0, start)
        XCTAssertEqual(b.t0, start + 305_320)
        XCTAssertEqual(b.t0 - a.t0, 305_320,
                       "cumulative offsets would have put this at 5,320 ms")
    }

    /// A decoder can report a range a few ms past the last sample; an utterance
    /// that ends after the recording did is a claim nothing supports.
    func testRangePastTheEndIsClampedWhenTheEndIsKnown() {
        let s = segment(0, at: start, length: 5_320)
        let w = AudioTimeline.window(from: 5.0, to: 9.9, in: s)
        XCTAssertEqual(w.t1, start + 5_320)
        XCTAssertEqual(w.t0, start + 5_000)
        XCTAssertLessThanOrEqual(w.t0, w.t1)
    }

    /// A segment with no end never closed — the crashed round. There is nothing to
    /// clamp against, and substituting "now" would invent recording that never
    /// happened, exactly as `SessionSummary.duration` refuses to.
    func testUnclosedSegmentIsNotClamped() {
        let s = segment(0, at: start, length: nil)
        let w = AudioTimeline.window(from: 0, to: 3_600, in: s)
        XCTAssertEqual(w.t1, start + 3_600_000)
        XCTAssertNil(AudioTimeline.duration(of: s))
    }

    func testWindowNeverInvertsOrPrecedesTheSegment() {
        let s = segment(0, at: start, length: 10_000)
        let w = AudioTimeline.window(from: 4, to: 1, in: s)   // end before start
        XCTAssertEqual(w.t0, start + 4_000)
        XCTAssertEqual(w.t1, start + 4_000)
    }

    func testDurationOfAClosedSegment() {
        XCTAssertEqual(AudioTimeline.duration(of: segment(0, at: start, length: 5_320))!,
                       5.32, accuracy: 0.0001)
    }
}

final class TranscriptCoverageTests: XCTestCase {
    /// A silent segment yields no utterances, so "did any utterance land here" is
    /// not a done-test — it would re-transcribe that segment on every pass forever.
    func testSilentSegmentIsStillRecordedAsCovered() {
        var c = TranscriptCoverage(transcriber: "apple", locales: ["en-US"])
        c.mark(0); c.mark(1, at: 5)
        XCTAssertTrue(c.covers(1))
        XCTAssertEqual(c.segments, [0, 1])
        XCTAssertEqual(c.updated, 5)
    }

    func testMarkIsIdempotentAndSorted() {
        var c = TranscriptCoverage(transcriber: "apple", locales: ["en-US"])
        c.mark(3); c.mark(1); c.mark(3)
        XCTAssertEqual(c.segments, [1, 3])
    }

    /// Phase 2 is a comparison between two transcribers. A cache that could not
    /// tell them apart would serve one path's output for the other's run and
    /// quietly invalidate the measurement.
    func testCacheDoesNotCrossTranscribersOrLocales() {
        let c = TranscriptCoverage(transcriber: "apple", locales: ["en-US"], segments: [0, 1])
        XCTAssertTrue(c.matches(transcriber: "apple", locales: ["en-US"]))
        XCTAssertFalse(c.matches(transcriber: "whisperkit", locales: ["en-US"]))
        XCTAssertFalse(c.matches(transcriber: "apple", locales: ["en-GB"]))
    }

    /// `en-US` and `en_US` name the same recognizer. Keying the cache on the
    /// spelling would miss and re-transcribe the whole round.
    func testLocaleSpellingAndOrderDoNotChangeTheKey() {
        let c = TranscriptCoverage(transcriber: "apple", locales: ["ko-KR", "en_US"])
        XCTAssertEqual(c.locales, ["en_US", "ko_KR"])
        XCTAssertTrue(c.matches(transcriber: "apple", locales: ["en-US", "ko-KR"]))
    }

    /// **The bilingual half-success.** A round asks for English and Korean and the
    /// device has only English. Recording the *request* would mark every segment
    /// done and the Korean half would never run again, on any later pass, with
    /// nothing to show it was missing.
    func testEnglishOnlyCoverageDoesNotSatisfyABilingualRun() {
        let c = TranscriptCoverage(transcriber: "apple", locales: ["en-US"], segments: [0])
        XCTAssertFalse(c.matches(transcriber: "apple", locales: ["en-US", "ko-KR"]))
        // And the reverse: a bilingual transcript holds Korean lines an
        // English-only run would not have produced, so it is not that run's cache.
        let both = TranscriptCoverage(transcriber: "apple", locales: ["en-US", "ko-KR"])
        XCTAssertFalse(both.matches(transcriber: "apple", locales: ["en-US"]))
    }

    /// A coverage file written before the round was bilingual carries a single
    /// `locale` string. It stays usable for a single-locale run.
    func testCoverageWrittenBeforeMultiLocaleStillDecodes() throws {
        let json = #"{"transcriber":"apple","locale":"en-US","segments":[0,2],"updated":7}"#
        let c = try JSONDecoder().decode(TranscriptCoverage.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(c.locales, ["en_US"])
        XCTAssertEqual(c.segments, [0, 2])
        XCTAssertTrue(c.matches(transcriber: "apple", locales: ["en-US"]))
    }

    func testCoverageRoundTripsThroughTheSessionFolder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cov-\(UUID().uuidString)")
        let folder = SessionFolder(url: dir)
        try folder.create()
        defer { try? FileManager.default.removeItem(at: dir) }

        var c = TranscriptCoverage(transcriber: "apple", locales: ["en-US"])
        c.mark(0, at: 42)
        try folder.writeJSON(c, to: .transcriptCoverage)
        XCTAssertEqual(try folder.readJSON(.transcriptCoverage, as: TranscriptCoverage.self), c)
        XCTAssertFalse(SessionFolder.File.transcriptCoverage.isGroundTruth)
    }
}


/// The live analyzer counts delivered samples, not elapsed time. Those are the same
/// number only while buffers keep arriving — and when they stop, the divergence is
/// invisible downstream.
final class LiveAudioClockTests: XCTestCase {
    /// 4,800 frames at 48 kHz is 100 ms.
    private func feed(_ clock: inout LiveAudioClock, buffers: Int, from t0: Millis) {
        for i in 0..<buffers {
            clock.accept(frames: 4_800, at: t0 + Millis(i) * 100)
        }
    }

    func testContinuousDeliveryNeedsNoCorrection() {
        var clock = LiveAudioClock(sampleRate: 48_000)
        feed(&clock, buffers: 10, from: 1_000_000)
        XCTAssertEqual(clock.anchor, 1_000_000)
        XCTAssertEqual(clock.deliveredMillis, 1_000)
        // A word the analyzer places half a second in is half a second after the
        // first buffer.
        XCTAssertEqual(clock.sessionTime(analyzerOffset: 0.5), 1_000_500)
    }

    /// **The interruption case, and the reason this type exists.** A four-minute
    /// phone call stops delivery; the analyzer's clock does not advance across it.
    /// Without the correction every word after the call lands four minutes early,
    /// and nothing downstream can tell.
    func testAGapInDeliveryMovesTheAnchorRatherThanCompressingTheRound() {
        var clock = LiveAudioClock(sampleRate: 48_000)
        feed(&clock, buffers: 10, from: 1_000_000)          // 1 s of audio
        let call: Millis = 240_000                          // four minutes off air
        feed(&clock, buffers: 10, from: 1_001_000 + call)   // 1 s more

        XCTAssertEqual(clock.deliveredMillis, 2_000, "only two seconds were ever heard")
        // The analyzer places a word 1.5 s into its input — i.e. half a second after
        // the call ended, which on the session clock is 1,001,000 + 240,000 + 500.
        XCTAssertEqual(clock.sessionTime(analyzerOffset: 1.5), 1_241_500)
    }

    /// Ordinary scheduling jitter is not a gap. Correcting for it would walk the
    /// anchor forward a few milliseconds per buffer — twelve times a second, for
    /// four and a half hours.
    func testJitterBelowToleranceDoesNotMoveTheAnchor() {
        var clock = LiveAudioClock(sampleRate: 48_000)
        var t: Millis = 500_000
        for i in 0..<50 {
            clock.accept(frames: 4_800, at: t)
            t += 100 + Millis(i % 3)      // 0–2 ms late, every buffer
        }
        XCTAssertEqual(clock.anchor, 500_000, "jitter was mistaken for a gap")
    }

    func testNothingMapsBeforeTheFirstBuffer() {
        let clock = LiveAudioClock(sampleRate: 48_000)
        XCTAssertNil(clock.anchor)
        XCTAssertNil(clock.sessionTime(analyzerOffset: 0))
    }
}
