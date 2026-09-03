import Foundation

/// One thing the golfer said happened, as they said it.
///
/// This is the round's **observation stream** — it is what the microphone would
/// have captured if the app were still listening, which it is not. A log arrives
/// either from Siri (the golfer dictates a sentence into an App Intent) or from
/// the input box, and it carries the two things a transcript never could: the
/// exact instant it was said, and where the phone was standing.
///
/// **A log is an observation, not ground truth** *(decision 2026-08-27)*, and that
/// is the whole reason it is a separate type from `Event`:
///
/// - A log is **model-visible**. Extraction reads it, exactly as it read
///   `transcript.jsonl` before. Nothing is filtered.
/// - Ground truth is unchanged and still narrow: `Mark`, `Scorecard`,
///   `Correction`, and an `Event` with `.user` provenance — which now means
///   specifically *a correction to a proposal*, not "anything a human typed".
///
/// Reading it the other way — "a human authored it, so it is the answer key" —
/// would put the entire product input behind the firewall and leave the extraction
/// pass with nothing to read. `Event.modelVisible(_:)` and `Event.Provenance` are
/// untouched by this type existing, which is the check that it is the right shape.
///
/// *Why not an `Utterance`.* An utterance has a speaker, a confidence, a locale and
/// a `[t0, t1]` window, and no coordinate; a log has a coordinate and none of the
/// rest. Widening `Utterance` to fit would add four permanently-nil fields to the
/// ASR type and make "does this line have a confidence?" a question with two
/// different meanings depending on which writer produced the row.
public struct LogEntry: Codable, Sendable, Identifiable, Equatable {

    /// How the text was captured. Kept because the two have different failure
    /// modes and it is the only way to tell them apart afterwards: Siri hands
    /// back a transcription that can be wrong, and the box hands back exactly
    /// what was typed.
    public enum Source: String, Codable, Sendable {
        /// Said out loud and transcribed by a speech recogniser, so the text may
        /// be misheard — names especially. See the note on `locale`.
        ///
        /// **The raw value is `"siri"` for a reason.** Rows written by the
        /// scrapped Siri intent *(2026-08-27)* are already on disk in real
        /// sessions, and a rename that stopped them decoding would throw away the
        /// only recorded input this app has ever taken. The case names what it has
        /// always meant — a spoken sentence — and never which engine heard it.
        case spoken = "siri"
        /// Typed into the input box. The text is exact.
        case typed
    }

    public var id: String
    /// When it was said, on the session clock.
    public var t: Millis
    public var text: String

    /// When the golfer stopped talking, on the session clock. Nil for a typed log
    /// and for any spoken log written before this field existed.
    ///
    /// **This is what makes a log re-transcribable, and it is the only thing that
    /// does.** Without it there is no way back from a sentence to the audio it
    /// came from, so a misheard line can be corrected by hand and never by a
    /// better model. With it, `[t, tEnd]` resolves against `audio.jsonl` the same
    /// way any other session time does.
    ///
    /// **Session-clock times, not a segment name and an offset.** The rule is one
    /// clock — milliseconds since epoch — and `AudioTimeline` already owns the
    /// mapping between a segment's own timeline and this one. Storing a file name
    /// here would make two authorities for that mapping, which can disagree; a
    /// pair of session times can only be resolved one way.
    ///
    /// A burst's entry grows: `t` stays the moment the first phrase began and this
    /// advances with the last one, so the span covers the whole burst — including
    /// the pauses inside it, which is correct, because the audio does too. And a
    /// burst can cross a segment boundary, so a span may cover **two files with a
    /// real gap between them**; see `AudioSegment`.
    public var tEnd: Millis?

    /// Where the phone was. Nil when there was no fix — a log from a cold start,
    /// or one made with the round not running. **Nil is a real answer and must
    /// stay one**: substituting the last known position would place a shot on the
    /// previous hole with nothing to show for it.
    public var lat: Double?, lon: Double?
    /// Horizontal accuracy in metres, so a 400 m fix can be told from a 4 m one
    /// before anything is placed on a hole from it.
    public var hAcc: Double?

    /// Which hole this belongs to, decided when the log was made — nearest hole by
    /// geometry when there is a course file and a fix, otherwise whatever hole was
    /// selected on screen.
    ///
    /// **Stored rather than recomputed.** Recomputing later gives a different
    /// answer as soon as the course file changes or the fix is reconsidered, and
    /// the user may have moved it by hand in between.
    public var hole: Int?

    /// Where `hole` came from. Nil means `.fix`, so every row already on disk keeps
    /// its meaning.
    ///
    /// **This exists because one field was being asked to carry two claims.** The
    /// rule was "`hole` means nearest hole to a *measured fix*, and stamping the
    /// hole the card happens to be showing puts a second, unmeasured meaning in one
    /// field" — with the escape hatch that doing it anyway "needs a discriminator on
    /// `LogEntry` first". *(X14, user 2026-08-28: "marker's hole — it should be the
    /// current hole".)* This is that discriminator.
    ///
    /// It is also the fix for a reported bug, not bookkeeping. `LogPlacement
    /// .converge` recomputes the hole from the fix and appends a superseding row, so
    /// a hole chosen by hand was silently replaced fifteen seconds later by
    /// `Course.nearestHole`'s coin toss between adjacent fairways — *"looked like
    /// associated hole # gets flipped sometimes"*. Convergence now leaves a `.user`
    /// hole alone, which it can only do if it can tell the two apart.
    public enum HoleSource: String, Codable, Sendable {
        /// Derived from a measured position by `Course.nearestHole`. A proposal.
        case fix
        /// Chosen by a person. Not a proposal, and nothing may recompute it.
        case user
    }
    public var holeSource: HoleSource?

    /// Whose shot this is — a `Player.id`, never a display name.
    ///
    /// **The id, for the same reason `Mark.player` and `Correction.player` store
    /// it**: a player is "steve" on the card, "스티브" to one friend and "형" to
    /// another, and a roster rename would orphan every marker that had spelled the
    /// name out.
    ///
    /// Nil is the ordinary case — a spoken sentence names whoever it names, and
    /// working out who did what from what was said is the extraction pass's whole
    /// job. This field is for the entries a person filled in by hand.
    public var player: String?

    /// Which shot of this player's hole it is, 1-based.
    ///
    /// Set with `player` or not at all: a shot number with nobody attached to it
    /// cannot be ordered against anything. Together they are what lets the hole view
    /// draw one player's shots as a line.
    public var shot: Int?

    public var source: Source

    /// The locale the text is in, canonical (`en_US`, `ko_KR`), when it is known.
    ///
    /// **Siri transcribes in the system Siri language and nothing else** — there
    /// is no second locale module the way there is for a recorded round, so a
    /// Korean sentence spoken to an English Siri comes back as mush and this field
    /// will confidently say `en_US`. It is a record of which recognizer ran, not a
    /// claim about what was spoken.
    public var locale: String?

    /// The `LogEntry.id` this replaces.
    ///
    /// **A log is edited by appending, never by rewriting**, because `JSONLWriter`
    /// opens `O_APPEND` and structurally cannot change a line that is already on
    /// disk. One mechanism therefore carries all four mutations a log can undergo:
    /// the coordinate arriving late once a fix stabilises, the sentence being
    /// corrected, the hole being moved by hand, and deletion.
    ///
    /// It lives here rather than in `journal.jsonl` on purpose. A log is
    /// **model-visible** and the journal is **ground truth**, so an edit recorded
    /// there would be invisible to the extraction pass that has to read it — the
    /// user would fix a misheard name and the model would keep reading the old
    /// one. One authority per kind of thing.
    public var supersedes: String?

    /// This row was filed by the Action Button: a position, with nobody and no
    /// shot number attached to it yet.
    ///
    /// *(User, 2026-09-03: "I want these markers to work the same way as when I
    /// clicked player marker button, just player, shot # unassigned.")* So it is an
    /// ordinary `LogEntry` written exactly as `CourseView.addShot` writes one — it
    /// supersedes, converges, is dragged, is tapped, is edited and is read by
    /// extraction like any other row. This field says only that **nothing has been
    /// assigned to it yet**, which is what lets the hole view draw it as an empty
    /// ring instead of a numbered circle, and what makes "show all unassigned
    /// marks" answerable at all.
    ///
    /// **An optional `Bool`, not a new `Source` case.** An unknown enum raw value
    /// fails the *whole row's* decode and `JSONLReader` skips the line silently, so
    /// a build or an exported `RoundBundle` that did not know the case would drop
    /// the mark entirely. A key an older reader has never heard of is simply
    /// ignored — the direction `RoundBundle.currentVersion`'s rule calls invisible.
    ///
    /// It does **not** clear when a player is assigned: `isShot` already answers
    /// "has this been attributed", and keeping the field is the only record that
    /// the row began as a button press rather than as something somebody said.
    public var mark: Bool?

    /// A tombstone: the user deleted this log.
    ///
    /// **Not an absence, deliberately.** A proposal that already cites a log has to
    /// keep rendering its evidence — `Event.logs` holds ids and the round screen
    /// looks them up — so a hard delete would leave a claim resting visibly on
    /// nothing. `LogEntry.current(_:)` drops deleted rows from the timeline;
    /// `LogEntry.byID(_:)` keeps them findable.
    public var deleted: Bool?

    public init(id: String = UUID().uuidString.prefix(8).lowercased(),
                t: Millis = SessionClock.now(),
                text: String,
                lat: Double? = nil, lon: Double? = nil, hAcc: Double? = nil,
                hole: Int? = nil,
                holeSource: HoleSource? = nil,
                player: String? = nil,
                shot: Int? = nil,
                source: Source,
                locale: String? = nil,
                supersedes: String? = nil,
                deleted: Bool? = nil,
                tEnd: Millis? = nil,
                mark: Bool? = nil) {
        self.id = id; self.t = t; self.text = text
        self.lat = lat; self.lon = lon; self.hAcc = hAcc
        self.hole = hole; self.holeSource = holeSource
        self.player = player; self.shot = shot
        self.source = source; self.locale = locale
        self.supersedes = supersedes; self.deleted = deleted
        self.tEnd = tEnd
        self.mark = mark
    }

    /// True when a person chose this row's hole, so nothing may recompute it.
    public var holeIsUserAssigned: Bool { holeSource == .user }

    /// True when this row records a specific shot by a specific player — which is
    /// what makes it drawable as part of a track rather than as a lone note.
    public var isShot: Bool { player != nil && shot != nil }

    /// A mark nobody has attributed yet — the state the hole view draws as an empty
    /// ring. Stops being true the moment a player and a shot number are put on it,
    /// which is the whole point of filing one.
    public var isUnassignedMark: Bool { mark == true && !isShot }

    /// Build one, rejecting whitespace. Returns nil rather than writing an empty
    /// row — Siri hands back an empty string when it hears nothing, and a blank
    /// log is indistinguishable on screen from a log that failed to save.
    public static func make(_ text: String, source: Source,
                            t: Millis = SessionClock.now(),
                            lat: Double? = nil, lon: Double? = nil,
                            hAcc: Double? = nil, hole: Int? = nil,
                            holeSource: HoleSource? = nil,
                            player: String? = nil, shot: Int? = nil,
                            locale: String? = nil,
                            id: String = UUID().uuidString.prefix(8).lowercased(),
                            tEnd: Millis? = nil
                            ) -> LogEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return LogEntry(id: id, t: t, text: trimmed, lat: lat, lon: lon, hAcc: hAcc,
                        hole: hole, holeSource: holeSource, player: player, shot: shot,
                        source: source, locale: locale, tEnd: tEnd)
    }

    /// The next shot number for `player` on `hole`, from rows already written.
    ///
    /// **Reads the current rows, never the raw file.** A burst entry grows by
    /// superseding, and an edited log is a new row superseding its parent — counting
    /// raw rows would jump the number every time somebody fixed a typo.
    public static func nextShot(for player: String, hole: Int?,
                                in logs: [LogEntry]) -> Int {
        let mine = current(logs).filter { $0.player == player && $0.hole == hole }
        return (mine.compactMap(\.shot).max() ?? 0) + 1
    }

    /// True when this log names a stretch of recorded audio, so it can be read
    /// again by a better model. False for a typed log — there is nothing to
    /// re-transcribe — and for any spoken log recorded before `tEnd` existed.
    public var hasAudioSpan: Bool {
        source == .spoken && (tEnd ?? 0) > t
    }

    /// May a convergence that started from `startedFrom` write a fix of this
    /// accuracy onto this chain head?
    ///
    /// **In the package because the three ways of getting it wrong are all silent**
    /// *(user, 2026-09-03: "what if the user deletes or moves while it's in flight")*
    /// — a convergence holds the radio for up to thirty seconds with the marker on
    /// screen and every gesture on it live:
    ///
    /// - **Deleted.** The row must stay deleted; a fix arriving afterwards is not a
    ///   reason to bring a mark back.
    /// - **Moved by hand.** A drag is a deliberate statement about where the shot
    ///   was played from, and it keeps whatever accuracy the row had — `nil` for a
    ///   mark that never got a fix — so the accuracy test below cannot see it. The
    ///   head's id having changed is what says somebody has spoken: nothing else in
    ///   the app writes a *position* onto a log.
    /// - **Already better.** Never replace a good fix with a worse one just because
    ///   it is newer.
    ///
    /// An edit that changed only *fields* — a player assigned to a mark, a sentence
    /// corrected — is not refused: the caller writes off the head, so those survive
    /// being placed.
    public func acceptsConvergedFix(accuracy: Double, startedFrom startID: String) -> Bool {
        if isDeleted { return false }
        if id != startID && hasPosition { return false }
        if let existing = hAcc, existing <= accuracy { return false }
        return true
    }

    /// True when this log can place something on a hole. A log without one is
    /// still worth keeping — the sentence is the signal — but nothing geometric
    /// may be derived from it.
    public var hasPosition: Bool { lat != nil && lon != nil }

    public var isDeleted: Bool { deleted == true }

    /// True when this log has a position good enough to place something from.
    ///
    /// **Says nothing about `hole`, and that is the whole point.** `hole` is a
    /// *proposal* — `Course.nearestHole` declines beyond 250 m, so a perfectly good
    /// fix taken between two fairways, or anywhere but on a mapped course,
    /// resolves to nil. Treating that as "not yet placed" made the app converge on
    /// a fix, append a superseding row, notice the hole was still nil, and
    /// converge again — forever, with a model pass on every lap. Reported from the
    /// device 2026-08-27.
    ///
    /// Lives here rather than beside the convergence code so the condition that
    /// caused the loop is one a test can reach.
    public func isPlaced(within accuracy: Double) -> Bool {
        hasPosition && (hAcc ?? .infinity) <= accuracy
    }

    // MARK: - Amending

    /// A superseding row carrying the coordinate that arrived after the fact.
    ///
    /// **`hole` is recomputed and passed in, not carried over.** The whole point of
    /// converging on a fix is to place a log that had nowhere to go; keeping the
    /// old nil would leave it exactly as unplaced as it was, which is the bug this
    /// path exists to fix.
    /// **There is deliberately no `at:` parameter.** `t` stays the moment the
    /// sentence was *said*, not the moment the fix landed — it is the one thing
    /// about a log that is not a proposal, and restamping it would reorder the
    /// round by however long the GPS took to settle.
    public func placed(lat: Double, lon: Double, hAcc: Double?, hole: Int?,
                       id newID: String = UUID().uuidString.prefix(8).lowercased()
                       ) -> LogEntry {
        var next = self
        next.id = newID
        next.lat = lat; next.lon = lon; next.hAcc = hAcc
        // **A hole a person chose survives placement.** Convergence derives the
        // hole from the fix, and `Course.nearestHole` is a coin toss between two
        // fairways forty metres apart — so a hole set by hand was being replaced
        // fifteen seconds later by a guess, which is what "the hole # gets flipped
        // sometimes" was. The position still updates: that is measured and this row
        // is the better measurement of it. Only the *claim about which hole* is
        // left alone.
        if !holeIsUserAssigned { next.hole = hole }
        next.supersedes = id
        return next
    }

    /// A superseding row with new text, a new hole, or both. Nil leaves that field
    /// as it was.
    /// A superseding row with new text, hole, player or shot. Nil leaves that field
    /// as it was.
    ///
    /// **Setting the hole here marks it `.user`**, because there is no other way to
    /// reach this method: a person is editing the row. That is what stops the next
    /// convergence recomputing it.
    /// - Parameter allowingEmptyText: let the sentence be emptied.
    ///
    ///   **Off by default, and the default is the safety rule** *(2026-09-03)*. The
    ///   two machine writers — `LiveTranscript` growing a burst and `LogRetranscribe`
    ///   re-reading one — both hand this whatever the recogniser produced, and an
    ///   empty result there means *it heard nothing this pass*, not *the golfer
    ///   deleted the sentence*. Wiping a row on that would lose what was said with
    ///   nothing anywhere saying why.
    ///
    ///   A **person** clearing the box in `LogEditor` is the opposite claim, and
    ///   since markers may legitimately carry no text at all *(user, 2026-09-03:
    ///   "empty string is fine")* the editor could not save one without this: every
    ///   edit of a textless mark returned nil here and was silently dropped.
    public func edited(text newText: String? = nil, hole newHole: Int?? = nil,
                       player newPlayer: String?? = nil, shot newShot: Int?? = nil,
                       allowingEmptyText: Bool = false,
                       id newID: String = UUID().uuidString.prefix(8).lowercased()
                       ) -> LogEntry? {
        var next = self
        next.id = newID
        next.supersedes = id
        if let newText {
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || allowingEmptyText else { return nil }
            next.text = trimmed
        }
        if let newHole {
            next.hole = newHole
            next.holeSource = .user
        }
        if let newPlayer { next.player = newPlayer }
        if let newShot { next.shot = newShot }
        return next
    }

    /// The tombstone row.
    public func removed(id newID: String = UUID().uuidString.prefix(8).lowercased()
                        ) -> LogEntry {
        var next = self
        next.id = newID
        next.supersedes = id
        next.deleted = true
        return next
    }

    // MARK: - Collapsing

    /// Latest-wins collapse for display: superseded and deleted rows drop out,
    /// chronological by when the sentence was **said**.
    ///
    /// Same shape as `Event.current(_:)`, and for the same reason — the sequence
    /// on disk is the record, and only the view is collapsed.
    public static func current(_ logs: [LogEntry]) -> [LogEntry] {
        let replaced = Set(logs.compactMap(\.supersedes))
        return logs
            .filter { !replaced.contains($0.id) && !$0.isDeleted }
            .sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
    }

    /// Every version of every log, addressable by id — **including superseded and
    /// deleted ones**, because an `Event.logs` citation points at whichever
    /// version the model actually read.
    public static func byID(_ logs: [LogEntry]) -> [String: LogEntry] {
        Dictionary(logs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Walk a log back to the row it ultimately supersedes, so a citation of an
    /// old version can be shown as the current text. Returns `self` when this is
    /// already the original.
    public static func chainRoot(of log: LogEntry, in byID: [String: LogEntry]) -> LogEntry {
        var seen = Set<String>()
        var current = log
        while let parent = current.supersedes, let next = byID[parent],
              seen.insert(current.id).inserted {
            current = next
        }
        return current
    }
}
