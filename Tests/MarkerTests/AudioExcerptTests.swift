import XCTest
import AVFoundation
@testable import GolfTranscription
@testable import GolfSessionFormat

/// Reading part of a recorded segment back as decoder input.
///
/// Written against a real file rather than a mock, because everything that can go
/// wrong here is in `AVFoundation`: the seek, the rate conversion, and the throw
/// at end of file that is not an error.
final class AudioExcerptTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A tone in the middle and silence either side, so a wrongly-seeked excerpt
    /// is visible as energy in the wrong place rather than as a plausible array.
    @discardableResult
    private func writeTone(seconds: Double, toneFrom: Double, toneTo: Double,
                           rate: Double = 44_100, named name: String = "audio-000.caf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: rate, channels: 1,
                                                 interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total))
        buffer.frameLength = total
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(total) {
            let t = Double(i) / rate
            channel[i] = (t >= toneFrom && t < toneTo)
                ? Float(0.5 * sin(2 * .pi * 440 * t)) : 0
        }
        try file.write(from: buffer)
        return url
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    func testAnExcerptIsResampledToWhispersOwnRate() throws {
        let url = try writeTone(seconds: 5, toneFrom: 0, toneTo: 5)
        let samples = try AudioExcerpt.samples(of: url, from: 1, to: 3)
        // Two seconds at 16 kHz. The converter primes its resampler, so a handful
        // of frames either way is expected; a wrong *rate* would be off by 2.75×.
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
    }

    /// The seek. A range that starts inside the silence and ends inside the tone
    /// must come back quiet-then-loud, in that order.
    func testTheExcerptComesFromWhereItWasAskedFor() throws {
        let url = try writeTone(seconds: 6, toneFrom: 3, toneTo: 6)
        let samples = try AudioExcerpt.samples(of: url, from: 2, to: 4)
        XCTAssertGreaterThan(samples.count, 30_000)
        let half = samples.count / 2
        XCTAssertLessThan(peak(samples[0..<(half - 800)]), 0.01, "the first second is silence")
        XCTAssertGreaterThan(peak(samples[(half + 800)...]), 0.3, "the second second is the tone")
    }

    /// Whisper's own frame is 30 s, so an excerpt running to the very end of a
    /// segment is the ordinary case — and `AVAudioFile.read` throws `nilError` at
    /// end of file on some encoders rather than returning zero frames. Treating
    /// that as a failure would silently truncate every such excerpt.
    func testAnExcerptRunningPastTheEndOfTheFileStopsAtTheEnd() throws {
        let url = try writeTone(seconds: 2, toneFrom: 0, toneTo: 2)
        let samples = try AudioExcerpt.samples(of: url, from: 1, to: 30)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 400)
        XCTAssertGreaterThan(peak(samples[...]), 0.3)
    }

    func testARangeBeyondTheFileIsEmptyRatherThanAnError() throws {
        let url = try writeTone(seconds: 2, toneFrom: 0, toneTo: 2)
        XCTAssertTrue(try AudioExcerpt.samples(of: url, from: 10, to: 12).isEmpty)
    }

    func testAMissingFileIsReportedAsUnreadableNotAsSilence() throws {
        XCTAssertThrowsError(
            try AudioExcerpt.samples(of: directory.appendingPathComponent("nope.m4a"),
                                     from: 0, to: 1))
    }

    /// End to end: two segments with a real gap, a span crossing them, and one
    /// array per file — **never concatenated**, because the audio between the two
    /// does not exist.
    func testSpansAcrossTwoSegmentsComeBackAsSeparateArrays() throws {
        try writeTone(seconds: 4, toneFrom: 0, toneTo: 4, named: "audio-000.caf")
        try writeTone(seconds: 4, toneFrom: 0, toneTo: 4, named: "audio-001.caf")
        let folder = SessionFolder(url: directory)
        let segments = [AudioSegment(index: 0, file: "audio-000.caf", t0: 0, t1: 4_000),
                        AudioSegment(index: 1, file: "audio-001.caf", t0: 300_000, t1: 304_000)]
        let spans = AudioSpans.resolve(from: 3_000, to: 301_000, in: segments)
        XCTAssertEqual(spans.count, 2)
        let audio = try AudioExcerpt.samples(of: spans, in: folder)
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(Double(audio[0].count), 16_000, accuracy: 400)   // last second of the first
        XCTAssertEqual(Double(audio[1].count), 16_000, accuracy: 400)   // first second of the second
    }
}
