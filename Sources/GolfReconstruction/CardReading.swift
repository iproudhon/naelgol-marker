import Foundation
import GolfSessionFormat

/// Reading a **filled-in** scorecard — the group's strokes — out of text.
///
/// **Not `CourseCard`.** That reads a course's own published card: par, stroke
/// index, per-tee yardage, the numbers that are the same next week. This reads what
/// four people shot this afternoon. They come from different sources, land in
/// different files, and only one of them is ground truth.
///
/// **The output is a set of proposals, never a write.** *(User decision,
/// 2026-08-27: "do not apply the action yet".)* A scorecard read off a photograph
/// is exactly the kind of input that is 95% right and silently wrong in one cell,
/// and a card is the answer key — so every number arrives as something to confirm.
///
/// The prompt and the shape live here rather than in the app so they can be
/// tested. `Sources/` has no `FoundationModels` dependency and must not gain one:
/// the package floor is iOS 16 and this type has to keep compiling on macOS for
/// `golfctl`.
public enum CardReading {

    /// One player's line, as read. Everything is optional because a photograph of
    /// a card is routinely missing a cell, and a reader that refuses the whole
    /// card for one smudge is a reader nobody uses.
    public struct Line: Codable, Sendable, Equatable {
        /// The name as written on the card — matched against the roster
        /// afterwards, never used as an id.
        public var name: String
        /// hole (1-based playing order) -> strokes.
        public var strokes: [Int: Int]
        public init(name: String, strokes: [Int: Int]) {
            self.name = name; self.strokes = strokes
        }
    }

    /// What the model is told. Kept beside the type it produces so the two cannot
    /// drift.
    ///
    /// The three rules exist because each one has a failure that looks like
    /// success: a hallucinated score is indistinguishable from a read one, a
    /// scorecard's *par* row is a set of plausible-looking strokes, and a card
    /// whose holes are named nines does not number 1…18.
    public static func instructions(players: [Player], holeCount: Int) -> String {
        let roster = players.map(\.name).joined(separator: "; ")
        return """
        You are reading a golf scorecard that has already been filled in, and \
        listing the strokes each player took on each hole.

        The players in this round are: \(roster)
        Match each row of the card to one of them by name, allowing for \
        misspellings, nicknames and a different script. If a row matches nobody, \
        use the name exactly as it appears.

        Rules:
        1. Report only numbers you can actually read. If a cell is blank, \
        illegible or missing, leave that hole out. Never estimate a score from \
        the par or from the other holes.
        2. Do not report the PAR, YARDAGE, HANDICAP or STROKE INDEX rows as a \
        player. They are properties of the course, not of anybody's round.
        3. Number the holes 1 to \(holeCount) in the order they were played, \
        left to right, ignoring any subtotal or TOTAL column. If the card names \
        its nines rather than numbering holes 1-18, keep counting straight \
        through: the first hole of the second nine is \(holeCount / 2 + 1).
        """
    }

    public static func prompt(cardText: String) -> String {
        """
        Here is the scorecard:

        \(cardText)
        """
    }

    /// Turn read lines into journal-ready proposals against a roster.
    ///
    /// Name matching is **fuzzy, and never positional**: a card says "Steve" where
    /// the roster says `steve`, and the row order on a card has nothing to do with
    /// the order of the roster. It matches the name and nothing else since aliases
    /// were removed *(user, 2026-08-31)*, so a card written in the other script
    /// than the roster matches nobody — which is *reported* as an unmatched row,
    /// never guessed at.
    ///
    /// Rows matching nobody are returned with a nil `player` rather than dropped —
    /// a card read that silently loses a person looks like a card with three
    /// players on it.
    public static func resolve(_ lines: [Line], players: [Player],
                               holeCount: Int) -> [Reading] {
        lines.map { line in
            Reading(name: line.name,
                    player: match(line.name, in: players)?.id,
                    strokes: line.strokes.filter { $0.key >= 1 && $0.key <= holeCount
                                                   && $0.value > 0 && $0.value <= 20 })
        }
    }

    /// A resolved line: what the card said, who it is, and what to propose.
    public struct Reading: Sendable, Equatable, Identifiable {
        public var name: String
        /// `Player.id`, or nil when nothing on the roster matched.
        public var player: String?
        public var strokes: [Int: Int]
        public var id: String { player ?? name }
        public init(name: String, player: String?, strokes: [Int: Int]) {
            self.name = name; self.player = player; self.strokes = strokes
        }
        public var total: Int { strokes.values.reduce(0, +) }
    }

    /// Case- and whitespace-insensitive, then a containment fallback in both
    /// directions ("Steve J" on the card, "steve" on the roster, and the reverse).
    ///
    /// Deliberately not an edit-distance match: at this length it starts pairing
    /// "min" with "kim", and the cost of a wrong pairing is a whole round of
    /// scores filed under the wrong person.
    public static func match(_ name: String, in players: [Player]) -> Player? {
        let needle = normalise(name)
        guard !needle.isEmpty else { return nil }
        for p in players where normalise(p.name) == needle {
            return p
        }
        for p in players {
            let c = normalise(p.name)
            if c.count >= 2, needle.count >= 2,
               c.contains(needle) || needle.contains(c) { return p }
        }
        return nil
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
