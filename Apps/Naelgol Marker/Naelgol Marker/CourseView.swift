import SwiftUI
import Combine
import GolfSessionFormat
import GolfCourse
import GolfMap

/// Course files on the phone.
///
/// Real courses live in `Documents/Courses/*.json`, which `UIFileSharingEnabled`
/// exposes — a course file can be dropped in over Finder or the Files app without
/// a rebuild. The sample is installable from the UI so a fresh install has
/// something to draw before any round has been recorded or any course surveyed.
@MainActor
final class CourseLibrary: ObservableObject {
    @Published private(set) var courses: [Course] = []
    @Published var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "marker.course")
            // **The sidecar follows the course from the one place the course
            // changes.** It used to be called from the picker menu, which covered
            // the golfer switching course and *not* the importer: `save(_:)` writes
            // the file, calls `reload()`, and only then assigns `selectedID` — so
            // after a `CourseFinder` import the new course was selected while
            // `terrain` still held the old one's grid, every `delta` fell outside
            // its bounds, and the plays-like chip silently vanished. That is
            // precisely the "reads as a broken feature rather than a file that is
            // too small" failure the coverage check exists to catch, arriving by
            // the one road it cannot see. One authority, not four.
            loadTerrain()
        }
    }

    private let store = CourseStore.documents

    init() {
        selectedID = UserDefaults.standard.string(forKey: "marker.course")
        reload()
    }

    func reload() {
        courses = store.loadAll()
        if selectedID == nil || !courses.contains(where: { $0.id == selectedID }) {
            selectedID = courses.first?.id
        }
        // Not `terrainID = nil` first: `reload()` runs on every appearance of the
        // hole view and re-reading three quarters of a megabyte each time buys
        // nothing. `saveTerrain` adopts a freshly downloaded grid directly, and
        // `selectedID`'s observer covers a change of course.
        loadTerrain()
    }

    var selected: Course? { courses.first { $0.id == selectedID } }

    /// The selected course's terrain, held so it is read once rather than on every
    /// body evaluation — a grid is most of a megabyte, and `holeScreen` runs
    /// whenever a fix arrives.
    ///
    /// **Not loaded by `loadAll`.** It is a sidecar (`Courses/<id>.dem`) and most
    /// courses have none: no file imported before 2026-08-30 does, and Korea has
    /// no source at all yet. Nil simply means the plays-like chip does not appear.
    @Published private(set) var terrain: Elevation?
    private var terrainID: String?

    func saveTerrain(_ grid: Elevation, for id: String) {
        try? store.save(grid, for: id)
        // Adopted immediately rather than re-read: the sheet is dismissing and the
        // hole view behind it must not draw the previous answer for a frame.
        if id == selectedID { terrain = grid; terrainID = id }
    }

    /// Reads the sidecar when the selected course changes, and not otherwise.
    func loadTerrain() {
        guard terrainID != selectedID else { return }
        terrainID = selectedID
        terrain = selectedID.flatMap { store.loadElevation(id: $0) }
    }

    func installSample() {
        try? store.save(SampleCourse.naelgol)
        reload()
        selectedID = SampleCourse.naelgol.id
    }

    /// Write an edited course back. The editor holds its own copy while the user
    /// works, so this is the one place a placement becomes permanent.
    func save(_ course: Course) {
        var c = course
        c.updated = SessionClock.now()
        try? store.save(c)
        reload()
        selectedID = c.id
    }

    /// A course imported from a card has holes and no coordinates. Offering the
    /// editor rather than an empty map is the difference between "this app is
    /// broken" and "this course is not mapped yet".
    func newEmptyCourse(named name: String, holes: Int = 18) -> Course {
        Course(id: "course-\(SessionClock.now())", name: name, source: .traced,
               updated: SessionClock.now(),
               holes: (1...max(1, holes)).map {
                   Hole(ref: "\($0)", par: 4, tees: [TeeBox(name: "white")])
               })
    }

    var folderPath: String { store.directory.path }
}

/// The hole view, wired to the live round.
///
/// Two layers, one hole: `HoleScreen` draws the vector hole from the course file
/// with no network at all, or Apple's aerial imagery under the same overlays.
/// Vector is the default — no provider licenses stored imagery, and text over a
/// photograph is the worst case for a screen in afternoon sun.
struct CourseView: View {
    @ObservedObject var model: RoundViewModel
    /// The hole view needs a position whether or not a round is recording. Before
    /// this it had one only during a round, so every distance outside a round fell
    /// back to the tee and location looked broken.
    ///
    /// **Owned by the app, not by this screen** *(2026-08-28, X2)*. It used to be a
    /// `@StateObject` here, which meant the feed was born when the course screen
    /// appeared and died when it went away — so "on means slow tracking even in the
    /// background" could not be true, and the Location button would have reported a
    /// different state on each of the two screens that show it.
    @ObservedObject var live: LiveLocation
    /// The round this screen was opened from, if any.
    ///
    /// **Passed in rather than read from `RoundViewModel`, because a finished round
    /// has no `sessionName`.** Reading the recording round instead made Marker mean
    /// two different things under one label: on the scorecard it reopened a finished
    /// round, and here it did nothing at all. That is exactly the drift the shared
    /// bar exists to prevent — and it is silent, which is worse.
    var roundID: String?
    /// Which hole to open on. **The current one whenever this is reached from the
    /// map button** — everything else about the hole view is remembered between
    /// visits (layer, units, tee), but the hole is not: a golfer tapping the map
    /// wants where they are now, not where they were looking an hour ago.
    var holeRef: String?
    /// Where one log entry was recorded, when the golfer asked to see it. Marked
    /// and panned to, never fitted to — see `HoleScreen.focus`.
    var focus: Coordinate?
    @StateObject private var library = CourseLibrary()
    /// The OSM course finder sheet *(user, 2026-08-30)*.
    ///
    /// Seeded from a launch key in DEBUG, because it lives behind a `Menu` and
    /// `ImageRenderer` cannot draw one — the same reason `marker.sheet` and
    /// `marker.course` exist.
    @State private var finding = CourseView.startFinding
    /// X31 — the terrain download. Its own step, per the user's decision, and
    /// seeded the same way `finding` is and for the same reason: it is behind a
    /// `Menu`, so it is otherwise unreviewable here.
    @State private var terrainSheet = CourseView.startTerrain

    private static var startTerrain: Bool {
        #if DEBUG
        return DemoSeed.wantsTerrain
        #else
        return false
        #endif
    }

    private static var startFinding: Bool {
        #if DEBUG
        return DemoSeed.wantsFinder
        #else
        return false
        #endif
    }
    /// The recording round, so Marker can write from the hole view.
    ///
    /// **Resolved from `RoundViewModel`, not carried in**, because the hole view is
    /// reachable without a round at all — from the rounds list, to look at a course.
    /// Nil then, and the bar says "No round" rather than offering a button that
    /// would have nowhere to put a sentence.
    @State private var marking: MarkingRound?
    /// X3 — the simulated position, when the hole view is simulating one. Nil
    /// otherwise, which is the ordinary case and leaves the fix path untouched.
    @State private var simulated: Coordinate?
    /// X7 — the round's logs, for the marker layer. Reloaded when one is moved.
    @State private var logs: [LogEntry] = []
    /// **The round's own roster, not `RoundViewModel`'s** *(found 2026-08-28 by
    /// screenshotting the hole view with placed shots on it)*.
    ///
    /// `model.players` is the *setup screen's* list and is empty whenever the hole
    /// view was reached on a round that is not the one recording — which is most of
    /// the time, and every time a finished round is looked at. Everything X13 built
    /// hangs off matching a log's `player` id against it: with an empty roster a
    /// shot pill loses its name **and its colour**, and `tracks(for:)` returns
    /// nothing at all, so the connecting line the user asked for simply never
    /// appeared. Same rule as `MarkerSheet.roster` — mid-round `RosterEditor` edits
    /// live in the journal, so the journal is what has to be replayed.
    @State private var roster: [Player] = []
    /// The round's scores, replayed from the journal alongside the roster.
    ///
    /// The legend needs it to know a hole is **closed out** — holed out *is* having
    /// a score, deliberately rather than a second flag. See `PlayerTrack.score`.
    @State private var scorecard = Scorecard(strokes: [:])
    /// Today's flag per hole, by 1-based playing index — read from the round's
    /// events, written back as one *(user, 2026-08-28: "pin location should be
    /// draggable, this one doesn't get saved into db. but will be saved as
    /// event")*. Deliberately not the course file: a pin is cut fresh every
    /// morning, and writing it there would give every later round one afternoon's
    /// flag position. See `Event.Kind.pin`.
    @State private var pins: [Int: Coordinate] = [:]
    /// The event id each hole's current pin was written as, so the next drag
    /// **supersedes** it rather than adding another row *(user, 2026-08-28: "pin
    /// movement, don't log all. just keep the last position")*.
    ///
    /// Superseding rather than rewriting is how every correction in this app works
    /// — `LogEntry.supersedes`, `Correction`, `Event.supersedes` — and it is what
    /// makes "keep the last position" true of the *list* without making the file
    /// mutable: the old rows stay on disk, `Event.current` collapses the chain to
    /// one, so nudging the flag five times leaves one `pin placed` line rather than
    /// five.
    @State private var pinEvents: [Int: String] = [:]
    /// Which hole the hole view is on — `Hole.ref` and the 1-based playing index.
    /// X14: a marker made here is filed on it.
    @State private var currentHole: (ref: String, index: Int)?
    /// A marker the finger tapped, opened for editing. X13.
    @State private var editingLog: LogEntry?
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing = false
    @State private var editingHole: String?
    @State private var naming = false
    @State private var newCourseName = ""

    /// **In its own function with pre-typed locals, in declaration order.**
    /// This call has enough defaulted parameters — and now a trailing view builder
    /// as well — that leaving it inline in `body` fails outright with "unable to
    /// type-check this expression in reasonable time". Adding the bar is what
    /// pushed it over; splitting it out is the fix, not reordering the arguments.
    @ViewBuilder
    private func holeScreen(_ course: Course) -> some View {
        let here: Coordinate? = model.here ?? live.here
        // The accuracy of *that* fix, from whichever feed produced it — the ring on
        // the position marker is this number. Taken from the recorder first, for the
        // same reason `here` is: during a round it owns the radio and this feed
        // stands down.
        let acc: Double? = model.here != nil ? model.fixAccuracy : live.accuracy
        // **No MARK here** *(user, 2026-08-28)*. It was a red button across the
        // bottom of the hole view, a second capture control beside Marker doing
        // nearly the same job — and MARK's own rule (nothing simulated may reach
        // `marks.jsonl`) then had to be enforced in two places. It lives in the
        // Marker sheet, per player, which is also where the names are. Passing nil
        // puts the course name back in that slot, which is what it is for.
        let onMark: (() -> Void)? = nil
        // The pin button lives inside the hole view: it opens a menu (tee, layer,
        // units, simulation) rather than jumping straight into the editor, so
        // editing is one item in it rather than the whole button.
        let onEdit: (String) -> Void = { ref in
            editingHole = ref
            editing = true
        }
        let ref: String? = holeRef
        let at: Coordinate? = focus
        // Pre-typed like everything else here, and read from `@State` rather than
        // from disk: this function runs on every body evaluation and the grid is
        // most of a megabyte. Loaded once in `appear`, per course.
        let dem: Elevation? = library.terrain
        #if DEBUG
        let openCourse = DemoSeed.wantsCourseView
        let sim = DemoSeed.wantsSimulation
        // Targets, as fractions along the hole on screen. Placed by tapping in real
        // use; `HoleScreen` takes them as a parameter so the plan — and the
        // plays-like suffix on each leg — can be *rendered* in this environment.
        let seededTargets: [Coordinate] = {
            let f = DemoSeed.targetFractions
            guard !f.isEmpty,
                  let h = course.holes.first(where: { $0.ref == ref }) ?? course.holes.first,
                  let g = h.geometry() else { return [] }
            return f.prefix(2).map { Geodesy.interpolate(g.teeAt, g.greenCenter, $0) }
        }()
        // **From the roster, not from `tracks(for:)`.** `HoleScreen` seeds this into
        // `@State` in `init`, which runs once per view identity — and on that first
        // evaluation `currentHole` is still nil, so `tracks(for:)` returns an empty
        // array and the bump would be nil forever. The roster is the same list the
        // legend is built from and it is populated on load.
        let bump: HoleScreen<MarkerBar>.ScoreBump? = DemoSeed.scoreBump.flatMap { v in
            roster.first.map {
                HoleScreen<MarkerBar>.ScoreBump(id: $0.id, up: v != "down")
            }
        }
        #else
        let openCourse = false
        let sim = false
        let seededTargets: [Coordinate] = []
        let bump: HoleScreen<MarkerBar>.ScoreBump? = nil
        #endif
        HoleScreen(course: course,
                   holeRef: ref,
                   player: here,
                   accuracy: acc,
                   tracks: tracks(for: course),
                   targets: seededTargets,
                   simulating: sim,
                   showingCourse: openCourse,
                   bump: bump,
                   focus: at,
                   terrain: dem,
                   onMark: onMark,
                   onEditHole: onEdit,
                   onPosition: { simulated = $0 },
                   markers: markers,
                   pins: pins,
                   onMovePin: movePin,
                   onAddShot: addShot,
                   onHoleOut: holeOut,
                   onMarkerMoved: moveMarker,
                   onMarkerTapped: { id in
                       editingLog = LogEntry.current(logs).first { $0.id == id }
                   },
                   onHoleChanged: { ref, index in currentHole = (ref, index) }) {
            // The same bar the scorecard shows, handed in through the package's
            // `bottomBar` slot — `HoleScreen` is in `GolfMap` and Marker needs the
            // capture stack, which that target must not import.
            MarkerBar(model: model, live: live,
                      roundID: roundID ?? model.sessionName,
                      onMarker: openMarker,
                      onEndRound: nil,
                      onStartRound: reopenRound)
        }
    }

    /// X7 — the round's logs as things to draw.
    ///
    /// **Only placed ones.** A log with no fix has nowhere to go, and putting it at
    /// the tee or the hole centre would invent a position that nothing measured —
    /// the same reason `LogEntry.hasPosition` is a real answer rather than a
    /// failure.
    /// **No capture icon** *(X13, user 2026-08-28: "no need to show keyboard or
    /// record icon")*. How a sentence was captured is a fact about the app, not
    /// about the round, and it was repeated on every pill. What earns an icon is
    /// being a **shot** — a player and a number — because that is what somebody
    /// scanning the hole is looking for.
    private var markers: [HoleMarker] {
        // **Only this hole's** *(user, 2026-08-28: "markers from other holes should
        // not appear")*. They were drawn wherever their coordinates put them, so a
        // hole that runs back alongside the previous one carried the previous
        // one's captions across it. `tracks(for:)` has always filtered this way;
        // the pills had not. A row with **no** hole is still drawn, the same rule
        // the round screen's timeline follows: it could not be placed, so it
        // belongs to every hole rather than to none.
        let here = currentHole?.index
        return LogEntry.current(logs).compactMap { log in
            guard log.hole == nil || log.hole == here else { return nil }
            guard let lat = log.lat, let lon = log.lon else { return nil }
            let slot = roster.firstIndex { $0.id == log.player }
            return HoleMarker(id: log.id,
                              at: Coordinate(lat: lat, lon: lon),
                              // **No icon on a shot either, as of 2026-08-30**
                              // ("no club icon or name"). A shot is now a numbered
                              // circle in the player's colour, and the golfer glyph
                              // was one more thing repeated on every dot.
                              symbol: nil,
                              label: HoleMarker.abbreviate(log.text),
                              shot: log.shot,
                              player: slot.map { roster[$0].name },
                              colorIndex: slot)
        }
    }

    /// A confirmed drag. Written as a **superseding row**, which is how a log is
    /// amended everywhere else — the original stays in `log.jsonl`, so a proposal
    /// that cites it still renders its evidence and the move is retraceable.
    private func moveMarker(_ id: String, _ to: Coordinate) {
        guard let name = roundID ?? model.sessionName else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        // **The chain head, re-read from disk.** Two writers grow one chain —
        // `LogPlacement` appends the converged coordinate — and editing a cached
        // copy forks it, so `LogEntry.current` keeps one head and the other's work
        // is silently dropped.
        guard let head = LogStore.head(ofChainFrom: id, in: folder) else { return }
        // The hole is recomputed from the *new* position by `LogPlacement`, not
        // carried over: it means "nearest hole to a measured fix", and this is a new
        // position. `hAcc` is kept — the fix that arrived was as good as it was, and
        // the user moving the pin does not make it better or worse.
        let moved = head.placed(lat: to.lat, lon: to.lon, hAcc: head.hAcc, hole: nil)
        _ = try? LogStore.shared.append(moved, to: folder)
        loadLogs()
    }

    /// A dragged flag, appended to `events.jsonl`.
    ///
    /// **Written straight through a `JSONLWriter` rather than through a
    /// `RoundDocument`.** This screen holds no document — it builds one for the
    /// Marker sheet and throws it away — and `RoundDocument.append` replays the
    /// journal and rewrites `scorecard.json` behind it, which is a lot of machinery
    /// for one coordinate. The writer is `O_APPEND` + `flock`, so a second writer
    /// on the same file is safe by construction.
    private func movePin(hole: Int, to c: Coordinate) {
        pins[hole] = c
        guard let name = roundID ?? model.sessionName else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        // **Supersedes this hole's previous pin, so the round keeps one.**
        let event = Event(id: id,
                          t: SessionClock.now(), kind: .pin, provenance: .user,
                          hole: hole, lat: c.lat, lon: c.lon,
                          supersedes: pinEvents[hole])
        pinEvents[hole] = id
        guard let w = try? folder.writer(.events) else { return }
        try? w.append(event)
        try? w.sync()
        try? w.close()
    }

    private func loadLogs() {
        guard let name = roundID ?? model.sessionName else { logs = []; roster = []; return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        logs = folder.readAll(.log, as: LogEntry.self)
        // The latest surviving `.pin` per hole. `Event.current` collapses the
        // supersede chains; a later row for the same hole simply wins, which is
        // what dragging the flag twice means.
        var flags: [Int: Coordinate] = [:]
        var ids: [Int: String] = [:]
        for e in Event.current(folder.readAll(.events, as: Event.self))
            .filter({ $0.kind == .pin })
            .sorted(by: { $0.t < $1.t }) {
            guard let h = e.hole, let lat = e.lat, let lon = e.lon else { continue }
            flags[h] = Coordinate(lat: lat, lon: lon)
            ids[h] = e.id
        }
        pins = flags
        pinEvents = ids
        // **Replayed, not read from `meta.json`** — a player added mid-round exists
        // only in the journal. `JournalReplay.replay` is pure; this deliberately
        // does *not* go through `RoundDocument`, which rewrites `scorecard.json` on
        // every replay and would do it once per phrase during a burst.
        let meta = try? folder.readMeta()
        let seed = RoundState(players: meta?.players ?? [], course: meta?.course)
        let state = JournalReplay.replay(folder.readAll(.journal, as: JournalEntry.self),
                                         seed: seed)
        roster = state.players
        scorecard = state.scorecard
    }

    /// The other half of the Round toggle — reopen the round this screen came from,
    /// so a hole view opened on a finished round is not a dead end.
    private func reopenRound() {
        guard let name = roundID else { return }
        Task { await model.reopenRound(id: name) }
    }

    /// Opens the Marker sheet on the recording round, if there is one.
    ///
    /// Silent when there is not, because the bar has already said "No round" — a
    /// sheet that opened and then explained it could not write anything would be
    /// worse than a button that does nothing.
    private func openMarker() {
        // The round this screen came from first; the recording one otherwise. Nil
        // only when the hole view was reached without a round at all, and the bar
        // has already said "No round".
        guard let name = roundID ?? model.sessionName else { return }
        let url = RoundViewModel.sessionsRoot.appendingPathComponent(name)
        let course = library.selected
        marking = MarkingRound(id: name,
                               doc: RoundDocument(folder: SessionFolder(url: url)),
                               simulated: simulated,
                               hole: currentHole?.index,
                               holeRef: currentHole?.ref ?? "this hole",
                               holes: course.map { c in
                                   c.holes.enumerated().map { ($0.offset + 1, $0.element.ref) }
                               } ?? [])
    }

    var body: some View {
        Group {
            if let course = library.selected {
                if course.hasGeometry {
                    // Arguments in declaration order and pre-typed: this call has
                    // enough defaulted parameters that letting the type-checker
                    // reorder them blows its budget outright.
                    // **Identity per course, and this is load-bearing.**
                    // `HoleScreen` seeds `holeIndex` and the remembered tee in its
                    // initialiser, and `@State` initial values apply once per view
                    // *identity* — so switching course from the menu here keeps the
                    // same identity, `init` never re-runs, and the previous course's
                    // tee carries over unvalidated. That is precisely the "Black on
                    // a course with no black tee" failure `HoleScreen.rememberedTee`
                    // exists to prevent, arriving through the one path it could not
                    // see; the hole index does the same, so hole 14 of an 18 renders
                    // "no holes in this course" on a nine.
                    holeScreen(course)
                        .id(course.id)
                        .ignoresSafeArea(edges: [.top, .bottom])
                } else {
                    unmapped(course)
                }
            } else {
                empty
            }
        }
        .modifier(MarkerSheetPresenter(model: model, live: live, marking: $marking,
                                       onDismiss: loadLogs))
        // **A marker written here has to appear here** *(user, 2026-08-28: "just
        // created marker is not shown in gps hole view")*. `logs` was read once on
        // appear, so an entry the Marker sheet wrote over this very screen was
        // invisible until the view was left and re-entered.
        //
        // Two signals, because one is not enough. `onDismiss` above covers the
        // entry that had a warm fix; this covers the one that did not — `place()`
        // converges in a detached task that routinely lands *after* the sheet has
        // gone, and a log with no coordinate is not drawn at all, so dismissal
        // alone would show nothing in exactly the case the golfer waited for.
        //
        // **`.receive(on:)` is load-bearing** and so is `SessionFolder.isSame`:
        // convergence appends from a background queue, and two URLs for one folder
        // compare unequal when one was built before the directory existed. That
        // exact comparison cost twenty-nine invisible logs on the round screen.
        .onReceive(NotificationCenter.default.publisher(for: LogStore.didAppend)
                     .receive(on: RunLoop.main)) { note in
            guard let name = roundID ?? model.sessionName else { return }
            let mine = SessionFolder(url: RoundViewModel.sessionsRoot
                                            .appendingPathComponent(name))
            if let object = note.object as? URL, !mine.isSame(as: object) { return }
            loadLogs()
        }
        // X13 — a tapped marker opens its dialog. `body` is already at the
        // type-checker's budget, which is why the content is its own function.
        .sheet(item: $editingLog) { markerEditor($0) }
        .sheet(isPresented: $editing) {
            if let course = library.selected {
                NavigationStack {
                    CourseEditorView(course: course, here: model.here,
                                     startAt: editingHole) { edited in
                        library.save(edited)
                        editing = false
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { editing = false }
                        }
                    }
                    .navigationTitle("Place tees and greens")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .alert("New course", isPresented: $naming) {
            TextField("내골 CC", text: $newCourseName)
            Button("Create") {
                let name = newCourseName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                library.save(library.newEmptyCourse(named: name))
                newCourseName = ""
                editingHole = nil
                editing = true
            }
            Button("Cancel", role: .cancel) { newCourseName = "" }
        } message: {
            Text("18 holes, par 4, one white tee — all placeholders you correct as you map it.")
        }
        // No course name up here — it is at the bottom of the hole view, set large.
        // Spending the top strip on a string that never changes was costing the most
        // valuable row on the screen. The *bar* stays: hiding it takes the back
        // button and the course switcher with it.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Transparent rather than hidden: the distance runs up through this band to
        // the top of the display, and hiding the bar would take the back button and
        // the course switcher with it.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // No pin here any more — a mapped hole carries its own settings menu in
            // the top right of the hole view, and an unmapped course offers the
            // editor as its primary action. Two pins meaning different things in the
            // same corner was the confusing part.
            // **Always a menu now, even with one course**, because it carries
            // *Find a course* — the only way into the OSM importer from the phone,
            // and hiding it behind "you already have two courses" would make it
            // unreachable on the install that needs it most.
            Menu {
                ForEach(library.courses) { c in
                    // The terrain follows from `selectedID`'s own observer — see
                    // `CourseLibrary`. Doing it here as well is a second authority
                    // that agrees right up until the day something else selects a
                    // course, which is what happened.
                    Button(c.name) { library.selectedID = c.id }
                }
                Divider()
                Button {
                    finding = true
                } label: {
                    Label("Find a course…", systemImage: "magnifyingglass")
                }
                // **A separate step from the import** *(user, 2026-08-30)*. A DEM is
                // another request and three quarters of a megabyte, and it finds
                // nothing outside the US, so it is asked for rather than assumed.
                if library.selected != nil {
                    Button {
                        terrainSheet = true
                    } label: {
                        Label(library.terrain == nil ? "Get terrain…" : "Terrain…",
                              systemImage: "mountain.2")
                    }
                }
            } label: { Image(systemName: "list.bullet") }
        }
        .sheet(isPresented: $finding) {
            CourseFinder(here: model.here ?? live.here,
                         existingIDs: Set(library.courses.map(\.id))) { course in
                library.save(course)
            }
        }
        .sheet(isPresented: $terrainSheet) {
            if let c = library.selected {
                TerrainSheet(course: c, existing: library.terrain) { grid in
                    library.saveTerrain(grid, for: c.id)
                }
            }
        }
        .onAppear { appear() }
        // Leaving the hole view gives the radio back — but only this screen's
        // claim on it. A Marker sheet that is somehow still holding one keeps it.
        .onDisappear {
            live.setFast(false, for: .holeView)
            model.trackFast(false, for: .holeView)
        }
        .onChange(of: scenePhase) { _, phase in
            // **Fast is for a screen somebody is looking at.** The hole view asks
            // for fast while it is up *(user, 2026-08-30)*, and a phone in a pocket
            // is not somebody looking at it — so backgrounding drops this screen's
            // claim and coming back re-asserts it. The feed itself keeps running
            // either way: "background tracking as well in slow mode" is the other
            // half of the same request, and `allowsBackgroundLocationUpdates` plus
            // `UIBackgroundModes: location` are what deliver it.
            //
            // **This used to be an unconditional `track(.slow)`, and it silently ate
            // the fast request** — `scenePhase` reaches `.active` after `onAppear`,
            // so the hole view asked for fast and this handler took it away one
            // event later. Caught by screenshot: the Location button read Slow on a
            // screen that had just asked for Fast.
            if model.isRecording {
                live.track(.off)
            } else {
                live.setFast(phase == .active, for: .holeView)
            }
            model.trackFast(phase == .active, for: .holeView)
        }
        // Stand-down and fix adoption are the app's job now, not this screen's —
        // see `MarkerApp`. What is left here is only this screen's own rate.
        .onChange(of: model.isRecording) { _, recording in handOver(recording) }
    }

    /// A course with a card and no coordinates — the state every scorecard import
    /// lands in. There is nothing to draw, and saying so beats an empty map.
    private func unmapped(_ course: Course) -> some View {
        ContentUnavailableView {
            Label("\(course.name) is not mapped yet", systemImage: "mappin.slash")
        } description: {
            Text("""
                 \(course.holes.count) holes with par and yardage, and no coordinates — \
                 a scorecard has none. Place a tee and a green centre per hole and \
                 the hole view starts drawing.
                 """)
        } actions: {
            Button("Place tees and greens") { editingHole = nil; editing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No course geometry", systemImage: "map")
        } description: {
            Text("""
                 A hole can only be drawn once its tee and green are known. Drop a \
                 course file into Courses/ over the Files app, or install the sample \
                 to see both layers now.
                 """)
        } actions: {
            VStack(spacing: 12) {
                // **First, because it is the one that gives a real course.**
                // The sample exists so a fresh install can draw *something*; this
                // downloads the course the golfer is standing on.
                Button("Find a course…") { finding = true }
                    .buttonStyle(.borderedProminent)
                Button("Install sample course") { library.installSample() }
                // A blank 18 plus the editor is the no-scorecard path: stand on
                // the course, tap "I'm standing here" on each tee and green, and
                // the file builds itself over one round.
                Button("Start a new course here") { naming = true }
                Text(library.folderPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// One track per player, starting at the tee and running through this round's
    /// MARKs. Until reconstruction exists (Phase 3) a MARK *is* the shot record,
    /// so this is the honest version of "four players on one hole".
    /// One line per player through the shots they played **on the hole being
    /// looked at** *(X13, user 2026-08-28: "connect the player's shots with line")*.
    ///
    /// Three things this has to get right, all of which the obvious version does
    /// not:
    ///
    /// - **Filtered to this hole.** `PlayerTrack.allPoints` feeds
    ///   `VectorHoleView.extraPoints`, which feeds the *framing fit* — so a shot
    ///   logged on the ninth would shrink the hole on screen to a dot to keep a
    ///   point half a mile away in frame. That is the bug the framing rule exists
    ///   for, arriving by a new road.
    /// - **It starts at shot 1, not at the tee** *(user, 2026-08-28: "why a line to
    ///   the first shot marker of a player. it should start from shot #1")*. The
    ///   tee used to be element 0, which drew a leg from the tee box to wherever
    ///   the drive finished — the one leg on the hole that nobody logged, in the
    ///   same line weight as the legs that were. A player with one shot now draws
    ///   no line, which is the honest answer: a line needs two ends. Both renderers
    ///   dropped their `dropFirst()` with it, or shot 1 would have lost its dot.
    /// - **Ordered by shot number, not by time.** The numbers are what a person
    ///   assigned; the order they typed them in is not.
    private func tracks(for course: Course) -> [PlayerTrack] {
        guard let hole = currentHole,
              course.holes.indices.contains(hole.index - 1)
        else { return [] }
        let shots = LogEntry.current(logs).filter { $0.isShot && $0.hole == hole.index }
        // **One per player, always** *(user, 2026-08-28: "always show player names
        // on the left side")*. The legend is the round's roster and a switch for
        // each name, not a key to whatever happens to be drawn on this hole — and
        // a player with no shots here still has a next one to file. A track with
        // fewer than two points draws no line and contributes no framing points,
        // so an empty one costs nothing on screen.
        return roster.enumerated().map { index, player in
            // **Carrying the shot number, not just the point.** A leg only earns a
            // distance label when it *skips* one — 1 to 3 with the 2 never logged —
            // and without the numbers every gap looks like every other gap.
            let mine = shots.filter { $0.player == player.id && $0.hasPosition }
                .sorted { ($0.shot ?? 0) < ($1.shot ?? 0) }
                .map { PlayerTrack.Shot(number: $0.shot,
                                        at: Coordinate(lat: $0.lat!, lon: $0.lon!)) }
            return PlayerTrack(id: player.id, name: player.name,
                               colorIndex: index, shots: mine,
                               // The same answer the Marker sheet's stepper
                               // auto-fills, from the same function over the same
                               // rows — two ways of working it out is two numbers
                               // that disagree the first time somebody edits a log.
                               nextShot: LogEntry.nextShot(for: player.id,
                                                           hole: hole.index,
                                                           in: logs),
                               // Holed out *is* having a score — no second flag.
                               score: scorecard.strokes[player.id]?[hole.index])
        }
    }

    /// **One tap files a shot where the golfer is standing** *(user, 2026-08-28:
    /// "if it's clicked create shot marker for the user at the current location or
    /// simulated position")*.
    ///
    /// It writes the same row the Marker sheet writes — hole `.user`, player, shot,
    /// and the `"1: 3"` prefix that is what a person reads in the timeline and what
    /// the extraction pass reads in `log.jsonl` — with no text after it, which is
    /// the empty-OK case the sheet already allows.
    ///
    /// **A simulated position wins**, the same knowing trade X3 records: simulation
    /// exists to try the app somewhere other than where the phone is, and a shot
    /// filed at the desk instead would make the mode useless.
    private func addShot(player: String, shot: Int) {
        guard let name = roundID ?? model.sessionName,
              let hole = currentHole else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        // Simulated first, then the round's own fix, then the view's feed — the
        // same order `MarkerSheet.send` uses, and for the same reasons.
        // **A coordinate with no accuracy is not a placed log**, so the pair is
        // taken or nothing is: `LogEntry.isPlaced` reads `hAcc ?? .infinity`, and a
        // row with a position and no accuracy joins the convergence backlog to ask
        // the radio for what it was already handed.
        let fix: (Coordinate, Double?)? = simulated.map { ($0, 0) }
            ?? model.fix.map { ($0.0, $0.1) }
            ?? live.here.map { ($0, live.state.accuracy) }
        // The button is disabled without one — `HoleScreen` gates it on the same
        // position this reads — so this is a belt, not the ordinary path.
        guard let fix else { return }
        let entry = LogEntry(text: "\(hole.ref): \(shot)",
                             lat: fix.0.lat, lon: fix.0.lon, hAcc: fix.1,
                             hole: hole.index, holeSource: .user,
                             player: player, shot: shot,
                             source: .typed)
        _ = try? LogStore.shared.append(entry, to: folder)
        loadLogs()
        // **Written first, placed second** — the same second half `MarkerSheet`
        // does for the same reason: `RoundScreen`'s convergence task is a stack
        // frame away holding a different document, so a shot filed here with a
        // warm-but-coarse fix would keep it. Safe to run alongside that task by
        // construction: `LogPlacement.attempted` is a reservation and a converged
        // log is no longer `unplaced`.
        guard model.isRecording else { return }
        Task {
            for log in LogPlacement.unplaced(logs) {
                await LogPlacement.converge(log, in: folder)
            }
            loadLogs()
        }
    }

    /// The tapped marker's dialog — X13.
    ///
    /// **Closing a hole out is one `setScore` row, and reopening it is the same row
    /// with nil** *(user, 2026-08-29: "swiping shot # to right closes it, i.e. hole
    /// out, no more shot creation on the hole")*.
    ///
    /// A score is what "holed out" means here, rather than a flag on the view: a
    /// local flag dies on relaunch, never reaches `ScorecardBand`, and makes the
    /// golfer type the number twice. Journalled, it undoes through `HistoryView`
    /// and the card is a view of it, which is the rule this whole file follows.
    ///
    /// **The number committed is the one already on screen** *(user, 2026-08-29:
    /// "hole out swipe means the last shot is in the hole, meaning, current shot #
    /// is the score")* — `HoleScreen.scoreCell` decides it and this only writes it
    /// down. "Holing out is a shot" still holds and has moved rather than been
    /// reversed: the stroke that goes in is the last marker the golfer *filed*, so
    /// there is nothing left to add at swipe time. See that method for the whole
    /// argument; two places working the number out is two numbers that disagree.
    ///
    /// Appended straight through a `JSONLWriter`, exactly like `movePin` — a
    /// `RoundDocument` would replay the journal and rewrite `scorecard.json` for
    /// one number, once per swipe.
    private func holeOut(player: String, strokes: Int?) {
        guard let hole = currentHole,
              let name = roundID ?? model.sessionName else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        // Read the previous value **before** the optimistic write, or `prevStrokes`
        // records the new one and the history says the score never changed.
        var byHole = scorecard.strokes[player] ?? [:]
        let previous = byHole[hole.index]
        // Optimistic, so the legend flips under the thumb rather than after a read.
        byHole[hole.index] = strokes
        scorecard.strokes[player] = byHole
        let entry = JournalEntry(act: .setScore, player: player,
                                 hole: hole.index, strokes: strokes,
                                 prevStrokes: previous)
        guard let w = try? folder.writer(.journal) else { return }
        try? w.append(entry)
        try? w.sync()
        try? w.close()
    }

    /// **Presented from here rather than from inside `HoleScreen`**, for the same
    /// reason `MarkerBar` is: editing a log needs `LogStore` and `RoundDocument`,
    /// and `GolfMap` must not import the capture stack.
    @ViewBuilder private func markerEditor(_ log: LogEntry) -> some View {
        let holes = library.selected.map { c in
            c.holes.enumerated().map { (index: $0.offset + 1, ref: $0.element.ref) }
        } ?? []
        LogEditor(log: log, holes: holes, players: roster) { text, hole, player, shot in
            amendMarker(log, text: text, hole: hole, player: player, shot: shot)
            editingLog = nil
        } cancel: { editingLog = nil } delete: {
            deleteMarker(log)
            editingLog = nil
        }
    }

    /// A superseding row off the **chain head read from disk**, never off the copy
    /// the hole view is drawing — `LogPlacement` grows the same chain with the
    /// converged coordinate, and superseding a stale row forks it.
    /// **A tombstone, not an erasure** *(user, 2026-08-28: "marker edit dialog: need
    /// delete")*. `LogEntry.deleted` is how a log is removed everywhere else: the
    /// row stays in `log.jsonl`, `LogEntry.current` drops it, and a proposal that
    /// cited it still renders its evidence rather than a claim resting on nothing.
    private func deleteMarker(_ log: LogEntry) {
        guard let name = roundID ?? model.sessionName else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        guard let head = LogStore.head(ofChainFrom: log.id, in: folder) else { return }
        _ = try? LogStore.shared.append(head.removed(), to: folder)
        loadLogs()
    }

    private func amendMarker(_ log: LogEntry, text: String, hole: Int?,
                             player: String?, shot: Int?) {
        guard let name = roundID ?? model.sessionName else { return }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        guard let head = LogStore.head(ofChainFrom: log.id, in: folder),
              let next = head.edited(text: text, hole: .some(hole),
                                     player: .some(player), shot: .some(shot))
        else { return }
        _ = try? LogStore.shared.append(next, to: folder)
        loadLogs()
    }

    private func appear() {
        library.reload()
        library.loadTerrain()
        // **Always-authorization is asked for here and only here.** It is the one
        // screen that is a statement of intent — somebody is looking at a hole, on a
        // course — and background tracking (`allowsBackgroundLocationUpdates`) is
        // refused by iOS without it. `escalateAuthorization` returns early unless
        // this has been called, which is what keeps a launch from throwing a dialog
        // at somebody who has not opened anything.
        live.requestAuthorization()
        loadLogs()
        handOver(model.isRecording)
        // **Belt.** Opening a hole view is a statement that nobody is mid-sentence,
        // so guarantee the recorded track has a scheduled way back to slow even if
        // a burst died before `stopListening` could arrange one. Scheduled rather
        // than immediate: a golfer who opens the map straight after speaking is
        // still inside the placement window, and cutting that short is the one thing
        // fast tracking during a burst exists for.
        if model.isRecording { model.handBackRadio() }
        // **Fast while this screen is up** *(user, 2026-08-30: "fast track when gps
        // hole view is on screen, slow when not")*. This reverses the 2026-08-28
        // decision that gave fast to the Marker sheet alone; the recorded track and
        // the view's own feed both take it, each under its own reason so the sheet's
        // hand-back cannot drop this one.
        live.setFast(true, for: .holeView)
        model.trackFast(true, for: .holeView)
    }

    /// While a round records, `LocationRecorder` owns the radio and writes the
    /// track. Two managers asking for Best is twice the power for one position, so
    /// this feed stands down and adopts the recorder's fixes for the indicator.
    /// **Slow, not fast** *(user, 2026-08-28: "in gps hole view, location tracking
    /// is fast always, I want it to be slow, and becomes fast when marker is up")*.
    ///
    /// A hole view is open for most of a round — it is the screen a golfer walks
    /// with — and reading a yardage does not need a fix a second. Saying what just
    /// happened does, and that is the Marker sheet, which escalates both feeds on
    /// the way in and drops them on the way out. This also closes TODO item 17 from
    /// the other end: the answer was not to make the hole view speed the *recorded*
    /// track up as well, but to stop it speeding anything up.
    private func handOver(_ recording: Bool) {
        live.standDown(recording)
        if recording {
            live.track(.off)
        } else {
            live.setFast(true, for: .holeView)
        }
        // **Re-assert on the recorder too.** `RoundViewModel.trackFast` is a no-op
        // with no session, so a round *started* while this screen is open would
        // begin at slow on the one screen that is asking for fast — the reason is
        // held and nothing ever applies it.
        model.trackFast(true, for: .holeView)
    }
}

/// The Marker sheet, as a modifier rather than another `.sheet` on `CourseView.body`.
///
/// **`body` there is already at the type-checker's budget** — the file carries a
/// comment about it, and adding the hole view's bottom bar plus one more sheet was
/// what tipped it over into "unable to type-check this expression in reasonable
/// time". Splitting the presentation out is the fix; reordering the chain is not.
@MainActor
private struct MarkerSheetPresenter: ViewModifier {
    @ObservedObject var model: RoundViewModel
    @ObservedObject var live: LiveLocation
    @Binding var marking: MarkingRound?
    /// Re-read the round's logs when the sheet goes. What it just wrote is what
    /// this screen draws.
    var onDismiss: () -> Void

    func body(content: Content) -> some View {
        // Marker from the hole view writes to the round that is recording — the same
        // `LogStore` path the round screen uses, not a second one.
        //
        // **It is filed on the hole being looked at** *(X14, user 2026-08-28:
        // "marker's hole — it should be the current hole")*. It used to be filed
        // with no hole at all, because `LogEntry.hole` meant "nearest hole to a
        // measured fix" and stamping the hole on screen would have put a second,
        // unmeasured claim in that one field. That objection is answered rather than
        // ignored: `LogEntry.HoleSource` now says which of the two a row's hole is,
        // and `LogEntry.placed` refuses to recompute a `.user` one — which is also
        // the fix for the hole flipping by itself a few seconds after it was set.
        content.sheet(item: $marking, onDismiss: onDismiss) { round in
            MarkerSheet(model: model, live: model.liveTranscript, doc: round.doc,
                        location: live,
                        hole: round.hole, holeRef: round.holeRef,
                        holes: round.holes, roundID: round.id,
                        override: round.simulated)
        }
    }
}

/// The round the Marker sheet is open on.
///
/// **A box rather than conforming `RoundDocument` to `Identifiable`.** A document is
/// a folder, and giving it an identity for the benefit of one `.sheet(item:)` would
/// invite `==` between two documents of the same round — which is the trap
/// `SessionFolder.isSame` exists for, since two URLs for one folder compare unequal
/// when one was built before the directory existed.
private struct MarkingRound: Identifiable {
    let id: String
    let doc: RoundDocument
    /// The simulated position, when the hole view is simulating. X3.
    var simulated: Coordinate?
    /// The hole on screen when Marker was tapped — playing index and `Hole.ref`. X14.
    var hole: Int?
    var holeRef: String = "this hole"
    /// The round's holes, for the sheet's hole picker. X15.
    var holes: [(index: Int, ref: String)] = []
}
