import Foundation

/// On-disk layout of one recorded round. Written on device, read on the Mac.
///
///     session-2026-09-14-1430/
///       meta.json
///       audio.m4a
///       gps.jsonl        GPSFix
///       motion.jsonl     MotionSample
///       altitude.jsonl   AltitudeSample
///       marks.jsonl      Mark        <- ground truth, never enters a bundle
///       scorecard.json   Scorecard   <- entered after the round
///       transcript.jsonl Utterance   <- produced by golfctl transcribe (cached)
///       bundle.json                  <- produced by golfctl bundle (cached)
///       round.json                   <- produced by golfctl reconstruct
public struct SessionFolder {
    public let url: URL
    public init(url: URL) { self.url = url }

    public enum File: String {
        case meta = "meta.json"
        case audio = "audio.m4a"
        case gps = "gps.jsonl"
        case motion = "motion.jsonl"
        case altitude = "altitude.jsonl"
        case marks = "marks.jsonl"
        case scorecard = "scorecard.json"
        case transcript = "transcript.jsonl"
        case bundle = "bundle.json"
        case round = "round.json"
    }

    public func path(_ f: File) -> URL { url.appendingPathComponent(f.rawValue) }

    // TODO(phase-1): JSONL append writer, JSONL streaming reader, atomic meta write.
}
