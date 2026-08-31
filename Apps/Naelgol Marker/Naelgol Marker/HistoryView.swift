import SwiftUI
import GolfSessionFormat

/// What changed, when, and what it replaced — with undo.
///
/// **Two streams, merged, because there are deliberately two authorities.** Acts
/// on the round (scores, stats, handicaps, the roster, accepting a proposal) are
/// rows in `journal.jsonl`; edits to a log are superseding rows in `log.jsonl`,
/// because a log is model-visible and the journal is ground truth. Neither
/// duplicates the other, so this is the one place they are shown together —
/// merging happens in the view, not in the files.
///
/// Undone rows stay listed, struck through. That is the whole point: the sequence
/// is the record, and a history that hides what was reversed cannot be retraced.
struct HistoryView: View {
    @ObservedObject var doc: RoundDocument
    /// The number printed on the card for a playing-order index — on a course of
    /// named nines they are not the same thing.
    let holeLabel: (Int) -> String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing changed yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Scores, handicaps and edits appear here as you make them.")
                    }
                } else {
                    List(rows) { row in
                        HistoryRow(row: row, holeLabel: holeLabel, players: doc.players)
                            .swipeActions {
                                if let entry = row.journal, row.isLive {
                                    Button("Undo") { doc.undo(entry) }
                                        .tint(.orange)
                                }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Newest first — a history is read from the thing that just happened.
    private var rows: [HistoryEntry] {
        // **`inForce`, not `live`.** `live` drops every `.undo` row because replay
        // must not apply one as an act — using it here struck through every undo
        // and labelled it UNDONE, saying the opposite of what happened.
        let liveIDs = JournalReplay.inForce(doc.journal)
        let byID = Dictionary(doc.journal.map { ($0.id, $0) },
                              uniquingKeysWith: { _, b in b })
        var out = doc.journal.map {
            HistoryEntry(journal: $0, log: nil, t: $0.t,
                         isLive: liveIDs.contains($0.id),
                         undone: $0.undoes.flatMap { byID[$0] })
        }
        // Only *amendments* to a log — the original arrival is already the log
        // itself, and listing it here would make every dictated sentence appear
        // twice, once as a log and once as a change to nothing.
        out += doc.logs.filter { $0.supersedes != nil }
            .map { HistoryEntry(journal: nil, log: $0, t: $0.t, isLive: true,
                                undone: nil) }
        return out.sorted { $0.t == $1.t ? $0.id > $1.id : $0.t > $1.t }
    }
}

struct HistoryEntry: Identifiable {
    var journal: JournalEntry?
    var log: LogEntry?
    var t: Millis
    /// False when a live `.undo` has cancelled it. Still listed — struck through.
    var isLive: Bool
    /// For an `.undo` row: the entry it reversed, so the row can name it.
    var undone: JournalEntry?
    var id: String { journal?.id ?? log?.id ?? "\(t)" }
}

private struct HistoryRow: View {
    let row: HistoryEntry
    let holeLabel: (Int) -> String
    let players: [Player]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .strikethrough(!row.isLive)
                    .foregroundStyle(row.isLive ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(clock)
                    if !row.isLive { Text("UNDONE").fontWeight(.semibold) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var clock: String {
        let d = SessionClock.date(from: row.t)
        return d.formatted(date: .omitted, time: .shortened)
    }

    private func name(_ id: String?) -> String {
        guard let id else { return "—" }
        return players.first { $0.id == id }?.name ?? id
    }

    /// Names what was reversed rather than saying "an earlier change" — a history
    /// whose undo rows are interchangeable cannot be retraced, which is the one
    /// job it has.
    private var undoTitle: String {
        guard let target = row.undone else { return "Undid an earlier change" }
        switch target.act {
        case .setScore:
            let who = name(target.player)
            let h = target.hole.map { " on \(holeLabel($0))" } ?? ""
            return "Undid \(who)\(h): \(target.strokes.map(String.init) ?? "—")"
        case .setStat:      return "Undid \(target.stat?.label ?? "a detail")"
        case .setIndex:     return "Undid a handicap change"
        case .setTee:       return "Undid a tee change"
        case .acceptEvent:  return "Undid accepting a proposal"
        case .rejectEvent:  return "Undid rejecting a proposal"
        case .undo:         return "Redid a change"
        default:            return "Undid an earlier change"
        }
    }

    private var symbol: String {
        if row.log != nil { return row.log?.isDeleted == true ? "trash" : "pencil" }
        // An undo is drawn as the arrow whether or not it has itself been undone.
        switch row.journal?.act {
        case .setScore: return "number"
        case .setStat: return "list.bullet"
        case .setIndex, .setTee: return "figure.golf"
        case .addPlayer, .editPlayer, .removePlayer: return "person"
        case .setCourse: return "map"
        case .acceptEvent: return "checkmark"
        case .rejectEvent: return "xmark"
        case .undo, .none: return "arrow.uturn.backward"
        }
    }

    /// **Written from the row's own fields, never from a replay.** That is what
    /// `prevStrokes` and friends are for: re-deriving the whole round once per
    /// history row to render "5 → 6" would be quadratic, and a row that cannot be
    /// read on its own cannot be blamed.
    private var title: String {
        if let log = row.log {
            if log.isDeleted { return "Deleted a log" }
            return "Edited a log — \u{201C}\(log.text)\u{201D}"
        }
        guard let e = row.journal else { return "—" }
        let who = name(e.player)
        switch e.act {
        case .setScore:
            let to = e.strokes.map(String.init) ?? "—"
            let from = e.prevStrokes.map(String.init)
            let hole = e.hole.map { " on \(holeLabel($0))" } ?? ""
            return from.map { "\(who)\(hole): \($0) → \(to)" } ?? "\(who)\(hole): \(to)"
        case .setStat:
            let label = e.stat?.label ?? "stat"
            let to = e.statValue.map(String.init) ?? "—"
            let hole = e.hole.map { " on \(holeLabel($0))" } ?? ""
            return "\(who)\(hole): \(label) \(to)"
        case .setIndex:
            let to = e.index.map { String(format: "%.1f", $0) } ?? "none"
            return "\(who): handicap index \(to)"
        case .setTee:
            return "\(who): playing \(e.tee ?? "no tee")"
        case .addPlayer:   return "Added \(e.name ?? who)"
        case .editPlayer:  return "Renamed \(who) to \(e.name ?? who)"
        case .removePlayer: return "Removed \(who)"
        case .setCourse:   return "Course: \(e.course ?? "none")"
        case .acceptEvent: return "Accepted a proposal"
        case .rejectEvent: return "Rejected a proposal"
        case .undo:        return undoTitle
        }
    }
}
