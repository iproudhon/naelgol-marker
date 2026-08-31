import SwiftUI
import GolfSessionFormat
import GolfCourse

/// Who is playing this round.
///
/// **This did not exist, and its absence is what caused a bug report.** The roster
/// was fixed at round start and there was no control anywhere to change it, so the
/// first person who wanted to set one reached for the only free-text box on the
/// screen — the log input — and typed "Players are A, B, C, D". That is an
/// observation with no shot and no score in it, so extraction found nothing,
/// recorded nothing, and re-read it on every trigger *(2026-08-27)*.
///
/// Everything here is a journal act, so adding or removing a player is undoable
/// and appears in History like a score.
///
/// **Removing keeps the scores.** `JournalReplay` does not delete them, so a player
/// removed by mistake and added back returns to their card — which is the whole
/// point of the journal.
struct RosterEditor: View {
    @ObservedObject var doc: RoundDocument
    let course: Course?

    @State private var draft = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(doc.players) { p in
                        NavigationLink {
                            PlayerEditor(doc: doc, player: p, course: course)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                if !p.aliases.isEmpty {
                                    Text(p.aliases.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        doc.record(offsets.map {
                            JournalEntry(act: .removePlayer, player: doc.players[$0].id)
                        })
                    }
                } header: {
                    Text("Playing")
                } footer: {
                    Text("Removing someone keeps their scores, so putting them back "
                       + "restores the card.")
                }

                Section {
                    HStack {
                        TextField("Name", text: $draft)
                            .focused($typing)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(names(in: draft).isEmpty)
                    }
                } header: {
                    Text("Add")
                } footer: {
                    // Several at once, because that is how anyone types a foursome
                    // and it is what the person who filed this was trying to do.
                    Text("One name, or several separated by commas — \u{201C}A, B, C, D\u{201D}. "
                       + "Nicknames go on each player's own screen; attribution "
                       + "matches what was said against every name they answer to.")
                }
            }
            .navigationTitle("Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// One journal row per player, in one `record`, so the whole foursome is a
    /// single replay and each name is still undoable on its own.
    private func add() {
        let existing = Set(doc.players.map { $0.id.lowercased() })
        let rows = names(in: draft)
            .filter { !existing.contains($0.lowercased()) }
            .map { JournalEntry(act: .addPlayer, player: $0, name: $0) }
        guard !rows.isEmpty else { draft = ""; return }
        doc.record(rows)
        draft = ""
        typing = true
    }

    /// Splits on commas **and** on the word "and", and strips a leading
    /// "players are" / "playing with" — because that is what someone types when
    /// they mean a roster, and refusing it would send them back to the input box.
    ///
    /// This is a **fixed prefix and a separator**, not a parser. It never reaches
    /// the model and it never guesses at anything else; a sentence it does not
    /// recognise simply becomes one player with a long name, which is visible and
    /// one swipe to delete.
    private func names(in text: String) -> [String] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["players are", "players:", "playing with", "the players are"] {
            if body.lowercased().hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count))
                break
            }
        }
        return body
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
