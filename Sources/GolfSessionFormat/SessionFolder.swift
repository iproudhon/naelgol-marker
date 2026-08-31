import Foundation

/// On-disk layout of one recorded round. Written on device, read on the Mac.
///
///     session-2026-09-14-1430/
///       meta.json
///       audio.jsonl       AudioSegment  <- index: which .m4a covers which millis
///       audio-000.m4a     ...one per uninterrupted stretch
///       gps.jsonl         GPSFix
///       motion.jsonl      MotionSample
///       altitude.jsonl    AltitudeSample
///       journal.jsonl     JournalEntry<- ground truth; the card is derived from it
///       marks.jsonl       Mark        <- ground truth, never enters a bundle
///       corrections.jsonl Correction  <- ground truth, never enters a bundle
///       scorecard.json    Scorecard   <- DERIVED snapshot of journal.jsonl
///       transcript.jsonl  Utterance   <- produced by golfctl transcribe (cached)
///       log.jsonl         LogEntry    <- what the golfer said, via Siri or the box
///       bundle.json                   <- produced by golfctl bundle (cached)
///       round.json                    <- produced by golfctl reconstruct
///
/// One clock across every stream: milliseconds since the Unix epoch (`Millis`).
/// Every writer here stamps from `SessionClock.now()` so that a GPS fix, an
/// altitude sample, and an utterance are directly comparable without conversion.
public struct SessionFolder: Sendable {


    /// Whether two references name the same session folder.
    ///
    /// **Never compare the `URL`s with `==`.** `URL.appendingPathComponent(_:)`
    /// consults the filesystem and appends a trailing slash when the component is
    /// an *existing* directory — so a URL built before the folder was created
    /// compares unequal to the identical path built afterwards. That is exactly
    /// the shape of this app: `RoundSession.create` builds its URL before
    /// `create()`, the round screen builds the same path after. Measured on device
    /// 2026-08-27: every `LogStore.didAppend` was dropped by that guard, so a
    /// burst filed twenty-nine logs and the screen showed "Nothing on this hole"
    /// — the file was right and only the refresh was lost.
    public static func isSame(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func isSame(as url: URL) -> Bool { Self.isSame(self.url, url) }
    public let url: URL
    public init(url: URL) { self.url = url }

    public enum File: String, CaseIterable, Sendable {
        case meta = "meta.json"
        /// Index of audio segments; the .m4a files themselves are audio-NNN.m4a.
        case audio = "audio.jsonl"
        case gps = "gps.jsonl"
        case motion = "motion.jsonl"
        case altitude = "altitude.jsonl"
        case marks = "marks.jsonl"
        case corrections = "corrections.jsonl"
        case scorecard = "scorecard.json"
        case transcript = "transcript.jsonl"
        /// Which audio segments the transcript covers — see `TranscriptCoverage`.
        /// A silent segment yields no utterances, so the transcript itself cannot
        /// say whether it was done.
        case transcriptCoverage = "transcript.coverage.json"
        /// What the golfer said happened — Siri dictation and the input box.
        ///
        /// **Observation, and therefore model input.** It is the stream that
        /// replaced `transcript.jsonl` as the app's primary evidence, and it is
        /// deliberately in neither list below: a log is not ground truth, and the
        /// file is not mixed either, because *every* row in it is model-visible.
        /// See `LogEntry` for why "a human typed it" does not make it the answer key.
        case log = "log.jsonl"
        /// **Every act a person performed on this round**, append-only. Scores,
        /// stats, handicaps, roster edits, accepting or rejecting a proposal —
        /// and the `undo` rows that reverse them. `scorecard.json` and the roster
        /// in `meta.json` are **derived from this**, not the other way round; see
        /// `JournalEntry`. Ground truth, so it never enters a bundle or a prompt.
        case journal = "journal.jsonl"
        /// Which logs extraction has already read — see `ExtractionCoverage`. A log
        /// that produced no proposal is cited by nothing, so the events alone
        /// cannot say whether it was read.
        case extractionCoverage = "extraction.coverage.json"
        /// Extracted and hand-entered events. **Mixed provenance** — see `mixed`.
        case events = "events.jsonl"
        case bundle = "bundle.json"
        case round = "round.json"

        /// Ground truth. Must never enter an evidence bundle or a prompt.
        /// See CLAUDE.md — the firewall is convention, so this list is the
        /// thing a bundle builder is expected to check against.
        public static let groundTruth: Set<File> = [.marks, .corrections, .scorecard,
                                                    .journal]
        public var isGroundTruth: Bool { File.groundTruth.contains(self) }

        /// Files that hold **both** model output and ground truth on alternating
        /// lines, so the whole-file check above cannot decide them. A reader must
        /// filter row by row — `Event.modelVisible(_:)` for `events.jsonl`.
        ///
        /// Listed rather than left to a comment because "is this file safe to send"
        /// is otherwise answered by `isGroundTruth == false`, which is *wrong* here
        /// and wrong in the direction that leaks.
        public static let mixedProvenance: Set<File> = [.events]
        public var isMixedProvenance: Bool { File.mixedProvenance.contains(self) }
    }

    public func path(_ f: File) -> URL { url.appendingPathComponent(f.rawValue) }

    /// Audio is segmented (see `AudioSegment`), so it is addressed by index.
    public static func audioFileName(index: Int) -> String {
        String(format: "audio-%03d.m4a", index)
    }
    /// The index in `audio-007.m4a`, or nil for anything else in the folder.
    public static func audioIndex(inFileName name: String) -> Int? {
        guard name.hasPrefix("audio-"), name.hasSuffix(".m4a") else { return nil }
        return Int(name.dropFirst("audio-".count).dropLast(".m4a".count))
    }

    /// The highest segment index this folder already holds.
    ///
    /// **Files and index rows both, and the maximum of the two.** A crash mid-
    /// segment leaves the `.m4a` on disk with no row in `audio.jsonl` — that is a
    /// deliberate property of the format, recoverable and better than a row that
    /// lies. Resuming from the rows alone would therefore hand the next burst a
    /// filename that already exists and overwrite a real recording.
    public func lastAudioIndex() -> Int? {
        let fromRows = readAll(.audio, as: AudioSegment.self).map(\.index).max()
        let fromFiles = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .compactMap(Self.audioIndex(inFileName:)).max()
        switch (fromRows, fromFiles) {
        case let (r?, f?): return Swift.max(r, f)
        case let (r?, nil): return r
        case let (nil, f?): return f
        default: return nil
        }
    }

    public func audioPath(index: Int) -> URL {
        url.appendingPathComponent(Self.audioFileName(index: index))
    }
    public func exists(_ f: File) -> Bool {
        FileManager.default.fileExists(atPath: path(f).path)
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A folder name inside `root` that nothing is using — `name`, or `name-2`,
    /// `name-3`…
    ///
    /// **One copy, because three callers now need it and they must agree.** A round
    /// is imported into a folder named from its start time, a deleted round is moved
    /// into the trash, and a trashed one is moved back — and every one of those can
    /// collide with a folder that appeared meanwhile. Three private uniquifiers
    /// would be three chances for one of them to overwrite instead of suffix, on the
    /// one operation where overwriting destroys a whole round.
    public static func freeName(_ name: String, in root: URL) -> String {
        let fm = FileManager.default
        var candidate = name
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(name)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Conventional folder name for a session starting at `start`, in local time.
    /// Local rather than UTC on purpose: a golfer looking for "the Sunday morning
    /// round" should find it by name.
    public static func folderName(start: Millis, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: Double(start) / 1000)
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return "session-\(fmt.string(from: date))"
    }

    // MARK: - Streams

    public func writer(_ f: File) throws -> JSONLWriter {
        try JSONLWriter(url: path(f))
    }

    /// Streaming read. Undecodable lines are skipped, not fatal — a round that
    /// ended in a battery death still has to open.
    public func stream<T: Decodable>(_ f: File, as type: T.Type) -> JSONLReader<T> {
        JSONLReader<T>(url: path(f))
    }

    public func readAll<T: Decodable>(_ f: File, as type: T.Type) -> [T] {
        Array(stream(f, as: type))
    }

    // MARK: - Whole-file JSON

    /// Atomic: write to a sibling temp file, then replace. meta.json is rewritten
    /// when the round ends, and a half-written meta would orphan the session.
    public func writeJSON<T: Encodable>(_ value: T, to f: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try create()
        let tmp = url.appendingPathComponent(".\(f.rawValue).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(path(f), withItemAt: tmp)
    }

    public func readJSON<T: Decodable>(_ f: File, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: path(f))
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func writeMeta(_ meta: SessionMeta) throws { try writeJSON(meta, to: .meta) }
    public func readMeta() throws -> SessionMeta { try readJSON(.meta, as: SessionMeta.self) }
}

/// The one clock. Every stream stamps from here so that timestamps are
/// comparable across audio, GPS, motion, altitude, and transcript.
public enum SessionClock {
    public static func now() -> Millis { millis(from: Date()) }
    public static func millis(from date: Date) -> Millis {
        Millis((date.timeIntervalSince1970 * 1000).rounded())
    }
    public static func date(from t: Millis) -> Date {
        Date(timeIntervalSince1970: Double(t) / 1000)
    }
}
