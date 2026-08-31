import SwiftUI
import GolfSessionFormat
import GolfCourse

/// The card, across the top of the round screen.
///
/// A real scorecard: hole number, yardage, par, stroke index, then a row per
/// player, with the subtotals the course actually uses. It scrolls sideways
/// because eighteen holes plus subtotals will never fit a phone, and **tapping a
/// hole column is the hole selector** — a separate control for something the user
/// is already pointing at is a control too many.
///
/// Column structure and the yardage row come from `CardLayout` / `CardYardage` in
/// the package, where they are tested. Both have a way of being quietly wrong on
/// screen and exactly right in a screenshot.
struct ScorecardBand: View {
    @ObservedObject var doc: RoundDocument
    let course: Course?
    @Binding var hole: Int
    /// Which tee the yardage row is read for. Per-tee is the only kind of yardage
    /// there is; a card has one column per tee.
    @Binding var teeName: String?

    @AppStorage("marker.units.yards") private var yards = true
    /// Show net rather than gross. **Off by default**: gross is what was actually
    /// struck, and a card silently showing net numbers is a card that disagrees
    /// with what everyone remembers shooting.
    @AppStorage("marker.card.net") private var net = false

    /// The cell whose second-rank numbers are open — putts, GIR, fairway, OB,
    /// hazard. See `JournalEntry.Stat`: those are first-class data behind a
    /// long-press, not a row in the grid.
    @State private var editingCell: Cell?

    struct Cell: Identifiable, Equatable {
        let player: String
        let hole: Int
        var id: String { "\(player)@\(hole)" }
    }

    private var layout: CardLayout { CardLayout(course: course) }
    private var holes: [Hole] { course?.holes ?? [] }

    /// player id -> hole -> strokes received. Computed once per body rather than
    /// per cell: `Handicap.strokesReceived` sorts the whole course, and doing that
    /// inside a cell is eighteen sorts per player per redraw.
    private var received: [String: [Int: Int]] {
        guard net || anyHandicap else { return [:] }
        var out: [String: [Int: Int]] = [:]
        for p in doc.players {
            let r = doc.strokesReceived(of: p.id, holes: holes)
            if !r.isEmpty { out[p.id] = r }
        }
        return out
    }

    private var anyHandicap: Bool {
        doc.players.contains { doc.courseHandicap(of: $0.id) != nil }
    }

    private enum Metrics {
        static let cell: CGFloat = 34
        static let label: CGFloat = 74
        static let row: CGFloat = 22
    }

    var body: some View {
        if layout.columns.isEmpty {
            noCourse
        } else {
            HStack(spacing: 0) {
                labels
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(layout.columns.enumerated()), id: \.offset) { _, column in
                                cell(column)
                            }
                        }
                    }
                    .onChange(of: hole) { _, new in
                        withAnimation { proxy.scrollTo("col-\(new)", anchor: .center) }
                    }
                    .onAppear { proxy.scrollTo("col-\(hole)", anchor: .center) }
                }
            }
            .font(.caption2.monospacedDigit())
            .background(Color(.secondarySystemBackground))
            .sheet(item: $editingCell) { cell in
                HoleDetailSheet(doc: doc, cell: cell,
                                player: doc.players.first { $0.id == cell.player },
                                hole: holes.indices.contains(cell.hole - 1)
                                    ? holes[cell.hole - 1] : nil,
                                received: received[cell.player]?[cell.hole] ?? 0)
            }
        }
    }

    /// Gross or net. Only offered when somebody actually has a course handicap —
    /// a Net toggle that changes nothing is a control that looks broken.
    var canShowNet: Bool { anyHandicap }

    // MARK: - Left column

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("HOLE", bold: true)
            row(yardageHeading)
            row("PAR")
            row("HCP")
            ForEach(doc.players) { p in
                row(p.name.uppercased(), bold: true)
            }
        }
        .frame(width: Metrics.label, alignment: .leading)
        .padding(.leading, 10)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator)).frame(width: 0.5)
        }
    }

    /// The heading says which tee, because a yardage with no tee beside it is a
    /// number from nowhere — and it is tappable, because a group rarely all plays
    /// the same tees.
    private var yardageHeading: String {
        let unit = yards ? "YDS" : "M"
        guard let teeName else { return unit }
        return "\(unit) · \(teeName.uppercased())"
    }

    private func row(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(bold ? Color.primary : .secondary)
            .frame(height: Metrics.row, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Columns

    @ViewBuilder private func cell(_ column: CardLayout.Column) -> some View {
        switch column {
        case .hole(let i): holeColumn(i)
        case .subtotal(let name, let holes): totalColumn(name, holes: holes)
        case .total: totalColumn("TOT", holes: layout.holeIndices)
        }
    }

    private func holeColumn(_ index: Int) -> some View {
        let h = index >= 1 && index <= holes.count ? holes[index - 1] : nil
        let selected = index == hole
        return VStack(spacing: 0) {
            // The *ref*, not the index — on a course of named nines the card says
            // 3, and the column that is "hole 12 of 18" to us is "3" to the golfer.
            value(h?.ref ?? "\(index)", bold: true)
            value(yardage(h))
            value(h.map { "\($0.par)" } ?? "—")
            value(h?.handicap.map { "\($0)" } ?? "—")
            ForEach(doc.players) { p in
                scoreCell(player: p, hole: index, par: h?.par,
                          received: received[p.id]?[index] ?? 0)
            }
        }
        .frame(width: Metrics.cell)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { hole = index }
        .id("col-\(index)")
    }

    private func totalColumn(_ name: String, holes idx: [Int]) -> some View {
        VStack(spacing: 0) {
            value(name.uppercased(), bold: true)
            value(totalYardage(idx))
            value("\(idx.compactMap { holes.indices.contains($0 - 1) ? holes[$0 - 1].par : nil }.reduce(0, +))")
            value("")
            ForEach(doc.players) { p in
                let strokes = idx.compactMap { h -> Int? in
                    guard let g = doc.score(player: p.id, hole: h) else { return nil }
                    return net ? g - (received[p.id]?[h] ?? 0) : g
                }
                let total = strokes.reduce(0, +)
                value(total > 0 ? "\(total)" : "—", bold: true)
            }
        }
        .frame(width: Metrics.cell + 8)
        .background(Color(.tertiarySystemBackground))
    }

    private func value(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .fontWeight(bold ? .semibold : .regular)
            .frame(height: Metrics.row)
            .frame(maxWidth: .infinity)
    }

    /// A score cell shows the stroke and colours it against par, the way a card
    /// is read. Tapping bumps it; long-pressing clears it. **Entered, never
    /// inferred** — this is the answer key `GolfEval` scores against.
    private func scoreCell(player: Player, hole index: Int, par: Int?,
                           received: Int) -> some View {
        let strokes = doc.score(player: player.id, hole: index)
        // Net is gross minus what this player receives *on this hole*, allocated
        // by stroke index. The colour still reads against par either way — a net
        // birdie is a birdie on the card the group is playing off.
        let shown = strokes.map { net ? $0 - received : $0 }
        let hasStats = JournalEntry.Stat.allCases.contains {
            doc.stat($0, player: player.id, hole: index) != nil
        }
        return ZStack(alignment: .topTrailing) {
            Text(shown.map { "\($0)" } ?? "·")
                .fontWeight(strokes == nil ? .regular : .semibold)
                .foregroundStyle(colour(strokes: shown, par: par))
                .frame(height: Metrics.row)
                .frame(maxWidth: .infinity)
            // A stroke received is marked the way a card marks it: a dot in the
            // corner, one per stroke. It is why a 5 can be a net 4 and the number
            // alone cannot say so.
            //
            // **Only where there is a score.** An empty cell already draws a
            // centre dot as its placeholder, so a second dot beside it reads as a
            // duplicate rather than an allocation — and on a 22 handicap that is
            // two extra dots in every unplayed column, which is most of the card
            // for most of the round. Screenshotted 2026-08-27 and it was unreadable.
            if received > 0 && !net && strokes != nil {
                Text(String(repeating: "\u{2022}", count: min(received, 2)))
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .offset(x: -2, y: 1)
            }
            // Something is recorded behind this cell.
            if hasStats {
                Rectangle().fill(Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 1.5)
                    .offset(y: Metrics.row - 4)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(height: Metrics.row)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // Bumps the **gross** score whatever the card is displaying —
            // incrementing a net number would write a stroke count nobody played.
            doc.setScore(player: player.id, hole: index,
                         strokes: min((strokes ?? par.map { $0 - 1 } ?? 0) + 1, 15))
        }
        .onLongPressGesture {
            // Long-press used to clear the cell. It now **opens** it: clearing is
            // one tap inside, and a destructive action on a gesture with no
            // confirmation was one slip away from deleting a hole's score.
            editingCell = Cell(player: player.id, hole: index)
        }
    }

    private func colour(strokes: Int?, par: Int?) -> Color {
        guard let strokes, let par else { return strokes == nil ? .secondary : .primary }
        switch strokes - par {
        case ..<0: return .red          // birdie or better, the way a card prints it
        case 0: return .primary
        case 1: return .primary
        default: return .blue
        }
    }

    // MARK: - Yardage

    /// Blank rather than wrong when there is no card, and **marked when the number
    /// is a measured centre line rather than a card yardage** — those are different
    /// quantities (Corica hole 1: 469 on the card, 426 measured, because nobody
    /// carries the corner of a dogleg). A `~` is the whole marking, but it is the
    /// difference between a number and a claim.
    private func yardage(_ hole: Hole?) -> String {
        guard let hole else { return "—" }
        let y = CardYardage.of(hole, teeName: teeName)
        guard let m = y.metres else { return "—" }
        let n = Int((yards ? m / 0.9144 : m).rounded())
        return y.isApproximate ? "~\(n)" : "\(n)"
    }

    private func totalYardage(_ idx: [Int]) -> String {
        var total = 0.0
        var any = false
        var approximate = false
        for i in idx where holes.indices.contains(i - 1) {
            let y = CardYardage.of(holes[i - 1], teeName: teeName)
            guard let m = y.metres else { continue }
            any = true
            approximate = approximate || y.isApproximate
            total += m
        }
        guard any else { return "—" }
        let n = Int((yards ? total / 0.9144 : total).rounded())
        return approximate ? "~\(n)" : "\(n)"
    }

    private var noCourse: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells").foregroundStyle(.secondary)
            Text("No course file for this round — pick one to get a card.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }
}
