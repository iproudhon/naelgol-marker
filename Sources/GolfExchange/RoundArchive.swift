import Foundation
import GolfSessionFormat
import GolfCourse

/// Reading a round out of a session folder, and putting one back.
///
/// **Nothing here overwrites anything.** A round always lands in a fresh folder and
/// a course already on disk is kept — the same rule the course finder follows, and
/// for the same reason: saving over a course id is a *replace*, so it destroys
/// every tee and green centre somebody placed by hand in the editor. An import that
/// silently did that would be a data-loss bug wearing the clothes of a convenience.
public enum RoundArchive {

    // MARK: - Export

    /// A row that is on disk and did not survive being read.
    ///
    /// **`JSONLReader` skips a line it cannot decode**, which is exactly right for
    /// opening a round that ended in a battery death and exactly wrong for an
    /// archive: the one job here is to lose nothing, and a silent skip is loss that
    /// reports success. So the export counts the lines in the file against the rows
    /// it got back and says when they differ. It cannot repair such a row — if it
    /// could, the reader would already have — but an export that says
    /// "3 of 41 rows in log.jsonl could not be read" is a problem somebody can act
    /// on, where a bundle quietly holding 38 is not.
    public struct Unreadable: Sendable, Equatable {
        public var file: String
        public var onDisk: Int
        public var decoded: Int
        public var lost: Int { max(0, onDisk - decoded) }
    }

    /// - Parameters:
    ///   - course: the course file for `folder`'s round, when the caller has one.
    ///     Passed in rather than looked up: this target has no opinion about where
    ///     courses live, and the app and the CLI answer that differently.
    ///   - elevation: the `.dem` sidecar, when there is one. Nil is ordinary.
    ///   - includeTerrain: false leaves the grid out and **records that it did**.
    ///     Terrain is most of an export's bytes — a whole-course grid is hundreds
    ///     of kilobytes of base64 and a hilly one barely compresses — and it is the
    ///     one part of a bundle the receiving side can go and fetch for itself,
    ///     from a public-domain source, in fifteen seconds on a signal. So it is
    ///     the part that is optional. Caller-supplied rather than derived: only the
    ///     caller knows whether this export is going down a wire or across a room.
    /// - Returns: the bundle, and every stream that lost a row on the way out.
    ///   A tuple rather than a side channel so no caller can forget to look:
    ///   the app shows it before it offers a share sheet, the CLI prints it.
    public static func bundle(from folder: SessionFolder,
                              course: Course? = nil,
                              elevation: Elevation? = nil,
                              includeTerrain: Bool = true,
                              exported: Millis = SessionClock.now(),
                              generator: String? = nil)
        throws -> (bundle: RoundBundle, unreadable: [Unreadable]) {
        let meta = try folder.readMeta()
        // **Read from the files, never from a view model's collapsed copy.**
        // `readAll` gives every row including superseded ones and tombstones, which
        // is what the archive has to carry; `LogEntry.current(_:)` is for drawing a
        // screen and would throw the correction history away.
        let round = RoundBundle.Round(
            meta: meta,
            logs: folder.readAll(.log, as: LogEntry.self),
            events: folder.readAll(.events, as: Event.self),
            gps: folder.readAll(.gps, as: GPSFix.self),
            motion: folder.readAll(.motion, as: MotionSample.self),
            altitude: folder.readAll(.altitude, as: AltitudeSample.self),
            audio: RoundBundle.Audio(
                segments: folder.readAll(.audio, as: AudioSegment.self),
                filesIncluded: false),
            groundTruth: RoundBundle.GroundTruth(
                journal: folder.readAll(.journal, as: JournalEntry.self),
                scorecard: try? folder.readJSON(.scorecard, as: Scorecard.self),
                marks: folder.readAll(.marks, as: Mark.self),
                corrections: folder.readAll(.corrections, as: Correction.self)))

        let bundle = RoundBundle(round: round,
                                 course: course.map {
                                     // Derived here, so `terrainOmitted` can never
                                     // contradict `elevation`: it is true only when
                                     // there really was a grid and it was left out.
                                     RoundBundle.CourseData(
                                         course: $0,
                                         elevation: includeTerrain ? elevation : nil,
                                         terrainOmitted: !includeTerrain && elevation != nil)
                                 },
                                 exported: exported,
                                 generator: generator)

        let checks: [(SessionFolder.File, Int)] = [
            (.log, round.logs.count), (.events, round.events.count),
            (.gps, round.gps.count), (.motion, round.motion.count),
            (.altitude, round.altitude.count), (.audio, round.audio.segments.count),
            (.journal, round.groundTruth.journal.count),
            (.marks, round.groundTruth.marks.count),
            (.corrections, round.groundTruth.corrections.count),
        ]
        let unreadable = checks.compactMap { file, decoded -> Unreadable? in
            let onDisk = lineCount(folder.path(file))
            guard onDisk > decoded else { return nil }
            return Unreadable(file: file.rawValue, onDisk: onDisk, decoded: decoded)
        }
        return (bundle, unreadable)
    }

    /// Non-empty lines in a JSONL file, or 0 when there is no such file.
    /// Deliberately counts the same way `JSONLReader` iterates, so a trailing
    /// newline is not a phantom lost row.
    static func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }

    // MARK: - Import

    /// What an import did — and, more importantly, what it declined to do.
    ///
    /// Printed by the CLI and shown in the app. A course that was kept rather than
    /// written is not a failure and not a detail: it is the one thing that decides
    /// whether the imported round's distances mean anything.
    public struct Report: Sendable, Equatable {
        public enum CourseOutcome: Sendable, Equatable {
            /// The bundle carried no course.
            case none
            /// The caller passed no store — `golfctl round import` without `--courses`.
            case notOffered
            case written(id: String)
            /// A course with this id is already here and is the same course.
            case kept(id: String)
            /// A course with this id is already here and **is not the same course**.
            /// The incoming one was stored beside it and the round repointed at it.
            case storedSeparately(id: String, name: String, was: String, why: String)
        }
        public enum TerrainOutcome: Sendable, Equatable {
            case none, notOffered
            case written(id: String)
            case kept(id: String)
            /// The export deliberately left the terrain out **and this phone has
            /// none for that course either**. Said only in that case: where the
            /// local course already has a grid the omission cost nothing, and a
            /// check that cries wolf about a course that is fine is a check nobody
            /// reads.
            case omitted(id: String)
        }

        public var folder: URL
        public var courseOutcome: CourseOutcome = .none
        public var terrainOutcome: TerrainOutcome = .none
        /// A round with this `sessionID` was already here. Not refused — the user
        /// asked to import — but said out loud, because the usual cause is pasting
        /// the same export twice.
        public var duplicateOfSessionID: String?
        public var logs = 0, events = 0, fixes = 0
        public var journalEntries = 0, marks = 0
        public var audioSegments = 0
        public var audioFilesIncluded = false

        /// One line per fact, in the order somebody needs them.
        public var lines: [String] {
            var out = ["round      \(folder.lastPathComponent)"]
            if let dup = duplicateOfSessionID {
                out.append("           already had a round with id \(dup) — imported as a second copy")
            }
            var counts = ["\(logs) logs", "\(events) events", "\(journalEntries) journal"]
            if fixes > 0 { counts.append("\(fixes) fixes") }
            if marks > 0 { counts.append("\(marks) marks") }
            out.append("           " + counts.joined(separator: ", "))
            if audioSegments > 0 && !audioFilesIncluded {
                out.append("audio      \(audioSegments) segment(s) indexed — the recordings are "
                         + "not included in an export")
            }
            switch courseOutcome {
            case .none:            out.append("course     none in this export")
            case .notOffered:
                // **Said, not skipped.** Everything else in this report names what
                // it declined to do, and a course that travelled and was then
                // dropped on the floor is exactly the thing somebody needs told —
                // most often because they forgot they passed the flag.
                out.append("course     one was included and NOT imported (courses were "
                         + "not offered a place to go)")
            case .written(let id): out.append("course     \(id) — written")
            case .kept(let id):    out.append("course     \(id) — already here, kept yours")
            case .storedSeparately(let id, let name, let was, let why):
                out.append("course     \(was) is already here and IS A DIFFERENT COURSE (\(why))")
                out.append("           the imported one was saved as \(id) and this round now "
                         + "names \"\(name)\"")
            }
            switch terrainOutcome {
            case .none, .notOffered: break
            case .written(let id):   out.append("terrain    \(id).dem — written")
            case .kept(let id):      out.append("terrain    \(id).dem — already here, kept yours")
            case .omitted(let id):
                out.append("terrain    LEFT OUT of this export and not here either — "
                         + "\(id) has no plays-like numbers")
                out.append("           download it from the course menu BEFORE the round; "
                         + "a course has no signal")
            }
            return out
        }
    }

    /// Write `bundle` into `root` as a new session folder.
    ///
    /// - Parameter courses: where a carried course would go. Nil skips the course
    ///   entirely and says so in the report, rather than dropping it in silence.
    @discardableResult
    public static func restore(_ bundle: RoundBundle,
                               into root: URL,
                               courses: CourseStore? = nil) throws -> Report {
        guard bundle.isSupported else { throw BundleText.Failure.unsupportedVersion(bundle.version) }

        var meta = bundle.round.meta

        // Course first, because it can rename the round.
        var courseOutcome = Report.CourseOutcome.none
        var terrainOutcome = Report.TerrainOutcome.none
        if let carried = bundle.course {
            if let store = courses {
                let placed = try place(carried, in: store)
                courseOutcome = placed.course
                terrainOutcome = placed.terrain
                // **Repoint the round at whatever we actually stored.**
                // `meta.course` is a *name*, and the app resolves a round's course
                // by matching that name against the library — so a course stored
                // under a different name leaves the round pointing at the local
                // course of the original name, which is precisely the different
                // course we just decided it was not. Every distance on the hole
                // view would then be wrong and nothing would say so.
                if case .storedSeparately(_, let name, _, _) = placed.course {
                    meta.course = name
                }
            } else {
                courseOutcome = .notOffered
                terrainOutcome = .notOffered
            }
        }

        let existing = SessionIndex.summaries(in: root)
        let folder = SessionFolder(url: root.appendingPathComponent(
            uniqueFolderName(for: meta.start, in: root)))
        try folder.create()

        // `sessionID` is preserved rather than regenerated: it is the round's own
        // identity, and keeping it is what lets a second import of the same export
        // be recognised as one. The rounds list is keyed on the *folder* name, so
        // two folders sharing an id is not an `Identifiable` collision.
        try folder.writeMeta(meta)
        if let card = bundle.round.groundTruth.scorecard {
            try folder.writeJSON(card, to: .scorecard)
        }

        try write(bundle.round.logs, to: .log, in: folder)
        try write(bundle.round.events, to: .events, in: folder)
        try write(bundle.round.gps, to: .gps, in: folder)
        try write(bundle.round.motion, to: .motion, in: folder)
        try write(bundle.round.altitude, to: .altitude, in: folder)
        try write(bundle.round.audio.segments, to: .audio, in: folder)
        try write(bundle.round.groundTruth.journal, to: .journal, in: folder)
        try write(bundle.round.groundTruth.marks, to: .marks, in: folder)
        try write(bundle.round.groundTruth.corrections, to: .corrections, in: folder)

        var report = Report(folder: folder.url)
        report.courseOutcome = courseOutcome
        report.terrainOutcome = terrainOutcome
        report.duplicateOfSessionID =
            existing.contains { $0.meta.sessionID == meta.sessionID } ? meta.sessionID : nil
        report.logs = bundle.round.logs.count
        report.events = bundle.round.events.count
        report.fixes = bundle.round.gps.count
        report.journalEntries = bundle.round.groundTruth.journal.count
        report.marks = bundle.round.groundTruth.marks.count
        report.audioSegments = bundle.round.audio.segments.count
        report.audioFilesIncluded = bundle.round.audio.filesIncluded
        return report
    }

    // MARK: - Placing the course

    private static func place(_ carried: RoundBundle.CourseData, in store: CourseStore)
        throws -> (course: Report.CourseOutcome, terrain: Report.TerrainOutcome) {

        let incoming = carried.course

        guard let local = try? store.load(id: incoming.id) else {
            try store.save(incoming)
            if let dem = carried.elevation { try store.save(dem, for: incoming.id) }
            return (.written(id: incoming.id), terrain(carried, wrote: incoming.id, kept: nil))
        }

        let match = CourseIdentity.compare(local, incoming)
        if match.isSame {
            // Terrain is the one thing an import may add to a course it kept: a
            // `.dem` is public-domain measurement with no hand-placed anything in
            // it, so writing one where there is none loses nobody's work and gains
            // the plays-like numbers. An existing one is still never replaced.
            // **`elevationExists`, not `loadElevation(id:) != nil`** — asked of the
            // filesystem rather than of the decoder, and the difference shows on a
            // `.dem` that is present and does not parse. Reading that as "no terrain
            // here" would overwrite it, and a file that fails to decode is not
            // necessarily junk: it may be a grid a newer build wrote, and nothing
            // can tell those apart. So it is left alone, which is this type's whole
            // rule. `.kept` then means exactly what it says — there is a sidecar
            // there and this import did not touch it.
            let hadLocal = store.elevationExists(id: incoming.id)
            if let dem = carried.elevation, !hadLocal {
                try store.save(dem, for: incoming.id)
                return (.kept(id: incoming.id), .written(id: incoming.id))
            }
            return (.kept(id: incoming.id),
                    terrain(carried, wrote: nil, kept: hadLocal ? incoming.id : nil))
        }

        // **Two different courses, one id.** Not hypothetical: `Course.slug` is
        // ASCII-only, so every Korean course name slugs to `"course"`. Keeping the
        // local file and letting the round point at it would give the round another
        // course's geometry — a file that passes every structural check and reads a
        // club and a half wrong, or a county out. So store this one beside it.
        let name = freeName(basedOn: incoming.name, in: store)
        var renamed = incoming
        renamed.name = name
        renamed.id = freeID(basedOn: Course.slug(name), in: store)
        // The original name is kept as an alias, so the round is still findable by
        // what it was actually called.
        if !renamed.aliases.contains(incoming.name) { renamed.aliases.append(incoming.name) }
        try store.save(renamed)
        if let dem = carried.elevation { try store.save(dem, for: renamed.id) }
        return (.storedSeparately(id: renamed.id, name: name,
                                  was: incoming.id, why: match.reason ?? "different geometry"),
                terrain(carried, wrote: renamed.id, kept: nil))
    }

    /// What to say about terrain, once the course itself has been placed.
    ///
    /// **`.omitted` fires only when this phone ends up with no grid.** The four
    /// cases are: a grid arrived and was written; one is already here and was kept;
    /// none exists anywhere, which is the ordinary case and is silent; and the
    /// export left one out and there is none here — the only one worth a line,
    /// because the plays-like chip will simply not appear and nothing else on
    /// screen would ever say why.
    private static func terrain(_ carried: RoundBundle.CourseData,
                                wrote: String?, kept: String?) -> Report.TerrainOutcome {
        if carried.elevation != nil, let id = wrote { return .written(id: id) }
        if let id = kept { return .kept(id: id) }
        if carried.terrainOmitted { return .omitted(id: wrote ?? carried.course.id) }
        return .none
    }

    // MARK: - Names that are free

    /// A folder name nothing is using. The conventional name is derived from the
    /// round's start in local time, so re-importing the same round twice collides
    /// by construction — which is a case to handle, not to refuse.
    ///
    /// Delegates to `SessionFolder.freeName`, which the trash also uses: a second
    /// copy of this arithmetic is a second chance for one of them to overwrite a
    /// round instead of suffixing it.
    static func uniqueFolderName(for start: Millis, in root: URL) -> String {
        SessionFolder.freeName(SessionFolder.folderName(start: start), in: root)
    }

    static func freeID(basedOn base: String, in store: CourseStore) -> String {
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: store.url(for: candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    static func freeName(basedOn base: String, in store: CourseStore) -> String {
        let taken = Set(store.loadAll().map(\.name))
        var candidate = "\(base) (imported)"
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) (imported \(n))"
            n += 1
        }
        return candidate
    }

    private static func write<T: Encodable>(_ rows: [T],
                                            to file: SessionFolder.File,
                                            in folder: SessionFolder) throws {
        guard !rows.isEmpty else { return }
        let w = try folder.writer(file)
        for r in rows { try w.append(r) }
        try w.close()
    }
}

// MARK: - Is this the same course?

/// Whether two course files describe the same piece of ground.
///
/// **Needed because an id collision is not evidence of sameness.** `Course.slug` is
/// ASCII-only by design, so *every* Korean course name slugs to `"course"` and two
/// unrelated courses collide on the first import. An id check alone would then keep
/// the local file and hand the imported round a course in another country, which is
/// the shape of error this codebase cares most about: everything renders, every
/// number is wrong, and nothing on screen says so.
public enum CourseIdentity {

    public struct Match: Sendable, Equatable {
        public var isSame: Bool
        /// Nil when neither course has any coordinates — a card-only file.
        public var metresApart: Double?
        /// Why not, in words, for the report.
        public var reason: String?
    }

    /// Two courses whose centres are further apart than this are not the same
    /// course, whatever their names say.
    ///
    /// A kilometre is comfortably wider than any golf facility's own extent and far
    /// narrower than the gap between two different ones. It is deliberately loose:
    /// the same course re-imported from OSM a year later, or one with a nine added,
    /// moves its centroid by hundreds of metres, and calling that a different course
    /// would fork a file every time somebody refreshed their geometry.
    public static let sameSiteRadius: Double = 1_000

    public static func compare(_ a: Course, _ b: Course) -> Match {
        if let ca = centroid(a), let cb = centroid(b) {
            let d = Geodesy.distance(ca, cb)
            if d > sameSiteRadius {
                return Match(isSame: false, metresApart: d,
                             reason: String(format: "their centres are %.1f km apart", d / 1000))
            }
            return Match(isSame: true, metresApart: d, reason: nil)
        }
        // No coordinates on one side or the other — a card-only file. Fall back to
        // what a card does carry. Weaker, and the report says which test was used.
        if a.holes.count != b.holes.count {
            return Match(isSame: false, metresApart: nil,
                         reason: "\(a.holes.count) holes here against \(b.holes.count) imported")
        }
        let pa = a.holes.reduce(0) { $0 + $1.par }, pb = b.holes.reduce(0) { $0 + $1.par }
        if pa != pb {
            return Match(isSame: false, metresApart: nil,
                         reason: "par \(pa) here against par \(pb) imported")
        }
        return Match(isSame: true, metresApart: nil, reason: nil)
    }

    /// The mean of every placed point on the course. Not `Geodesy.centroid`, which
    /// is an area-weighted polygon centroid and wants a ring — this is a cloud of
    /// points from all eighteen holes and only has to be stable to a few hundred
    /// metres.
    static func centroid(_ c: Course) -> Coordinate? {
        var lat = 0.0, lon = 0.0, n = 0
        for h in c.holes {
            for p in h.line + h.tees.compactMap(\.at) + [h.green.center].compactMap({ $0 }) {
                lat += p.lat; lon += p.lon; n += 1
            }
        }
        guard n > 0 else { return nil }
        return Coordinate(lat: lat / Double(n), lon: lon / Double(n))
    }
}
