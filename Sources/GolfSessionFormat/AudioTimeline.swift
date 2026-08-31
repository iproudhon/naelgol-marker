import Foundation

/// Putting a time measured *inside one audio segment* back on the session clock.
///
/// Every ASR result is timed from the start of the file it analysed, and a round's
/// audio is many files (`AudioSegment`). Each segment carries its own `t0`, so the
/// conversion is per segment and nothing else.
///
/// **The trap this type exists to prevent is accumulating offsets across
/// segments.** It looks like the obvious thing — segment 1 is 600 s long, so
/// segment 2 starts at 600 s — and it is wrong, because *a segment boundary is a
/// real gap in time*. Segments close on an interruption: a phone call, Siri,
/// another app taking the microphone. The mic was shut for the length of that call
/// and `segment[n].t0` is genuinely later than `segment[n-1].t1`. An accumulated
/// offset silently compresses the round, and every timestamp after the first
/// interruption drifts by the total length of every interruption before it —
/// which nothing downstream can detect, because the numbers stay plausible.
///
/// So there is deliberately **no API here that takes a list of segments**. One
/// segment, one offset, one answer.
public enum AudioTimeline {

    /// Session-clock time of `offset` seconds into `segment`.
    public static func sessionTime(_ offset: TimeInterval, in segment: AudioSegment) -> Millis {
        segment.t0 + Millis((offset * 1000).rounded())
    }

    /// Session-clock window for a `[start, end]` range measured inside `segment`.
    ///
    /// Clamped to the segment's own end **when that end is known**. A decoder can
    /// report a range running a few milliseconds past the last sample, and an
    /// utterance that ends after the recording did is a claim nothing supports.
    /// A segment with `t1 == nil` never ended cleanly — the crashed round — so
    /// there is nothing to clamp against and the raw value stands.
    public static func window(from start: TimeInterval, to end: TimeInterval,
                              in segment: AudioSegment) -> (t0: Millis, t1: Millis) {
        var t0 = sessionTime(start, in: segment)
        var t1 = sessionTime(max(start, end), in: segment)
        if let hardEnd = segment.t1 {
            t0 = min(t0, hardEnd)
            t1 = min(t1, hardEnd)
        }
        t0 = max(t0, segment.t0)
        t1 = max(t1, t0)
        return (t0, t1)
    }

    /// Length of a segment in seconds, when it has an end. nil for one that never
    /// closed — do not substitute "now", the same reason `SessionSummary.duration`
    /// does not.
    public static func duration(of segment: AudioSegment) -> TimeInterval? {
        segment.t1.map { Double($0 - segment.t0) / 1000 }
    }
}

/// Which segments of a session have been transcribed, and by what.
///
/// **A segment that contained no speech produces no utterances**, so "does any
/// utterance fall inside this segment's window?" is not a usable done-test — a
/// silent segment would look untranscribed and be re-run on every pass, forever.
/// Coverage is therefore recorded explicitly.
///
/// It also records *which* transcriber and locales produced the transcript, because
/// the Apple/WhisperKit comparison is the point of Phase 2 and a cache that cannot
/// tell the two apart would silently serve one path's output for the other's run.
///
/// **`locales` is what actually ran, never what was asked for.** A bilingual round
/// asks for `en_US` and `ko_KR`; if only English resolved — no Korean model on the
/// device, or no signal to fetch one — recording the request would mark the segment
/// done and the Korean half would never be transcribed, on any later pass, with
/// nothing to show it was missing. It is the same trap as the silent segment, one
/// level up.
public struct TranscriptCoverage: Codable, Sendable, Equatable {
    /// Transcriber identity, e.g. `"apple"` or `"whisperkit"`.
    public var transcriber: String
    /// The locales that produced this transcript, canonical (`"en_US"`) and sorted.
    public var locales: [String]
    /// Indices of `AudioSegment`s fully transcribed — including ones that yielded
    /// nothing.
    public var segments: [Int]
    /// When the pass ran.
    public var updated: Millis

    public init(transcriber: String, locales: [String],
                segments: [Int] = [], updated: Millis = SessionClock.now()) {
        self.transcriber = transcriber
        self.locales = Self.canonical(locales)
        self.segments = segments; self.updated = updated
    }

    /// `en-US` and `en_US` are the same recognizer; a cache keyed on the spelling
    /// would miss on the difference and re-transcribe the round.
    ///
    /// `.icu` and not `.identifier`: **`Locale.identifier` hands back whatever it
    /// was given** (measured — `Locale(identifier: "ko-KR").identifier` is
    /// `"ko-KR"`), so it normalises nothing and the two spellings would key
    /// differently. `.icu` is the underscored form and is available at the package
    /// floor.
    public static func canonicalLocale(_ locale: String) -> String {
        Locale(identifier: locale).identifier(.icu)
    }

    public static func canonical(_ locales: [String]) -> [String] {
        var seen = Set<String>()
        return locales
            .map(canonicalLocale)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    public func covers(_ index: Int) -> Bool { segments.contains(index) }

    /// True when this coverage came from the same transcriber and the same *set* of
    /// locales as the run about to happen. A mismatch means the cache is not
    /// reusable — including the case where the earlier run covered more locales
    /// than this one asks for, because the transcript file then holds lines this
    /// run would not have produced.
    public func matches(transcriber: String, locales: [String]) -> Bool {
        self.transcriber == transcriber && self.locales == Self.canonical(locales)
    }

    public mutating func mark(_ index: Int, at t: Millis = SessionClock.now()) {
        if !segments.contains(index) { segments.append(index); segments.sort() }
        updated = t
    }

    // A coverage file written before the round was bilingual carries a single
    // `locale` string. Decoding it as one-element `locales` keeps that cache
    // usable for a single-locale run instead of silently re-transcribing.
    private enum CodingKeys: String, CodingKey {
        case transcriber, locales, locale, segments, updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriber = try c.decode(String.self, forKey: .transcriber)
        let ls = try c.decodeIfPresent([String].self, forKey: .locales)
            ?? (try c.decodeIfPresent(String.self, forKey: .locale)).map { [$0] }
            ?? []
        locales = Self.canonical(ls)
        segments = try c.decodeIfPresent([Int].self, forKey: .segments) ?? []
        updated = try c.decodeIfPresent(Millis.self, forKey: .updated) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transcriber, forKey: .transcriber)
        try c.encode(locales, forKey: .locales)
        try c.encode(segments, forKey: .segments)
        try c.encode(updated, forKey: .updated)
    }
}


/// Puts *live* recognizer output back on the session clock.
///
/// The file path has `AudioTimeline`, which can do this exactly because a segment
/// carries its own `t0`. A live analyzer has no segments: it counts the audio it was
/// handed, so its clock is "delivered samples", not "elapsed time". Those are the
/// same number only while buffers keep arriving.
///
/// **When they diverge, they diverge in the direction that hides it.** A phone call
/// stops delivery for four minutes; the analyzer's clock does not advance; every
/// word after the call maps four minutes early, and nothing downstream can tell —
/// exactly the failure `AudioTimeline`'s "never accumulate" rule exists to prevent,
/// one layer up. So each buffer is *stamped* on arrival, the stamp is compared with
/// where the analyzer thinks it is, and a gap past `gapTolerance` moves the anchor
/// by the difference instead of being averaged away.
public struct LiveAudioClock: Sendable, Equatable {
    /// Session-clock time that analyzer-offset zero corresponds to. Nil until the
    /// first buffer.
    public private(set) var anchor: Millis?
    /// Frames handed to the analyzer so far, at `sampleRate`.
    public private(set) var deliveredFrames: Int = 0
    public let sampleRate: Double
    /// How far delivery may fall behind the clock before it counts as a gap rather
    /// than ordinary jitter. A tap buffer is ~85 ms and scheduling adds to that;
    /// a second is comfortably above the noise and far below any real interruption.
    public var gapTolerance: Millis

    public init(sampleRate: Double, gapTolerance: Millis = 1_000) {
        self.sampleRate = sampleRate
        self.gapTolerance = gapTolerance
    }

    /// Milliseconds of audio the analyzer has been given.
    public var deliveredMillis: Millis {
        guard sampleRate > 0 else { return 0 }
        return Millis((Double(deliveredFrames) / sampleRate * 1000).rounded())
    }

    /// Record one buffer, stamped with when it was captured.
    ///
    /// Call **before** handing the buffer on, so `deliveredFrames` and the anchor
    /// describe the same audio the analyzer is about to hear.
    public mutating func accept(frames: Int, at sessionTime: Millis) {
        guard let current = anchor else {
            anchor = sessionTime
            deliveredFrames = frames
            return
        }
        let expected = current + deliveredMillis
        let drift = sessionTime - expected
        if drift > gapTolerance { anchor = current + drift }
        deliveredFrames += frames
    }

    /// An analyzer offset, in seconds from the start of its input, as a session time.
    public func sessionTime(analyzerOffset seconds: Double) -> Millis? {
        guard let anchor else { return nil }
        return anchor + Millis((max(0, seconds) * 1000).rounded())
    }
}
