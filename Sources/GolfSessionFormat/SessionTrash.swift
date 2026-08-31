import Foundation

/// Rounds the user deleted, kept for a while in case they did not mean it.
///
/// **Deleting a round is the one destructive act in this app**, and it is destructive
/// in a way nothing else here is: a round holds a GPS track, a card, the sentences
/// four people said out loud and — on a `golfctl`-recorded round — the recordings
/// themselves. Everywhere else the codebase refuses to destroy: a log is
/// tombstoned rather than removed, an event is superseded rather than rewritten, a
/// player removed from the roster keeps their scores. A hard `removeItem` on the
/// folder would be the only place that rule does not hold, and a stray swipe on a
/// list is exactly how it would get exercised.
///
/// So a delete is a **move**, into `Sessions/.trash/`, and the round is still there
/// until the user says otherwise or `retention` runs out.
///
/// ## Why a dot directory
///
/// `SessionIndex.summaries(in:)` scans with `.skipsHiddenFiles`, so a trashed round
/// disappears from the rounds list by construction rather than by a filter every
/// future caller has to remember. `UIFileSharingEnabled` exposes `Documents` to
/// Finder and the Files app, and a dot directory is hidden there too — so a golfer
/// dragging their sessions off the phone gets what they still have, not what they
/// threw away.
public enum SessionTrash {

    public static let directoryName = ".trash"

    /// Written inside a trashed round, holding the `Millis` it was deleted at.
    ///
    /// A sidecar rather than the folder's modification date, which a move may or
    /// may not preserve and which anything touching the folder would reset — the
    /// retention window has to be anchored to an act, not to a filesystem
    /// side effect. Dot-prefixed so `SessionIndex.summary`'s byte count (which
    /// scans with `.skipsHiddenFiles`) never sees it, and **removed on restore**, so
    /// a round that comes back is exactly the round that left.
    static let stampName = ".deleted"

    /// How long a deleted round is kept before it is purged for real.
    ///
    /// Thirty days, which is what every "Recently deleted" a golfer has used means.
    /// Stated on screen, because a recovery window nobody knows about is not a
    /// recovery window.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Deleting

    /// Move a round into the trash.
    ///
    /// - Returns: where it went, so a caller can offer an immediate Undo without
    ///   having to search for it.
    ///
    /// **Nothing here knows which round is recording**, and it must not guess: only
    /// the running process knows, which is the same reason `SessionIndex.summaries`
    /// takes `recordingID` rather than working it out. The caller does not offer the
    /// control on that row.
    @discardableResult
    public static func discard(_ folder: SessionFolder, in root: URL,
                               at now: Millis = SessionClock.now()) throws -> URL {
        let fm = FileManager.default
        let trash = url(in: root)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let name = SessionFolder.freeName(folder.url.lastPathComponent, in: trash)
        let destination = trash.appendingPathComponent(name, isDirectory: true)
        try fm.moveItem(at: folder.url, to: destination)
        // Stamped **after** the move: a stamp written first and then a move that
        // fails leaves a live round carrying a deletion date.
        try? Data("\(now)".utf8).write(to: destination.appendingPathComponent(stampName))
        return destination
    }

    // MARK: - Reading the trash

    /// A deleted round: everything the rounds list shows, plus when it went.
    public struct Deleted: Sendable, Identifiable, Equatable {
        public var summary: SessionSummary
        /// Nil when the stamp is missing — a folder moved in by hand, or one whose
        /// stamp did not survive. **Never substituted with "now"**, which would
        /// silently restart the retention window on every scan and keep a round
        /// forever; `expires` is nil too and `purgeExpired` leaves it alone. Same
        /// rule as an unfinished round's nil duration.
        public var deletedAt: Millis?
        public var url: URL
        public var id: String { url.lastPathComponent }

        public var expires: Date? {
            deletedAt.map { SessionClock.date(from: $0).addingTimeInterval(retention) }
        }
    }

    /// Everything in the trash, most recently deleted first.
    public static func contents(in root: URL) -> [Deleted] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: url(in: root),
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folderURL -> Deleted? in
                guard let s = SessionIndex.summary(of: SessionFolder(url: folderURL))
                else { return nil }
                return Deleted(summary: s, deletedAt: stamp(at: folderURL), url: folderURL)
            }
            .sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) }
    }

    static func stamp(at folderURL: URL) -> Millis? {
        guard let text = try? String(contentsOf: folderURL.appendingPathComponent(stampName),
                                     encoding: .utf8) else { return nil }
        return Millis(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Putting one back

    /// Move a trashed round back among the live ones.
    ///
    /// - Returns: where it landed, which is **not necessarily where it came from**:
    ///   a folder of that name may have appeared meanwhile — an import, or a round
    ///   started at the same minute — and quietly replacing it would destroy a live
    ///   round through the control that exists to undo a destruction.
    @discardableResult
    public static func restore(_ trashed: URL, to root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let name = SessionFolder.freeName(trashed.lastPathComponent, in: root)
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try fm.moveItem(at: trashed, to: destination)
        // The stamp is a fact about being in the trash, so it does not come back
        // out with the round.
        try? fm.removeItem(at: destination.appendingPathComponent(stampName))
        return destination
    }

    // MARK: - Actually deleting

    /// Permanent. There is nothing after this.
    public static func purge(_ trashed: URL) throws {
        try FileManager.default.removeItem(at: trashed)
    }

    /// Everything in the trash, permanently.
    /// - Returns: how many rounds went.
    @discardableResult
    public static func empty(in root: URL) throws -> Int {
        let all = contents(in: root)
        for d in all { try purge(d.url) }
        return all.count
    }

    /// Purge anything past `retention`.
    ///
    /// Called on the rounds list appearing rather than on a timer: this app has no
    /// background work and a golfer who never opens it should not have rounds
    /// vanishing behind them. **A round with no stamp is left alone** — see
    /// `Deleted.deletedAt`.
    ///
    /// - Returns: the folder names that were purged, so the caller can say so
    ///   rather than have rounds disappear with nothing accounting for them.
    @discardableResult
    public static func purgeExpired(in root: URL,
                                    now: Millis = SessionClock.now()) -> [String] {
        var gone: [String] = []
        for d in contents(in: root) {
            guard let at = d.deletedAt else { continue }
            guard Double(now - at) / 1000 > retention else { continue }
            if (try? purge(d.url)) != nil { gone.append(d.id) }
        }
        return gone
    }
}
