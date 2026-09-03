import SwiftUI
import GolfSessionFormat
import GolfMap

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

    /// `steve · Hole 4 · 4th: on in two` — see `LogTitle`, which the entry list
    /// uses too *(user, 2026-09-03)*.
    ///
    /// Built from **the fields as they currently stand**, not from the row on disk:
    /// the title answers "what am I editing", so it has to follow a player being
    /// picked.
    private var title: String {
        LogTitle.of(player: playerName, holeRef: hole == nil ? nil : holeRef,
                    shot: shot, text: draft)
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
                        // as a sentence. **The "Tap to edit" hint is gone** *(user,
                        // 2026-09-03: "no label needed")*: it was a caption under
                        // every entry explaining a tap, on a screen whose rows are
                        // all tappable.
                        Button {
                            editingText = true
                            // **Focus on the next turn, never in the same one**
                            // *(user, 2026-09-03: "text box in marker editor is not
                            // editable")*. `@FocusState` names a field that has to
                            // *exist*: assigning it in the same update that flips
                            // `editingText` targets a `TextField` SwiftUI has not
                            // built yet, so the assignment is dropped and the tap
                            // produces a field with no keyboard — which reads as a
                            // box that cannot be typed in. Same shape as
                            // `HoleScreen.bump`'s clear and `centerOn`'s reset.
                            Task { @MainActor in typing = true }
                        } label: {
                            // **A placeholder when there is nothing to read.** A
                            // marker filed from the Action Button has no text at
                            // all *(user, 2026-09-03: "empty string is fine")*, and
                            // an empty row is one nobody can tell is tappable. This
                            // is not the "Tap to edit" caption that was removed —
                            // that sat under a sentence that was already there.
                            Text(log.text.isEmpty ? "Add a note" : log.text)
                                .foregroundStyle(log.text.isEmpty ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 22,
                                       alignment: .leading)
                                // The whole row is the target. An empty marker's
                                // label is a few words wide and the rest of the row
                                // was dead space, which is most of what a thumb
                                // lands on.
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
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

            }
            // **The title says what the entry is about** *(user, 2026-09-03:
            // "Player name · Hole # · Shot #")*. It replaces the two section
            // headers that used to say it in words — the fields are directly
            // underneath and label themselves.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // **Delete is a top-level button** *(user, 2026-09-03)*. It was the
            // last row of the form, under a stepper and below the fold on a short
            // screen. **Still confirmed**: moving it to the navigation bar makes a
            // mis-tap easier, not harder, and it is used through a glove.
            .toolbar {
                if let delete {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete", systemImage: "trash")
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

}
