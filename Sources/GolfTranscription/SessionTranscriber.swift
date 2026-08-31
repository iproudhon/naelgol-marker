import Foundation
import GolfSessionFormat

/// Transcribes a whole session folder, segment by segment, onto the session clock.
///
/// The two things this owns that a `Transcriber` does not:
///
/// 1. **The clock.** An ASR result is timed from the start of the file it read;
///    `AudioTimeline` puts it back on the one clock, per segment and never
///    cumulatively (see that type for why cumulative is wrong).
/// 2. **The cache.** Re-tuning anything downstream must never re-run a 30-minute
///    transcription (CLAUDE.md), so coverage is recorded per segment and a second
///    pass does only what is missing.
public struct SessionTranscriber: Sendable {

    public struct Progress: Sendable {
        public var segment: Int
        public var total: Int
        public var file: String
        public var utterances: Int
        public var seconds: TimeInterval
    }

    public struct Report: Sendable {
        public var transcribed: [Int] = []
        public var skipped: [Int] = []
        public var missing: [Int] = []
        /// The locales that actually ran, canonical.
        public var locales: [String] = []
        /// Requested locales with no recognizer on this device. **Reported, never
        /// swallowed**: a bilingual round that silently ran in English only looks
        /// exactly like a round where nobody spoke Korean.
        public var unavailableLocales: [String] = []
        public var utterances = 0
        public var audioSeconds: TimeInterval = 0
        public var wallSeconds: TimeInterval = 0

        /// How much faster than real time the pass ran. The number that decides
        /// whether a 4.5-hour round is a coffee break or an afternoon.
        public var realtimeFactor: Double? {
            wallSeconds > 0 ? audioSeconds / wallSeconds : nil
        }
    }

    let folder: SessionFolder
    public init(folder: SessionFolder) { self.folder = folder }

    /// Sorted by time and then by locale, so the two accounts of one moment sit
    /// together in the file.
    ///
    /// - Parameters:
    ///   - force: re-transcribe segments the coverage file already claims.
    ///   - onProgress: called as each segment completes.
    public func run<T: Transcriber>(_ transcriber: T,
                                    context: TranscriptionContext,
                                    force: Bool = false,
                                    onProgress: (@Sendable (Progress) -> Void)? = nil)
        async throws -> Report
    {
        let segments = folder.readAll(.audio, as: AudioSegment.self)
            .sorted { $0.index < $1.index }
        guard !segments.isEmpty else { return Report() }

        // Resolved before a single sample is read, because the cache is keyed on it
        // — see `Transcriber.effectiveLocales`.
        let locales = await transcriber.effectiveLocales(for: context)
        guard !locales.isEmpty else {
            throw TranscriptionError.noLocaleAvailable(context.locales)
        }
        var coverage = loadCoverage(transcriber: transcriber.runID, locales: locales)
        // Utterances already on disk for segments we are keeping, so a partial
        // re-run does not lose the rest of the round. Rewritten wholesale at the
        // end: the file is a derived artifact, unlike the append-only streams.
        var kept: [Utterance] = force ? [] : existingUtterances(coverage: coverage,
                                                               segments: segments)
        var report = Report()
        report.locales = coverage.locales
        // **`auto` means "asked nobody, detects per phrase" and is not a shortfall.**
        // A transcriber that resolves per-locale models reports which of the
        // requested ones it got, and a missing one is loud because an English-only
        // pass over a bilingual round looks exactly like a round in which nobody
        // spoke Korean. Whisper is told nothing on purpose, so the same subtraction
        // reports *every* requested locale as unavailable — which reads as total
        // failure on the run that worked.
        report.unavailableLocales = coverage.locales == ["auto"]
            ? []
            : TranscriptCoverage.canonical(context.locales)
                .filter { !coverage.locales.contains($0) }
        let started = Date()

        for segment in segments {
            let url = folder.url.appendingPathComponent(segment.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // The index says there was a segment and the file is gone. Say so
                // rather than reporting a shorter round that looks complete.
                report.missing.append(segment.index)
                continue
            }
            if !force, coverage.covers(segment.index) {
                report.skipped.append(segment.index)
                continue
            }

            let result = try await transcriber.transcribe(file: url, context: context)
            let mapped = result.utterances.map { u -> Utterance in
                let w = AudioTimeline.window(from: Double(u.t0) / 1000,
                                             to: Double(u.t1) / 1000,
                                             in: segment)
                return Utterance(t0: w.t0, t1: w.t1, speaker: u.speaker,
                                 text: u.text, conf: u.conf, locale: u.locale)
            }
            kept.append(contentsOf: mapped)
            coverage.mark(segment.index)
            report.transcribed.append(segment.index)
            report.utterances += mapped.count
            let secs = AudioTimeline.duration(of: segment) ?? 0
            report.audioSeconds += secs
            onProgress?(Progress(segment: segment.index, total: segments.count,
                                 file: segment.file, utterances: mapped.count,
                                 seconds: secs))
        }

        kept.sort { $0.t0 != $1.t0 ? $0.t0 < $1.t0 : ($0.locale ?? "") < ($1.locale ?? "") }
        try write(kept)
        try folder.writeJSON(coverage, to: .transcriptCoverage)
        report.wallSeconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: -

    func loadCoverage(transcriber: String, locales: [String]) -> TranscriptCoverage {
        let existing = try? folder.readJSON(.transcriptCoverage, as: TranscriptCoverage.self)
        // A cache produced by a different transcriber or a different set of locales
        // is not this run's cache. Phase 2 exists to compare the two paths; serving
        // one path's output for the other's run would quietly invalidate the
        // comparison — and serving an English-only transcript to a bilingual run
        // would lose the Korean half of the round with nothing to show for it.
        if let existing, existing.matches(transcriber: transcriber, locales: locales) {
            return existing
        }
        return TranscriptCoverage(transcriber: transcriber, locales: locales)
    }

    /// Utterances belonging to segments already covered, so an incremental run
    /// keeps them.
    func existingUtterances(coverage: TranscriptCoverage,
                            segments: [AudioSegment]) -> [Utterance] {
        guard !coverage.segments.isEmpty else { return [] }
        let windows = Self.windows(of: segments).filter { coverage.covers($0.index) }
        guard !windows.isEmpty else { return [] }
        return folder.readAll(.transcript, as: Utterance.self).filter { u in
            windows.contains { u.t0 >= $0.start && u.t0 <= $0.end }
        }
    }

    /// Closed [start, end] windows for every segment.
    ///
    /// **A segment with no `t1` is bounded by the next segment's `t0`, not by
    /// infinity.** An unclosed segment is normally the last one — the round that
    /// crashed — but taking "everything from here on" as its window would let a
    /// stale unclosed row in the middle of the index claim every later segment's
    /// utterances as its own, and a partial re-run would then keep lines it was
    /// supposed to replace.
    static func windows(of segments: [AudioSegment])
        -> [(index: Int, start: Millis, end: Millis)]
    {
        let ordered = segments.sorted { $0.t0 < $1.t0 }
        return ordered.enumerated().map { i, seg in
            let next = i + 1 < ordered.count ? ordered[i + 1].t0 - 1 : Millis.max
            return (seg.index, seg.t0, min(seg.t1 ?? Millis.max, next))
        }
    }

    func write(_ utterances: [Utterance]) throws {
        let path = folder.path(.transcript)
        try? FileManager.default.removeItem(at: path)
        let w = try folder.writer(.transcript)
        for u in utterances { try w.append(u) }
        try w.close()
    }
}
