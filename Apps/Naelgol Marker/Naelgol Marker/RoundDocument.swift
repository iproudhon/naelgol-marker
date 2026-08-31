import Foundation
import Combine
import GolfSessionFormat
import GolfCourse

/// The *contents* of one round, live or finished, read straight from its session
/// folder.
///
/// Separate from `RoundViewModel` on purpose. `RoundViewModel` owns the capture
/// hardware — one microphone, one `AVAudioSession`, one round recording — and
/// there is exactly one of it for the life of the app. A round you are *reading*
/// has none of that: it is a folder on disk, and there can be dozens. Conflating
/// them is what made the old single-screen shell unable to open a round that had
/// already ended.
@MainActor
final class RoundDocument: ObservableObject {
    let folder: SessionFolder

    @Published private(set) var meta: SessionMeta
    /// Every event ever written, superseded ones included — the sequence is the
    /// labelled error set. Use `visible` to draw.
    @Published private(set) var events: [Event] = []
    @Published private(set) var utterances: [Utterance] = []
    /// What the golfer said, typed or transcribed. **Observation, not ground
    /// truth** — see `LogEntry`. This is the stream extraction reads.
    @Published private(set) var logs: [LogEntry] = []

    /// Every act a person performed on this round, oldest first, **superseded and
    /// undone rows included** — the sequence is the record and the history screen
    /// reads it raw.
    @Published private(set) var journal: [JournalEntry] = []

    /// What the journal says is true right now. **Derived, never stored** — see
    /// `JournalEntry`. `scorecard.json` is rewritten from this after every change
    /// so `golfctl` and any reader older than the journal keep working, but it is
    /// a cache and this is the answer.
    @Published private(set) var state: RoundState = RoundState()

    /// Reading convenience for the many call sites that only want the card.
    var scorecard: Scorecard { state.scorecard }

    private var writer: JSONLWriter?
    private var journalWriter: JSONLWriter?
    private var logWriter: JSONLWriter?

    /// Non-failable on purpose. A folder whose `meta.json` is missing or torn is
    /// exactly the round the user most needs to open — it is the one that crashed
    /// — so it gets a placeholder header and its streams are read anyway, rather
    /// than a screen that refuses to appear.
    init(folder: SessionFolder) {
        self.folder = folder
        self.meta = (try? folder.readMeta())
            ?? SessionMeta(sessionID: folder.url.lastPathComponent, start: 0,
                           device: "unknown", audioFormat: "")
        self.metaIsReadable = (try? folder.readMeta()) != nil
        reload()
    }

    /// False when `meta.json` could not be read — the header on screen is a
    /// placeholder, not the round's own.
    private(set) var metaIsReadable: Bool

    var id: String { folder.url.lastPathComponent }
    /// From the journal, not `meta.json` — a player added or renamed mid-round is
    /// a journal act and `meta.json` is left as the round was started.
    var players: [Player] { state.players }
    /// Likewise. `meta.course` is the round's original choice; this is the current one.
    var course: String? { state.course }
    var isOpen: Bool { meta.end == nil }

    /// Latest-wins, chronological — what the list draws.
    var visible: [Event] { Event.current(events) }

    func reload() {
        if let m = try? folder.readMeta() { meta = m }
        events = folder.readAll(.events, as: Event.self)
        utterances = folder.readAll(.transcript, as: Utterance.self).sorted { $0.t0 < $1.t0 }
        logs = folder.readAll(.log, as: LogEntry.self)
        journal = folder.readAll(.journal, as: JournalEntry.self).sorted { $0.t < $1.t }
        replay()
    }

    /// Rebuild `state` from the journal, then refresh the snapshot on disk.
    ///
    /// **Seeded from `scorecard.json` and `meta.json`.** A round played before the
    /// journal existed has no journal at all, and that snapshot is the only record
    /// there is — replaying from empty would hand the user a blank card and call
    /// it correct.
    private func replay() {
        let seed = RoundState(
            scorecard: (try? folder.readJSON(.scorecard, as: Scorecard.self))
                ?? Scorecard(strokes: [:]),
            players: meta.players,
            course: meta.course)
        state = JournalReplay.replay(journal, seed: seed, events: events)
        // The snapshot is a **cache**, so a write failure is not a lost score —
        // the journal row is already durable and the next replay rebuilds it. It
        // is written so `golfctl` and anything older than the journal keep working.
        try? folder.writeJSON(state.scorecard, to: .scorecard)
    }

    // **`meta.json` is deliberately not rewritten from replay.** The roster and the
    // course now live in the journal, and `writeJSON` is temp-file-then-replace
    // with no `flock` — two processes replaying at once would clobber each other.
    // `scorecard.json` survives that because it is a cache and the journal rebuilds
    // it; `meta.json` is not a cache, so it stays exactly as the round was started
    // and `state.players` / `state.course` are the answer everywhere on screen.

    // MARK: - The journal

    /// Append one act and replay. **The only way anything about this round
    /// changes** — a direct write to `scorecard.json` or `meta.json` would be a
    /// change with no history, which is the thing the journal exists to prevent.
    @discardableResult
    func record(_ entry: JournalEntry) -> JournalEntry? {
        record([entry]) ? entry : nil
    }

    /// Append several acts and replay **once**.
    ///
    /// **Not a convenience.** `replay` walks the whole journal and rewrites
    /// `scorecard.json` through a temp file, so a loop of single `record` calls is
    /// quadratic in replays and does one atomic file replacement per row. Reading
    /// a scorecard applies up to fifty-four cells on one button tap; that is
    /// fifty-four replays and fifty-four file swaps, on the main actor.
    @discardableResult
    func record(_ entries: [JournalEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        do {
            if journalWriter == nil { journalWriter = try folder.writer(.journal) }
            for entry in entries { try journalWriter?.append(entry) }
            try journalWriter?.sync()
            journal.append(contentsOf: entries)
            replay()
            return true
        } catch {
            NSLog("journal.jsonl append failed: \(error)")
            return false
        }
    }

    /// Reverse one act. **A row, never a deletion** — and an undo can itself be
    /// undone, which is redo. See `JournalReplay.live`.
    func undo(_ entry: JournalEntry) {
        record(JournalEntry(act: .undo, undoes: entry.id))
    }

    /// The most recent act that is still in force, which is what an Undo button
    /// acts on. Nil when there is nothing left to reverse.
    var undoable: JournalEntry? { JournalReplay.live(journal).last }

    // MARK: - Events

    /// Append one event. Append-only: a correction **supersedes** its target
    /// rather than rewriting the line, because the sequence of amendments is
    /// exactly what `GolfEval` consumes.
    func append(_ event: Event) {
        do {
            if writer == nil { writer = try folder.writer(.events) }
            try writer?.append(event)
            try writer?.sync()
            events.append(event)
        } catch {
            // A failed append must not take the round down; the user can retype.
            NSLog("events.jsonl append failed: \(error)")
        }
    }

    // MARK: - Logs

    /// The input box.
    ///
    /// **A typed sentence is an observation, not ground truth** *(decision
    /// 2026-08-27)*. It is what the microphone would have heard, so it goes to
    /// `log.jsonl` alongside anything transcribed, and extraction reads both. The
    /// only difference recorded is `LogEntry.Source`: a spoken line can be
    /// misheard, a typed one cannot.
    ///
    /// This used to produce an `Event` with `.user` provenance, which would now
    /// put the app's entire input behind the firewall and leave the extraction
    /// pass with nothing to read. `Event.typed` still exists, for the other
    /// thing — adding an event by hand *after* extraction has run, which is a
    /// correction and genuinely is ground truth.
    /// - Parameter accuracy: the fix's `horizontalAccuracy`. **Not optional
    ///   decoration** — `LogEntry.isPlaced` reads `hAcc ?? .infinity`, so a log
    ///   given a coordinate without one is never placed and joins the convergence
    ///   backlog to ask the radio for the position it was already handed.
    @discardableResult
    func addLog(_ text: String, hole: Int? = nil,
                holeSource: LogEntry.HoleSource? = nil,
                player: String? = nil, shot: Int? = nil,
                at coordinate: Coordinate? = nil,
                accuracy: Double? = nil) -> LogEntry? {
        do {
            guard let entry = try LogStore.shared.append(
                text, source: .typed, to: folder, hole: hole,
                holeSource: holeSource, player: player, shot: shot,
                coordinate: coordinate, accuracy: accuracy) else { return nil }
            logs.append(entry)
            return entry
        } catch {
            NSLog("log.jsonl append failed: \(error)")
            return nil
        }
    }

    /// Tombstone a log — used by the Marker sheet's Cancel, which the user asked to
    /// **delete what the burst wrote** rather than leave it behind.
    ///
    /// Appends the tombstone off the chain **head read from disk**, never off a
    /// cached copy: `LiveTranscript` and `LogPlacement` both grow these chains, and
    /// superseding a stale row forks it.
    func deleteLog(chainFrom id: String) {
        guard let head = LogStore.head(ofChainFrom: id, in: folder) else { return }
        do {
            let gone = try LogStore.shared.append(head.removed(), to: folder)
            logs.append(gone)
        } catch {
            NSLog("log.jsonl tombstone failed: \(error)")
        }
    }

    /// Re-read just the log stream — cheap enough for a single arrival, where the
    /// events and the scorecard have not changed.
    func reloadLogs() {
        logs = folder.readAll(.log, as: LogEntry.self)
    }

    /// What the timeline draws: latest version of each log, deleted ones dropped.
    /// The raw `logs` array keeps every version, because a proposal cites the one
    /// the model actually read.
    var currentLogs: [LogEntry] { LogEntry.current(logs) }

    /// Every version by id, for resolving an `Event.logs` citation.
    var logsByID: [String: LogEntry] { LogEntry.byID(logs) }

    /// Edit, move or delete a log — **all three are superseding rows in
    /// `log.jsonl`, not journal acts**.
    ///
    /// A log is model-visible and the journal is ground truth, so an edit recorded
    /// there would be invisible to the extraction pass that has to read it: the
    /// user would fix a misheard name and the model would go on reading the old
    /// one. The history screen merges the two streams instead.
    @discardableResult
    func amendLog(_ log: LogEntry, text: String? = nil, hole: Int?? = nil,
                  player: String?? = nil, shot: Int?? = nil) -> LogEntry? {
        guard let next = log.edited(text: text, hole: hole,
                                    player: player, shot: shot) else { return nil }
        return appendLog(next)
    }

    @discardableResult
    func deleteLog(_ log: LogEntry) -> LogEntry? { appendLog(log.removed()) }

    /// Place a log that arrived without a fix. See `LogEntry.placed`.
    @discardableResult
    func placeLog(_ log: LogEntry, at coordinate: Coordinate, accuracy: Double?,
                  hole: Int?) -> LogEntry? {
        appendLog(log.placed(lat: coordinate.lat, lon: coordinate.lon,
                             hAcc: accuracy, hole: hole))
    }

    @discardableResult
    private func appendLog(_ entry: LogEntry) -> LogEntry? {
        do {
            if logWriter == nil { logWriter = try folder.writer(.log) }
            try logWriter?.append(entry)
            try logWriter?.sync()
            logs.append(entry)
            return entry
        } catch {
            NSLog("log.jsonl append failed: \(error)")
            return nil
        }
    }

    /// Adding an event by hand, **after** a proposal exists to correct. Ground
    /// truth, and the one place in this type that still writes `.user`.
    func addTypedEvent(_ text: String, hole: Int? = nil) {
        guard let event = Event.typed(text, hole: hole) else { return }
        append(event)
    }

    func delete(_ event: Event) { append(Event.deletion(of: event)) }

    // MARK: - Scorecard

    /// Ground truth (`Scorecard` lives in `Mark.swift`). A score the user sets here
    /// is the answer key; a score the extraction pass proposes is a draft `Event`
    /// and stays one until it is accepted.
    ///
    /// `prevStrokes` is carried on the row so a history entry reads on its own —
    /// "steve, 7: 5 → 6" — without re-deriving the whole round once per row.
    func setScore(player: String, hole: Int, strokes: Int?) {
        record(scoreEntry(player: player, hole: hole, strokes: strokes))
    }

    /// The row `setScore` would write, without writing it — so a bulk apply can
    /// build the whole set and `record` them in one replay.
    func scoreEntry(player: String, hole: Int, strokes: Int?) -> JournalEntry {
        JournalEntry(act: .setScore, player: player, hole: hole, strokes: strokes,
                     prevStrokes: state.score(player: player, hole: hole))
    }

    /// One of the second-rank per-hole numbers. Journals exactly like a score —
    /// second rank is a statement about the UI, not about the data.
    func setStat(_ stat: JournalEntry.Stat, player: String, hole: Int, value: Int?) {
        record(JournalEntry(act: .setStat, player: player, hole: hole,
                            stat: stat, statValue: value,
                            prevStatValue: state.stat(stat, player: player, hole: hole)))
    }

    /// The player's own handicap index. **Not a course handicap**, which is
    /// derived from this and the frozen tee and is never stored.
    func setIndex(player: String, index: Double?) {
        record(JournalEntry(act: .setIndex, player: player, index: index,
                            prevIndex: state.indexes[player]))
    }

    /// Which tee this player is on, **with the rating and slope frozen as they are
    /// now**. Re-importing the course later must never rewrite a card already
    /// played; see `JournalEntry.rating`.
    func setTee(player: String, tee: TeeBox?, par: Int?) {
        record(JournalEntry(act: .setTee, player: player,
                            tee: tee?.name, rating: tee?.rating, slope: tee?.slope,
                            par: par,
                            prevTee: state.tees[player]?.name))
    }

    func addPlayer(name: String, aliases: [String] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record(JournalEntry(act: .addPlayer, player: trimmed, name: trimmed,
                            aliases: aliases))
    }

    func editPlayer(id: String, name: String?, aliases: [String]?) {
        record(JournalEntry(act: .editPlayer, player: id, name: name, aliases: aliases))
    }

    func removePlayer(id: String) {
        record(JournalEntry(act: .removePlayer, player: id))
    }

    // MARK: - Proposals

    /// Confirm a `.model` proposal. Its claim then counts — a `.score` proposal
    /// reaches the card **through replay**, not by a second write.
    ///
    /// **Deliberately not also a `.user` event.** The journal row is the user's
    /// assertion; two records of one act is how they drift apart.
    func accept(_ event: Event) {
        // **One act, one row.** The score it claims is applied by `JournalReplay`
        // at this row — writing a second `.setScore` here would mean one Undo
        // reversed half the act and left the card disagreeing with the proposal
        // list, and the history would show every acceptance twice.
        record(JournalEntry(act: .acceptEvent, eventID: event.id))
    }

    /// Throw a proposal out. **Kept, not deleted** — a rejected guess is a free
    /// labelled error, the same argument that makes `Correction` append-only.
    func reject(_ event: Event) {
        record(JournalEntry(act: .rejectEvent, eventID: event.id))
    }

    func status(of event: Event) -> ProposalStatus {
        if state.accepted.contains(event.id) { return .accepted }
        if state.rejected.contains(event.id) { return .rejected }
        return .draft
    }

    enum ProposalStatus { case draft, accepted, rejected }

    /// The course this round was played on, stored in its own `meta.json`.
    ///
    /// **A round's course is a property of the round, not an app-wide setting.**
    /// The course picker persists a global selection for the hole view, and reading
    /// the title from it put another round's course name on this screen's header.
    func setCourse(_ name: String?) {
        record(JournalEntry(act: .setCourse, course: name))
    }

    func score(player: String, hole: Int) -> Int? { state.score(player: player, hole: hole) }
    func total(player: String) -> Int { state.total(player: player) }
    func stat(_ s: JournalEntry.Stat, player: String, hole: Int) -> Int? {
        state.stat(s, player: player, hole: hole)
    }
    func index(of player: String) -> Double? { state.indexes[player] }
    func tee(of player: String) -> PlayerTee? { state.tees[player] }

    /// Course handicap for one player: derived from their index and their **frozen**
    /// tee, nil when the tee carries no USGA numbers. See `Handicap.course`.
    func courseHandicap(of player: String) -> Int? {
        Handicap.course(index: state.indexes[player], tee: state.tees[player])
    }

    /// Strokes received per hole, keyed by 1-based playing order.
    func strokesReceived(of player: String, holes: [Hole]) -> [Int: Int] {
        guard let ch = courseHandicap(of: player) else { return [:] }
        return Handicap.strokesReceived(courseHandicap: ch, holes: holes)
    }
}
