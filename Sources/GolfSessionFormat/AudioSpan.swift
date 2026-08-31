import Foundation

/// A stretch of one recorded file, named by where it sits inside that file.
///
/// The inverse of what `AudioTimeline` does: that maps a time measured inside a
/// segment onto the session clock, this takes a session-clock window and works out
/// which files hold it and where.
public struct AudioSpan: Sendable, Equatable {
    public var segment: AudioSegment
    /// Seconds from the first sample of `segment.file`.
    public var start: TimeInterval
    public var end: TimeInterval

    public init(segment: AudioSegment, start: TimeInterval, end: TimeInterval) {
        self.segment = segment
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end - start }
}

/// Which recorded audio a session-clock window actually covers.
///
/// **This takes a list of segments and `AudioTimeline` deliberately does not, so
/// the difference is worth being explicit about.** The rule there is *never
/// accumulate offsets across segments* — "segment 1 is 600 s long so segment 2
/// starts at 600 s" is wrong, because a segment boundary is a real gap in time and
/// an accumulated offset silently compresses the round. Nothing here accumulates:
/// every span is resolved against **its own segment's `t0`** and the list is only
/// used to decide which segments the window touches. Adding them up is still
/// forbidden; that is why ``AudioSpans/resolve(from:to:in:)`` returns the pieces
/// separately instead of one range.
///
/// Which matters, because a burst genuinely can cross a boundary: the stall
/// watchdog rotates the segment mid-burst, and an interruption closes one. The
/// audio between two segments **does not exist** — it is a phone call — so a
/// caller must transcribe each piece and join the text, never slice one contiguous
/// range across the join.
public enum AudioSpans {

    /// The pieces of recorded audio inside `[t0, t1]`, in recording order.
    ///
    /// **A segment that never closed is skipped, and that is a correctness rule,
    /// not caution.** `t1 == nil` means either the round crashed mid-segment or —
    /// far more often — the microphone is open *right now*. An `.m4a` still being
    /// written is not a readable file: measured 2026-08-27, a file whose
    /// `AVAudioFile` is still alive fails to open at all, and one that does open is
    /// missing the encoder's last frames. There is also no honest end time to
    /// clamp against, and substituting "now" would claim recording that may not
    /// have happened. So the answer for a log spoken into the burst that is still
    /// running is an empty list — nothing to read yet — and a caller shows that as
    /// "not until this recording stops" rather than as a failure.
    public static func resolve(from t0: Millis, to t1: Millis,
                               in segments: [AudioSegment]) -> [AudioSpan] {
        let lo = min(t0, t1), hi = max(t0, t1)
        return segments
            .filter { $0.t1 != nil }
            .sorted { $0.t0 < $1.t0 }
            .compactMap { segment -> AudioSpan? in
                guard let end = segment.t1 else { return nil }
                let overlapStart = max(lo, segment.t0)
                let overlapEnd = min(hi, end)
                guard overlapEnd > overlapStart else { return nil }
                return AudioSpan(segment: segment,
                                 start: Double(overlapStart - segment.t0) / 1000,
                                 end: Double(overlapEnd - segment.t0) / 1000)
            }
    }

    /// How much recorded audio a window actually holds, which is **not** its
    /// wall-clock length. A burst interrupted by a two-minute call spans two
    /// minutes of clock and a few seconds of sound.
    public static func recordedSeconds(from t0: Millis, to t1: Millis,
                                       in segments: [AudioSegment]) -> TimeInterval {
        resolve(from: t0, to: t1, in: segments).reduce(0) { $0 + $1.duration }
    }
}
