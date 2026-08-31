import Foundation
import GolfSessionFormat

/// The columns of a scorecard, and what goes in the rows above the players.
///
/// In the package rather than the view because both halves have a way of being
/// quietly wrong on screen and exactly right in a screenshot: the column set
/// depends on how a course is *numbered*, and the yardage row depends on where a
/// course's numbers came from. Neither can be reviewed by looking at a phone.
public struct CardLayout: Sendable, Equatable {

    public enum Column: Sendable, Equatable, Hashable {
        /// A hole, by **1-based playing-order index** — which is what a scorecard
        /// column means, and deliberately not `Hole.ref`: a 27 has three holes
        /// called "1", so a ref cannot address a column.
        case hole(Int)
        /// Out / In, or a named nine. `holes` are playing-order indices.
        case subtotal(name: String, holes: [Int])
        case total
    }

    public var columns: [Column]
    /// The subtotal headings in order, for a caller that wants them separately.
    public var subtotals: [String]

    /// **Out / In is not the universal answer.** It assumes holes numbered 1–18,
    /// which is exactly what `Hole.ref` is not: a Korean 18 is two of three named
    /// nines each numbered 1–9 (천룡: 황룡 / 청룡 / 흑룡), and printing OUT and IN
    /// over them labels the second nine with a word the card does not use.
    ///
    /// So: named nines win when the course has them, Out/In is the fallback for a
    /// course numbered straight through, and a course of nine or fewer holes gets
    /// no subtotal at all — a single "Out" beside an identical "Total" is noise.
    public init(course: Course?) {
        let holes = course?.holes ?? []
        guard !holes.isEmpty else {
            self.columns = []
            self.subtotals = []
            return
        }

        var groups: [(name: String, holes: [Int])] = []
        let nines = course?.nines ?? []
        if nines.count >= 2 {
            for nine in nines {
                let idx = holes.enumerated().filter { $0.element.nine == nine }.map { $0.offset + 1 }
                if !idx.isEmpty { groups.append((nine, idx)) }
            }
        } else if holes.count > 9 {
            groups = [("Out", Array(1...9)), ("In", Array(10...holes.count))]
        }

        var columns: [Column] = []
        if groups.isEmpty {
            columns = (1...holes.count).map { .hole($0) }
        } else {
            for group in groups {
                columns.append(contentsOf: group.holes.map { Column.hole($0) })
                columns.append(.subtotal(name: group.name, holes: group.holes))
            }
        }
        columns.append(.total)

        self.columns = columns
        self.subtotals = groups.map(\.name)
    }

    /// Playing-order indices, in card order.
    public var holeIndices: [Int] {
        columns.compactMap { if case .hole(let i) = $0 { return i } else { return nil } }
    }
}

/// What goes in the yardage row — and how much to believe it.
///
/// **The row will be empty on a course imported from OpenStreetMap, which is most
/// of what exists today.** OSM never supplies yardage in any region: `dist` is on
/// 0.3% of US hole ways and 1.8% of Korean ones. Per-tee distance comes from a
/// card, and a card comes from a web page or a photograph.
///
/// The tempting fix is wrong twice over. Falling back to another tee's distance is
/// forbidden outright (`Hole.cardLength(from:)` returns nil for exactly this
/// reason — a number under the wrong tee's name is worse than a blank). And
/// falling back to the *measured* centre-line length silently substitutes a
/// different quantity: Corica hole 1 is 469 yd on the card and 426 measured,
/// because nobody carries the corner of a dogleg. So a measured number is offered,
/// **labelled as measured**, and the caller must render it differently.
public enum CardYardage: Sendable, Equatable {
    /// Per-tee distance off a real card. Metres, as everything stored is.
    case card(Double)
    /// The centre line walked, tee to green. A different quantity — shorter than
    /// the card on any dogleg — and it must never be printed as if it were a card
    /// number.
    case measured(Double)
    case none

    public var metres: Double? {
        switch self {
        case .card(let m), .measured(let m): return m
        case .none: return nil
        }
    }

    /// True when the number came from somewhere other than a card and the display
    /// has to say so.
    public var isApproximate: Bool { if case .measured = self { return true }; return false }

    /// - Parameter teeName: the tee the card is being read for. A hole with no such
    ///   tee yields `.measured` or `.none` — **never another tee's number.**
    public static func of(_ hole: Hole, teeName: String?) -> CardYardage {
        var tee: TeeBox?
        if let teeName {
            // **A named tee this hole does not have is `.none`, full stop.**
            // Passing nil on to `cardLength(from:)` does *not* mean "no tee" — it
            // means "the default tee", which is the longest one. So the obvious
            // `teeName.flatMap { hole.tee(named: $0) }` quietly prints Black's
            // yardage under the White heading: an ordinary-looking number, a club
            // and a half wrong, on the holes where a course does not offer every
            // tee. Caught by a test, not by reading it.
            guard let found = hole.tee(named: teeName) else { return .none }
            tee = found
        }
        if let d = hole.cardLength(from: tee) { return .card(d) }
        if let g = hole.geometry(tee: tee) { return .measured(g.measuredLength) }
        return .none
    }
}

extension Course {
    /// Tee names across the whole course, longest first by total card distance,
    /// falling back to the order they appear.
    ///
    /// Matched **case-insensitively**, because OSM tags `black`, an American card
    /// prints `BLACK` and the editor writes `Black`; `TeeBox.sameTee` is the same
    /// rule one level down. An exact match here would list one tee three times and
    /// let the picker select a set that only covers a third of the holes.
    public var teeNames: [String] {
        var order: [String] = []
        var totals: [String: Double] = [:]
        for hole in holes {
            for tee in hole.tees {
                let existing = order.first { TeeBox.sameTee($0, tee.name) }
                let key = existing ?? tee.name
                if existing == nil { order.append(tee.name) }
                totals[key, default: 0] += tee.distance ?? 0
            }
        }
        return order.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
    }
}
