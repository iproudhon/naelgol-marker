import SwiftUI
import GolfSessionFormat
import GolfCourse

/// One player, one hole: the score, and the second-rank numbers behind it.
///
/// **Second rank is a statement about the screen, not about the data** *(user,
/// 2026-08-27)*. Putts, GIR, fairway, OB and hazard journal, undo and blame
/// exactly like a score does — they simply do not belong in the grid, which has
/// room for eighteen columns of one number and is read at arm's length while
/// walking. So the card shows the stroke and a cell opens to reveal the rest.
///
/// Everything here writes a `JournalEntry`. There is no path from this screen to
/// `scorecard.json` — that file is a derived snapshot.
struct HoleDetailSheet: View {
    @ObservedObject var doc: RoundDocument
    let cell: ScorecardBand.Cell
    let player: Player?
    let hole: Hole?
    /// Strokes this player receives here, allocated by stroke index. Shown rather
    /// than assumed: it is what turns a 5 into a net 4 and it comes from two
    /// numbers the user cannot see from this screen.
    let received: Int

    @Environment(\.dismiss) private var dismiss

    private var score: Int? { doc.score(player: cell.player, hole: cell.hole) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: Binding(get: { score ?? 0 },
                                           set: { set($0) }),
                            in: 0...15) {
                        HStack {
                            Text("Score")
                            Spacer()
                            Text(score.map { "\($0)" } ?? "—")
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                    if let score, received > 0 {
                        LabeledContent("Net") {
                            Text("\(score - received)")
                                .monospacedDigit()
                        }
                    }
                    if score != nil {
                        Button("Clear score", role: .destructive) { set(0) }
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text(scoreFooter)
                }

                Section {
                    ForEach(JournalEntry.Stat.allCases, id: \.self) { stat in
                        row(stat)
                    }
                } header: {
                    Text("Detail")
                } footer: {
                    Text("Optional. Every one of these is journaled, so it can be "
                       + "undone and traced like a score.")
                }
            }
            .navigationTitle(player?.name ?? cell.player)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func row(_ stat: JournalEntry.Stat) -> some View {
        let value = doc.stat(stat, player: cell.player, hole: cell.hole)
        if stat.isCount {
            Stepper(value: Binding(get: { value ?? 0 },
                                   set: { doc.setStat(stat, player: cell.player,
                                                      hole: cell.hole,
                                                      value: $0 == 0 ? nil : $0) }),
                    in: 0...10) {
                HStack {
                    Text(stat.label)
                    Spacer()
                    Text(value.map { "\($0)" } ?? "—").monospacedDigit()
                        .foregroundStyle(value == nil ? .secondary : .primary)
                }
            }
        } else {
            // Three-valued, not two: **unrecorded is not the same as "no"**. A
            // plain toggle would write "missed the fairway" for every hole nobody
            // has looked at, and a GIR percentage computed off that is a lie made
            // of defaults.
            // **The label goes beside it, not into the `Picker`.** A segmented
            // picker in a `Form` discards its own label, so the row rendered as a
            // bare — / No / Yes with nothing saying which stat it was. Caught by
            // screenshot, 2026-08-27.
            HStack {
                Text(stat.label)
                Spacer(minLength: 12)
                Picker(stat.label, selection: Binding(
                    get: { value.map { $0 > 0 ? 1 : 0 } ?? -1 },
                    set: { doc.setStat(stat, player: cell.player, hole: cell.hole,
                                       value: $0 < 0 ? nil : $0) })) {
                    Text("—").tag(-1)
                    Text("No").tag(0)
                    Text("Yes").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private var title: String {
        let where_ = hole.map { h in h.nine.map { "\($0) \(h.ref)" } ?? h.ref }
            ?? "\(cell.hole)"
        let par = hole.map { " · par \($0.par)" } ?? ""
        return "Hole \(where_)\(par)"
    }

    private var scoreFooter: String {
        guard received > 0 else { return "" }
        let s = received == 1 ? "stroke" : "strokes"
        let si = hole?.handicap.map { ", stroke index \($0)" } ?? ""
        return "Receives \(received) \(s) here\(si)."
    }

    /// Zero clears rather than recording a nought — nobody holes out in no shots,
    /// so the stepper's floor is the way back to an empty cell.
    private func set(_ strokes: Int) {
        doc.setScore(player: cell.player, hole: cell.hole,
                     strokes: strokes == 0 ? nil : strokes)
    }
}
