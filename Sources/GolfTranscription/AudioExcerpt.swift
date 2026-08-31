import Foundation
import AVFoundation
import GolfSessionFormat

/// Reads part of a recorded segment back as the samples a decoder wants.
///
/// This exists so one log entry can be transcribed again by a bigger model without
/// re-running the whole round. The measured cost is what makes that the right
/// shape: `openai_whisper-small` runs at 1.5–2.7× realtime on this Mac and slower
/// on a phone, so a `large-v3` pass over 4.5 hours is most of a day, while the same
/// model over one twenty-second entry is seconds. Per-entry is not a convenience,
/// it is the only affordable way to use the big model at all.
public enum AudioExcerpt {

    /// Whisper's own input: 16 kHz mono float. Ask rather than assume — the `.m4a`
    /// happens to be written at the same rate, and a converter is built anyway
    /// because nothing guarantees it stays that way.
    public static let sampleRate: Double = 16_000

    /// - Parameters:
    ///   - from: seconds from the file's first sample.
    ///   - to: seconds from the file's first sample; clamped to the file's length.
    /// - Returns: mono float samples at ``sampleRate``, empty when the range falls
    ///   outside the file.
    public static func samples(of url: URL,
                               from start: TimeInterval,
                               to end: TimeInterval,
                               sampleRate rate: Double = AudioExcerpt.sampleRate) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw TranscriptionError.audioUnreadable(url, underlying: "\(error)") }

        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: rate, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw TranscriptionError.audioUnreadable(url, underlying: "no converter") }

        let first = AVAudioFramePosition(max(0, start) * inFormat.sampleRate)
        let last = AVAudioFramePosition(max(start, end) * inFormat.sampleRate)
        guard first < file.length else { return [] }
        file.framePosition = first
        var remaining = min(last, file.length) - first
        guard remaining > 0 else { return [] }

        // Generous, because a rate conversion upward would otherwise overflow the
        // output buffer and the converter reports that as a plain failure.
        let chunk: AVAudioFrameCount = 8192
        let outCapacity = AVAudioFrameCount(Double(chunk) * rate / inFormat.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
        else { throw TranscriptionError.audioUnreadable(url, underlying: "no buffer") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(remaining) / inFormat.sampleRate * rate) + 1)

        while true {
            var conversionError: NSError?
            out.frameLength = 0
            let status = converter.convert(to: out, error: &conversionError) { _, inStatus in
                guard remaining > 0 else { inStatus.pointee = .endOfStream; return nil }
                let want = AVAudioFrameCount(min(Int64(chunk), remaining))
                guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: want)
                else { inStatus.pointee = .endOfStream; return nil }
                // **A throw here is end of file, not an error.** `AVAudioFile.read`
                // raises `nilError` at EOF on some encoders rather than returning
                // zero frames; treating it as a failure loses the last chunk of
                // every excerpt that runs to the end of a segment.
                do { try file.read(into: input, frameCount: want) }
                catch { inStatus.pointee = .endOfStream; return nil }
                guard input.frameLength > 0 else { inStatus.pointee = .endOfStream; return nil }
                remaining -= Int64(input.frameLength)
                inStatus.pointee = .haveData
                return input
            }

            if out.frameLength > 0, let channel = out.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                               count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || conversionError != nil { break }
            if status == .inputRanDry && remaining <= 0 { break }
        }
        return samples
    }

    /// Every span's audio, one array per span.
    ///
    /// **Deliberately not concatenated.** A burst that crossed a segment boundary
    /// has a real gap in it — the microphone was shut for the length of a phone
    /// call — and gluing the two sides together would hand the decoder a join that
    /// never happened, in the middle of a 30-second frame. Transcribe each piece
    /// and join the *text*.
    public static func samples(of spans: [AudioSpan],
                               in folder: SessionFolder,
                               sampleRate rate: Double = AudioExcerpt.sampleRate) throws -> [[Float]] {
        try spans.map { span in
            try samples(of: folder.url.appendingPathComponent(span.segment.file),
                        from: span.start, to: span.end, sampleRate: rate)
        }
    }
}
