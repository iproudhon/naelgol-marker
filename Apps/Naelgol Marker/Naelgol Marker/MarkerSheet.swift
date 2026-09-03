import SwiftUI
import GolfSessionFormat
import GolfCourse
import GolfCaptureCore
import GolfTranscription
import CoreLocation

/// What the Marker button opens: **either** our own recording, **or** the phone's
/// keyboard. One at a time.
///
/// *(User, 2026-08-28: "when marker view is on, it's either our own recording or
/// iphone input text view. Not both." This corrects a first version that put the
/// live pane and the text field on one surface — X1's "either … or" is two modes
/// after all.)*
///
/// **They are two modes because they are two recognizers.** Speak runs
/// `WhisperLiveTranscriber` off our own tap; Type hands the sentence to the iOS
/// keyboard, which has its own dictation button. Running both means two things
/// listening to one voice and two log entries for one sentence — so switching to
/// Type **closes the burst** rather than leaving it open behind the keyboard.
///
/// Speak is the default: it is the mode the product exists for, and the one that
/// works with the phone in a pocket and a glove on.
///
/// > **Closing the sheet ends the burst.** A burst that outlives the surface showing
/// > it is the failure the record button's own doc comment warns about: a live
/// > microphone with nothing on screen saying so. The orange dot is the only
/// > remaining signal and it is not one this app should rely on.
///
/// > **The sheet is also the fast-tracking window** *(user, 2026-08-28)*. The hole
/// > view used to go fast merely for being open, which is most of a round; a golfer
/// > reading a yardage does not need a fix a second, and a golfer saying what just
/// > happened does. Both feeds escalate here and drop back on the way out — the
/// > recorded track through `RoundViewModel.trackFast`, the view's own through
/// > `LiveLocation`.
@MainActor
struct MarkerSheet: View {
    @ObservedObject var model: RoundViewModel
    @ObservedObject var live: LiveTranscript
    @ObservedObject var doc: RoundDocument
    /// The round-independent feed. Escalated with the sheet, not with the hole view.
    @ObservedObject var location: LiveLocation

    /// Which hole a typed log belongs to. Nil means the golfer is looking at all
    /// holes, which is a real answer — `LogEntry.hole` is "nearest hole to a
    /// measured fix", and a row with no hole is drawn on every hole rather than none.
    var hole: Int?
    var holeRef: String
    /// The round's holes as the card prints them — playing index and `Hole.ref`.
    ///
    /// **Handed in rather than looked up.** The course lives in `CourseLibrary` and
    /// in the round's own `meta.json`, and reading the library here is exactly what
    /// once put another round's course on this round's screen. The caller already
    /// knows which course this round is on; it passes the list.
    var holes: [(index: Int, ref: String)] = []
    /// The round this sheet writes to. Needed because opening the sheet on a
    /// **finished** round reopens it first.
    var roundID: String
    /// **X3** *(user, 2026-08-28: "when simulated position is on, use the location
    /// for marker")*. Where the hole view says the golfer is, which while simulating
    /// is the dragged point rather than the phone's own fix. Nil everywhere else, so
    /// the ordinary path is untouched.
    ///
    /// > It **overrides the stabilised fix as well**, and that is the point:
    /// > simulating exists to try the app somewhere other than where the phone is,
    /// > and a log that quietly recorded the desk instead would make the whole mode
    /// > useless. The consequence is real and worth knowing — a hand-placed
    /// > coordinate then sits in `log.jsonl` looking exactly like a measured one,
    /// > because `LogEntry` has no discriminator for it. `Mark` is protected from
    /// > this by MARK being disabled while simulating; a log is not, because a log
    /// > is an observation rather than ground truth.
    var override: Coordinate?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// **Remembered** *(user, 2026-08-28)*. Which way a golfer records is a habit,
    /// not a per-sentence decision — someone who types every entry should not have
    /// to switch modes eighteen times a round.
    @AppStorage("marker.input.mode") private var modeRaw = Mode.speak.rawValue
    private var mode: Mode {
        get { Mode(rawValue: modeRaw) ?? .speak }
        nonmutating set { modeRaw = newValue.rawValue }
    }
    /// Whether a burst ran at all, so the teardown knows whether the recorded track
    /// is already spoken for. After a burst `stopListening` deliberately stays fast
    /// and `handBackRadio` drops it once placement is done; forcing slow here would
    /// ask for ten-metre fixes during the fifteen seconds the app is specifically
    /// waiting for a three-metre one.
    @State private var recorded = false
    /// The stabilized fix — **final once it arrives** *(user, 2026-08-28: "keep
    /// updating location until it's stabilized, once stabilized, it's final, and
    /// change it back to slow")*. Every log this sheet writes after that point uses
    /// it rather than asking the radio again.
    @State private var settled: (Coordinate, Double)?
    @State private var settling: Task<Void, Never>?
    @FocusState private var typing: Bool

    // MARK: - X15 — what this entry is about

    /// Which hole, which player, which shot. **Filled in rather than guessed**
    /// *(X15, user 2026-08-28)*.
    ///
    /// The hole is pre-assigned to the one on screen and is written with
    /// `holeSource: .user`, which is what stops `LogPlacement` recomputing it into
    /// a different fairway fifteen seconds later — see `LogEntry.HoleSource`.
    @State private var chosenHole: Int?
    @State private var chosenPlayer: String?
    @State private var chosenShot: Int?
    /// Chain roots the **typed** path wrote this visit.
    ///
    /// Cancel never sees these, and that is not an oversight: `send()` dismisses the
    /// sheet in Type mode, because a typed entry is one deliberate sentence with a
    /// full stop on it. So a typed entry is committed the moment it is sent, and
    /// what Cancel takes back is what the *microphone* wrote — which the golfer
    /// never chose sentence by sentence. Kept because `place()` and any later
    /// stamping need to know what this visit produced.
    @State private var written: [String] = []

    /// **The round's roster, not the setup screen's.** `state.players` is what a
    /// mid-round `RosterEditor` edit changes, and it is the answer everywhere else
    /// on screen.
    private var roster: [Player] { doc.players }
    private var playerName: String? {
        chosenPlayer.flatMap { id in roster.first { $0.id == id }?.name }
    }
    /// Holes to choose from, as the card prints them — `Hole.ref` is "황룡/3" on a
    /// Korean 27, and the playing index is what `LogEntry.hole` stores.
    private var holeChoices: [(index: Int, ref: String)] { holes }
    private var chosenHoleRef: String {
        holeChoices.first { $0.index == chosenHole }?.ref ?? holeRef
    }

    enum Mode: String, CaseIterable, Identifiable {
        case speak, type
        var id: String { rawValue }
        var label: String { self == .speak ? "Speak" : "Type" }
        var symbol: String { self == .speak ? "waveform" : "keyboard" }
    }

    private var interrupted: Bool { model.audioState == .interrupted }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: Binding(get: { mode },
                                              set: { mode = $0 })) {
                    ForEach(Mode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                fields

                switch mode {
                case .speak:
                    transcriptPane
                    Spacer(minLength: 0)
                    markRow
                case .type:
                    typeArea
                }
            }
            .padding(.vertical, 10)
            .navigationTitle(hole == nil ? "Marker" : "Marker · \(holeRef)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { decision }
        }
        .task { await enter() }
        // **Switching mode is switching recognizer.** Type closes the burst rather
        // than leaving it running behind the keyboard: two things listening to one
        // voice is two log entries for one sentence.
        .onChange(of: modeRaw) { _, raw in
            let m = Mode(rawValue: raw) ?? .speak
            Task {
                if m == .type {
                    await model.stopListening()
                    typing = true          // the keyboard is the mode
                } else {
                    typing = false
                    await begin()
                }
            }
        }
        // `.large` while typing: the medium detent plus a keyboard leaves about two
        // lines of what is being written visible.
        .presentationDetents(mode == .type ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        // Swiping the sheet away is the same act as Done and must have the same
        // effect, or a swipe leaves the microphone open behind a dismissed screen.
        .onDisappear { Task { await leave() } }
    }

    /// **OK and Cancel, at the bottom** *(user, 2026-08-28: "cancel and ok should
    /// be at the bottom")*.
    ///
    /// They were toolbar items, which is where iOS puts them by default and the
    /// wrong place here: this sheet is operated one-handed with a glove on, and the
    /// two buttons that decide what happens to the entry were the furthest things
    /// on the screen from the thumb. `.safeAreaInset` rather than `.bottomBar`, so
    /// they ride above the keyboard in Type mode instead of behind it.
    ///
    /// **OK and Cancel, not Done** *(X15)*. "Done" says the sheet is finished and
    /// says nothing about what happens to what is in it; with fields to fill in,
    /// the golfer needs to know which button keeps the entry and which throws it
    /// away.
    private var decision: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) { Task { await discard() } }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            Button("OK") { Task { await finish() } }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// Hole, player and shot — two rows, above whichever recogniser is running.
    ///
    /// **Above both modes rather than inside one**, because they describe the entry
    /// and not the way it was captured: a golfer who speaks the sentence and one who
    /// types it are filing the same thing.
    ///
    /// **The players run across, not down** *(user, 2026-08-28: "player names should
    /// be horrizontally arranged" — correcting the column this had for one
    /// afternoon; the vertical arrangement they had asked for was the legend on the
    /// hole view, which is a different control doing a different job)*. Hole and
    /// shot take the top line, the roster the one under it, so a four-player roster
    /// costs one row rather than four and the transcript pane keeps its height at
    /// the medium detent.
    ///
    /// **Both the player and the shot number are optional, and either can be put
    /// back to blank** *(user, 2026-08-28)*. The number still needs a player —
    /// a shot with nobody attached cannot be ordered against anything, which is what
    /// `LogEntry.isShot` requiring both exists to prevent — but picking a player no
    /// longer *commits* you to the number it auto-fills: stepping below 1 clears it.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(holeChoices, id: \.index) { choice in
                        Button(choice.ref) { pick(hole: choice.index) }
                    }
                } label: {
                    chip("Hole", chosenHoleRef)
                }

                // **0 is "no shot", and it is how the number is cleared.** A stepper
                // that bottoms out at 1 makes the auto-filled number impossible to
                // take back — X15 asked for the auto-fill, not for it to be
                // compulsory.
                Stepper(value: Binding(get: { chosenShot ?? 0 },
                                       set: { chosenShot = $0 == 0 ? nil : $0 }),
                        in: 0...20) {
                    chip("Shot", chosenShot.map(String.init) ?? "—")
                }
                .fixedSize()
                .disabled(chosenPlayer == nil)
                .opacity(chosenPlayer == nil ? 0.45 : 1)
            }

            // Horizontal, and scrollable rather than wrapped: five names on a phone
            // is the case that decides it, and a row that reflows moves the button
            // a thumb was aiming for.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(roster) { p in
                        playerChip(p)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal)
    }

    /// One name, **togglable** *(user, 2026-08-28: "player button should be
    /// togglelable")*.
    ///
    /// Tapping the selected player clears it, which is the only way back to "this
    /// entry is about nobody in particular" — the ordinary case for a sentence
    /// about the group or the hole. Clearing takes the **shot number with it**: a
    /// number with nobody attached cannot be ordered against anything.
    private func playerChip(_ p: Player) -> some View {
        let on = chosenPlayer == p.id
        return Button {
            if on { chosenPlayer = nil; chosenShot = nil } else { pick(player: p.id) }
        } label: {
            Text(p.name)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill),
                            in: Capsule())
                .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Choosing a hole or a player **re-derives the shot number**, because the
    /// number is per player *per hole*: picking a player on 7 and then correcting
    /// the hole to 8 would otherwise file 7's number on 8.
    private func pick(hole: Int? = nil, player: String? = nil) {
        if let hole { chosenHole = hole }
        if let player { chosenPlayer = player }
        guard let who = chosenPlayer else { return }
        chosenShot = LogEntry.nextShot(for: who, hole: chosenHole, in: doc.logs)
    }

    private func chip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value).font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Type is the text box and nothing else** *(user, 2026-08-28: "the whole
    /// content area should be input box and focus should be in it, so that keyboard
    /// shows up")*.
    ///
    /// It was a caption, a spacer, the MARK row and a one-line field pinned to the
    /// bottom — which left the golfer tapping a small target to raise the keyboard,
    /// on a screen whose only purpose is typing. Now the field *is* the mode: full
    /// height, focused on arrival, and the keyboard comes up with the sheet.
    ///
    /// `.large` is forced with it, because the medium detent plus a keyboard leaves
    /// about two lines of the thing being typed visible.
    private var typeArea: some View {
        VStack(spacing: 8) {
            TextField("What happened on \(holeRef)?", text: $draft, axis: .vertical)
                .lineLimit(3...)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))
                .focused($typing)
                // **Return, and it inserts one** *(user, 2026-08-28: "keyboard
                // return button should be return, not up arrow")*. It was
                // `.submitLabel(.send)` with `.onSubmit(send)`, so the key that
                // looks like a newline on a three-line box filed the entry and
                // dismissed the sheet — and a golfer writing two sentences lost the
                // second before typing it. With no `onSubmit` attached a vertical
                // `TextField` inserts the newline itself.
                .submitLabel(.return)

            HStack {
                // Said once, quietly: this is the phone's recogniser if they reach
                // for the keyboard's dictation key, not ours, and the microphone is
                // closed. The two modes are two recognizers and that is the whole
                // reason they are two modes.
                //
                // **The up-arrow send button is gone** *(user, 2026-08-28: "no send
                // button (up arrow)")*. There were two ways to commit one sentence
                // — the arrow and OK — sitting a centimetre apart and behaving
                // differently: the arrow refused an empty box, OK did not. OK is
                // the only one now, which is also what makes the empty-text rule
                // below expressible at all.
                Text("Microphone closed — this is the keyboard.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal)
    }

    // MARK: - The fast-tracking window

    /// Opening the sheet is what asks the radio to work harder — not opening a hole.
    /// **Two calls, but never two radios.** `trackFast` is the *recorded* track and
    /// only exists during a round; `LiveLocation` stands down for exactly that
    /// period, so precisely one of these does anything at any moment. The third
    /// manager — `StableLocation`, inside `settle` — always runs at Best whatever
    /// mode the others are in, which is what makes the log path independent of all
    /// of this and is why dropping back to slow below costs nothing.
    private func enter() async {
        model.trackFast(true, for: .marker)
        location.setFast(true, for: .marker)
        settling = Task { await settle() }
        // **The hole is pre-assigned from the one on screen** — X14. It is written
        // as `.user`, so nothing recomputes it afterwards.
        chosenHole = hole
        // Cancel has to be able to take back what this visit wrote, and a spoken
        // phrase is on disk the moment it finalises.
        live.beginMarkerSession()
        if mode == .speak { await begin() } else { typing = true }
    }

    /// **The fast window ends at a stable fix, not at dismissal.**
    ///
    /// *(User, 2026-08-28: "when marker view is done, fast tracking is still on. it
    /// should go to fast tracking when marker view is clicked, keep updating
    /// location until it's stabilized, once stabilized, it's final, and change it
    /// back to slow.")*
    ///
    /// The first version held fast for the life of the sheet and then handed back on
    /// a twenty-second timer, so a golfer who spent two minutes describing a hole
    /// paid Best for all of it and for twenty seconds more. What the dense rate is
    /// *for* is getting one good position for this stop — and "good" already has a
    /// definition here, `TrackingState`'s lock: three consecutive fixes inside 15 m.
    /// Once that lands there is nothing left to spend the power on.
    ///
    /// `StableLocation.best` returns the moment it locks, or at the deadline. Either
    /// way both feeds go back to slow immediately afterwards — and the log path is
    /// unaffected, because `StableLocation` always builds its own manager at Best
    /// regardless of what mode the recorder is in.
    private func settle() async {
        // Nothing to converge on while a position is being simulated — the point is
        // deliberately not where the phone is, so asking the radio harder is only
        // spending power to be told the wrong answer more precisely.
        guard override == nil else {
            model.trackFast(false, for: .marker)
            location.setFast(false, for: .marker)
            return
        }
        let fix = await StableLocation.best(within: LogPlacement.deadline)
        guard !Task.isCancelled else { return }
        if let fix, fix.horizontalAccuracy >= 0 {
            settled = (Coordinate(lat: fix.coordinate.latitude,
                                  lon: fix.coordinate.longitude),
                       fix.horizontalAccuracy)
        }
        model.trackFast(false, for: .marker)
        location.setFast(false, for: .marker)
    }

    /// Nothing is left holding the radio, whichever way the sheet ended.
    ///
    /// **Its own reason, not a blanket drop to slow** *(2026-08-30)*. The hole view
    /// asks for fast too now, and this sheet opens *over* it — so an unconditional
    /// `track(.slow)` here took the hole view's fast tracking away underneath it and
    /// nothing ever asked again.
    private func leave() async {
        settling?.cancel()
        await model.stopListening()
        model.trackFast(false, for: .marker)
        location.setFast(false, for: .marker)
    }

    /// **Reopening a finished round is part of opening this sheet.** A round does
    /// not end when the golfer stops talking — the scores get said on the way to the
    /// car park — and the alternative is a second session folder holding half a
    /// hole. `RoundSession.resume()` clears `meta.end`, so the round reads as
    /// unfinished again while it runs, which is what it is.
    private func begin() async {
        guard !model.isListening else { return }
        if !(model.isRecording && model.sessionName == roundID) {
            await model.reopenRound(id: roundID)
            doc.reload()
            // `errorMessage` says why. Refusing here rather than listening into a
            // round that is not open: one microphone, and `SessionIndex` assumes
            // exactly one recording round.
            guard model.isRecording else { return }
        }
        // The round's own roster, not the setup screen's drafts — players added
        // mid-round through `RosterEditor` are exactly the names the recognizer
        // most needs, and they exist only in the journal.
        await model.startListening(players: doc.players)
        recorded = true
    }

    private func finish() async {
        // Anything half-typed is a sentence the golfer meant to record. Send it
        // before tearing down rather than discarding it on the way out — `send`
        // dismisses by itself in Type mode, and `onDisappear` does the teardown
        // either way.
        send(allowingEmpty: true)
        // A burst's spoken rows carry no hole, player or shot of their own: they are
        // written phrase by phrase while the golfer is still choosing. OK is the
        // moment those choices become true of them.
        await stampSpokenEntries()
        dismiss()
    }

    /// **Cancel deletes what this visit wrote, spoken rows included** *(user
    /// decision, 2026-08-28)*.
    ///
    /// It cannot do it by not-writing: a phrase is committed to `log.jsonl` the
    /// instant it finalises, which is deliberate — a round that dies mid-burst keeps
    /// what was already said. So Cancel *tombstones*, which is how a log is deleted
    /// everywhere else: the rows stay on disk, `LogEntry.current` drops them, and a
    /// proposal that somehow cited one still renders its evidence.
    private func discard() async {
        await model.stopListening()
        for id in live.markerSessionEntries + written {
            doc.deleteLog(chainFrom: id)
        }
        written = []
        draft = ""
        dismiss()
    }

    /// Put the chosen hole, player and shot onto the phrases the burst wrote.
    ///
    /// A superseding row per entry, off the **chain head read from disk** — the
    /// burst grew by superseding and `LogPlacement` may have appended a coordinate
    /// underneath, so editing a cached copy would fork the chain and drop one of the
    /// two writers' work.
    private func stampSpokenEntries() async {
        guard chosenHole != nil || chosenPlayer != nil else { return }
        for id in live.markerSessionEntries {
            guard let head = LogStore.head(ofChainFrom: id, in: doc.folder) else { continue }
            // **The text is left exactly as it was heard** *(user, 2026-09-03: "no
            // fillers")*. It used to be re-written with a `"7: 2"` prefix, which put
            // words into a sentence somebody spoke; the hole and the shot are the
            // fields being stamped on the very next lines, and `LogTitle` prints
            // them in front of the sentence wherever a row is read.
            guard let next = head.edited(hole: chosenHole.map { $0 },
                                         player: chosenPlayer.map { $0 },
                                         shot: chosenShot.map { $0 })
            else { continue }
            _ = try? LogStore.shared.append(next, to: doc.folder)
        }
        doc.reloadLogs()
    }

    // MARK: - What is being heard

    @ViewBuilder private var transcriptPane: some View {
        if interrupted {
            pane(Text("The microphone was taken by something else — a call, or Siri. "
                    + "Recording resumes on its own if the system gives it back; the "
                    + "gap is recorded as a gap.")
                    .font(.caption).foregroundStyle(.secondary))
        }
        switch live.status {
        case .off:
            pane(Text("Opening the microphone…").font(.caption).foregroundStyle(.secondary))

        case .preparing(let name, let downloading):
            pane(HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(downloading ? "Downloading \(WhisperModels.prettyName(name))…"
                                     : "Loading \(WhisperModels.prettyName(name))…")
                    Text(downloading
                         ? "A few hundred megabytes, and it needs signal. Get models before the round, in the ••• menu."
                         : "A few seconds. It is already recording.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            })

        case .finishing:
            pane(HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing the last phrase…").font(.caption).foregroundStyle(.secondary)
            })

        // Recording and recognition fail separately and the sheet says so
        // separately: the simulator has a working microphone and no speech model at
        // all, and collapsing the two reads as the button being broken.
        case .unavailable(let why):
            pane(VStack(alignment: .leading, spacing: 4) {
                Text(why).font(.caption).foregroundStyle(.secondary)
                Text("The audio is still being recorded, so it can be transcribed later.")
                    .font(.caption2).foregroundStyle(.tertiary)
            })

        case .listening(let name):
            pane(VStack(alignment: .leading, spacing: 6) {
                if live.hypothesis.isEmpty {
                    Text("Listening — \(WhisperModels.prettyName(name))")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let tag = live.detected {
                            Text(tag.prefix(2))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        // Dimmed and italic, and never stored. A hypothesis drawn
                        // like a committed line is the same failure as a simulated
                        // position drawn like a fix.
                        Text(live.hypothesis)
                            .font(.callout).italic()
                            .foregroundStyle(.secondary)
                            // Newest words matter most, so the tail is what stays on
                            // screen as the phrase outgrows the box.
                            .lineLimit(4, reservesSpace: false)
                            .animation(.default, value: live.hypothesis)
                    }
                }
                if live.heard > 0 {
                    // One entry per recording, so this counts what has been added to
                    // it rather than how many rows exist.
                    Text("\(live.heard) phrase\(live.heard == 1 ? "" : "s") in this entry")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            })
        }
    }

    private func pane(_ content: some View) -> some View {
        HStack {
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    // MARK: - MARK

    /// **MARK moved in here with the rest of capture**, and it keeps its rule: it is
    /// the survey button, `marks.jsonl` is ground truth *and* `GolfEval`'s answer
    /// key, so nothing simulated may ever reach it. The hole view disables it under
    /// simulation by construction; this sheet has no simulated position to offer.
    @ViewBuilder private var markRow: some View {
        if model.isRecording && !doc.players.isEmpty {
            // **Labelled, because the roster is now on this sheet twice.** The
            // column above is who the *entry* is about; these are the survey
            // button, one per player, and they write `marks.jsonl` rather than a
            // log. Two unlabelled lists of the same three names read as one of
            // them being a mistake.
            HStack {
                Text("MARK")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(doc.players) { p in
                        Button { model.mark(player: p.id) } label: {
                            Label(p.name, systemImage: "mappin.and.ellipse")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Typing

    /// Written first, placed second — the write takes whatever fix is already warm,
    /// or none, and `LogPlacement` appends the superseding coordinate afterwards.
    /// Both the pair, not just the coordinate: a `Coordinate` with no accuracy is
    /// not a placed log, and it would join the convergence backlog to ask the radio
    /// for a position it had already been handed.
    private func send(allowingEmpty: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            // **OK with an empty box still creates a marker** *(user, 2026-08-28)*.
            // A row that says only *hole 7, shot 2, here* is a real entry — it is
            // where a shot was played from, which is the whole of what the hole view
            // draws — and requiring a sentence for it meant a golfer marking a
            // position had to invent one. Since 2026-09-03 the row really is empty:
            // it used to carry a `"7: 2"` prefix that made the text non-empty by
            // accident.
            //
            // Two guards, and both are about not writing an empty *nothing*. The
            // entry must be *about* something, or the pill renders as a content-free
            // capsule that is still tappable and still in the extraction pass's
            // input. And nothing may be added when this visit has already written —
            // a burst's phrases, or a sent line — because then OK would file a
            // second, blank entry beside the one the golfer actually made.
            guard allowingEmpty,
                  chosenHole != nil || chosenPlayer != nil,
                  live.markerSessionEntries.isEmpty, written.isEmpty
            else { return }
        }
        // The stabilized fix if it has landed, the warm one otherwise. An entry
        // written before the lock is still written — a log must never wait on GPS —
        // and `place()` supersedes it with the coordinate afterwards.
        // Simulation first, then the stabilised fix, then whatever is warm.
        let fix: (Coordinate, Double)? = override.map { ($0, 0) } ?? settled ?? model.fix
        // **No hole, deliberately** — the same rule a spoken log follows.
        // `LogEntry.hole` means "nearest hole to a *measured fix*", with
        // `lat`/`lon`/`hAcc` beside it as the evidence; stamping the hole the card
        // happens to be showing puts a second, unmeasured claim in that one field
        // and there is nothing downstream that can tell the two apart. It is the
        // `defaultTee` trap, and CLAUDE.md already forbids it for a spoken log — the
        // typed path had been doing it since the old input box, which is why a typed
        // entry never showed the `no hole` chip a spoken one did. `LogPlacement`
        // derives the hole from the fix afterwards.
        // **What was typed, and nothing else** *(user, 2026-09-03, retiring the
        // 2026-08-28 `"7: 2 drive into the left bunker"` prefix)*. The hole and the
        // shot are stored as fields and `LogTitle` composes them in front of the
        // sentence wherever one is read, so the prefix had become the same claim
        // printed twice — and on a marker with no sentence it was the whole text.
        let entry = doc.addLog(text,
                               hole: chosenHole,
                               holeSource: chosenHole == nil ? nil : .user,
                               player: chosenPlayer, shot: chosenShot,
                               at: fix?.0, accuracy: fix?.1)
        if let entry { written.append(entry.id) }
        draft = ""
        place()
        // **No dismiss here any more.** This used to end the marker in Type mode,
        // because the up-arrow was a second way to commit and a typed entry is one
        // deliberate sentence. With the arrow gone the only caller is `finish()`,
        // which dismisses anyway — and a second dismiss path is how two buttons
        // come to mean subtly different things. Same lesson as the press-and-hold
        // branch that outlived its gesture.
    }

    /// **A typed entry is placed the same way a spoken one is** *(user, 2026-08-28:
    /// "typed entries should do the same as what record entries have, i.e.
    /// location")*.
    ///
    /// It always *could* be — `LogPlacement.unplaced` has never filtered on
    /// `source`, and the write already takes whatever fix is warm — but the
    /// convergence that appends the superseding coordinate is driven by
    /// `RoundScreen`'s `.task(id:)`, and this sheet opens over the **hole view**
    /// too, where that screen is a stack frame down and holds a *different*
    /// `RoundDocument`. Relying on it staying alive underneath is relying on a
    /// SwiftUI detail, for the one thing that makes a log a shot rather than a note.
    ///
    /// So the sheet converges what it just wrote. `RoundScreen`'s task stays the
    /// backstop, and running both is safe by construction: `LogPlacement.attempted`
    /// is a reservation, so two passes cannot converge one log at once, and a
    /// converged log is no longer `unplaced`.
    private func place() {
        guard model.isRecording else { return }
        let folder = doc.folder
        Task {
            for log in LogPlacement.unplaced(doc.logs) {
                await LogPlacement.converge(log, in: folder)
            }
            doc.reloadLogs()
        }
    }
}
