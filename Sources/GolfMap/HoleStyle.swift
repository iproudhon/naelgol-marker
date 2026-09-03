#if canImport(SwiftUI)
import SwiftUI
import GolfCourse

/// One palette for both renderers, so a hole looks like the same hole whether the
/// photograph is under it or not.
///
/// Chosen for **separation in sunlight**, not for prettiness: washed-out screens
/// in afternoon sun are the most common complaint about this whole category of
/// app, so nothing here relies on a subtle hue difference.
public struct HoleStyle: Sendable {
    public var rough = Color(red: 0.145, green: 0.235, blue: 0.176)
    public var roughDeep = Color(red: 0.113, green: 0.184, blue: 0.137)
    public var fairway = Color(red: 0.298, green: 0.506, blue: 0.349)
    public var green = Color(red: 0.380, green: 0.627, blue: 0.431)
    public var sand = Color(red: 0.851, green: 0.780, blue: 0.604)
    public var water = Color(red: 0.243, green: 0.431, blue: 0.525)
    /// Cart paths. Pale and thin: they orient a golfer on an unfamiliar course and
    /// carry no number, so they must read as *ground* and never compete with the
    /// plan, the rulers or the track drawn over them.
    public var cartPath = Color(red: 0.788, green: 0.769, blue: 0.714)
    public var ink = Color(red: 0.937, green: 0.953, blue: 0.925)
    public var flag = Color(red: 0.769, green: 0.271, blue: 0.176)
    public var target = Color.white

    /// The ring a target is *drawn* with, in points.
    public var targetRadius: Double = 13
    /// The circle a *finger* gets — three times the one an eye gets, and the same on
    /// both layers. It was vector-only for a while, which made satellite feel like
    /// the target could not be grabbed at all.
    public var grabRadius: Double = 39
    /// The circle a **marker** gets, which is deliberately much smaller.
    ///
    /// *(X9, user 2026-08-28: "click z hierarchy: should be the last to get picked
    /// up".)* Markers are on by default and a hole can carry a dozen, so a 39-point
    /// disc each covers most of the hole in invisible handles and a tap meant for
    /// the ground lands on one. A marker is also the rarest thing here to move —
    /// once, deliberately, with a confirmation after it — while the ground under it
    /// is tapped constantly. So it gets a handle the size of what is drawn, and a
    /// tap that hits one still falls through to the ground.
    /// How thick a player's track is drawn, on **both** layers.
    ///
    /// *(User, 2026-08-28: "line thickness flip / flops: check it out".)* It lived
    /// as a literal in each renderer — 1.3 on vector, 1.6 on satellite — so
    /// switching layer changed the weight of the same line, which is the one
    /// difference between the layers a golfer would read as meaning something. One
    /// constant, and neither renderer gets to have an opinion.
    public var shotLineWidth: Double = 1.5
    public var markerGrabRadius: Double = 17
    /// How far the marker's handle reaches **above** its point *(user, 2026-08-28:
    /// "drag handle should be extended toward down, so that I can see the marker
    /// itself while dragging with finger"; flipped 2026-08-29 with "marker display
    /// label under the point")*.
    ///
    /// A handle centred on the point puts the fingertip on the thing being dragged,
    /// and a fingertip covers about 40 points of screen — so the pill, its text and
    /// the position it is being dragged to are all under the hand for the whole
    /// gesture. The handle therefore reaches away from the label, giving the thumb
    /// somewhere to be that is not on top of what it is moving. **It reached down
    /// while the label sat above the point; the label moved under the point, so the
    /// handle moved above it.** The direction is not the rule — *away from the
    /// label* is the rule, and the two must be flipped together or the fix becomes
    /// the bug it was written against.
    public var markerGrabRise: Double = 34
    /// The gap between a marker's point and the top of its label *(user,
    /// 2026-08-29: "marker label further down. it should be under the circle / dot.
    /// it's overlapping right now")*.
    ///
    /// A shot's own dot is 11 points across, so a pill starting at the coordinate
    /// covers the lower half of the very thing it is a claim about. Big enough to
    /// clear the dot and its outline, and no bigger: a caption that floats too far
    /// from its point stops reading as belonging to it, which is why the leader line
    /// exists for the stacked case.
    public var markerLabelGap: Double = 14

    /// The radius of an unassigned **mark**'s ring, in points.
    ///
    /// Deliberately smaller than a shot's circle and drawn hollow: a mark is a
    /// position somebody stamped in a pocket, and a false positive is expected —
    /// it must read as a note on the hole rather than as a shot that was played.
    /// See `HoleMarker.isMark`.
    public var markRadius: Double = 5.5
    /// A mark's ink. The ordinary marker ink at half strength, so a hole carrying a
    /// dozen of them stays readable underneath.
    public var markInk = Color(red: 0.937, green: 0.953, blue: 0.925).opacity(0.65)
    /// The dot drawn **at a mark's own coordinate**, in points *(user, 2026-09-03:
    /// "position dot is too small. drag handle size is fine")*.
    ///
    /// Twice the 2.5 every other marker's point gets, because a mark is the only
    /// thing on this layer whose point is otherwise **undrawn**: a shot's dot comes
    /// from its `PlayerTrack`, and a mark has no track. The handle is unchanged —
    /// `markerGrabRadius` was never the complaint; what was missing was something to
    /// see under the finger.
    public var markDotRadius: Double = 5
    /// The ink of the line joining one mark to the next.
    ///
    /// **Fainter than the ring, and fainter again after the first attempt** *(user,
    /// 2026-09-03: "lines are too prominent. I want even thinner lines with lower
    /// opacity", after "can't see the lines" the same day)*. The two reports are not
    /// in conflict: the first was a satellite hairline with no casing under it,
    /// which was invisible over grass at any opacity. With the casing there, the
    /// line can go back under the ring it joins — it is a trace of the order things
    /// were pressed in, not a thing anybody clubs off.
    public var markLineInk = Color(red: 0.937, green: 0.953, blue: 0.925).opacity(0.45)
    /// The line joining one mark to the next, in points *(user, 2026-09-03: "draw
    /// lines between unassigned marks using thin line, ordered by entered time")*.
    ///
    /// **Thinner than `shotLineWidth`**, which is already the slim one. A player's
    /// track joins shots somebody assigned a number to; this joins presses of a
    /// hardware button, in the order they were pressed, with the false positives
    /// still in — so it has to read as the fainter claim of the two on a hole
    /// carrying both.
    public var markLineWidth: Double = 0.7

    /// Widths in **metres**, not points — they scale with the hole so a par 3 and a
    /// par 5 read the same.
    ///
    /// *(There was a `trackWidth` here too, in metres and read by nobody. It
    /// collided with the points-based one below the moment that was added, which is
    /// the whole argument for the rename: two numbers called the same thing in two
    /// different units.)*
    public var fairwayWidth: Double = 52
    /// Cart path width, in metres like every other width here — a real path is about
    /// this wide, so it stays honest at 40× and does not swell into a road when the
    /// green fills the screen.
    public var cartPathWidth: Double = 3

    public init() {}

    /// Player colours. Four tracks on one hole is the hard visual problem here and
    /// has no prior art — nobody else reconstructs a whole group from one phone.
    /// These four separate against fairway green and against aerial imagery.
    public static let playerColors: [Color] = [
        Color(red: 0.910, green: 0.698, blue: 0.184),   // amber
        Color(red: 0.247, green: 0.663, blue: 0.831),   // cyan
        Color(red: 0.871, green: 0.431, blue: 0.565),   // rose
        Color(red: 0.957, green: 0.965, blue: 0.949),   // bone
    ]
    public static func playerColor(_ index: Int) -> Color {
        playerColors[((index % playerColors.count) + playerColors.count) % playerColors.count]
    }

    /// Ruler colours — X10, "assign new colors, but set, to a new line segment".
    ///
    /// **A set of its own, not `playerColors`.** A ruler drawn in a player's colour
    /// reads as that player's track, which is the one thing on this screen it is
    /// not. Same bar as the player set: these separate against fairway green *and*
    /// against aerial imagery, because both layers draw rulers.
    public static let measureColors: [Color] = [
        Color(red: 0.976, green: 0.965, blue: 0.925),   // bone
        Color(red: 0.639, green: 0.847, blue: 0.976),   // ice
        Color(red: 0.984, green: 0.788, blue: 0.443),   // sand-gold
        Color(red: 0.788, green: 0.702, blue: 0.945),   // lilac
    ]
    public static func measureColor(_ index: Int) -> Color {
        measureColors[((index % measureColors.count) + measureColors.count) % measureColors.count]
    }
}

/// One player's shots on this hole: **shot 1 first**, then each one after it.
///
/// *(User, 2026-08-28: "why a line to the first shot marker of a player. it should
/// start from shot #1." The tee used to be prepended, which drew a line from the
/// tee box to wherever the drive finished — a leg nobody logged, on a hole where
/// every other leg is a row in `log.jsonl`.)*
///
/// The consequence is deliberate: a player with **one** logged shot draws no line,
/// because a line needs two ends and the second one has not been recorded yet. The
/// dot is still drawn — see the renderers, where dropping the tee also meant
/// dropping the `dropFirst()` that existed only to skip it.
public struct PlayerTrack: Identifiable, Sendable {
    /// One shot on the track: where it finished, and **which shot it was**.
    ///
    /// The number is what lets a leg know it is a *jump* — 1 to 3 with the 2 never
    /// logged — which is the only leg that gets a distance printed on it. Without
    /// it a track is a list of points and every gap looks like every other gap.
    /// Optional because a caller may have positions and no numbering, in which case
    /// no leg is ever labelled, which is the right answer rather than a guess.
    public struct Shot: Sendable, Equatable {
        public var number: Int?
        public var at: Coordinate
        public init(number: Int? = nil, at: Coordinate) {
            self.number = number; self.at = at
        }
    }

    public var id: String
    public var name: String
    public var colorIndex: Int
    public var shots: [Shot]
    /// The number the player's **next** shot on this hole would be — what the
    /// legend shows and what its button files *(user, 2026-08-28: "make font bigger
    /// and show current shot #… if it's clicked create shot marker for the user at
    /// the current location or simulated position")*.
    ///
    /// Worked out by the app from the round's logs, not from `shots`: a shot with
    /// no position is not on the track and still counts, and the answer has to be
    /// the same one the Marker sheet's stepper auto-fills or the two disagree.
    public var nextShot: Int?
    /// Drawn dashed — a shot being aimed rather than one already hit.
    public var aiming: Coordinate?
    /// This player's **score on this hole**, or nil while the hole is still open
    /// *(user, 2026-08-29: "swiping shot # to right closes it, i.e. hole out, no
    /// more shot creation on the hole … # shown is delta from par")*.
    ///
    /// **Holed out *is* having a score, and that is deliberately not a second piece
    /// of state.** A local `holedOut` flag would die on relaunch, would be invisible
    /// to `ScorecardBand`, and would make the golfer write the same number twice —
    /// while a score is a journal act, so it undoes through `HistoryView` and the
    /// card is a view of it. "The journal is the record; the card is a view of it."
    public var score: Int?

    public init(id: String, name: String, colorIndex: Int,
                shots: [Shot], aiming: Coordinate? = nil,
                nextShot: Int? = nil, score: Int? = nil) {
        self.id = id; self.name = name; self.colorIndex = colorIndex
        self.shots = shots; self.aiming = aiming
        self.nextShot = nextShot; self.score = score
    }

    /// Positions with no numbering — nothing is ever labelled as a jump.
    public init(id: String, name: String, colorIndex: Int,
                shots: [Coordinate], aiming: Coordinate? = nil,
                nextShot: Int? = nil, score: Int? = nil) {
        self.init(id: id, name: name, colorIndex: colorIndex,
                  shots: shots.map { Shot(at: $0) }, aiming: aiming,
                  nextShot: nextShot, score: score)
    }

    /// Is this hole closed out for this player? One question, one place — the
    /// legend asks it three times (what to print, whether the button is live,
    /// which way a swipe goes).
    public var holedOut: Bool { score != nil }

    /// The score relative to par, formatted the way the user asked for it: `-1`,
    /// `+0`, `+1` *(2026-08-29)*. **Zero prints as `+0`, not `E` and not `0`** —
    /// a bare `0` beside a legend that also prints shot counts is two meanings for
    /// one glyph, and the sign is what says which of the two is on screen.
    ///
    /// **Nil for a par of zero**, which is what a hole with no par at all would
    /// have to look like: a delta measured against nothing is an ordinary-looking
    /// number that is wrong, the same shape as a tee answering with another tee's
    /// yardage. The cell falls back to the shot count.
    ///
    /// *(What this does **not** catch: `OSMCourse` writes `par: 4` where the tag is
    /// missing — 11% of US hole ways — and `Hole.par` is a non-optional `Int` with
    /// no discriminator, so a guessed 4 is indistinguishable from a surveyed one
    /// here and everywhere else on the card. Pre-existing, and wider than this
    /// cell; see "Known gaps".)*
    public func toPar(_ par: Int) -> String? {
        guard let score, par > 0 else { return nil }
        let d = score - par
        return d < 0 ? "\(d)" : "+\(d)"
    }

    /// How many shots this player has **taken** on this hole — what the legend
    /// prints *(user, 2026-08-29: "it should be shots taken, so it should start with
    /// 0, not 1")*.
    ///
    /// It is `nextShot - 1` rather than `shots.count`: a shot with no position is
    /// not on the track and still counts, and the highest number anybody assigned is
    /// what "taken" means when the numbering has a gap in it. The button still files
    /// `nextShot`, so the number read and the number written differ by exactly one —
    /// deliberately. The legend answers "where am I in this hole", not "what will
    /// this button write".
    public var shotsTaken: Int? { nextShot.map { max(0, $0 - 1) } }

    public var color: Color { HoleStyle.playerColor(colorIndex) }
    public var points: [Coordinate] { shots.map(\.at) }
    /// What the **framing fit** is allowed to see — see `VectorHoleView.extraPoints`.
    ///
    /// **The closing leg's pin end is deliberately not here.** It is a point the
    /// golfer never placed, and the fit is the documented trap on this screen: a
    /// point off the hole shrinks the hole to a dot to keep it in frame. The pin
    /// sits on the green and would be harmless *today*, which is exactly how a
    /// stray point gets into the fit and stays there.
    public var allPoints: [Coordinate] { points + (aiming.map { [$0] } ?? []) }

    /// The last leg of a closed-out hole: from the final logged shot **to the
    /// flag** *(user, 2026-08-29: "when holed out, line segment extends to the
    /// pin")*.
    ///
    /// That leg is a real shot — the one that went in — so it is drawn like the
    /// rest of the track rather than as a decoration. Nil while the hole is open,
    /// because until there is a score nothing says the ball ever reached the hole.
    ///
    /// `labelled` is the **consecutive rule arriving by a new road**: the score is
    /// how many strokes were played, and the last marker's stored number is which
    /// stroke it was, so the two agreeing means this leg spans exactly one shot and
    /// its length is how far that shot went. When they disagree, shots went
    /// unlogged between the last marker and the cup, and a number on the line would
    /// state something nobody recorded.
    public func closingLeg(to pin: Coordinate) -> (from: Coordinate, to: Coordinate,
                                                   labelled: Bool)? {
        guard let score, let last = shots.last else { return nil }
        return (last.at, pin, last.number == score)
    }

    /// The legs, and whether each one joins **consecutive** shots.
    ///
    /// *(User, 2026-08-28, correcting the first reading of it: "Show distance when
    /// shot #'s are consecutive, e.g. between #2 and #3, and don't show otherwise,
    /// e.g. between #1 and #3, i.e. there's missing shots.")*
    ///
    /// A leg from 2 to 3 **is** a shot, and its length is how far that shot went —
    /// a real number about a real swing. A leg from 1 to 3 is a line drawn across a
    /// gap in the record: whatever it measures, it is not the length of any one
    /// shot, so putting a number on it would state something nobody logged.
    /// Unnumbered shots label nothing, because nothing can be told about them.
    public var legs: [(from: Shot, to: Shot, consecutive: Bool)] {
        guard shots.count >= 2 else { return [] }
        return zip(shots, shots.dropFirst()).map { a, b in
            let consecutive: Bool
            if let x = a.number, let y = b.number { consecutive = y - x == 1 }
            else { consecutive = false }
            return (a, b, consecutive)
        }
    }
}
#endif
