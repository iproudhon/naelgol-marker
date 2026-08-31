import Foundation

/// What a round looks like from the rounds list, without opening its streams.
///
/// Cheap on purpose: `meta.json` plus a directory listing. A 4.5-hour round's
/// `gps.jsonl` is thousands of lines and the list must not read it to draw a row.
public struct SessionSummary: Sendable, Identifiable, Equatable {
    /// Exactly one round can be *recording* — the app holds one `RoundSession` —
    /// and that is a fact only the running process knows. The interesting state is
    /// the third one.
    public enum State: String, Sendable, CaseIterable {
        /// This process, right now.
        case recording
        /// Started and never ended. **Usually this means the app was killed
        /// mid-round** — until there was a rounds list, such a folder was orphaned
        /// silently and nothing would ever show it again.
        case unfinished
        /// Ended cleanly.
        case finished
    }

    /// The folder name, e.g. `session-2026-08-26-0812`.
    public var id: String
    public var url: URL
    public var meta: SessionMeta
    public var state: State
    /// Bytes on disk for the whole folder.
    ///
    /// *This used to be dominated by audio and is not any more* — the app stopped
    /// recording on 2026-08-27, so a round is now a few hundred kilobytes of JSONL
    /// rather than a gigabyte of `.m4a`. Kept because a `golfctl`-recorded round
    /// still has audio in it, and because a phone filling up is worth saying out
    /// loud when it happens.
    public var bytes: Int64
    public var audioSegments: Int
    public var hasTranscript: Bool
    public var hasEvents: Bool
    /// Whether the round holds any `LogEntry` rows — what the golfer said.
    ///
    /// **Existence, not a count**, like the two above: this list reads `meta.json`
    /// and a directory listing and must not open a stream to draw a row. A count
    /// would be nicer and is not worth reading the file for.
    public var hasLogs: Bool

    public var start: Millis { meta.start }
    public var end: Millis? { meta.end }
    public var startDate: Date { SessionClock.date(from: meta.start) }

    /// Wall-clock length. **nil for an unfinished round rather than "now minus
    /// start"** — a session killed three days ago has not been running for three
    /// days, and a list that says so is lying in a way that looks like a bug.
    public var duration: TimeInterval? {
        guard let end = meta.end else { return nil }
        return Double(end - meta.start) / 1000
    }

    public var courseName: String? { meta.course?.isEmpty == false ? meta.course : nil }
    public var players: [Player] { meta.players }
}

/// The rounds list, read straight from the session folders on disk.
///
/// **Deliberately not a database.** Session folders already *are* the durable
/// record — `meta.json` and the JSONL streams, written by code that works and read
/// by `golfctl` on a Mac. A store in front of them would add a schema, a migration
/// policy and a translation layer to show a list. `GolfStore` (SwiftData) stays a
/// Phase 5 concern, where replay gives it a real job.
public enum SessionIndex {
    /// Every session under `root`, newest first.
    ///
    /// - Parameter recordingID: folder name of the round this process is recording,
    ///   if any. Nothing on disk can tell you this, which is why it is passed in.
    public static func summaries(in root: URL, recordingID: String? = nil) -> [SessionSummary] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { summary(of: SessionFolder(url: $0), recordingID: recordingID) }
            .sorted { $0.start > $1.start }
    }

    /// nil when the folder has no readable `meta.json` — a directory that is not a
    /// session, or one whose meta was lost. Skipped rather than fatal, the same
    /// tolerance `JSONLReader` has for a torn final line.
    public static func summary(of folder: SessionFolder,
                               recordingID: String? = nil) -> SessionSummary? {
        guard let meta = try? folder.readMeta() else { return nil }
        let id = folder.url.lastPathComponent
        let state: SessionSummary.State =
            id == recordingID ? .recording : (meta.end == nil ? .unfinished : .finished)

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder.url,
                                                 includingPropertiesForKeys: [.fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var bytes: Int64 = 0
        var segments = 0
        for f in files {
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if f.pathExtension == "m4a" { segments += 1 }
        }

        return SessionSummary(
            id: id, url: folder.url, meta: meta, state: state,
            bytes: bytes, audioSegments: segments,
            hasTranscript: folder.exists(.transcript),
            hasEvents: folder.exists(.events),
            hasLogs: folder.exists(.log))
    }

    /// Sessions that were left open — the crash-recovery list.
    public static func unfinished(in root: URL, recordingID: String? = nil) -> [SessionSummary] {
        summaries(in: root, recordingID: recordingID).filter { $0.state == .unfinished }
    }

    /// Close a round that was never ended, stamping `end` so it stops being
    /// offered for recovery.
    ///
    /// **`end` is the last evidence in the folder, not `now`.** The app died at
    /// some point during the round and the clock has run on since; stamping the
    /// present would invent hours of round that were never recorded, and that
    /// number would land in every duration and every rate computed from it.
    @discardableResult
    public static func closeOut(_ folder: SessionFolder,
                                fallback now: Millis = SessionClock.now()) throws -> SessionMeta {
        var meta = try folder.readMeta()
        guard meta.end == nil else { return meta }
        meta.end = lastEvidence(in: folder) ?? max(meta.start, now)
        try folder.writeMeta(meta)
        return meta
    }

    /// Latest timestamp any stream in the folder actually recorded.
    public static func lastEvidence(in folder: SessionFolder) -> Millis? {
        var latest: Millis?
        func consider(_ t: Millis?) {
            guard let t else { return }
            if latest == nil || t > latest! { latest = t }
        }
        for seg in folder.readAll(.audio, as: AudioSegment.self) { consider(seg.t1 ?? seg.t0) }
        for fix in folder.readAll(.gps, as: GPSFix.self) { consider(fix.t) }
        for m in folder.readAll(.motion, as: MotionSample.self) { consider(m.t) }
        for a in folder.readAll(.altitude, as: AltitudeSample.self) { consider(a.t) }
        return latest
    }
}
