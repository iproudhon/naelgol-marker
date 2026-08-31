import Foundation
import GolfSessionFormat

/// A scorecard as published — par, handicap, and a distance per named tee, per
/// hole. **No coordinates.** This is the half of a course that comes off a web
/// page or a photograph; geometry comes from somewhere else entirely
/// (docs/research-scorecard-import.md).
///
/// Decoded straight from the extraction schema, so field names here and in
/// `Prompts/course-card.schema.json` must stay in step.
public struct CourseCard: Codable, Sendable, Hashable {

    public struct Tee: Codable, Sendable, Hashable {
        public var name: String
        /// As printed, in whatever `unit` says. Not normalised until `course(...)`.
        public var distance: Double?
        /// USGA rating and slope, printed under the tee name on every American card.
        public var rating: Double?
        public var slope: Int?
        public init(name: String, distance: Double? = nil,
                    rating: Double? = nil, slope: Int? = nil) {
            self.name = name; self.distance = distance
            self.rating = rating; self.slope = slope
        }
    }

    public struct CardHole: Codable, Sendable, Hashable {
        public var ref: String
        public var par: Int
        /// Men's stroke index, or the only one where the card prints one row.
        public var handicap: Int?
        /// The women's row. American cards commonly print both, and they differ —
        /// one `handicap` field would silently pick a column and both allocations
        /// pass the 1…18 permutation check, so the error would be invisible.
        public var handicapWomen: Int?
        public var tees: [Tee]
        public init(ref: String, par: Int, handicap: Int? = nil,
                    handicapWomen: Int? = nil, tees: [Tee] = []) {
            self.ref = ref; self.par = par
            self.handicap = handicap; self.handicapWomen = handicapWomen
            self.tees = tees
        }
    }

    /// A named nine, or the whole 18 when the card does not name them.
    ///
    /// Korean 18s are usually two of three named nines, each numbered 1–9 — so a
    /// nine is the natural unit of a card, not the round.
    public struct Nine: Codable, Sendable, Hashable {
        public var name: String?
        public var holes: [CardHole]
        /// The totals row as printed. Kept separately from the holes on purpose:
        /// it is an independent statement of the same numbers, which is what makes
        /// `issues()` a real check rather than a restatement.
        public var printedPar: Int?
        public var printedTees: [Tee]
        public init(name: String? = nil, holes: [CardHole] = [],
                    printedPar: Int? = nil, printedTees: [Tee] = []) {
            self.name = name; self.holes = holes
            self.printedPar = printedPar; self.printedTees = printedTees
        }
    }

    public var courseName: String
    public var aliases: [String]
    /// "metres" | "yards" | "unknown" — a string, not the enum, because **the card
    /// usually does not say**, and forcing the extractor to choose would turn a
    /// known unknown into a confident wrong answer. What to do about "unknown" is
    /// `resolveUnit(preferring:assuming:)`'s problem, not the extractor's.
    public var unit: String
    public var nines: [Nine]
    /// Anything the extractor wants to flag: an unreadable row, a missing handicap
    /// column, a second card on the same page.
    public var notes: String?

    public init(courseName: String, aliases: [String] = [], unit: String = "unknown",
                nines: [Nine] = [], notes: String? = nil) {
        self.courseName = courseName; self.aliases = aliases
        self.unit = unit; self.nines = nines; self.notes = notes
    }

    public var holes: [CardHole] { nines.flatMap(\.holes) }
    public var declaredUnit: DistanceUnit? { DistanceUnit(rawValue: unit) }

    /// The unit to import with, and where it came from.
    ///
    /// Order: what the caller passed, then what the card printed, then the regional
    /// assumption. **The totals are not consulted**, and that is the finding rather
    /// than a shortcut — an ordinary American card from the tips and a Korean metric
    /// card occupy the same per-par window, so no total-based rule separates them
    /// (`DistanceUnit.plausibility`). Guessing from the numbers refuses ordinary
    /// American cards and still gets Korean ones wrong.
    ///
    /// This never returns nil: an assumed unit that is checked beats a refusal that
    /// stops the import. It is checked twice — `unitWarning` catches the impossible
    /// now, and `HoleGeometry.lengthDisagreement` catches the merely wrong as soon
    /// as anyone places a tee and a green.
    public func resolveUnit(preferring override: DistanceUnit? = nil,
                            assuming fallback: DistanceUnit = .assumedWhenUnstated)
        -> (unit: DistanceUnit, source: UnitSource) {
        if let override { return (override, .explicit) }
        if let d = declaredUnit { return (d, .printed) }
        return (fallback, .assumed)
    }

    /// A note when the totals are impossible in *any* unit — a misread column or a
    /// totals row taken for a hole. Nil is the normal case and does not mean the
    /// unit is right.
    public func unitWarning() -> String? {
        DistanceUnit.plausibility(total: longestTeeTotal,
                                  par: holes.reduce(0) { $0 + $1.par })
    }

    /// Sum of the longest tee across every hole — the number a card's grand total
    /// row reports, and what the unit guess keys off.
    public var longestTeeTotal: Double {
        holes.reduce(0) { sum, h in sum + (h.tees.compactMap(\.distance).max() ?? 0) }
    }

    // MARK: - Building a course

    /// Convert to a `Course`, normalising every distance to metres.
    ///
    /// Holes keep their nine, so `ref` collisions across a 27-hole course become
    /// distinct `Hole.id`s rather than silently overwriting each other.
    public func course(id: String, source: Course.Source = .card,
                       attribution: String? = nil,
                       unit: DistanceUnit,
                       updated: Millis? = nil) -> Course {
        var holes: [Hole] = []
        for nine in nines {
            for h in nine.holes {
                let tees = h.tees.map {
                    TeeBox(name: $0.name, at: nil, distance: $0.distance.map(unit.metres),
                           rating: $0.rating, slope: $0.slope)
                }
                holes.append(Hole(ref: h.ref, nine: nine.name, par: h.par,
                                  handicap: h.handicap, handicapWomen: h.handicapWomen,
                                  tees: tees, green: Green(), source: source))
            }
        }
        return Course(id: id, name: courseName, aliases: aliases,
                      source: source, attribution: attribution,
                      cardUnit: unit, updated: updated, holes: holes)
    }

    // MARK: - Reconciliation

    /// What did not add up. A card is self-validating in a way most model output is
    /// not: the per-nine and grand totals are printed on the page, so the extracted
    /// holes can be summed and compared. That catches a transposed or invented
    /// digit, which is the failure mode that matters.
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Kind: String, Sendable {
            case parSumMismatch, teeSumMismatch, holeCount, duplicateRef
            case handicapNotAPermutation, parOutOfRange, distanceOutOfRange, noDistances
        }
        public var kind: Kind
        public var detail: String
        /// True for things that make the import wrong, as opposed to merely thin.
        public var blocking: Bool
        public var description: String { "\(blocking ? "error" : "warn") \(kind.rawValue): \(detail)" }
        public init(_ kind: Kind, _ detail: String, blocking: Bool = true) {
            self.kind = kind; self.detail = detail; self.blocking = blocking
        }
    }

    /// - Parameter unit: only used to sanity-check magnitudes; sums are compared in
    ///   the card's own printed numbers, where they are directly comparable.
    public func issues(unit: DistanceUnit? = nil) -> [Issue] {
        var out: [Issue] = []

        for nine in nines {
            let label = nine.name ?? "card"

            if let printed = nine.printedPar {
                let summed = nine.holes.reduce(0) { $0 + $1.par }
                if summed != printed {
                    out.append(Issue(.parSumMismatch,
                                     "\(label): holes sum to par \(summed), card prints \(printed)"))
                }
            }
            for pt in nine.printedTees {
                guard let printed = pt.distance else { continue }
                let summed = nine.holes.reduce(0.0) { sum, h in
                    sum + (h.tees.first { $0.name.caseInsensitiveCompare(pt.name) == .orderedSame }?
                        .distance ?? 0)
                }
                // One metre of slack for a card that rounds its own total.
                if abs(summed - printed) > 1 {
                    out.append(Issue(.teeSumMismatch,
                                     String(format: "%@ · %@: holes sum to %.0f, card prints %.0f",
                                            label, pt.name, summed, printed)))
                }
            }
            if !nine.holes.isEmpty, nine.holes.count != 9, nine.holes.count != 18 {
                out.append(Issue(.holeCount,
                                 "\(label): \(nine.holes.count) holes — expected 9 or 18",
                                 blocking: false))
            }
        }

        let ids = nines.flatMap { n in n.holes.map { "\(n.name ?? "")/\($0.ref)" } }
        if Set(ids).count != ids.count {
            out.append(Issue(.duplicateRef,
                             "two holes share a nine and a number — the nine name is probably missing"))
        }

        let all = holes
        if let bad = all.first(where: { $0.par < 3 || $0.par > 6 }) {
            out.append(Issue(.parOutOfRange, "hole \(bad.ref) has par \(bad.par)"))
        }

        // Handicaps are an allocation, so on a full 18 each row must be a
        // permutation of 1…18. A repeated stroke index is a misread column, not a
        // quirky course. Both American rows are checked — picking the women's
        // column for `handicap` passes on its own and is wrong for a men's match.
        let hcps = all.compactMap(\.handicap)
        if all.count == 18, hcps.count == 18, Set(hcps) != Set(1...18) {
            out.append(Issue(.handicapNotAPermutation,
                             "the 18 handicaps are not 1…18 exactly once — column probably misread"))
        }
        let womens = all.compactMap(\.handicapWomen)
        if all.count == 18, womens.count == 18, Set(womens) != Set(1...18) {
            out.append(Issue(.handicapNotAPermutation,
                             "the 18 women's handicaps are not 1…18 exactly once"))
        }
        if !womens.isEmpty, womens.count != hcps.count {
            out.append(Issue(.handicapNotAPermutation,
                             "a women's stroke index on only \(womens.count) of \(all.count) holes",
                             blocking: false))
        }

        let ds = all.flatMap { $0.tees.compactMap(\.distance) }
        if ds.isEmpty {
            out.append(Issue(.noDistances, "no tee distances found — the card gave par only",
                             blocking: false))
        } else if let bad = ds.first(where: { $0 < 60 || $0 > 700 }) {
            out.append(Issue(.distanceOutOfRange,
                             String(format: "a hole measures %.0f — outside 60…700", bad)))
        }
        return out
    }
}
