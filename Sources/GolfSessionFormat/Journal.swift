import Foundation

// GROUND TRUTH — everything in this file. See Mark.swift's header; the same
// firewall applies. Nothing in GolfReconstruction may import or reference it.

/// One thing a person did to this round.
///
/// **The journal is the record; the card is a view of it** *(user decision,
/// 2026-08-27)*. `scorecard.json` and the roster in `meta.json` used to be written
/// by whole-file replacement, so setting a score destroyed the previous value —
/// there was nothing to undo, nothing to retrace, and nobody to blame. Both are now
/// **derived snapshots** rebuilt by replaying `journal.jsonl`, which is append-only
/// for the same reason `Correction` is: the *sequence* is the record, and
/// collapsing it to a final state throws away exactly what makes it worth keeping.
///
/// **Flat, with optionals, in the shape of `Correction`** rather than an enum with
/// associated values. An enum reads better and decodes worse: a new act or a new
/// field breaks every file written before it, and these files are the user's own
/// scores. A flat struct gains a field and old rows still decode.
///
/// **What is deliberately *not* here: anything about a `LogEntry`.** Editing a
/// log's text, moving it to another hole and deleting it are superseding rows in
/// `log.jsonl`, not journal acts. A log is **model-visible** and this file is
/// ground truth, so an edit recorded here would be invisible to the extraction
/// pass that has to read it — the same reason the converged coordinate goes there
/// too. One authority per kind of thing; `RoundHistory` merges the two streams for
/// display.
public struct JournalEntry: Codable, Sendable, Identifiable, Equatable {

    public enum Act: String, Codable, Sendable, CaseIterable {
        /// A score for one player on one hole. `strokes == nil` clears it.
        case setScore
        /// One of the second-rank per-hole numbers — putts, GIR, fairway, OB,
        /// hazard. See `Stat`.
        case setStat
        /// The player's own handicap index. Portable between rounds and courses;
        /// it is **not** a course handicap, which is derived and never stored.
        case setIndex
        /// Which tee this player is on, **with the rating and slope frozen as they
        /// were when the round was played**. See the type note on `rating`.
        case setTee
        case addPlayer
        /// Rename a player.
        case editPlayer
        case removePlayer
        case setCourse
        /// A `.model` proposal the user confirmed. What it claims then counts.
        case acceptEvent
        /// A `.model` proposal the user threw out. Kept, not deleted — a rejected
        /// guess is a free labelled error for `GolfEval`, which is the whole
        /// argument for `Correction` being append-only.
        case rejectEvent
        /// Reverses the entry named in `undoes`. Undo is a row, never a deletion,
        /// and an undo can itself be undone — that is redo.
        case undo
    }

    /// The second-rank per-hole numbers.
    ///
    /// **Second rank in the UI, first-class in the data** *(user, 2026-08-27)*: the
    /// card shows the score and a cell opens to reveal these, but they journal,
    /// undo and blame exactly like a score does. They are also a later extraction
    /// target — "two putts" and "found the bunker" are things people say out loud.
    public enum Stat: String, Codable, Sendable, CaseIterable {
        case putts
        /// Green in regulation.
        case gir
        case fairway
        case ob
        case hazard
        case penalty

        /// True for the ones that are a count rather than a yes/no, which is what
        /// decides whether a cell offers a stepper or a toggle.
        public var isCount: Bool {
            switch self {
            case .putts, .ob, .penalty: return true
            case .gir, .fairway, .hazard: return false
            }
        }

        public var label: String {
            switch self {
            case .putts: return "Putts"
            case .gir: return "GIR"
            case .fairway: return "Fairway"
            case .ob: return "OB"
            case .hazard: return "Hazard"
            case .penalty: return "Penalty"
            }
        }
    }

    public var id: String
    /// When the *act* happened — not when the shot did. A history screen is
    /// ordered by this, and it is what makes "blame" mean anything.
    public var t: Millis

    public var act: Act

    /// `Player.id`, never a roster position or a display name.
    public var player: String?
    /// 1-based playing order, the same thing a scorecard column means. **Not
    /// `Hole.ref`**, which repeats across the named nines of a 27.
    public var hole: Int?
    public var strokes: Int?

    public var stat: Stat?
    /// A count for `Stat.isCount`, else 1 or 0. One field rather than two so that a
    /// row is one shape whatever the stat is.
    public var statValue: Int?

    /// Handicap index — the player's own number, e.g. `14.2`. Course handicap is
    /// derived from this plus the tee below and is never stored.
    public var index: Double?

    public var tee: String?
    /// USGA rating and slope for that tee, and the par they were rated against,
    /// **copied out of the course file when the round was set up**.
    ///
    /// *(User decision, 2026-08-27.)* Course handicap is `index × slope/113 +
    /// (rating − par)`, so leaving these in the course file would mean a later
    /// re-import silently rewrote the card of a round already played — every round
    /// in the history, from one bad import, with nothing to show it happened. The
    /// course file is the source for a round being *set up*; the journal is the
    /// record of one that *happened*.
    public var rating: Double?
    public var slope: Int?
    public var par: Int?

    public var name: String?
    public var course: String?

    /// The `Event.id` an `acceptEvent` / `rejectEvent` refers to.
    public var eventID: String?

    /// What this replaced, so that **one row reads on its own**: "steve, 7: 5 → 6".
    /// Not redundant with replay — a history screen would otherwise have to
    /// re-derive the whole round once per row, and a row that cannot be read alone
    /// cannot be blamed.
    public var prevStrokes: Int?
    public var prevStatValue: Int?
    public var prevIndex: Double?
    public var prevTee: String?

    /// The `JournalEntry.id` this reverses. Only meaningful on `.undo`.
    public var undoes: String?

    public init(id: String = UUID().uuidString.prefix(8).lowercased(),
                t: Millis = SessionClock.now(),
                act: Act,
                player: String? = nil, hole: Int? = nil, strokes: Int? = nil,
                stat: Stat? = nil, statValue: Int? = nil,
                index: Double? = nil,
                tee: String? = nil, rating: Double? = nil, slope: Int? = nil,
                par: Int? = nil,
                name: String? = nil, course: String? = nil,
                eventID: String? = nil,
                prevStrokes: Int? = nil, prevStatValue: Int? = nil,
                prevIndex: Double? = nil, prevTee: String? = nil,
                undoes: String? = nil) {
        self.id = id; self.t = t; self.act = act
        self.player = player; self.hole = hole; self.strokes = strokes
        self.stat = stat; self.statValue = statValue
        self.index = index
        self.tee = tee; self.rating = rating; self.slope = slope; self.par = par
        self.name = name; self.course = course
        self.eventID = eventID
        self.prevStrokes = prevStrokes; self.prevStatValue = prevStatValue
        self.prevIndex = prevIndex; self.prevTee = prevTee
        self.undoes = undoes
    }
}

/// The tee a player is on, with the numbers frozen as played. See
/// `JournalEntry.rating`.
///
/// Lives here rather than in `GolfCourse` because `GolfSessionFormat` is the
/// zero-dependency contract and a *round* has to be able to state what was played
/// without the course file being present at all.
public struct PlayerTee: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var rating: Double?
    public var slope: Int?
    public var par: Int?
    public init(name: String, rating: Double? = nil, slope: Int? = nil,
                par: Int? = nil) {
        self.name = name; self.rating = rating; self.slope = slope; self.par = par
    }
}

/// Everything the journal says is true right now.
///
/// Produced by replaying `journal.jsonl` in order. Nothing here is stored except as
/// a snapshot for readers that predate the journal — `scorecard.json` is written
/// after every replay so `golfctl` and any older reader keep working, but it is a
/// **cache**, and the journal is the authority.
public struct RoundState: Sendable, Equatable {
    public var scorecard: Scorecard
    /// player id -> hole -> stat -> value
    public var stats: [String: [Int: [JournalEntry.Stat: Int]]]
    /// player id -> handicap index
    public var indexes: [String: Double]
    /// player id -> the tee they played, with its frozen rating
    public var tees: [String: PlayerTee]
    public var players: [Player]
    public var course: String?
    /// `Event.id`s the user confirmed, and ones they threw out. An event in
    /// neither set is still a draft.
    public var accepted: Set<String>
    public var rejected: Set<String>

    public init(scorecard: Scorecard = Scorecard(strokes: [:]),
                stats: [String: [Int: [JournalEntry.Stat: Int]]] = [:],
                indexes: [String: Double] = [:],
                tees: [String: PlayerTee] = [:],
                players: [Player] = [],
                course: String? = nil,
                accepted: Set<String> = [], rejected: Set<String> = []) {
        self.scorecard = scorecard; self.stats = stats
        self.indexes = indexes; self.tees = tees
        self.players = players; self.course = course
        self.accepted = accepted; self.rejected = rejected
    }

    public func score(player: String, hole: Int) -> Int? {
        scorecard.strokes[player]?[hole]
    }
    public func stat(_ s: JournalEntry.Stat, player: String, hole: Int) -> Int? {
        stats[player]?[hole]?[s]
    }
    public func total(player: String) -> Int {
        (scorecard.strokes[player] ?? [:]).values.reduce(0, +)
    }
}

/// Replaying the journal, and deciding what an undo actually cancels.
public enum JournalReplay {

    /// The entries that still count, in order — everything not cancelled by a live
    /// `.undo`.
    ///
    /// **An undo can itself be undone, and that is how redo works**, so this is not
    /// "drop every row some undo names". An entry is live unless a **live** undo
    /// names it, which is recursive — and well-founded, because an undo can only
    /// name a row that already existed. Walking newest to oldest therefore settles
    /// it in a single pass: every undo that could cancel a row has been decided
    /// before that row is reached. A forward pass cannot do this, and a fixpoint
    /// loop over the whole set is not guaranteed to converge at all.
    public static func live(_ entries: [JournalEntry]) -> [JournalEntry] {
        let ordered = entries.sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
        var undoers: [String: [String]] = [:]
        for e in ordered where e.act == .undo {
            if let target = e.undoes { undoers[target, default: []].append(e.id) }
        }
        guard !undoers.isEmpty else { return ordered.filter { $0.act != .undo } }

        var alive: [String: Bool] = [:]
        for e in ordered.reversed() {
            // Every undo naming `e` is later than `e`, so it is already decided.
            alive[e.id] = !(undoers[e.id] ?? []).contains { alive[$0] == true }
        }
        return ordered.filter { alive[$0.id] == true && $0.act != .undo }
    }

    /// Every entry still in force, **`.undo` rows included**.
    ///
    /// `live(_:)` drops undo rows because replay must never apply one as an act.
    /// A *history screen* asks a different question — "is this row still in
    /// force?" — and using `live` for it renders every undo struck through and
    /// labelled UNDONE, which says the opposite of what happened. Found by
    /// screenshot, 2026-08-27.
    public static func inForce(_ entries: [JournalEntry]) -> Set<String> {
        let ordered = entries.sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
        var undoers: [String: [String]] = [:]
        for e in ordered where e.act == .undo {
            if let target = e.undoes { undoers[target, default: []].append(e.id) }
        }
        guard !undoers.isEmpty else { return Set(ordered.map(\.id)) }
        var alive: [String: Bool] = [:]
        for e in ordered.reversed() {
            alive[e.id] = !(undoers[e.id] ?? []).contains { alive[$0] == true }
        }
        return Set(alive.filter { $0.value }.keys)
    }

    /// Replay to current state.
    ///
    /// - Parameter seed: what to start from. **A round played before the journal
    ///   existed has no journal at all**, and its `scorecard.json` is the only
    ///   record there is — replaying from empty would present the user with a blank
    ///   card and call it correct. Pass the snapshot and the roster from
    ///   `meta.json`.
    /// - Parameter events: the round's `events.jsonl`, so that **accepting a
    ///   proposal applies its claim here** rather than in a second journal row.
    ///   One user act must be one entry: two rows means Undo reverses half of it
    ///   and leaves the card disagreeing with the proposal list, and it means the
    ///   history screen shows every acceptance twice.
    public static func replay(_ entries: [JournalEntry],
                              seed: RoundState = RoundState(),
                              events: [Event] = []) -> RoundState {
        var s = seed
        let eventsByID = Dictionary(events.map { ($0.id, $0) },
                                    uniquingKeysWith: { _, b in b })
        for e in live(entries).sorted(by: { $0.t < $1.t }) {
            switch e.act {
            case .setScore:
                guard let p = e.player, let h = e.hole else { continue }
                var byHole = s.scorecard.strokes[p] ?? [:]
                if let n = e.strokes, n > 0 { byHole[h] = n } else { byHole[h] = nil }
                s.scorecard.strokes[p] = byHole

            case .setStat:
                guard let p = e.player, let h = e.hole, let k = e.stat else { continue }
                var byHole = s.stats[p] ?? [:]
                var atHole = byHole[h] ?? [:]
                if let v = e.statValue { atHole[k] = v } else { atHole[k] = nil }
                byHole[h] = atHole.isEmpty ? nil : atHole
                s.stats[p] = byHole

            case .setIndex:
                guard let p = e.player else { continue }
                if let v = e.index { s.indexes[p] = v } else { s.indexes[p] = nil }

            case .setTee:
                guard let p = e.player else { continue }
                if let name = e.tee {
                    s.tees[p] = PlayerTee(name: name, rating: e.rating,
                                          slope: e.slope, par: e.par)
                } else {
                    s.tees[p] = nil
                }

            case .addPlayer:
                guard let name = e.name else { continue }
                let id = e.player ?? name
                guard !s.players.contains(where: { $0.id == id }) else { continue }
                s.players.append(Player(id: id, name: name))

            case .editPlayer:
                guard let id = e.player,
                      let i = s.players.firstIndex(where: { $0.id == id }) else { continue }
                if let name = e.name { s.players[i].name = name }

            case .removePlayer:
                guard let id = e.player else { continue }
                s.players.removeAll { $0.id == id }
                // Scores and stats are **kept**. A player removed by mistake and
                // added back should not come back with an empty card, and the
                // journal is supposed to make mistakes recoverable.

            case .setCourse:
                s.course = e.course

            case .acceptEvent:
                guard let id = e.eventID else { continue }
                s.accepted.insert(id); s.rejected.remove(id)
                // The claim lands **here**, at the moment of acceptance, so a
                // later hand-typed score on the same cell still wins and a single
                // undo takes the whole act back.
                if let ev = eventsByID[id], ev.kind == .score,
                   let p = ev.player, let h = ev.hole, let n = ev.strokes, n > 0 {
                    var byHole = s.scorecard.strokes[p] ?? [:]
                    byHole[h] = n
                    s.scorecard.strokes[p] = byHole
                }

            case .rejectEvent:
                guard let id = e.eventID else { continue }
                s.rejected.insert(id); s.accepted.remove(id)

            case .undo:
                continue   // never applied; `live` has already resolved it
            }
        }
        return s
    }
}
