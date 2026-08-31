import SwiftUI
import GolfSessionFormat

/// Correcting an entry: what it says, and what it is about.
///
/// **A sheet rather than an inline field.** A log is a whole sentence, the
/// keyboard covers most of the list it came from, and the thing being corrected is
/// usually a misheard *name* — which needs to be read against the rest of the
/// sentence, not squinted at through a two-line row.
///
/// It saves a **superseding row**, never an edit in place. The original stays on
/// disk: it is what was actually heard, and a proposal already built on it cites
/// it by id.
///
/// ## Create and edit are one arrangement, differing in one thing
///
/// *(X15, user 2026-08-28: "creation dialog and edit dialog … is slightly
/// different as text edit is upon clicking for edit dialog, whereas for creation
/// it's default. Give me good arrangement on this.")*
///
/// Both carry the same three fields — hole, player, shot — in the same order, so
/// the two screens are the same screen and nothing has to be re-learnt. What
/// differs is **what the keyboard is for**:
///
/// - Creating (`MarkerSheet`), the sentence does not exist yet, so the text is the
///   whole point: the field is focused on arrival and the keyboard comes up with
///   the sheet.
/// - Editing (here), the sentence already exists and is usually *right*. The
///   common edit is a field, not the words — so the text is shown as text, and one
///   tap turns it into a field. Raising the keyboard over a sentence somebody only
///   wanted to file under a different player is the wrong default and hides the
///   fields underneath it.
struct LogEditor: View {
    let log: LogEntry
    /// The round's holes: playing index and `Hole.ref` as the card prints it.
    var holes: [(index: Int, ref: String)] = []
    var players: [Player] = []
    /// Text, hole, player, shot — whatever the golfer changed.
    let save: (String, Int?, String?, Int?) -> Void
    let cancel: () -> Void
    /// **Delete lives here too** *(user, 2026-08-28: "marker edit dialog: need
    /// delete")*. On the round screen a log is deleted by swiping its row; a marker
    /// on the hole view has no row to swipe, so before this the only way to remove
    /// one was to leave the map and find it in the list. Nil for callers that have
    /// their own delete affordance.
    var delete: (() -> Void)?

    @State private var draft: String
    @State private var hole: Int?
    @State private var player: String?
    @State private var shot: Int?
    /// **The one difference from the create dialog.** Editing starts read-only.
    @State private var editingText = false
    @State private var confirmingDelete = false
    @FocusState private var typing: Bool

    init(log: LogEntry,
         holes: [(index: Int, ref: String)] = [],
         players: [Player] = [],
         save: @escaping (String, Int?, String?, Int?) -> Void,
         cancel: @escaping () -> Void,
         delete: (() -> Void)? = nil) {
        self.log = log
        self.holes = holes
        self.players = players
        self.save = save
        self.cancel = cancel
        self.delete = delete
        _draft = State(initialValue: log.text)
        _hole = State(initialValue: log.hole)
        _player = State(initialValue: log.player)
        _shot = State(initialValue: log.shot)
    }

    private var holeRef: String {
        holes.first { $0.index == hole }?.ref ?? hole.map(String.init) ?? "—"
    }
    private var playerName: String? {
        player.flatMap { id in players.first { $0.id == id }?.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if editingText {
                        TextField("What happened", text: $draft, axis: .vertical)
                            .lineLimit(3...8)
                            .focused($typing)
                    } else {
                        // Tap turns it into a field — X13, "text editable upon
                        // clicking". Drawn as ordinary text so the sentence reads
                        // as a sentence, with the hint saying what a tap does; an
                        // affordance nobody can see is one nobody finds.
                        Button {
                            editingText = true
                            typing = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log.text)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text("Tap to edit")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("What was said")
                } footer: {
                    Text(footer)
                }

                Section("What it is about") {
                    Picker("Hole", selection: $hole) {
                        Text("No hole").tag(Int?.none)
                        ForEach(holes, id: \.index) { h in
                            Text(h.ref).tag(Int?.some(h.index))
                        }
                    }
                    Picker("Player", selection: $player) {
                        Text("Nobody").tag(String?.none)
                        ForEach(players) { p in
                            Text(p.name).tag(String?.some(p.id))
                        }
                    }
                    // **Clearing the player clears the number.** The stepper is
                    // merely disabled without one, so a shot number left behind
                    // would be written with nobody attached — a number ordered
                    // against nothing, which is exactly what `isShot` requiring
                    // both exists to prevent.
                    .onChange(of: player) { _, who in if who == nil { shot = nil } }
                    // **0 clears it** — the same rule the create sheet follows.
                    // Both fields are optional, and a number you cannot take back
                    // is not.
                    Stepper(value: Binding(get: { shot ?? 0 },
                                           set: { shot = $0 == 0 ? nil : $0 }),
                            in: 0...20) {
                        HStack {
                            Text("Shot")
                            Spacer()
                            Text(shot.map(String.init) ?? "—").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(player == nil)
                }

                if let delete {
                    Section {
                        // Confirmed, because it is destructive and the row above it
                        // is a stepper — a mis-tap on a phone in a glove is exactly
                        // what this dialog is used through.
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete this entry", systemImage: "trash")
                        }
                        .confirmationDialog("Delete this entry?",
                                            isPresented: $confirmingDelete,
                                            titleVisibility: .visible) {
                            Button("Delete", role: .destructive, action: delete)
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("It stops being shown. The original row stays in "
                               + "the round's log, so anything already read from it "
                               + "still quotes it.")
                        }
                    }
                }
            }
            .navigationTitle(log.isShot ? "\(holeRef) · shot \(log.shot ?? 0)" : "Entry")
            .navigationBarTitleDisplayMode(.inline)
            // **At the bottom, the same as the create sheet** *(user, 2026-08-28:
            // "cancel and ok should be at the bottom")*. The two dialogs are one
            // arrangement — that is X15's whole point — so the decision buttons
            // cannot sit in the toolbar on one and under the thumb on the other.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel, action: cancel)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("OK") { save(draft, hole, player, shot) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        // An entry may be emptied of *text* — "7: 2" is a real
                        // marker, the same rule the create sheet follows — but not
                        // of everything: with no hole and no player it would render
                        // as a blank capsule nobody can read.
                        .disabled(!changed || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                               && hole == nil && player == nil))
                }
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var changed: Bool {
        draft != log.text || hole != log.hole || player != log.player || shot != log.shot
    }

    /// Says what editing does and does not change. Worth the two lines: a user who
    /// thinks they have overwritten the transcription would not expect the
    /// original to still be quoted under an old proposal.
    private var footer: String {
        let heard = log.source == .spoken
            ? "This is what was heard; the original is kept."
            : "The original is kept."
        return heard + " Anything already read from it keeps quoting what was read."
    }
}
