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
///       marks.jsonl       Mark        <- ground truth, never enters a bundle
///       corrections.jsonl Correction  <- ground truth, never enters a bundle
///       scorecard.json    Scorecard   <- entered after the round
///       transcript.jsonl  Utterance   <- produced by golfctl transcribe (cached)
///       bundle.json                   <- produced by golfctl bundle (cached)
///       round.json                    <- produced by golfctl reconstruct
///
/// One clock across every stream: milliseconds since the Unix epoch (`Millis`).
/// Every writer here stamps from `SessionClock.now()` so that a GPS fix, an
/// altitude sample, and an utterance are directly comparable without conversion.
public struct SessionFolder: Sendable {
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
        case bundle = "bundle.json"
        case round = "round.json"

        /// Ground truth. Must never enter an evidence bundle or a prompt.
        /// See CLAUDE.md — the firewall is convention, so this list is the
        /// thing a bundle builder is expected to check against.
        public static let groundTruth: Set<File> = [.marks, .corrections, .scorecard]
        public var isGroundTruth: Bool { File.groundTruth.contains(self) }
    }

    public func path(_ f: File) -> URL { url.appendingPathComponent(f.rawValue) }

    /// Audio is segmented (see `AudioSegment`), so it is addressed by index.
    public static func audioFileName(index: Int) -> String {
        String(format: "audio-%03d.m4a", index)
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
