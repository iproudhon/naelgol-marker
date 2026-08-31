import Foundation
import GolfSessionFormat
import GolfCourse

/// Writes what the golfer said into the round in progress.
///
/// **One writer, whatever the input was.** A typed sentence and a transcribed one
/// produce the same `LogEntry` in the same `log.jsonl`, because extraction should
/// not be able to tell them apart — the only difference is `LogEntry.Source`, which
/// is kept because a spoken sentence can be misheard and a typed one cannot.
///
/// `JSONLWriter`'s `O_APPEND` + `flock` is kept even though there is now one
/// writing process again *(the Siri intent was scrapped 2026-08-27)*: appending
/// under a lock costs nothing, and it is the property that makes a live
/// transcription feed writing alongside the input box safe by construction.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    /// Posted after a successful append, so the round screen refreshes as a log
    /// lands rather than on the next reload.
    static let didAppend = Notification.Name("marker.log.didAppend")

    private let lock = NSLock()
    private var writer: JSONLWriter?
    private var writerFolder: URL?

    /// **`SessionFolder.isSame`, never `==`.** Two URLs for one round compare
    /// unequal when one was built before the directory existed —
    /// `appendingPathComponent` consults the filesystem and adds a trailing slash
    /// for a directory that is already there. With `==` the writer was torn down and
    /// reopened on every append that alternated between two `RoundDocument`s over
    /// the same round, which is now the ordinary case: the Marker sheet opens over
    /// the hole view with its own document while the round screen holds another.
    /// `O_APPEND` keeps that safe rather than correct, and the same comparison bug
    /// one layer up cost twenty-nine invisible logs.
    private func isCurrentWriter(_ folder: SessionFolder) -> Bool {
        guard let writerFolder else { return false }
        return SessionFolder(url: writerFolder).isSame(as: folder.url)
    }

    private init() {}

    // MARK: - Appending

    /// Append one log. Returns nil when the text is blank — a recogniser hands
    /// back an empty string when it hears nothing, and a blank row on screen is
    /// indistinguishable from a log that failed to save.
    @discardableResult
    func append(_ text: String,
                source: LogEntry.Source,
                to folder: SessionFolder,
                hole: Int? = nil,
                holeSource: LogEntry.HoleSource? = nil,
                player: String? = nil,
                shot: Int? = nil,
                coordinate: Coordinate? = nil,
                accuracy: Double? = nil,
                locale: String? = Locale.current.identifier(.icu),
                at t: Millis = SessionClock.now(),
                until tEnd: Millis? = nil) throws -> LogEntry?
    {
        guard let entry = LogEntry.make(text, source: source, t: t,
                                        lat: coordinate?.lat, lon: coordinate?.lon,
                                        hAcc: accuracy, hole: hole,
                                        holeSource: holeSource,
                                        player: player, shot: shot, locale: locale,
                                        tEnd: tEnd)
        else { return nil }

        lock.lock()
        defer { lock.unlock() }
        if !isCurrentWriter(folder) {
            try? writer?.close()
            writer = try folder.writer(.log)
            writerFolder = folder.url
        }
        try writer?.append(entry)
        try writer?.sync()          // a round can end by battery death mid-hole
        NotificationCenter.default.post(name: Self.didAppend, object: folder.url)
        return entry
    }

    /// Append a row that supersedes an existing log — a late coordinate, an edit,
    /// a deletion. Same file, same notifications; see `LogEntry.supersedes`.
    @discardableResult
    func append(_ entry: LogEntry, to folder: SessionFolder) throws -> LogEntry {
        lock.lock()
        defer { lock.unlock() }
        if !isCurrentWriter(folder) {
            try? writer?.close()
            writer = try folder.writer(.log)
            writerFolder = folder.url
        }
        try writer?.append(entry)
        try writer?.sync()
        NotificationCenter.default.post(name: Self.didAppend, object: folder.url)
        return entry
    }

    /// The latest version of a log, following the supersede chain forward.
    ///
    /// **Read from disk, never from a cached copy, and this is not fussiness.**
    /// Two writers grow the same chain: `LiveTranscript` extends a burst's entry as
    /// more is said, and `LogPlacement.converge` appends a placed row when a fix
    /// finally arrives. Editing a stale in-memory copy forks the chain — two rows
    /// superseding the same parent — and `LogEntry.current` keeps one head, so the
    /// coordinate that convergence just spent fifteen seconds of radio acquiring is
    /// silently dropped. Re-reading costs a few kilobytes per phrase.
    static func head(ofChainFrom id: String, in folder: SessionFolder) -> LogEntry? {
        let all = folder.readAll(.log, as: LogEntry.self)
        var current = all.first { $0.id == id }
        var hops = 0
        while let c = current,
              let next = all.first(where: { $0.supersedes == c.id }),
              hops < 1_000 {
            current = next
            hops += 1
        }
        return current
    }

    // MARK: -

    /// Nearest hole on *this round's* course. See `Course.nearestHole` for why the
    /// answer is a proposal the user can move rather than a derived fact.
    static func hole(at p: Coordinate, folder: SessionFolder) -> Int? {
        guard let name = (try? folder.readMeta())?.course else { return nil }
        let course = CourseStore.documents.loadAll().first {
            $0.name == name || $0.aliases.contains(name)
        }
        return course?.nearestHole(to: p)?.index
    }
}
