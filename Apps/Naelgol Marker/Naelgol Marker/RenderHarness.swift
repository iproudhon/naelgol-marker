#if DEBUG
import SwiftUI
import GolfSessionFormat

/// Demo data and a deep link, so the two screens can be *seen* without a finger.
///
/// **`ImageRenderer` is no use here.** It already could not draw a SwiftUI `Menu`;
/// it cannot draw a `List` either, and both of these screens are lists — the whole
/// page comes back as the yellow prohibition box. So review happens the other way
/// round: seed real session folders, launch the real app in the simulator, and take
/// a real screenshot.
///
///     xcrun simctl launch <device> com.naelgol.Naelgol-Marker \
///         -marker.seed 1 -marker.open session-2026-08-26-0705
///     xcrun simctl io <device> screenshot round-events.png
///
/// `-marker.seed` wipes `Sessions/` and writes three rounds; `-marker.open` pushes
/// straight to one. Both are DEBUG-only and inert without the argument.
enum DemoSeed {
    static var wantsSeed: Bool { UserDefaults.standard.bool(forKey: "marker.seed") }
    /// Wipe `Sessions/` and seed nothing — the fresh-install state.
    static var wantsWipe: Bool { UserDefaults.standard.bool(forKey: "marker.wipe") }
    /// Hole to select on the round screen, so the middle band can be reviewed —
    /// it is otherwise whichever hole has no scores yet, which is by definition
    /// the one with nothing on it.
    static var openHole: Int? {
        let v = UserDefaults.standard.integer(forKey: "marker.hole")
        return v > 0 ? v : nil
    }
    /// Which sheet to open on the round screen: `history`, `roster`, `detail`,
    /// `marker`, `export`.
    ///
    /// **Scripted taps do not exist in this environment**, so a sheet that is only
    /// reachable through a menu is a sheet nobody can look at before it ships.
    /// This is the same argument as `openRound` and `openHole`.
    static var openSheet: String? {
        let v = UserDefaults.standard.string(forKey: "marker.sheet")
        return (v?.isEmpty == false) ? v : nil
    }

    /// Open the round importer on the rounds list, optionally with an export
    /// already in the box: `-marker.import YES -marker.import.file /path/to/round.txt`.
    ///
    /// Both halves are needed for the same reason `marker.find.query` is. The sheet
    /// lives behind a menu on the first screen, so without the flag it cannot be
    /// looked at at all; and an *empty* importer shows none of what the feature is
    /// actually for — the decoded summary, the ground-truth line, the warning that
    /// the recordings did not travel. Those only appear once something has been
    /// pasted, and there is no way to paste here.
    static var wantsImport: Bool { UserDefaults.standard.bool(forKey: "marker.import") }

    /// Renders the export sheet with **terrain switched off** —
    /// `-marker.sheet export -marker.export.terrain no`.
    ///
    /// Same argument as every other key here: it is a `Toggle`, and a toggle is
    /// flipped by a finger. Without this only the on state can ever be looked at,
    /// and the off state is the one that changes three rows at once — the summary
    /// says "terrain left out", the size collapses, and the wire form usually flips
    /// from compressed to readable JSON because terrain was most of the bytes.
    static var exportIncludesTerrain: Bool {
        UserDefaults.standard.string(forKey: "marker.export.terrain").map {
            !["no", "NO", "0", "off"].contains($0)
        } ?? true
    }

    /// Pushes straight to the New round setup screen — `-marker.new YES`.
    ///
    /// It is reached by tapping `+` on the rounds list, and scripted taps do not
    /// exist here. Without it the roster fields could not be looked at at all —
    /// which is exactly what changed on 2026-08-31, when the alias row went and the
    /// remembered roster went with it.
    static var wantsNewRound: Bool { UserDefaults.standard.bool(forKey: "marker.new") }

    /// Opens one player's own screen inside the roster sheet —
    /// `-marker.sheet roster -marker.player steve`.
    ///
    /// `PlayerEditor` sits behind a `NavigationLink` in that sheet, so `marker.sheet
    /// roster` gets one tap short of it. Same argument as `marker.new`: without this
    /// the screen that holds the name field, the index and the tee picker could not
    /// be looked at at all.
    static var openPlayer: String? {
        let v = UserDefaults.standard.string(forKey: "marker.player")
        return (v?.isEmpty == false) ? v : nil
    }

    /// Move a seeded round into the trash on launch, so "Recently deleted" can be
    /// looked at: `-marker.trash YES`.
    ///
    /// The section is drawn only when the trash has something in it, and the only
    /// way to put something there is to swipe a row and confirm a dialog — two taps
    /// that do not exist in this environment. Without this the section, its expiry
    /// line, its footer and its Empty button would all ship unlooked-at.
    /// `-marker.trash YES` seeds one, `-marker.trash confirm` opens the delete
    /// confirmation instead.
    static var trashMode: String? {
        let v = UserDefaults.standard.string(forKey: "marker.trash")
        return (v?.isEmpty == false) ? v : nil
    }

    /// The file named by `marker.import.file`, opened as though it had been picked
    /// out of the file importer. Nil when the key is absent.
    ///
    /// **It goes down the file road, not the paste road**, because the picker itself
    /// is a system sheet nothing here can drive: this is the only way the read, the
    /// "From <file>" row and the unreadable-file message get looked at before they
    /// ship. It does *not* prove the security-scoped call — a plain path in the
    /// simulator is already inside the sandbox — so that half stays unverified.
    /// A path that does not exist is left to the ordinary failure message rather
    /// than checked for, since that message is a thing worth seeing.
    static var importFile: URL? {
        guard let path = UserDefaults.standard.string(forKey: "marker.import.file"),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Start a round on launch and open it, so the recording controls can be
    /// looked at.
    ///
    /// **The record button and the live caption pane exist only while a round is
    /// recording**, and starting one takes a tap on the list, a tap on New round,
    /// a roster and a tap on Start. Scripted taps do not exist in this
    /// environment, so without this the whole feature is unreviewable before it
    /// reaches a phone — the same argument as `openSheet` and `openRound`, just
    /// one screen earlier.
    ///
    /// Optionally `-marker.record YES` as well, to open the microphone burst too.
    /// That one really does record: the simulator has a working microphone (it
    /// borrows the Mac's) and no speech model at all, which is exactly the split
    /// the pane is built to show honestly.
    /// Push straight through to the hole view.
    ///
    /// **Same argument as `openSheet`, one screen further out.** The hole view is
    /// reachable only by tapping the map button in the round screen's toolbar, and
    /// scripted taps do not exist here — so `MarkerBar` on that screen, which is
    /// half of what X1 asked for, would otherwise ship unlooked-at. Also opens the
    /// sheet with `-marker.sheet marker`.
    static var wantsMap: Bool { UserDefaults.standard.bool(forKey: "marker.map") }

    /// Opens the whole-course view on top of the hole view — `-marker.map YES
    /// -marker.course YES`.
    ///
    /// **The same argument again, one level deeper.** The course view is a sheet
    /// behind the pin *menu*, so it needs two taps that do not exist here to reach,
    /// and `ImageRenderer` draws neither a `Menu` nor a MapKit `Map`. Without this
    /// key nothing in this environment can see it at all.
    static var wantsCourseView: Bool { UserDefaults.standard.bool(forKey: "marker.course") }

    /// Opens the terrain sheet on top of the hole view — `-marker.map YES
    /// -marker.terrain YES`.
    ///
    /// It lives behind the same `Menu` the course finder does, so without this the
    /// checks a person reads before saving a DEM — is it lidar, does it cover the
    /// course, what does each hole rise — would ship having been reasoned about and
    /// never looked at. Same argument as `marker.find`.
    static var wantsTerrain: Bool {
        UserDefaults.standard.string(forKey: "marker.terrain") != nil
    }

    /// `-marker.terrain fetch` also **runs the download**, for the same reason
    /// `marker.find.query` runs the search: without it only the empty sheet is
    /// reviewable, and the checks are the whole sheet.
    static var fetchesTerrain: Bool {
        UserDefaults.standard.string(forKey: "marker.terrain") == "fetch"
    }

    /// Opens the hole view with the **simulated position on** — `-marker.map YES
    /// -marker.simulate YES`.
    ///
    /// **The simulated marker is only reachable by a finger.** It is switched on
    /// from a button in the tool column and then dragged, and scripted taps do not
    /// exist here — so its layering, its z-order against the marker pills and its
    /// grab handle have all been changed twice on the user's report without anyone
    /// here ever having seen one on screen. That is what this key is for.
    static var wantsSimulation: Bool { UserDefaults.standard.bool(forKey: "marker.simulate") }

    /// Opens naelvol's swing sheet on the hole view — `-marker.swings YES` for the
    /// list, `-marker.swings capture` for the camera.
    ///
    /// The same argument as `marker.sheet` and `marker.find`: both live behind the
    /// pin menu, `ImageRenderer` cannot draw a `Menu`, and scripted taps do not
    /// exist here — so without this the only reviewable state is the screen that
    /// opens them.
    static var openSwings: String? {
        let value = UserDefaults.standard.string(forKey: "marker.swings")
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Pushes the player over one seeded clip — `-marker.swings YES
    /// -marker.swing swing-0001.mov`.
    static var openSwing: String? {
        let value = UserDefaults.standard.string(forKey: "marker.swing")
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Writes a few short videos into `Documents/Swings/` so the grid has
    /// something in it — `-marker.swings.seed YES`.
    ///
    /// **Real files, tagged with the seeded course and hole**, because the thing
    /// worth looking at is the filter: a list opened from hole 7 must come up
    /// showing hole 7's swings and a chip that clears.
    static var wantsSwingSeed: Bool { UserDefaults.standard.bool(forKey: "marker.swings.seed") }

    /// Places targets on the hole — `-marker.targets 0.35,0.7`, as fractions along
    /// the tee-to-green line.
    ///
    /// A target is placed by **tapping the hole**, and scripted taps do not exist
    /// here, so without this the two leg distance boxes — and now the plays-like
    /// suffix on each of them *(user, 2026-08-30)* — could only be reasoned about.
    /// `HoleScreen.targets` has been an init parameter for exactly this reason
    /// since it was written; this is the launch key that finally reaches it.
    static var targetFractions: [Double] {
        (UserDefaults.standard.string(forKey: "marker.targets") ?? "")
            .split(separator: ",").compactMap { Double($0) }.filter { $0 > 0 && $0 < 1 }
    }

    /// Opens the OSM course finder on top of the hole view — `-marker.map YES
    /// -marker.find YES`.
    ///
    /// It is reached through the course menu in the navigation bar, and
    /// `ImageRenderer` draws neither a `Menu` nor a sheet behind one — so without a
    /// key it is a screen nobody here can look at before it ships. Same argument as
    /// `marker.sheet` and `marker.course`.
    static var wantsFinder: Bool { UserDefaults.standard.bool(forKey: "marker.find") }

    /// Opens the finder **and runs the search** — `-marker.find YES
    /// -marker.find.query "Corica Park"`.
    ///
    /// Without it only the empty sheet can be looked at: there is no way to type in
    /// this simulator, so the list of facilities, the candidate rows and the three
    /// checks in front of the Save button — the whole reason the screen exists —
    /// would ship unreviewed.
    /// Renders a legend cell in its nudged state — `-marker.bump up` or
    /// `-marker.bump down`, applied to the first player.
    ///
    /// The score nudge is a swipe, and scripted swipes do not exist here. Without
    /// this the enlarge/shrink indicator the user asked for by name would ship
    /// having been reasoned about and never looked at — and its first version was a
    /// no-op that no diff would have shown.
    static var scoreBump: String? {
        let v = UserDefaults.standard.string(forKey: "marker.bump") ?? ""
        return v.isEmpty ? nil : v
    }

    static var finderQuery: String? {
        let q = UserDefaults.standard.string(forKey: "marker.find.query") ?? ""
        return q.isEmpty ? nil : q
    }

    static var wantsAutoStart: Bool { UserDefaults.standard.bool(forKey: "marker.start") }
    static var wantsAutoRecord: Bool { UserDefaults.standard.bool(forKey: "marker.record") }

    /// A `.wav`/`.aiff`/`.m4a` in the app's Documents to feed the live recognizer
    /// **instead of the microphone**.
    ///
    /// **The live pane is otherwise unreviewable here.** It only draws while a
    /// burst is running and the recognizer is producing text, and this environment
    /// has no way to speak into the simulator's microphone — the same wall as
    /// scripted taps. Pointing it at a file replays that audio through the real
    /// `LiveTranscript`, the real commit rule and the real `LogStore.append`, so
    /// what the screenshot shows is the actual path and not a mock. The `.m4a`
    /// still records from the microphone alongside it, which is silence.
    static var speechFile: String? {
        let v = UserDefaults.standard.string(forKey: "marker.speech")
        return (v?.isEmpty == false) ? v : nil
    }

    /// Session id to open straight into, if any.
    static var openRound: String? {
        let v = UserDefaults.standard.string(forKey: "marker.open")
        return (v?.isEmpty == false) ? v : nil
    }

    @MainActor
    static func seedIfRequested() {
        if wantsSwingSeed { seedSwings() }
        guard wantsSeed || wantsWipe else { return }
        let root = RoundViewModel.sessionsRoot
        try? FileManager.default.removeItem(at: root)
        guard wantsSeed else { return }

        seed(name: "session-2026-08-24-0812", start: at(2026, 8, 24, 8, 12),
             minutes: 268, course: "Corica Park South", events: 0, logs: 0)
        seed(name: "session-2026-08-25-1530", start: at(2026, 8, 25, 15, 30),
             minutes: nil, course: "Corica Park South", events: 0, logs: 3) // killed mid-round
        seed(name: "session-2026-08-26-0705", start: at(2026, 8, 26, 7, 5),
             minutes: 254, course: "Corica Park South", events: 6, logs: 15)
    }

    // MARK: -

    private static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Millis {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        let date = Calendar.current.date(from: c) ?? Date()
        return SessionClock.millis(from: date)
    }

    private static func seed(name: String, start: Millis, minutes: Int?,
                             course: String, events: Int, logs: Int) {
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot.appendingPathComponent(name))
        try? folder.create()
        let players = [Player(name: "steve"),
                       Player(name: "dave"), Player(name: "min")]
        try? folder.writeMeta(SessionMeta(
            sessionID: name, course: course, players: players,
            start: start, end: minutes.map { start + Millis($0) * 60_000 },
            // No audio: the app stopped recording on 2026-08-27. A round folder
            // is now kilobytes, not gigabytes, which is itself worth seeing in the
            // rounds list.
            device: "iOS", audioFormat: "none"))

        seedLogs(folder: folder, start: start, count: logs)
        seedMarks(folder: folder, start: start)
        seedScores(folder: folder, players: players, start: start,
                   through: min(4, max(0, logs / 3)))

        guard events > 0, let w = try? folder.writer(.events) else { return }
        let samples: [Event] = [
            Event(id: "a1", t: start + 40_000, kind: .shot, provenance: .model,
                  player: "steve", hole: 1, club: "driver", confidence: 0.82,
                  logs: ["lg0"]),
            Event(id: "a2", t: start + 150_000, kind: .shot, provenance: .model,
                  player: "dave", hole: 1, lie: "bunker", confidence: 0.41,
                  logs: ["lg1"]),
            Event(id: "a3", t: start + 700_000, kind: .score, provenance: .model,
                  player: "steve", hole: 1, strokes: 5, confidence: 0.66,
                  logs: ["lg3"]),
            Event(id: "a4", t: start + 705_000, kind: .score, provenance: .user,
                  player: "dave", hole: 1, strokes: 6),
            Event(id: "a5", t: start + 1_050_000, kind: .penalty, provenance: .model,
                  player: "min", hole: 2, confidence: 0.55, logs: ["lg4", "lg5"]),
            // The misheard name, kept as the thing the golfer has to catch.
            Event(id: "a6", t: start + 1_900_000, kind: .shot, provenance: .model,
                  player: "chungman", hole: 3, club: "7 iron", confidence: 0.35,
                  logs: ["lg7"]),
        ]
        for e in samples.prefix(events) { try? w.append(e) }
        try? w.close()
    }

    /// Unassigned marks — the Action Button's, which is the only writer of them.
    ///
    /// **Ordinary `LogEntry` rows with `mark: true` and no player**, because that
    /// is what `QuickMark` writes; seeding anything else would review a screen the
    /// app does not produce. Written through the same `.log` writer as `seedLogs`,
    /// after it, so the ids do not collide and the seeded events' citations do not
    /// slide onto a different sentence.
    ///
    /// Seeded at all because there is **no Action Button in the simulator**, so
    /// without these rows the empty ring cannot be looked at here. Three on hole 1
    /// down the white-tee-to-green line, one of them beside a shot pill so the ring
    /// and the numbered circle can be compared for weight; and one **with no fix**,
    /// which is what a mark written when the radio never settled looks like — it
    /// must be stored, must appear on the round screen's timeline, and must *not*
    /// be drawn on the hole.
    private static func seedMarks(folder: SessionFolder, start: Millis) {
        guard let w = try? folder.writer(.log) else { return }
        let rows: [(t: Int, at: (Double, Double)?, hole: Int?)] = [
            (300,  (37.737100, -122.231900), 1),
            (500,  (37.736500, -122.231300), 1),
            // **Placed, and on no hole** — `Course.nearestHole` declines beyond
            // 250 m and a round with no course file has nothing to ask, so this is
            // the ordinary shape rather than a corner. It is drawn on every hole,
            // and joined on every hole *(user, 2026-09-03)*; without a row like it
            // the line's own selection rule cannot be looked at here.
            (580,  (37.736100, -122.231260), nil),
            // Beside steve's shot 2 pill.
            (660,  (37.735906, -122.231226), 1),
            (800,  nil, nil),
        ]
        for (i, r) in rows.enumerated() {
            try? w.append(LogEntry(id: "mk\(i)",
                                   t: start + Millis(r.t) * 1_000,
                                   text: QuickMark.text,
                                   lat: r.at?.0, lon: r.at?.1,
                                   hAcc: r.at == nil ? nil : 5,
                                   hole: r.hole,
                                   source: .typed,
                                   mark: true))
        }
        try? w.close()
    }

    /// Spoken logs as they actually arrive — misheard names included. "Chungman"
    /// for "Chungmin" is a real observed failure of on-device recognition, and the
    /// event list is where fuzzy name matching has to survive it.
    private static func seedLogs(folder: SessionFolder, start: Millis, count: Int) {
        guard count > 0, let w = try? folder.writer(.log) else { return }
        // **Some of them are shots**, because a shot is the only entry that draws a
        // player-coloured pill and joins a `PlayerTrack` — X13 shipped both with no
        // way to look at either in this environment, which is the same argument as
        // every other key in this file. Two of steve's and one of dave's, on hole 1,
        // so the line has two ends and one player has only one shot: that is the
        // case that draws a dot and *no* line, and it is the one the tee used to
        // hide.
        // **Coordinates on the holes the entries are about.** They used to march
        // north from 37.7402, -122.2661 — three kilometres west of Corica, which is
        // the course this seed names — so every log was placed, none was on any
        // hole, and **the marker layer could not be seen in this environment at
        // all**. Points below are interpolated along each hole's own white-tee-to-
        // green line in `Courses/corica-park-south.json`.
        // **No `"1: 2"` prefix on any of them** *(user, 2026-09-03: "no fillers")*.
        // The hole and the shot are fields on the row and `LogTitle` prints them in
        // front of the sentence; a seed that still wrote them into the text would
        // review a row shape the app no longer produces — and would show the golfer
        // the doubled title the prefix was retired for.
        let lines: [(t: Int, text: String, hole: Int?, at: (Double, Double)?,
                     player: String?, shot: Int?)] = [
            (40,   "steve is up first, driver",           1, (37.737387, -122.231713), "steve", 1),
            (150,  "dave in the left bunker off the tee", 1, (37.737600, -122.232100), "dave",  1),
            (420,  "steve on in two, about fifteen feet", 1, (37.735906, -122.231026), "steve", 2),
            // **A skipped shot on purpose**: 2 then 4, with no 3 ever logged, so
            // the leg that jumps carries a distance and the 1→2 leg does not.
            // That pair is the only way to look at the rule at all here.
            (620,  "steve pitched on",                     1, (37.735400, -122.230850), "steve", 4),
            (700,  "steve made five, dave had a six",          1, nil, nil, nil),
            (1_050,"min hit it in the water off the tee",      2, (37.736084, -122.229477), nil, nil),
            (1_260,"penalty drop for min",                     2, (37.736431, -122.229231), nil, nil),
            (1_500,"everybody bogeyed two",                    2, (37.737124, -122.228738), nil, nil),
            (1_900,"chungman with a seven iron to the front",  3, (37.736299, -122.228500), nil, nil),
            (2_300,"three putts, that's a bogey",              3, (37.735216, -122.229218), nil, nil),
            // **The unplaceable one.** No fix and no hole, which is what a log
            // made off the course actually looks like.
            // Seeded because it is drawn on *every* hole and its caption carries
            // two chips beside the clock — the one row here that can overflow.
            (2_600,"lost ball walking back to the cart",      nil, nil, nil, nil),
            // **A hole played out and closed** *(2026-08-29)*. min's three shots on
            // hole 1 plus a seeded score of 3 are the only way to look at the
            // closing leg into the flag, and at the case where it carries a
            // **number**: the last marker's stored number equals the score, so
            // exactly one shot spans marker to cup. dave, one marker and a six, is
            // the other half of the pair — a closing leg with no number on it,
            // because five strokes went unlogged between his tee shot and the hole.
            // Appended at the end rather than in date order on purpose: the seeded
            // events cite logs by id, and inserting mid-list would slide every
            // citation onto a different sentence.
            (2_900,"min striped one down the middle",     1, (37.737450, -122.231600), "min", 1),
            (2_920,"min laid up short of the green",      1, (37.736200, -122.230600), "min", 2),
            (2_940,"min holed it from the fringe",        1, (37.735700, -122.229900), "min", 3),
            // **Twenty metres off the white tee, so its pill lands *on* the
            // simulated marker** *(2026-08-29)*. The simulated position seeds at the
            // tee and a pill hangs below its own point, so nothing here had ever
            // been drawn where the two overlap — "is the simulated marker above the
            // pills?" had no overlap to look at and could not be reviewed in this
            // environment at all. Placed down the tee-to-green line rather than due
            // north: the camera is rotated to put the green at the top, so
            // *increasing* latitude moves a point **down** the screen here.
            (2_960,"chungman still on the tee",           1, (37.738366, -122.232166), "chungman", 1),
        ]
        for (i, line) in lines.prefix(count).enumerated() {
            try? w.append(LogEntry(
                id: "lg\(i)", t: start + Millis(line.t) * 1_000, text: line.text,
                lat: line.at?.0, lon: line.at?.1, hAcc: line.at == nil ? nil : 6,
                hole: line.hole,
                player: line.player, shot: line.shot,
                source: i % 3 == 2 ? .typed : .spoken, locale: "en_US"))
        }
        try? w.close()
    }

    /// Scores **through the journal**, not by writing `scorecard.json`.
    ///
    /// The snapshot is derived now, so seeding it directly would produce a card
    /// that renders correctly and has no history behind it — exactly the state the
    /// journal exists to make impossible, and the one that would make a History
    /// screenshot look broken.
    private static func seedScores(folder: SessionFolder, players: [Player],
                                   start: Millis, through: Int) {
        guard through > 0, let w = try? folder.writer(.journal) else { return }
        var rows: [JournalEntry] = []
        // min's 3 on hole 1 is deliberate: it matches his last seeded shot number,
        // which is what makes his closing leg into the flag a *labelled* one.
        let scores: [[Int]] = [[5, 4, 5, 3], [6, 4, 5, 4], [3, 5, 6, 4]]
        var t = start + 300_000
        for (i, p) in players.enumerated() {
            // A handicap index and a frozen tee, so the net column and the course
            // handicap have something to show. Corica's OSM file has no rating, so
            // one is supplied here — this is the seed, not a course file.
            rows.append(JournalEntry(t: t, act: .setIndex, player: p.id,
                                     index: [14.2, 8.0, 22.4][i % 3]))
            t += 1_000
            rows.append(JournalEntry(t: t, act: .setTee, player: p.id,
                                     tee: "black", rating: 71.9, slope: 129, par: 72))
            t += 1_000
            for h in 1...through {
                // **Hole 1 is left open for the first player**, and that is not an
                // oversight *(2026-08-29)*. Holed out *is* having a score, so the
                // legend's two states — shots taken with a swipe chevron, and a
                // score to par with the button dead — can only be looked at
                // together if one player on the hole with the seeded shots has no
                // score yet. Hole 1 is that hole; steve is that player.
                if h == 1 && i == 0 { t += 60_000; continue }
                let n = scores[i % scores.count][h - 1]
                rows.append(JournalEntry(t: t, act: .setScore, player: p.id,
                                         hole: h, strokes: n))
                t += 60_000
            }
        }
        // One correction and one undo, so History has both states to draw and the
        // strike-through is exercised rather than assumed.
        let mistake = JournalEntry(t: t, act: .setScore, player: players[0].id,
                                   hole: 2, strokes: 9, prevStrokes: 4)
        rows.append(mistake)
        t += 30_000
        rows.append(JournalEntry(t: t, act: .undo, undoes: mistake.id))
        t += 30_000
        rows.append(JournalEntry(t: t, act: .setStat, player: players[0].id, hole: 1,
                                 stat: .putts, statValue: 3))
        t += 1_000
        rows.append(JournalEntry(t: t, act: .setStat, player: players[0].id, hole: 1,
                                 stat: .gir, statValue: 0))

        for row in rows { try? w.append(row) }
        try? w.close()

        // The derived snapshot, written once so a reader older than the journal
        // still sees a card. `RoundDocument.replay` rewrites it on every change.
        let state = JournalReplay.replay(rows)
        try? folder.writeJSON(state.scorecard, to: .scorecard)
    }
}
#endif

#if DEBUG
import AVFoundation
import NaelvolCore

extension DemoSeed {
    /// Three tiny movies in `Documents/Swings/`, tagged the way a capture from the
    /// hole view would tag them.
    ///
    /// **Written rather than checked in**: a fixture video in git is a binary
    /// nobody can review, and this is a dozen lines of AVFoundation. Two are on
    /// hole 7 of the seeded course and one is on hole 3, so a list opened from
    /// hole 7 can be seen to be *filtered* rather than merely short.
    static func seedSwings() {
        let root = SwingFeature.swingsRoot
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let course = "corica-park-south"
        let plan: [(String, UInt8, SwingContext)] = [
            ("swing-0001.mov", 40, SwingContext(courseID: course, courseName: "Corica Park South",
                                                hole: 7, playerName: "steve", tags: ["driver"])),
            ("swing-0002.mov", 90, SwingContext(courseID: course, courseName: "Corica Park South",
                                                hole: 7, playerName: "dave", tags: ["7-iron", "fade"])),
            ("swing-0003.mov", 140, SwingContext(courseID: course, courseName: "Corica Park South",
                                                 hole: 3, playerName: "steve", tags: ["wedge"])),
        ]
        for (name, shade, context) in plan {
            let url = root.appendingPathComponent(name)
            writeMovie(at: url, frames: 24, shade: shade)
            writeMeta(SwingMeta(context: context), to: url)
        }
    }

    /// **Synchronous on purpose.** This runs before the first screen appears, from
    /// a stored-property initialiser, so anything that finishes a moment later is
    /// a screenshot of an empty grid.
    private static func writeMovie(at url: URL, frames: Int, shade: UInt8) {
        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(shade &+ UInt8(i * 3)), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }

    private static func writeMeta(_ meta: SwingMeta, to url: URL) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await SwingMetadata.write(meta, to: url)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
    }
}
#endif
