import SwiftUI
import GolfSessionFormat
import GolfCourse

/// One player's name, the names they answer to, their handicap index and their tee.
///
/// **Three numbers, and only two of them are stored.** The index is the player's
/// own and is portable; the tee carries the USGA rating and slope **frozen as they
/// are now**; the course handicap is derived from the two and never written down.
/// Re-importing a course later must not rewrite a card already played, which is
/// exactly what would happen if the rating were read from the course file at
/// display time.
///
/// The rating and slope are shown, not just used. A course handicap that appears
/// from nowhere is unarguable; one printed beside the two numbers it came from is
/// checkable — and most course files here have neither, in which case there is no
/// course handicap and the screen says so rather than inventing one.
struct PlayerEditor: View {
    @ObservedObject var doc: RoundDocument
    let player: Player
    let course: Course?

    @State private var name: String = ""
    @State private var aliases: String = ""
    @State private var indexText: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit(commitName)
                TextField("Also called", text: $aliases)
                    .onSubmit(commitName)
            } header: {
                Text("Name")
            } footer: {
                // Attribution matches what was *said* against every name a player
                // answers to, never a roster position.
                Text("Comma separated. A player is often \u{201C}steve\u{201D} on the card and "
                   + "something else out loud, sometimes inside one hole.")
            }

            Section {
                HStack {
                    Text("Index")
                    Spacer()
                    TextField("none", text: $indexText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .onSubmit(commitIndex)
                }
                teePicker
                LabeledContent("Course handicap") {
                    Text(courseHandicapText)
                        .foregroundStyle(doc.courseHandicap(of: player.id) == nil
                                         ? .secondary : .primary)
                }
            } header: {
                Text("Handicap")
            } footer: {
                Text(handicapFooter)
            }
        }
        .navigationTitle(player.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = player.name
            aliases = player.aliases.joined(separator: ", ")
            indexText = doc.index(of: player.id).map { String(format: "%.1f", $0) } ?? ""
        }
        // A Form field that only commits on Submit loses whatever was typed when
        // the user swipes back, which on this screen is most of the time. Both in
        // one `record` so leaving the screen is one replay, not two.
        .onDisappear {
            doc.record([nameEntry(), indexEntry()].compactMap { $0 })
        }
    }

    @ViewBuilder private var teePicker: some View {
        if let course, !course.teeNames.isEmpty {
            Picker("Tee", selection: Binding(
                get: { doc.tee(of: player.id)?.name ?? "" },
                set: { pick($0) })) {
                Text("None").tag("")
                ForEach(course.teeNames, id: \.self) { Text($0).tag($0) }
            }
        } else {
            LabeledContent("Tee") {
                Text(doc.tee(of: player.id)?.name ?? "no course file")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var courseHandicapText: String {
        doc.courseHandicap(of: player.id).map(String.init) ?? "—"
    }

    private var handicapFooter: String {
        guard let tee = doc.tee(of: player.id) else {
            return "Pick a tee to get a course handicap."
        }
        if let r = tee.rating, let s = tee.slope {
            return String(format: "%@ is rated %.1f / %d, frozen as played — "
                          + "re-importing the course will not change this card.",
                          tee.name, r, s)
        }
        return "\(tee.name) has no course rating or slope, so there is no course "
             + "handicap. A number invented without them would be several shots wrong."
    }

    // MARK: -

    private func commitName() { doc.record(nameEntry().map { [$0] } ?? []) }
    private func commitIndex() { doc.record(indexEntry().map { [$0] } ?? []) }

    /// Nil when nothing changed — an unchanged field must not write a journal row,
    /// or every visit to this screen leaves two entries in the history.
    private func nameEntry() -> JournalEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty,
              trimmed != player.name || list != player.aliases else { return nil }
        return JournalEntry(act: .editPlayer, player: player.id,
                            name: trimmed, aliases: list)
    }

    private func indexEntry() -> JournalEntry? {
        let trimmed = indexText.trimmingCharacters(in: .whitespaces)
        // An empty field means "no index", which is a real answer — a casual round
        // has none — and is not the same as zero, which is scratch.
        let value = trimmed.isEmpty ? nil : Double(trimmed)
        guard value != doc.index(of: player.id) else { return nil }
        return JournalEntry(act: .setIndex, player: player.id, index: value,
                            prevIndex: doc.index(of: player.id))
    }

    /// Freezes the rating and slope at the moment of choosing. `par` is the
    /// course's own total, which is what the rating was measured against.
    private func pick(_ teeName: String) {
        guard !teeName.isEmpty else {
            doc.setTee(player: player.id, tee: nil, par: nil)
            return
        }
        let box = course?.holes
            .flatMap(\.tees)
            .first { TeeBox.sameTee($0.name, teeName) }
        let par = course.map { $0.holes.reduce(0) { $0 + $1.par } }
        doc.setTee(player: player.id, tee: box.map {
            TeeBox(name: teeName, rating: $0.rating, slope: $0.slope)
        }, par: par)
    }
}
