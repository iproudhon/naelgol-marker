import XCTest
import AVFoundation
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
    /// One converter is reused for every tap buffer, so it has to hold its
    /// resampler state across calls. The failure this guards is not a crash: a
    /// converter rebuilt per buffer re-primes its filter every time, dropping a
    /// slice of every tap — an audible click about twelve times a second, in a file
    /// nobody plays back until after the round.
    ///
    /// Measured against the alternative rather than against a constant, because the
    /// absolute frame count carries one priming cost either way and only the
    /// *difference* says whether the state survived.
    func testConverterHoldsResamplerStateAcrossBuffers() throws {
        let input = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 1,
                                                interleaved: false))
        let output = try XCTUnwrap(AudioRecorder.Config().pcmFormat)

        func tone() throws -> AVAudioPCMBuffer {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            // A 440 Hz tone rather than silence: a resampler fed zeros converts
            // zeros whatever state it is in, which would pass either way.
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000))
            }
            return buffer
        }

        let shared = try XCTUnwrap(AVAudioConverter(from: input, to: output))
        var reused: AVAudioFrameCount = 0, fresh: AVAudioFrameCount = 0
        for _ in 0..<8 {
            let buffer = try tone()
            let a = try XCTUnwrap(AudioRecorder.convert(buffer, with: shared, from: input))
            XCTAssertEqual(a.format.sampleRate, 16_000)
            reused += a.frameLength
            let throwaway = try XCTUnwrap(AVAudioConverter(from: input, to: output))
            fresh += try XCTUnwrap(AudioRecorder.convert(buffer, with: throwaway,
                                                         from: input)).frameLength
        }

        // 8 × 100 ms of 48 kHz is 12,800 frames at 16 kHz, less one priming cost at
        // the very start. A converter rebuilt per buffer pays that cost eight times.
        XCTAssertGreaterThan(reused, fresh + 1_000,
                             "the converter is being re-primed per buffer")
        XCTAssertEqual(Double(reused), 12_800, accuracy: 800)
    }

    /// Rotation is the whole reason the recorder is built on `AVAudioEngine`: the
    /// tap keeps running and only the destination file changes, which is what makes
    /// a segment readable *during* a round.
    ///
    /// The assertion that matters is `AVAudioFile(forReading:)` on the rotated
    /// segment. An `AVAudioFile` still alive when its `.m4a` is opened fails with
    /// `ExtAudioFileOpenURL` — measured — so a rotation that forgets to release the
    /// file produces exactly what the design is trying to avoid: a closed segment
    /// that cannot be transcribed.
    func testRotationLeavesEverySegmentReadable() throws {
        guard AudioRecorder.permission == .granted else {
            throw XCTSkip("no microphone permission in this process")
        }
        let folder = SessionFolder(url: root.appendingPathComponent("session-rotate"))
        let recorder = AudioRecorder(folder: folder)
        try recorder.start()
        Thread.sleep(forTimeInterval: 1.0)
        recorder.rotateSegment()
        Thread.sleep(forTimeInterval: 1.0)
        recorder.stop()

        let segments = folder.readAll(.audio, as: AudioSegment.self).sorted { $0.index < $1.index }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.endReason), ["rotate", "stop"])
        for segment in segments {
            let url = folder.url.appendingPathComponent(segment.file)
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0, "\(segment.file) has no samples")
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        }
    }
    /// **A segment ends when its last sample arrived, not when the code noticed.**
    ///
    /// The watchdog waits ten seconds before declaring a stall, so stamping the
    /// present put the dead stretch *inside* a window the session clock says is
    /// continuous recording — measured at 18.0 s claimed against 6 s of audio.
    /// Everything derived from `t1 - t0` then lies.
    func testASegmentEndsAtItsLastSampleNotWhenTheStallWasNoticed() {
        let t0: Millis = 1_000_000
        let lastBuffer = Date(timeIntervalSince1970: 1_006.0)     // six seconds in
        XCTAssertEqual(AudioRecorder.endTime(lastBuffer: lastBuffer, notBefore: t0),
                       1_006_000)
    }

    /// A segment that opened and received nothing — a restart immediately followed
    /// by a stop. `t1` before `t0` is a negative duration, which reads as corruption
    /// rather than as silence.
    func testASegmentThatHeardNothingIsZeroLengthNotNegative() {
        let t0: Millis = 2_000_000
        // The last buffer belongs to the *previous* segment.
        let stale = Date(timeIntervalSince1970: 1_990.0)
        XCTAssertEqual(AudioRecorder.endTime(lastBuffer: stale, notBefore: t0), t0)
        XCTAssertEqual(AudioRecorder.endTime(lastBuffer: nil, notBefore: t0), t0)
    }
}
