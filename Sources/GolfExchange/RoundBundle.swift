import Foundation
import GolfSessionFormat
import GolfCourse

/// One round, complete enough to put back — **and the course it was played on**.
///
/// This is the *archive* shape, and it is deliberately not `RoundExport`, which
/// lives in `GolfSessionFormat` and is a different thing for a different reader.
/// `RoundExport` is what the Copy buttons put on the clipboard for a **model**: it
/// carries `log.jsonl` and `events.jsonl` and nothing else, because those are the
/// two streams that are model-visible by design. This carries the round's ground
/// truth as well, because a round that comes back without its scores is not the
/// round that left.
///
/// The two must not be merged, and the firewall is what keeps them apart:
///
/// - `RoundExport` is model-facing and is safe to paste into a prompt.
/// - `RoundBundle` is **not**. Its `groundTruth` member holds `journal.jsonl`,
///   `scorecard.json`, `marks.jsonl` and `corrections.jsonl` — the answer key.
///
/// That member is a **nested object rather than four fields spread through the
/// round**, so stripping it is one line and a reader can see at a glance what it
/// is. `RoundBundle.modelVisible` does exactly that, and is the only supported way
/// to get from an archive to something a model may read.
///
/// It is also structural, not only conventional: `GolfReconstruction` does not
/// depend on `GolfExchange` and cannot import this type at all.
public struct RoundBundle: Codable, Sendable {

    /// What this is, written into the file so a reader never has to guess from the
    /// shape. A JSON object that does not carry it is some other JSON.
    public static let formatName = "marker.round"
    /// **2 since 2026-08-31**, when `Player.aliases` was removed.
    ///
    /// The rule for moving it, which the two changes either side of that date
    /// demonstrate: an **added** key (`CourseData.terrainOmitted`) is invisible to
    /// an older reader — `JSONDecoder` ignores what it does not know — so bumping
    /// for one would make that reader refuse, with "update the app", a document it
    /// can read perfectly. A **removed non-optional** property is the opposite: an
    /// older reader hits `keyNotFound` and reports a missing field of *ours*, which
    /// is exactly the confusion `BundleText`'s `Envelope` probe exists to prevent,
    /// arriving from the other side. `isSupported` is `version <= currentVersion`,
    /// so every v1 document still reads here.
    public static let currentVersion = 2

    public var format: String
    public var version: Int
    /// When the archive was made — **not** when the round was played, which is
    /// `round.meta.start`. Two different questions, and a single `date` field would
    /// answer the wrong one on every re-export.
    public var exported: Millis
    /// Free text naming what wrote it, for when a file turns up a year later.
    public var generator: String?

    public var round: Round
    /// Nil when the round names no course, or when the exporter had no file for the
    /// name it names. A round is still worth carrying without one — the logs, the
    /// track and the card are all still there; only the map is missing.
    public var course: CourseData?

    // MARK: - The round

    public struct Round: Codable, Sendable {
        public var meta: SessionMeta

        /// **Every row, exactly as `log.jsonl` holds it** — superseded rows and
        /// tombstones included, never `LogEntry.current(_:)`.
        ///
        /// A supersede chain *is* the history: the sentence as first heard, the
        /// coordinate that converged fifteen seconds later, the name the golfer
        /// corrected. Collapsing it on export would throw away every labelled
        /// error the eval set is made of, and the round would come back looking
        /// like it had been right the first time.
        public var logs: [LogEntry]
        /// Same rule. `Event.supersedes` carries the correction history.
        public var events: [Event]

        public var gps: [GPSFix]
        public var motion: [MotionSample]
        public var altitude: [AltitudeSample]

        public var audio: Audio
        public var groundTruth: GroundTruth
    }

    /// The audio **index**, without the audio.
    ///
    /// The rows are carried because they are the round's clock: `LogEntry.tEnd`
    /// resolves against them through `AudioSpans`, and a segment's `t0`/`t1` is
    /// what puts a decoder's file-relative time back on the session clock. Drop
    /// them and every log loses the ability to name the audio it came from, which
    /// is a property of the round rather than of the files.
    ///
    /// The `.m4a`s themselves are not carried: a 4.5-hour round is tens of
    /// megabytes, and this format has to survive being pasted into a text box.
    /// `filesIncluded` says so out loud rather than leaving a reader to infer it
    /// from an absence — the same reason `TranscriptCoverage` records what ran
    /// instead of what was asked for.
    public struct Audio: Codable, Sendable {
        public var segments: [AudioSegment]
        public var filesIncluded: Bool

        public init(segments: [AudioSegment], filesIncluded: Bool = false) {
            self.segments = segments
            self.filesIncluded = filesIncluded
        }
    }

    /// **GROUND TRUTH. Never put this in a prompt.**
    ///
    /// Nested so that removing it is one line and so that a person looking at the
    /// JSON can see where the line is. `SessionFolder.File.groundTruth` names the
    /// same four files.
    public struct GroundTruth: Codable, Sendable {
        public var journal: [JournalEntry]
        /// Derived from `journal` by `JournalReplay`, and carried anyway: a round
        /// played before the journal existed has no journal, and then this snapshot
        /// is the only record of the card there is.
        public var scorecard: Scorecard?
        public var marks: [Mark]
        public var corrections: [Correction]

        public init(journal: [JournalEntry] = [], scorecard: Scorecard? = nil,
                    marks: [Mark] = [], corrections: [Correction] = []) {
            self.journal = journal; self.scorecard = scorecard
            self.marks = marks; self.corrections = corrections
        }

        public var isEmpty: Bool {
            journal.isEmpty && scorecard == nil && marks.isEmpty && corrections.isEmpty
        }
    }

    // MARK: - The course

    /// The course file and its terrain sidecar, carried together because they are
    /// two halves of one thing on disk (`Courses/<id>.json` and `Courses/<id>.dem`)
    /// and because a round imported without terrain silently loses its plays-like
    /// numbers with nothing on screen saying why.
    public struct CourseData: Codable, Sendable {
        public var course: Course
        /// Nil is the ordinary case: no course imported before 2026-08-30 has
        /// terrain, and there is no source outside the United States.
        public var elevation: Elevation?

        /// **The exporting side had a `.dem` for this course and left it out.**
        ///
        /// Terrain is optional in an export (it is most of the bytes), so `nil`
        /// elevation now answers two different questions — *this course has no
        /// terrain* and *this export does not carry it* — and only the second one
        /// is something the receiving golfer can act on: open the course menu and
        /// download it, **before** the round, because a course has no signal. The
        /// same reason `Audio.filesIncluded` is stated rather than inferred, and
        /// the same reason `TranscriptCoverage` records what ran instead of what
        /// was asked for.
        ///
        /// It cannot be set contradictorily: `RoundArchive.bundle` derives it, and
        /// it is only ever true when there really was a grid to leave out.
        public var terrainOmitted: Bool { storedTerrainOmitted == true }

        /// Stored optional and read non-optional — **the `Hole.paths` rule**. A
        /// missing key for a non-optional `Bool` is a *decode failure*, so writing
        /// this as `var terrainOmitted: Bool` would make every export already on a
        /// clipboard or in a file unreadable. It is also written back as nil when
        /// false, so an ordinary export encodes byte-for-byte as it did before the
        /// field existed and **the format version does not move** — an additive
        /// key that an older build ignores must not make that build refuse the
        /// document with "update the app".
        var storedTerrainOmitted: Bool?

        enum CodingKeys: String, CodingKey {
            case course, elevation
            case storedTerrainOmitted = "terrainOmitted"
        }

        public init(course: Course, elevation: Elevation? = nil,
                    terrainOmitted: Bool = false) {
            self.course = course
            self.elevation = elevation
            self.storedTerrainOmitted = terrainOmitted && elevation == nil ? true : nil
        }
    }

    public init(round: Round, course: CourseData? = nil,
                exported: Millis = SessionClock.now(),
                generator: String? = nil) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.exported = exported
        self.generator = generator
        self.round = round
        self.course = course
    }

    // MARK: - Reading

    /// True when this really is one of ours and a version we understand.
    public var isSupported: Bool {
        format == Self.formatName && version <= Self.currentVersion
    }

    /// The archive with its answer key removed — the only supported way to get
    /// from a bundle to something a model may read.
    ///
    /// Note what this does **not** do: `events.jsonl` is mixed provenance, so a
    /// `.user` event is ground truth sitting on the same stream as the proposals.
    /// `Event.modelVisible(_:)` is the per-row filter and it is applied here too.
    public var modelVisible: RoundBundle {
        var copy = self
        copy.round.groundTruth = GroundTruth()
        copy.round.events = Event.modelVisible(copy.round.events)
        return copy
    }

    /// A one-line description for the header comment of the text form, and for a
    /// confirmation before an import writes anything.
    public var summary: String {
        var parts: [String] = []
        if let c = round.meta.course, !c.isEmpty { parts.append(c) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        parts.append(f.string(from: SessionClock.date(from: round.meta.start)))
        if !round.meta.players.isEmpty {
            parts.append("\(round.meta.players.count) player"
                       + (round.meta.players.count == 1 ? "" : "s"))
        }
        if !round.logs.isEmpty { parts.append("\(round.logs.count) logs") }
        if !round.events.isEmpty { parts.append("\(round.events.count) events") }
        if let c = course {
            parts.append("course \(c.course.id)"
                       + (c.elevation != nil ? " + terrain"
                          : c.terrainOmitted ? " (terrain left out)" : ""))
        }
        return parts.joined(separator: " · ")
    }
}
