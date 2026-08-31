import Foundation
import GolfSessionFormat

/// Handicap arithmetic. Three numbers, and only the ends are ever stored.
///
///     handicap index      journaled, the player's own          14.2
///     tee rating / slope  journaled, frozen at round start     71.2 / 128
///     course handicap     DERIVED here, never stored           16
///
/// **`Hole.handicap` is not any of these.** It is the stroke *index* — the row on
/// an American card saying which hole is hardest — and it is the same word for an
/// unrelated quantity. The two meet in exactly one place, `strokesReceived`, and
/// that is the function to read carefully.
public enum Handicap {

    /// Course handicap: `index × slope/113 + (rating − par)`, rounded.
    ///
    /// **Returns nil when the tee has no rating or no slope.** Most courses in
    /// this project's files have neither — OSM never supplies them and only an
    /// American card prints them — and a course handicap invented from a missing
    /// slope is an ordinary-looking number that is wrong by several shots. Same
    /// rule as `Hole.cardLength(from:)` refusing to answer with another tee's
    /// yardage rather than falling back.
    ///
    /// The `rating − par` term is what makes this differ from the older
    /// slope-only formula, and it is why `par` is frozen alongside the rating: a
    /// course whose par changes between rounds must not retroactively move a
    /// handicap that was already played off.
    public static func course(index: Double?, rating: Double?, slope: Int?,
                              par: Int?) -> Int? {
        guard let index, let rating, let slope, let par, slope > 0 else { return nil }
        let raw = index * Double(slope) / 113.0 + (rating - Double(par))
        return Int(raw.rounded())
    }

    /// Convenience over a `PlayerTee` — the shape the journal stores.
    public static func course(index: Double?, tee: PlayerTee?) -> Int? {
        course(index: index, rating: tee?.rating, slope: tee?.slope, par: tee?.par)
    }

    /// How many strokes a player receives on each hole, keyed by **1-based playing
    /// order** — the same thing a scorecard column means.
    ///
    /// **Allocated against `Hole.handicap`, the stroke index, and that is the trap
    /// this function exists to contain.** The obvious implementation walks the
    /// holes array and gives a stroke to the first *n* — which is allocation by
    /// playing order, not by difficulty, and is wrong on every course. The next
    /// obvious one keys off `Hole.ref`, which repeats across the named nines of a
    /// Korean 27 (황룡/3 and 청룡/3 are both "3") and quietly allocates two holes'
    /// strokes onto one column.
    ///
    /// A handicap above the hole count wraps: 22 on an 18 gives every hole one
    /// stroke and the six hardest a second. A negative one (a plus handicap) takes
    /// strokes back from the *easiest* holes first, which is the mirror of the same
    /// rule and the reason this is not written as `max(0, …)`.
    ///
    /// - Parameter women: allocate against `Hole.handicapWomen` where a course has
    ///   a second stroke-index row. **Both rows are valid 1…18 permutations and
    ///   nothing downstream can tell them apart**, so it has to be asked for.
    public static func strokesReceived(courseHandicap: Int, holes: [Hole],
                                       women: Bool = false) -> [Int: Int] {
        guard !holes.isEmpty else { return [:] }
        // Playing-order index paired with the stroke index that ranks it. A hole
        // with no stroke index sorts last and is allocated last — it cannot be
        // dropped, or the strokes it should have carried vanish.
        //
        // Written with an explicit loop and a pre-typed array: the one-line
        // `enumerated().map { }.sorted { }` over a labelled tuple defeats the type
        // checker outright ("unable to type-check this expression in reasonable
        // time"), the same failure as the `HoleScreen` call in `CourseView`.
        var ranked: [(index: Int, rank: Int)] = []
        ranked.reserveCapacity(holes.count)
        for (offset, hole) in holes.enumerated() {
            let si: Int? = women ? hole.handicapWomen : hole.handicap
            ranked.append((index: offset + 1, rank: si ?? Int.max))
        }
        ranked.sort { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }

        var out: [Int: Int] = [:]
        let n = holes.count
        let sign = courseHandicap < 0 ? -1 : 1
        let magnitude = abs(courseHandicap)
        let everyHole = magnitude / n
        let remainder = magnitude % n
        for (position, hole) in ranked.enumerated() {
            // A plus handicap gives strokes back from the easiest hole up, so the
            // remainder is taken off the *end* of the ranking rather than the front.
            let extra = sign > 0 ? (position < remainder ? 1 : 0)
                                 : (position >= n - remainder ? 1 : 0)
            let strokes = sign * (everyHole + extra)
            if strokes != 0 { out[hole.index] = strokes }
        }
        return out
    }

    /// Net score for one hole: gross minus the strokes received there.
    public static func net(gross: Int, received: Int) -> Int { gross - received }
}
