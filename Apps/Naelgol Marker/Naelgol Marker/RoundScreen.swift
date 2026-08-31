import SwiftUI
import Combine
import GolfSessionFormat
import GolfCourse
import GolfCaptureCore
import GolfTranscription

/// The round, in three bands.
///
///     +--------------------------+   the card
///     +--------------------------+   what happened on the chosen hole
///     +--------------------------+   the input box
///
/// The ordering follows the same argument as the hole view
/// (research-course-display.md §5): the reachable one-handed band is the bottom
/// third, so what is **read** goes up and what is **touched** goes down. The card
/// is a reference at the top, the middle is the scroll, and the box is pinned
/// where a thumb already is.
///
/// **What the middle band shows is both streams at once** — the events extraction
/// proposed, and the raw logs they came from, interleaved by time. A log with no
/// event beside it is the visible signal that nothing has read it yet; hiding the
/// logs would make an un-extracted round look like an empty one.
///
/// **There is no extraction running behind this screen** *(2026-08-27)*. The
/// on-device Apple Intelligence pass was scrapped, so every event row here is one
/// a person entered or a future reconstructor wrote. See TODO.md.
struct RoundScreen: View {
    let id: String
    @ObservedObject var model: RoundViewModel
    /// The caption feed is its own observable, so the pane redraws on a volatile
    /// line without republishing the whole round.
    @ObservedObject var live: LiveTranscript
    /// The app-wide position feed. Named `location` because `live` is the caption
    /// feed on this screen; they are two different things and one round screen
    /// holds both.
    @ObservedObject var location: LiveLocation
    @StateObject private var library = CourseLibrary()
    /// The OSM course finder *(user, 2026-08-30)*. Offered here as well as on the
    /// hole view, because the hole view is reached *through* a course — so the one
    /// entry point that mattered was the one an install with no courses cannot use.
    @State private var finding = false
    @StateObject private var doc: RoundDocument

    @State private var hole = 1
    @State private var teeName: String?
    @State private var showCloseOut = false
    /// The Marker sheet — the app's one input surface.
    @State private var showMarker = false
    @State private var showAllHoles = false
    /// The log being edited, if any. A sheet rather than an inline field: the text
    /// is a whole sentence and the keyboard covers the list it came from.
    @State private var editing: LogEntry?
    @State private var showHistory = false
    @State private var exporting = false
    @State private var showRoster = false
    @State private var showModels = false
    /// Re-reading one entry's audio with the bigger model. Its own object because
    /// the pass takes seconds and the row has to show that it is running.
    @StateObject private var retranscribe = LogRetranscribe()
    /// Which hole the map button is about to open, and whether it is showing a
    /// particular log. Programmatic because two different controls push the same
    /// destination with different arguments.
    @State private var holeFocus: HoleFocus?
    /// Screenshot support only — the band owns its own cell sheet in normal use.
    @State private var detailCell: ScorecardBand.Cell?
    /// Mirrors `ScorecardBand`'s own `@AppStorage` so the menu can toggle it.
    @AppStorage("marker.card.net") private var showNet = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(id: String, model: RoundViewModel, live location: LiveLocation) {
        self.id = id
        self.model = model
        self.live = model.liveTranscript
        self.location = location
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(id))
        _doc = StateObject(wrappedValue: RoundDocument(folder: folder))
    }

    /// The course file for the course **this round** was played on. Never
    /// `library.selected`, which is a global preference and once printed another
    /// course's pars over this card.
    private var roundCourse: Course? {
        guard let name = doc.meta.course else { return nil }
        return library.courses.first { $0.name == name || $0.aliases.contains(name) }
    }

    private var isLive: Bool { model.isRecording && model.sessionName == id }
    private var holeCount: Int { max(roundCourse?.holes.count ?? 18, 1) }

    var body: some View {
        VStack(spacing: 0) {
            ScorecardBand(doc: doc, course: roundCourse, hole: $hole, teeName: $teeName)
            Divider()
            middleBand
        }
        .sheet(isPresented: $finding) {
            CourseFinder(here: model.here,
                         existingIDs: Set(library.courses.map(\.id))) { course in
                library.save(course)
                doc.setCourse(course.name)
            }
        }
        .navigationTitle(doc.meta.course ?? "Round")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { liveChip }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // **Always the hole the card is on.** Layer, units and tee are
                // remembered between visits; the hole is not — someone tapping
                // the map wants where they are now.
                Button { holeFocus = HoleFocus(ref: holeRefFor(hole)) } label: {
                    Label("Hole view", systemImage: "map")
                }
                roundMenu
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            doc.reload()
            if let match = roundCourse { library.selectedID = match.id }
            if teeName == nil { teeName = roundCourse?.teeNames.first }
            hole = firstUnplayedHole
            #if DEBUG
            if let h = DemoSeed.openHole { hole = h }      // screenshot support
            switch DemoSeed.openSheet {
            case "history": showHistory = true
            case "roster":  showRoster = true
            case "detail":  detailCell = ScorecardBand.Cell(
                                player: doc.players.first?.id ?? "", hole: hole)
            case "marker":  showMarker = true
            case "export":  exporting = true
            default: break
            }
            if DemoSeed.wantsMap { holeFocus = HoleFocus(ref: holeRefFor(hole)) }
            #endif
        }
        // A round's files can change while this screen is backgrounded, so coming
        // back to the foreground re-reads. See `LogStore.didAppend` for the live
        // half.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { doc.reload() }
        }
        // **`.receive(on:)` is load-bearing.** `LogStore.append` is not actor
        // isolated and a caller may append from a background queue — a location
        // convergence does — so the notification arrives off the main thread and
        // this closure would touch `@MainActor` state from it. SwiftUI infers the
        // closure as main-actor, which makes it compile and not correct.
        .onReceive(NotificationCenter.default.publisher(for: LogStore.didAppend)
                     .receive(on: RunLoop.main)) { note in
            // A nil object means the sender could not say which round; re-reading
            // this one is the right answer anyway, since it is the only one shown.
            // **`SessionFolder.isSame`, never `==`.** The two URLs are the same
            // path and compare unequal, because `appendingPathComponent` adds a
            // trailing slash for a directory that already exists — see
            // `SessionFolder.isSame`. This guard silently dropped every refresh
            // during a recording burst.
            guard let object = note.object as? URL,
                  doc.folder.isSame(as: object) else {
                // A nil object means the sender could not say which round;
                // re-reading this one is right anyway, since it is the only one
                // shown.
                if note.object == nil { doc.reloadLogs() }
                return
            }
            doc.reloadLogs()
        }
        .onChange(of: roundCourse?.id) { _, _ in
            teeName = roundCourse?.teeNames.first
        }
        .sheet(item: $editing) { log in
            LogEditor(log: log, holes: holeChoices, players: doc.players) {
                text, hole, player, shot in
                doc.amendLog(log, text: text, hole: .some(hole),
                             player: .some(player), shot: .some(shot))
                editing = nil
            } cancel: { editing = nil }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(doc: doc, holeLabel: label(forHole:))
        }
        .sheet(isPresented: $exporting) {
            RoundExportSheet(folder: doc.folder, library: library)
        }
        // Reopening a finished round is the Marker button's job now: a round does
        // not end when the golfer stops talking — the scores get said on the way to
        // the car park — and the alternative is a second folder holding half a hole.
        .sheet(isPresented: $showMarker) {
            MarkerSheet(model: model, live: live, doc: doc,
                        location: location,
                        hole: showAllHoles ? nil : hole, holeRef: holeRef,
                        holes: holeChoices,
                        roundID: id)
        }
        .sheet(isPresented: $showRoster) {
            RosterEditor(doc: doc, course: roundCourse)
        }
        .sheet(isPresented: $showModels) {
            WhisperModelPicker(model: model)
        }
        .navigationDestination(item: $holeFocus) { f in
            CourseView(model: model, live: location, roundID: id,
                       holeRef: f.ref, focus: f.coordinate)
        }
        .sheet(item: $detailCell) { cell in
            HoleDetailSheet(doc: doc, cell: cell,
                            player: doc.players.first { $0.id == cell.player },
                            hole: roundCourse.flatMap {
                                $0.holes.indices.contains(cell.hole - 1)
                                    ? $0.holes[cell.hole - 1] : nil
                            },
                            received: doc.strokesReceived(of: cell.player,
                                                          holes: roundCourse?.holes ?? [])[cell.hole] ?? 0)
        }
        // **Placing a log is the foreground app's job** — see `LogPlacement`, and
        // `logSignature` for why this is keyed on the *unplaced* logs only.
        .task(id: logSignature) {
            await placeUnplacedLogs()
        }
        .confirmationDialog("Close out this round?", isPresented: $showCloseOut) {
            Button("Close it out") {
                try? SessionIndex.closeOut(doc.folder)
                doc.reload()
            }
        } message: {
            Text("It was started and never ended. Closing it stamps the end time from the "
               + "last thing actually recorded — not from now — and stops it being offered "
               + "for recovery. Nothing is deleted.")
        }
    }

    /// What is still **waiting to be placed**, cheaply comparable.
    ///
    /// **Not every log id.** This keys the placement task, and `.task(id:)`
    /// cancels and restarts on every change — which was fine when the typed box
    /// appended a row every few minutes and is not when a bilingual burst appends
    /// one every few seconds. Keyed on all ids, an arriving log that needs no
    /// placement at all still tore down a convergence that was fifteen seconds
    /// into its radio wait.
    ///
    /// **Keyed on the ids, not the count.** A delete and an arrival in the same
    /// reload leave the count identical, and convergence itself appends a
    /// superseding row that `current` collapses — so a count is a trigger that
    /// silently misses the two cases it exists for.
    private var logSignature: String {
        LogPlacement.unplaced(doc.logs).map(\.id).joined(separator: ",")
    }

    /// Converge on a fix for any log that arrived without one, newest first — the
    /// golfer is standing nearest to the most recent thing they said.
    ///
    /// Only while the round is **live**: converging for a round that ended last
    /// Sunday would place its logs wherever the phone happens to be now, which is
    /// worse than leaving them unplaced. One at a time, because two location
    /// managers asking for Best is twice the power for one position — the same
    /// argument that makes `LiveLocation` stand down during a round.
    private func placeUnplacedLogs() async {
        guard isLive else { return }
        // The recorded track was put into fast when the burst opened and is held
        // there through this window: these fifteen seconds are exactly when the
        // app wants the best fix it can get. Handed back whichever way the loop
        // ends, cancellation included — a task torn down mid-convergence must not
        // leave the radio at Best for the rest of the round.
        defer { if !model.isListening { model.trackFast(false, for: .marker) } }
        for log in LogPlacement.unplaced(doc.logs).reversed() {
            await LogPlacement.converge(log, in: doc.folder)
            if Task.isCancelled { return }
        }
        doc.reloadLogs()
    }

    /// Where to open the card. The hole after the last one with a score is a
    /// better guess than 1 for a round already underway, and no worse for a new
    /// one.
    private var firstUnplayedHole: Int {
        let played = (1...holeCount).filter { h in
            doc.players.contains { doc.score(player: $0.id, hole: h) != nil }
        }
        return min((played.max() ?? 0) + 1, holeCount)
    }

    // MARK: - Middle band

    @ViewBuilder private var middleBand: some View {
        let rows = timeline
        VStack(spacing: 0) {
            holeStrip
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(showAllHoles ? "Nothing yet" : "Nothing on this hole",
                          systemImage: "text.bubble")
                } description: {
                    Text("Type what happened below.")
                }
            } else {
                List {
                    ForEach(rows) { row in
                        switch row {
                        case .event(let e):
                            EventRow(event: e, players: doc.players,
                                     evidence: cited(e),
                                     holeLabel: holeLabel(e.hole),
                                     status: doc.status(of: e),
                                     accept: { doc.accept(e) },
                                     reject: { doc.reject(e) })
                                .swipeActions {
                                    Button(role: .destructive) { doc.delete(e) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                // The same copy a log row has, on the other row
                                // type: an event is what a proposal *is*, and its
                                // citations are what make it checkable.
                                .contextMenu {
                                    Button { copy(e) } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                        case .log(let l):
                            LogRow(log: l, start: doc.meta.start,
                                   holeLabel: holeLabel(l.hole),
                                   playerName: doc.players.first { $0.id == l.player }?.name,
                                   rereading: retranscribe.running.contains(l.id))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { doc.deleteLog(l) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { editing = l } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.accentColor)
                                }
                                // Moving a log is a two-tap menu rather than a
                                // swipe: it needs a hole picker, and a swipe that
                                // opens a sheet is a gesture with no visible result.
                                .contextMenu { logMenu(l) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// A `Picker` would need eighteen rows of a menu; the card above is already the
    /// selector. This is the caption that says which hole the list is showing, plus
    /// the escape hatch to see everything.
    private var holeStrip: some View {
        HStack(spacing: 10) {
            Text(showAllHoles ? "WHOLE ROUND" : "HOLE \(holeRef)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !showAllHoles, let par = parOfSelectedHole {
                Text("PAR \(par)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(showAllHoles ? "This hole" : "All holes") {
                withAnimation { showAllHoles.toggle() }
            }
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// The number printed on the card, which on a course of named nines is not the
    /// playing-order index — hole 12 of 18 is "3" on the second nine.
    private var holeRef: String {
        guard let course = roundCourse, hole >= 1, hole <= course.holes.count else {
            return "\(hole)"
        }
        let h = course.holes[hole - 1]
        return h.nine.map { "\($0) \(h.ref)" } ?? h.ref
    }

    private var parOfSelectedHole: Int? {
        guard let course = roundCourse, hole >= 1, hole <= course.holes.count else { return nil }
        return course.holes[hole - 1].par
    }

    /// The logs an event rests on, in the order they were said.
    ///
    /// Looked up in **every** version, not just the current ones: a citation names
    /// the row the model actually read, which may since have been edited or
    /// deleted, and a proposal rendering no evidence at all reads as a claim
    /// resting on nothing. `LogEntry.chainRoot` is not used here on purpose — the
    /// point is to show what the model saw.
    private func cited(_ event: Event) -> [LogEntry] {
        let ids = Set(event.logs ?? [])
        guard !ids.isEmpty else { return [] }
        return doc.logs.filter { ids.contains($0.id) }.sorted { $0.t < $1.t }
    }

    /// Move a log to another hole, or take its hole away. Both are superseding
    /// rows in `log.jsonl` — never journal acts, or the extraction pass would go
    /// on reading the old hole. See `RoundDocument.amendLog`.
    @ViewBuilder private func logMenu(_ log: LogEntry) -> some View {
        Button { editing = log } label: { Label("Edit", systemImage: "pencil") }
        Button {
            copy(log)
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        // **Only when there is audio to read.** Empty spans mean the log was
        // typed, predates `LogEntry.tEnd`, or was spoken into the burst that is
        // still recording — an `.m4a` still being written cannot be opened at all.
        // Offering a button that cannot work is worse than not offering one.
        if !LogRetranscribe.spans(for: log, in: doc.folder).isEmpty {
            Button {
                Task {
                    await retranscribe.run(log, in: doc.folder,
                                           model: model.whisperFinalModel,
                                           players: doc.players)
                    doc.reload()
                }
            } label: {
                Label("Transcribe again · \(WhisperModels.prettyName(model.whisperFinalModel))",
                      systemImage: "waveform.badge.magnifyingglass")
            }
            // **Not while the microphone is open.** The final model is a second
            // half-gigabyte of CoreML, and holding it resident beside the live one
            // is two graphs on a phone that is four holes from the car — a jetsam
            // kill mid-burst costs the round, which is a much worse trade than
            // waiting until Stop. The audio is not going anywhere.
            .disabled(retranscribe.running.contains(log.id) || model.isListening)
        }
        // **Only when there is a measured position.** `LogEntry.hole` alone is a
        // proposal and can be nil for a log with a perfectly good fix; a fix with
        // no hole is still worth showing, and a hole with no fix has nowhere to
        // point. See `LogPlacement`.
        if log.hasPosition, let at = coordinate(of: log) {
            Button {
                holeFocus = HoleFocus(ref: holeRefFor(log.hole ?? hole), at: at)
            } label: { Label("Show where this was said", systemImage: "mappin.and.ellipse") }
        }
        Menu {
            ForEach(1...holeCount, id: \.self) { h in
                Button {
                    doc.amendLog(log, hole: .some(h))
                } label: {
                    Text(label(forHole: h)) + Text(h == log.hole ? "  ✓" : "")
                }
            }
            if log.hole != nil {
                Divider()
                Button("No hole") { doc.amendLog(log, hole: .some(nil)) }
            }
        } label: { Label("Move to hole", systemImage: "flag") }
        Button(role: .destructive) { doc.deleteLog(log) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// `Hole.ref` for a 1-based playing-order index — what `HoleScreen` opens on.
    /// Nil when this round has no course file, which is a real state: the hole
    /// view then falls back to its own first hole.
    /// How a hole is written on a row.
    ///
    /// **`Hole.ref` when there is a course file, the playing index otherwise.** The
    /// index is what `LogEntry.hole` stores — a scorecard column — and `ref` is what
    /// the card prints, which for a Korean 27 is "황룡/3" and not "3". A round with
    /// no course file still shows the number rather than nothing: it is the honest
    /// answer, and it is the one the card's own header falls back to.
    /// The round's own holes for the Marker sheet's picker — **from the round's
    /// course, never the library's selection**, which is the rule that exists
    /// because reading the library put another course's pars on this round twice in
    /// one screen.
    private var holeChoices: [(index: Int, ref: String)] {
        guard let course = roundCourse else { return [] }
        return course.holes.enumerated().map { ($0.offset + 1, $0.element.ref) }
    }

    private func holeLabel(_ index: Int?) -> String? {
        guard let index else { return nil }
        return holeRefFor(index) ?? "\(index)"
    }

    private func holeRefFor(_ index: Int) -> String? {
        guard let course = roundCourse, index >= 1, index <= course.holes.count
        else { return nil }
        return course.holes[index - 1].ref
    }

    private func coordinate(of log: LogEntry) -> Coordinate? {
        guard let lat = log.lat, let lon = log.lon else { return nil }
        return Coordinate(lat: lat, lon: lon)
    }

    /// Where the map button is going. A value type so `navigationDestination`
    /// re-pushes when the same hole is opened twice with a different log.
    private struct HoleFocus: Identifiable, Hashable {
        var ref: String?
        var lat: Double?
        var lon: Double?
        var id: String { "\(ref ?? "-")@\(lat ?? 0),\(lon ?? 0)" }

        init(ref: String?, at: Coordinate? = nil) {
            self.ref = ref
            self.lat = at?.lat
            self.lon = at?.lon
        }

        var coordinate: Coordinate? {
            guard let lat, let lon else { return nil }
            return Coordinate(lat: lat, lon: lon)
        }
    }

    /// The number printed on the card for a playing-order index, which on a course
    /// of named nines is not the index itself.
    private func label(forHole h: Int) -> String {
        guard let course = roundCourse, h >= 1, h <= course.holes.count else { return "\(h)" }
        let hole = course.holes[h - 1]
        return hole.nine.map { "\($0) \(hole.ref)" } ?? hole.ref
    }

    /// Events and logs on one clock.
    ///
    /// A cited log does not get its own row — it is quoted **under the event it
    /// produced**, which is the pairing the user is here to check. Leaving it as a
    /// separate row put the same sentence on screen twice; hiding it behind a
    /// count was worse, because then verifying a draft costs a tap and verifying
    /// drafts is the entire job of this screen.
    ///
    /// What keeps its own row is a log nothing has read yet.
    ///
    /// **A row with no hole is shown on every hole, never on none.** `hole` is a
    /// *proposal* from `Course.nearestHole`, and it is nil whenever there was no
    /// fix by the time the log was written, no course file for the round, or the
    /// phone more than 250 m from any hole — walking between two, or standing in a
    /// kitchen testing it. `$0.hole == hole` is false for nil on all eighteen, so
    /// a log the app had just confirmed it saved was invisible everywhere except
    /// "All holes". Reported from the device 2026-08-27, and it is the same failure the
    /// paragraph above argues against one level down: a log that cannot be placed
    /// still has to be *seen*, or the app quietly eats the sentence the golfer
    /// spoke. `LogRow`/`EventRow` mark it so the repetition reads as "not placed"
    /// rather than as a duplicate.
    private var timeline: [TimelineRow] {
        let events = Event.current(doc.events).filter {
            showAllHoles || $0.hole == hole || $0.hole == nil
        }
        let cited = Set(events.flatMap { $0.logs ?? [] })
        let logs = doc.currentLogs.filter {
            (showAllHoles || $0.hole == hole || $0.hole == nil) && !cited.contains($0.id)
        }
        return (events.map { TimelineRow.event($0) } + logs.map { TimelineRow.log($0) })
            .sorted { $0.t < $1.t }
    }

    private enum TimelineRow: Identifiable {
        case event(Event)
        case log(LogEntry)
        var id: String {
            switch self {
            case .event(let e): return "e-\(e.id)"
            case .log(let l): return "l-\(l.id)"
            }
        }
        var t: Millis {
            switch self {
            case .event(let e): return e.t
            case .log(let l): return l.t
            }
        }
    }

    // MARK: - Bottom band

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Drawn while the round is live **or** while a stopped burst is still
            // finishing, so tapping Stop shows something happening rather than
            // silence for several seconds.
            if isLive || model.isListening || live.status == .finishing { livePane }

            // **Marker · Round · Location.** This replaced a record button, a text
            // field and End round sitting in a stack: three controls competing for
            // the one strip of screen a thumb reaches, the first two of which asked
            // the golfer to choose between speaking and typing before they had said
            // anything. Both are now inside the Marker sheet, which opens listening.
            //
            // MARK went with them — it is a capture action, its output is
            // `GolfEval`'s answer key, and it belongs beside the other two rather
            // than on a screen where it is the only one left.
            //
            // The same bar is handed to the hole view through
            // `HoleScreen.bottomBar`, so the two screens cannot drift.
            MarkerBar(model: model, live: location, roundID: id,
                      onMarker: { showMarker = true },
                      onEndRound: isLive ? { model.stopRound(); doc.reload() } : nil,
                      onStartRound: {
                          Task { await model.reopenRound(id: id); doc.reload() }
                      })

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The microphone was taken by something else — a call, or Siri. Rendered,
    /// because a control that looks like it is recording while it is not is the same
    /// failure as a simulated position drawn like a fix.
    private var interrupted: Bool { model.audioState == .interrupted }

    @ViewBuilder private var livePane: some View {
        if interrupted {
            liveRow(Text("The microphone was taken by something else — a call, or Siri. "
                       + "Recording resumes on its own if the system gives it back; the gap "
                       + "is recorded as a gap.")
                    .font(.caption).foregroundStyle(.secondary))
        }
        switch live.status {
        case .off:
            EmptyView()

        case .preparing(let model, let downloading):
            liveRow(
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(downloading
                             ? "Downloading \(WhisperModels.prettyName(model))…"
                             : "Loading \(WhisperModels.prettyName(model))…")
                        Text(downloading
                             ? "A few hundred megabytes, and it needs signal. "
                             + "Get models before the round, in the ••• menu."
                             : "A few seconds. The round is already recording.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            )

        case .finishing:
            liveRow(
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finishing the last phrase…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            )

        case .unavailable(let why):
            // Recording is still running; only the caption is missing.
            liveRow(Text(why).font(.caption).foregroundStyle(.secondary))

        case .listening(let model):
            liveRow(
                VStack(alignment: .leading, spacing: 3) {
                    if live.hypothesis.isEmpty {
                        Text("Listening — \(WhisperModels.prettyName(model))")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let tag = live.detected {
                                Text(tag.prefix(2))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(live.hypothesis)
                                .italic()
                                .foregroundStyle(.secondary)
                                // Newest words matter most, so the tail is what
                                // stays on screen as the phrase outgrows the box.
                                .lineLimit(3, reservesSpace: false)
                                .animation(.default, value: live.hypothesis)
                        }
                    }
                    if live.heard > 0 {
                        // One entry per recording, so this counts what has been
                        // added to it rather than how many rows exist.
                        Text("\(live.heard) phrase\(live.heard == 1 ? "" : "s") in this entry")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            )
        }
    }

    private func liveRow(_ content: some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(model.isListening ? .red : .secondary)
                .symbolEffect(.variableColor, isActive: model.isListening)
            content
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }


    // MARK: - Toolbar

    private var roundMenu: some View {
        Menu {
            // **Undo before anything else in the menu.** It is the one control
            // that has to be findable in a hurry, and it names what it will
            // reverse rather than saying "Undo" — undoing the wrong thing is the
            // failure a journal is supposed to make impossible.
            if let last = doc.undoable {
                Button { doc.undo(last) } label: {
                    Label(undoTitle(last), systemImage: "arrow.uturn.backward")
                }
            }
            Button { showHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            // Copies **what the list is showing** — this hole or the whole round,
            // whichever the strip says. Built from the logs rather than from
            // `timeline`, which hides a log an event already cites; see
            // `LogTranscript`.
            Button { copyTranscript() } label: {
                Label(showAllHoles ? "Copy whole round" : "Copy hole \(holeRef)",
                      systemImage: "doc.on.doc")
            }
            // **Beneath Copy, and named differently, because they are not the same
            // thing.** Copy puts `RoundExport`'s logs and events on the clipboard
            // for a model; Export puts the whole round — scores, marks, the track,
            // the course file and its terrain — where another phone can take it
            // back. The one is safe in a prompt and the other is the answer key, and
            // once either is on a clipboard nothing says which.
            Button { exporting = true } label: {
                Label("Export round…", systemImage: "square.and.arrow.up")
            }
            // Only offered when somebody has a course handicap. A Net toggle that
            // changes nothing on screen is a control that looks broken.
            if doc.players.contains(where: { doc.courseHandicap(of: $0.id) != nil }) {
                Toggle(isOn: $showNet) { Label("Net scores", systemImage: "minus.circle") }
            }
            Divider()

            Section("Players") {
                ForEach(doc.players) { p in
                    NavigationLink {
                        PlayerEditor(doc: doc, player: p, course: roundCourse)
                    } label: {
                        Text(handicapSummary(p))
                    }
                }
                // **There was no way to add a player mid-round**, which is why the
                // first person to want one typed it into the input box and got a
                // model pass over a sentence about nothing *(reported 2026-08-27)*.
                // The roster is a journal act like anything else.
                Button { showRoster = true } label: {
                    Label("Add or remove players", systemImage: "person.badge.plus")
                }
            }

            // **Moved out of the bottom band and into the menu**
            // *(user, 2026-08-28: "no need for 'Close out this round' button")* —
            // not deleted. It is the only crash-recovery control there is: the
            // rounds list has none, so a round the app was killed during would
            // otherwise stay unfinished forever with nothing able to stamp it. It
            // is rare and it does not belong in the thumb zone, which is the whole
            // of the complaint.
            if !isLive, doc.isOpen {
                Button { showCloseOut = true } label: {
                    Label("Close out this round", systemImage: "exclamationmark.triangle")
                }
            }

            Section("Listening") {
                Button { showModels = true } label: {
                    Label(WhisperModels.prettyName(model.whisperModel),
                          systemImage: "waveform.badge.mic")
                }
            }

            if let course = roundCourse, course.teeNames.count > 1 {
                Picker("Tee", selection: Binding(get: { teeName ?? "" },
                                                 set: { teeName = $0.isEmpty ? nil : $0 })) {
                    ForEach(course.teeNames, id: \.self) { Text($0).tag($0) }
                }
            }

            Picker("Course", selection: Binding(
                get: { library.selectedID ?? "" },
                set: { id in
                    library.selectedID = id.isEmpty ? nil : id
                    if let c = library.courses.first(where: { $0.id == id }) {
                        doc.setCourse(c.name)
                    }
                })) {
                ForEach(library.courses) { c in Text(c.name).tag(c.id) }
            }
            Button {
                finding = true
            } label: {
                Label("Find a course…", systemImage: "magnifyingglass")
            }
            if library.courses.isEmpty {
                Button("Install sample course") { library.installSample() }
            }
            Button { library.reload(); doc.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        } label: {
            Label("Round", systemImage: "ellipsis.circle")
        }
    }

    /// Everything the middle band is showing, as **JSON** *(user, 2026-08-29)*.
    ///
    /// Deliberately **not** the timeline: that list drops a log an event cites,
    /// because the event quotes it underneath instead. Copying it would omit the
    /// sentences extraction actually understood and look complete doing it.
    ///
    /// It used to be `0:12:04  steve made par` per line, which is every field the
    /// round turns on thrown away — position, player id, hole, whether the hole was
    /// measured or chosen, what language it was heard in. The clipboard's job here
    /// is to feed a model or another tool, and none of that is recoverable from the
    /// sentence. `RoundExport` decides the shape; this decides the selection.
    private func copyTranscript() {
        let object = RoundExport.round(logs: doc.currentLogs, events: Event.current(doc.events),
                                       players: doc.players, course: doc.meta.course,
                                       start: doc.meta.start, end: doc.meta.end,
                                       hole: showAllHoles ? nil : hole, holeRefs: holeRefs)
        UIPasteboard.general.string = RoundExport.string(object)
    }

    /// One row, same shape as a row inside the round export — so a single entry and
    /// a whole round paste into the same reader.
    private func copy(_ log: LogEntry) {
        UIPasteboard.general.string = RoundExport.string(
            RoundExport.log(log, players: doc.players, start: doc.meta.start,
                            holeRef: log.hole.flatMap { holeRefs[$0] }))
    }

    private func copy(_ event: Event) {
        UIPasteboard.general.string = RoundExport.string(
            RoundExport.event(event, players: doc.players, start: doc.meta.start,
                              holeRef: event.hole.flatMap { holeRefs[$0] }))
    }

    /// Playing index → the label the card prints. `GolfSessionFormat` has no course,
    /// so the export is handed this rather than guessing that hole 12 is called "12"
    /// — on a Korean 27 it is "황룡/3".
    private var holeRefs: [Int: String] {
        guard let course = roundCourse else { return [:] }
        return Dictionary(uniqueKeysWithValues:
            course.holes.enumerated().map { ($0.offset + 1, $0.element.ref) })
    }

    /// "Undo steve on 7: 6" — a label, not a verb. See the menu.
    private func undoTitle(_ e: JournalEntry) -> String {
        switch e.act {
        case .setScore:
            let who = doc.players.first { $0.id == e.player }?.name ?? e.player ?? ""
            let h = e.hole.map { " on \(label(forHole: $0))" } ?? ""
            return "Undo \(who)\(h): \(e.strokes.map(String.init) ?? "—")"
        case .setStat:      return "Undo \(e.stat?.label ?? "stat")"
        case .setIndex:     return "Undo handicap change"
        case .setTee:       return "Undo tee change"
        case .addPlayer:    return "Undo adding \(e.name ?? "player")"
        case .editPlayer:   return "Undo rename"
        case .removePlayer: return "Undo removing player"
        case .setCourse:    return "Undo course change"
        case .acceptEvent:  return "Undo accepting a proposal"
        case .rejectEvent:  return "Undo rejecting a proposal"
        case .undo:         return "Redo"
        }
    }

    /// `steve · 14.2 · white (CH 15)`. Nil handicap prints nothing rather than a
    /// zero — a player with no index has no course handicap, and 0 means scratch.
    private func handicapSummary(_ p: Player) -> String {
        var parts = [p.name]
        if let i = doc.index(of: p.id) { parts.append(String(format: "%.1f", i)) }
        if let tee = doc.tee(of: p.id)?.name { parts.append(tee) }
        if let ch = doc.courseHandicap(of: p.id) { parts.append("CH \(ch)") }
        return parts.joined(separator: " · ")
    }

    private var liveChip: some View {
        Group {
            if isLive {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(timeString(model.elapsed)).monospacedDigit()
                    if let acc = model.fixAccuracy {
                        Text(String(format: "±%.0f", acc)).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            } else if doc.isOpen {
                Label("Unfinished", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Rows

/// A log: what was said, before anything read it.
///
/// Drawn plainly and quietly. It is not a claim about the round — it is the raw
/// material — and dressing it up like an event would make an un-extracted round
/// look finished.
private struct LogRow: View {
    let log: LogEntry
    let start: Millis
    /// Which hole this was filed on, as the card writes it — `Hole.ref`, not the
    /// playing index, because a Korean 27 has three holes called "3".
    ///
    /// **Shown whether or not it is nil** *(user, 2026-08-28)*. A row carries a hole
    /// number when it has one and `no hole` when it does not, so the two are the
    /// same field answered two ways rather than a chip that only appears on
    /// failure — which read as "this row is broken" instead of "this row is on 7".
    /// It matters most under *All holes*, where every row comes from somewhere else.
    var holeLabel: String?
    /// Who the entry is about, resolved to a **display name** *(user, 2026-08-28:
    /// "marker list in scorecard view: show player name")*. `LogEntry.player` is a
    /// `Player.id`, which survives a rename and would render as a stale name if
    /// printed raw. Nil for the ordinary entry, which is about nobody in particular.
    var playerName: String?
    /// The bigger model is reading this entry's audio again. Seconds, not
    /// instant — and a row that changes text with no warning reads as a bug.
    var rereading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: log.source == .spoken ? "waveform" : "keyboard")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(log.text)
                HStack(spacing: 6) {
                    Text(clock).monospacedDigit()
                    if rereading {
                        ProgressView().controlSize(.mini)
                        Text("re-reading")
                    }
                    if !log.hasPosition {
                        // Said out loud, because a log with no fix cannot place
                        // anything on a hole and nothing downstream will say so.
                        Label("no fix", systemImage: "location.slash")
                    }
                    if let playerName {
                        // Shot number and name together when it is a shot, the name
                        // alone otherwise — the same reading `HoleMarker.title`
                        // gives the pill on the hole, so a row and its marker say
                        // the same thing.
                        Label(log.shot.map { "\($0) · \(playerName)" } ?? playerName,
                              systemImage: "figure.golf")
                    }
                    if let holeLabel {
                        Label(holeLabel, systemImage: "flag")
                    } else {
                        // This row appears on *every* hole. Unlabelled it reads as
                        // a duplicate; labelled it reads as the open question it is.
                        Label("no hole", systemImage: "flag.slash")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var clock: String { LogTranscript.elapsed(log.t, from: start) }
}

/// One event. **A proposal and a fact must not look alike** — the model's guesses
/// are what the user is here to correct, and a confident-looking draft is how a
/// wrong score gets confirmed by accident.
private struct EventRow: View {
    let event: Event
    let players: [Player]
    /// The logs this rests on. Quoted under the claim, because "is this draft
    /// right?" is answered by reading what was actually said and nothing else.
    let evidence: [LogEntry]
    /// The hole, as the card writes it. Same rule as `LogRow.holeLabel`.
    var holeLabel: String?
    /// Draft, accepted, or thrown out — from the journal, never from the event.
    let status: RoundDocument.ProposalStatus
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(event.provenance == .user ? .primary : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                HStack(spacing: 6) {
                    if event.provenance == .user {
                        Text("YOU").font(.caption2.weight(.bold)).foregroundStyle(.tint)
                    } else {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(status == .accepted ? Color.green : .secondary)
                    }
                    if let holeLabel {
                        Label(holeLabel, systemImage: "flag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        // Same reason as `LogRow`: it is drawn on every hole.
                        Label("no hole", systemImage: "flag.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // **Only a draft offers the two buttons.** An accepted or
                    // rejected proposal keeps its badge and loses the controls —
                    // the decision is a journal row and the way back is Undo, not
                    // a second tap that would write a contradicting row.
                    if event.provenance == .model, status == .draft {
                        Button(action: reject) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        Button(action: accept) {
                            Image(systemName: "checkmark")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                }
                ForEach(evidence) { log in
                    HStack(alignment: .top, spacing: 5) {
                        Rectangle().fill(Color(.separator)).frame(width: 2)
                        Text(log.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        // A rejected proposal stays on screen — it is a labelled error, not
        // rubbish — but it must not read like a claim about the round.
        .opacity(status == .rejected ? 0.45 : (event.provenance == .model ? 0.9 : 1))
    }

    private var badge: String {
        switch status {
        case .accepted: return "ACCEPTED"
        case .rejected: return "REJECTED"
        case .draft:
            return event.confidence.map { String(format: "DRAFT · %.0f%%", $0 * 100) }
                ?? "DRAFT"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .shot: return "figure.golf"
        case .score: return "number"
        case .penalty: return "exclamationmark.triangle"
        case .holeChange: return "flag"
        case .note: return "text.bubble"
        case .pin: return "flag.checkered"
        }
    }

    /// The player's display name, not the id it is stored under — `Player.id`
    /// defaults to the name but survives a rename, and printing the raw id would
    /// show a stale one.
    private var playerName: String? {
        guard let id = event.player else { return nil }
        return players.first { $0.id == id }?.name ?? id
    }

    private var title: String {
        if event.kind == .note, let text = event.text, !text.isEmpty { return text }
        var parts: [String] = []
        if let p = playerName { parts.append(p) }
        switch event.kind {
        case .shot:
            // "shot" is a placeholder, not a fact — drop it the moment the lie or
            // the club says something. "dave · shot · bunker" reads like three
            // claims where there is one.
            if let club = event.club { parts.append(club) }
            else if event.lie == nil { parts.append("shot") }
        case .score: parts.append(event.strokes.map { "\($0)" } ?? "score")
        case .penalty: parts.append("penalty")
        case .holeChange: parts.append("moved on")
        case .note: break
        // Where the flag was cut. It is about the hole rather than about a player,
        // so it never has a name in front of it.
        case .pin: parts.append("pin placed")
        }
        if let lie = event.lie { parts.append(lie) }
        let head = parts.joined(separator: " · ")
        return head.isEmpty ? (event.text ?? "—") : head
    }
}
