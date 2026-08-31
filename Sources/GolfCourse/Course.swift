import Foundation
import GolfSessionFormat

/// Metres or yards, as printed on a scorecard.
///
/// Exists because **cards usually do not say which**. Everything downstream —
/// `Geodesy`, `playsLike`, `TeeBox.distance` — is metres, so the unit is carried
/// explicitly through import and normalised once, at the boundary.
public enum DistanceUnit: String, Codable, Sendable, CaseIterable {
    case metres, yards

    public var toMetres: Double { self == .metres ? 1 : 0.9144 }
    public func metres(_ v: Double) -> Double { v * toMetres }

    /// What to assume when a card does not say.
    ///
    /// **Yards**, because the courses this is aimed at are mainly American and an
    /// American card is in yards essentially always. A regional default is not a
    /// guess dressed up: it is the fact about the region, and it is right far more
    /// often than anything derivable from the numbers (see `plausibility`).
    ///
    /// Assuming is safe *because the assumption gets checked later*: the moment a
    /// tee and a green are placed, `HoleGeometry.lengthDisagreement` compares the
    /// card against the ground, and a metric card read as yards is stored ~9.4%
    /// short — far past the editor's 25 m flag. Do not try to make the inference
    /// smarter instead; that path was measured and it does not work.
    public static let assumedWhenUnstated: DistanceUnit = .yards

    /// How a total sits against a unit — **advisory only, and deliberately not a
    /// decider.**
    ///
    /// Measured, not assumed. Against the four Korean cards in
    /// research-scorecard-import.md §3.1: 도고 is 6,556 **metres** at 91.0 per par
    /// while 천룡 is 6,914 **yards** at 96.0 — five units apart, opposite units. And
    /// an ordinary American public course plays 6,100–6,600 from the tips, which is
    /// 84.7–91.7 per par: exactly the same window. **There is no total-based rule
    /// that separates them**, which is why this returns a note rather than an answer
    /// and why `assumedWhenUnstated` exists.
    ///
    /// So it flags only the genuinely impossible — a total that no course of that
    /// par plays in either unit, i.e. a misread column or a total row mistaken for
    /// a hole.
    public static func plausibility(total: Double, par: Int) -> String? {
        guard total > 0, par > 0 else { return nil }
        let perPar = total / Double(par)
        if perPar < 55 {
            return String(format: "%.0f over par %d is %.0f per hole-par — far too short for any "
                          + "full course in either unit; a tee row was probably misread", total, par, perPar)
        }
        if perPar > 115 {
            return String(format: "%.0f over par %d is %.0f per hole-par — longer than any course "
                          + "in either unit; a totals row was probably read as a hole", total, par, perPar)
        }
        return nil
    }
}

/// Where a resolved unit came from. Shown to the user, because an assumed unit and
/// a printed one deserve different amounts of trust.
public enum UnitSource: String, Sendable {
    /// The caller passed `--unit`.
    case explicit
    /// The card said so — `(M)`, `YARDS`, `미터`.
    case printed
    /// Nobody said, so `DistanceUnit.assumedWhenUnstated` was used.
    case assumed

    public var needsChecking: Bool { self == .assumed }
}

/// One tee box. Colour names because that is what a group says out loud —
/// "we're playing whites" — not a rating number.
///
/// **`at` is optional and `distance` is not redundant with it.** A card imported
/// from a course website gives the distance and no coordinates at all; a tee
/// placed by hand or derived from a track gives the coordinate and no card
/// number. Most real courses end up with both, from different sources, and the
/// two disagreeing is a useful signal rather than a bug — see
/// `HoleGeometry.lengthDisagreement`.
public struct TeeBox: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var at: Coordinate?
    /// Card distance to the green, **always metres** — normalised at import.
    public var distance: Double?
    /// USGA course rating and slope for this tee, per nine or per eighteen as the
    /// card prints them. Every American card carries both and nothing here uses
    /// them yet — they are the input any real handicap calculation needs, and they
    /// are free to capture at import and expensive to go back for.
    ///
    /// **Not a unit detector.** Rating and slope are USGA constructs but the KGA
    /// and others use them over metric cards too, so their presence says nothing
    /// about whether the yardages are yards.
    public var rating: Double?
    public var slope: Int?
    /// The name was **assigned from length order, not read off the data**.
    ///
    /// *(User decision, 2026-08-30: adopt untagged OSM tee polygons everywhere.)*
    /// 107 of Coyote Creek's 112 `golf=tee` polygons carry no `tee` colour, so
    /// dropping them left 16 of 18 holes with no tee at all. Adopted, they need a
    /// name, and the only evidence available is where each one sits in the length
    /// order — which is what `standardRamp` turns into black/blue/white/… .
    ///
    /// **So this flag is the honesty marker, and it is load-bearing.** Nothing
    /// surveyed says this tee is called "blue"; the screen prints `~ Blue Tee` for
    /// the same reason `HoleGeometry.teeInferred` and `CardYardage` do — a
    /// different quantity, not a substitute. Nil decodes as `false`, so every
    /// course file already on disk keeps saying what it always said.
    public var inferredName: Bool?
    public var id: String { name }

    /// The standard American ramp of tee names, **longest to shortest**.
    ///
    /// The single source for both the names assigned at import and the colours
    /// `TeePalette` draws — `TeePalette.standard` reads its names from here, so the
    /// two cannot drift into a course whose "blue" tee is painted green.
    public static let standardRamp = ["black", "blue", "white", "green", "gold", "red"]

    /// The ramp for a set of `n` tees, longest first.
    ///
    /// Degrades by dropping the middles rather than by truncating: five tees give
    /// the common black/blue/white/gold/red and four give black/blue/white/red,
    /// which is what American courses actually print. Truncating instead would call
    /// a four-tee course's forward tee "green", which no card does.
    public static func ramp(of n: Int) -> [String] {
        switch n {
        case ..<1: return []
        case 1: return ["black"]
        case 2: return ["black", "white"]
        case 3: return ["black", "white", "red"]
        case 4: return ["black", "blue", "white", "red"]
        case 5: return ["black", "blue", "white", "gold", "red"]
        case 6: return standardRamp
        default: return standardRamp + (6..<n).map { "tee \($0 + 1)" }
        }
    }

    /// Whether two tee names are the same tee. Colour names arrive from OSM
    /// (`black`), from a card (`BLACK`, `Black Tees`) and from the editor, and the
    /// merge has to see through the casing — see `Course.merging(card:)`.
    public static func sameTee(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "\\s+tees?$", with: "",
                                      options: [.regularExpression])
                .trimmingCharacters(in: .whitespaces)
        }
        return key(a) == key(b)
    }

    public init(name: String, at: Coordinate? = nil, distance: Double? = nil,
                rating: Double? = nil, slope: Int? = nil, inferredName: Bool? = nil) {
        self.name = name; self.at = at; self.distance = distance
        self.rating = rating; self.slope = slope; self.inferredName = inferredName
    }
}

/// The green. `polygon` is the real thing; `front` and `back` are a fallback for
/// geometry that arrived without an outline.
public struct Green: Codable, Sendable, Hashable {
    /// Nil for a card-only hole — par and yardage with no coordinates. Check
    /// `Hole.hasGeometry` before doing anything geometric.
    public var center: Coordinate?
    /// **Fallback only.** A stored front/back point is correct only from the angle
    /// it was surveyed from — approach the same green from the side and it is
    /// wrong by most of the green's width, which is exactly the full-club error
    /// front/back numbers exist to prevent. Prefer `polygon`, which
    /// `Hole.distances(from:)` measures against at render time.
    public var front: Coordinate?
    public var back: Coordinate?
    public var polygon: [Coordinate]

    public init(center: Coordinate? = nil, front: Coordinate? = nil, back: Coordinate? = nil,
                polygon: [Coordinate] = []) {
        self.center = center; self.front = front; self.back = back; self.polygon = polygon
    }
}

public struct Hazard: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case bunker, water, trees, outOfBounds
    }
    public var kind: Kind
    public var polygon: [Coordinate]
    public init(kind: Kind, polygon: [Coordinate]) { self.kind = kind; self.polygon = polygon }
}

public struct Hole: Codable, Sendable, Hashable, Identifiable {
    /// Hole number as printed on the card. A string because "9A" exists.
    public var ref: String
    /// Which nine, when the course has more than two. Korean 18s are usually two
    /// of three named nines — 천룡 plays 황룡 / 청룡 / 흑룡, each numbered 1–9 —
    /// so `ref` alone is **not** a key within a course
    /// (research-scorecard-import.md §3.2).
    public var nine: String?
    public var par: Int
    /// Stroke index. **American cards routinely print two allocations** — men's and
    /// women's — as separate rows, and they differ. This is the men's row where a
    /// card distinguishes them, and the only row where it does not.
    public var handicap: Int?
    /// The women's stroke index, when the card prints a second row. Nil is honest:
    /// it means the card had one allocation, not that men's applies to everyone.
    public var handicapWomen: Int?
    public var tees: [TeeBox]
    public var green: Green
    /// Tee → dogleg → green. What gives the hole its shape and the camera its heading.
    public var line: [Coordinate]
    /// Optional outline. When empty the renderer draws a band along `line` instead.
    public var fairway: [Coordinate]
    public var hazards: [Hazard]
    /// Cart paths crossing this hole, each a polyline, clipped to the stretch that
    /// is nearer this hole than any other.
    ///
    /// *(User decision, 2026-08-30: add a cartpath layer.)* Navigation rather than a
    /// number — nothing measures against them — so they are drawn faint and under
    /// everything, and they are the first thing to leave if a file gets too big.
    /// Empty on every course imported before this existed, and on every course that
    /// has none: OSM tags them at some sites and not at others.
    ///
    /// **Stored optional, read non-optional.** Every course file written before
    /// 2026-08-30 has no `paths` key at all, and a missing key for a non-optional
    /// array is a *decode failure* — one added field would have made every course
    /// already on disk unreadable. Verified the hard way against
    /// `Courses/corica-park-south.json`.
    private var storedPaths: [[Coordinate]]?
    public var paths: [[Coordinate]] {
        get { storedPaths ?? [] }
        // Written back as nil when empty, so a course with no cart paths encodes
        // exactly as it did before the field existed.
        set { storedPaths = newValue.isEmpty ? nil : newValue }
    }
    /// Geometry derived from one walked round is a draft, like everything else here.
    public var confidence: Double?
    /// Overrides the file's `source` for this hole. The mixed case — card from a
    /// course website, geometry from our own track — is the **normal** one, and
    /// research-course-map.md already requires provenance per hole when a file
    /// mixes sources.
    public var source: Course.Source?

    private enum CodingKeys: String, CodingKey {
        case ref, nine, par, handicap, handicapWomen, tees, green, line, fairway,
             hazards, confidence, source
        case storedPaths = "paths"
    }

    /// Unique within a course. Composite when the course names its nines.
    public var id: String { nine.map { "\($0)/\(ref)" } ?? ref }

    public init(ref: String, nine: String? = nil, par: Int, handicap: Int? = nil,
                handicapWomen: Int? = nil,
                tees: [TeeBox] = [], green: Green = Green(), line: [Coordinate] = [],
                fairway: [Coordinate] = [], hazards: [Hazard] = [],
                paths: [[Coordinate]] = [],
                confidence: Double? = nil, source: Course.Source? = nil) {
        self.ref = ref; self.nine = nine; self.par = par
        self.handicap = handicap; self.handicapWomen = handicapWomen
        self.tees = tees; self.green = green; self.line = line
        self.fairway = fairway; self.hazards = hazards
        self.storedPaths = paths.isEmpty ? nil : paths
        self.confidence = confidence; self.source = source
    }

    /// True when this hole can be drawn and measured. False for a card-only hole,
    /// which has par and yardage and no coordinates — those must render their
    /// numbers with the map suppressed, never a degenerate plane at (0, 0).
    public var hasGeometry: Bool { geometry() != nil }

    /// The tee `nil` means, everywhere. **One answer, and that is the point.**
    ///
    /// It used to prefer a tee called "white" over a *placed* one, while
    /// `geometry(tee:)` independently preferred the first tee with coordinates —
    /// so on Corica hole 1 `cardLength(from: nil)` meant white and
    /// `geometry(tee: nil)` meant black, and `length(from: nil)` therefore
    /// returned **black's 483 m under white's name**: 59 yards, four clubs, on the
    /// first hole of the only real course file there is. Exactly the fault
    /// `cardLength`'s own doc comment warns about, one level up from where it was
    /// being guarded.
    ///
    /// Placed tees win the pool first, so `geometry(tee: nil)` can use this
    /// directly without a card-only course losing its hole view.
    public var defaultTee: TeeBox {
        let placed = tees.filter { $0.at != nil }
        let pool = placed.isEmpty ? tees : placed
        return pool.first { $0.name.lowercased() == "white" }
            ?? pool.first
            ?? TeeBox(name: "tee")
    }

    public func tee(named name: String) -> TeeBox? {
        tees.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The resolved, non-optional view of this hole. Nil when there is no
    /// geometry — which is the point: renderers and distance readouts take this
    /// instead of `Hole`, so "no coordinates" is handled once here rather than
    /// with an optional dance at every draw call.
    /// Nil when *this* tee has no coordinate — never another tee's. Substituting
    /// would put the big number, the F/C/B tray and the camera on a tee other than
    /// the one the screen is labelled with, which is worse than saying nothing.
    public func geometry(tee: TeeBox? = nil) -> HoleGeometry? {
        // `defaultTee` and nothing else — see its doc comment for the 59-yard
        // disagreement that a second, independent "which tee does nil mean?"
        // produced.
        let t = tee ?? defaultTee
        // **A hole with a centre line is drawable even with no tee and no green
        // point** *(user, 2026-08-30: "if tees are not in the data, we're not
        // showing anything right now. We should show the hole as long as any
        // locatable data is there")*. This is not hypothetical: `golfctl course osm`
        // reports "no tee found for hole(s) 1…9" on a real site, and those holes
        // have a surveyed `golf=hole` way and were rendering as *"No map for this
        // hole yet"* — which reads as the app being broken about a hole OSM
        // describes perfectly well.
        //
        // The line's ends are real surveyed points, **not** a nil coalesced to
        // something plausible: `line` runs tee end to green end, and its orientation
        // is decided from the data (see `OSMCourse`). That distinction is the whole
        // of the `HolePlane` rule about nil-coalesced coordinates drawing the hole
        // at the equator.
        //
        // **Only when nothing on the hole is placed.** If some tee has coordinates
        // and this one does not, the answer stays nil — "no tee may answer with
        // another tee's numbers", and a tee answering with the centre line's start
        // under its own name is the same error wearing a different hat.
        let anyTeePlaced = tees.contains { $0.at != nil }
        let teeAt = t.at ?? (anyTeePlaced ? nil : line.first)
        let centre = green.center ?? line.last
        guard let teeAt, let centre, teeAt != centre else { return nil }
        return HoleGeometry(hole: self, tee: t, teeAt: teeAt, greenCenter: centre,
                            teeInferred: t.at == nil,
                            greenInferred: green.center == nil)
    }

    /// Distance printed on the card **for this tee**, in metres. Independent of
    /// geometry — the number on the tee sign, right even before anyone has placed
    /// a coordinate.
    ///
    /// Nil when that tee has no card number, and deliberately **not** the longest
    /// tee's number instead: a members' tee added in the editor would otherwise
    /// render as "350 M · MEMBERS TEE", which is another tee's distance under this
    /// tee's name. A missing number must read as missing.
    public func cardLength(from tee: TeeBox? = nil) -> Double? {
        (tee ?? defaultTee).distance
    }

    /// What to *show* the golfer: the card number when there is one, and the
    /// measured geometry otherwise. Nil when the hole has neither.
    public func length(from tee: TeeBox? = nil) -> Double? {
        cardLength(from: tee) ?? geometry(tee: tee)?.measuredLength
    }

    /// Bearing tee → green, or nil for a card-only hole.
    public func bearing(from tee: TeeBox? = nil) -> Double? {
        geometry(tee: tee)?.bearing
    }

    /// Front, centre and back **measured from where the player is standing**, not
    /// read out of the file. Nil for a card-only hole.
    public func distances(from p: Coordinate) -> GreenDistances? {
        geometry()?.distances(from: p)
    }

    /// Metres of rise from `p` to the green, **read out of a stored DEM**.
    ///
    /// The preferred form, and the only one with a real source behind it: both
    /// ends come from the same grid, so the datum cancels by construction —
    /// research-elevation.md §4's invariant, which is enforced one layer down by
    /// `Elevation.Sample.delta`. Falls back to the file's own altitudes when there
    /// is no terrain, which is every course imported from OSM.
    public func elevationDelta(from p: Coordinate, using terrain: Elevation?) -> Double? {
        if let terrain, let green = green.center ?? geometry()?.greenCenter,
           let d = terrain.delta(from: p, to: green) {
            return d
        }
        // **The fallback is per hole and carries no discriminator**, so a table
        // built from this can blend DEM-sourced rows with file-sourced ones and
        // say nothing. `HoleReadout.riseSource` answers the question for the one
        // number a golfer clubs off; nothing else does. Only `SampleCourse` has
        // file altitudes at all today, so it does not yet bite.
        return elevationDelta(from: p)
    }

    /// Metres of rise from `p` to the green, from the **course file's own**
    /// altitudes.
    ///
    /// **`p.alt` is deliberately not read, and that is the datum rule.** This used
    /// to prefer the point's own altitude and fall back to the interpolated
    /// profile, which is correct only for a point that came out of this file. Hand
    /// it a GPS fix — `CLLocation.altitude` is above mean sea level,
    /// `ellipsoidalAltitude` is not, and the two differ by roughly −30 m in
    /// California — and the subtraction is between two different references and is
    /// out by the geoid separation. That is far larger than the rise it is trying
    /// to express and it reads like an ordinary large number rather than like an
    /// error. `RoundViewModel.here` already nils the altitude for exactly this
    /// reason; relying on every future caller to remember is what this removes.
    /// research-elevation.md §4.
    ///
    /// Nil is honest — a plays-like number with no elevation behind it must
    /// disappear, not read 0.
    public func elevationDelta(from p: Coordinate) -> Double? {
        guard let there = green.center?.alt,
              let here = estimatedAltitude(at: p) else { return nil }
        return there - here
    }

    /// Ground elevation at `p`, interpolated along the hole line.
    ///
    /// Needed because **the phone's barometer cannot supply this directly**:
    /// `CMAltimeter` relative altitude is measured from session start, not from
    /// sea level, so it is not comparable with a course file's altitudes. Absolute
    /// altitude needs a pressure reference and is often far off. Interpolating the
    /// surveyed profile is the honest substitute — it is an estimate from geometry,
    /// and it is why `Hole.confidence` exists.
    public func estimatedAltitude(at p: Coordinate) -> Double? {
        var path = line
        if path.count < 2 {
            guard let g = geometry() else { return nil }
            path = [g.teeAt, g.greenCenter]
        }
        guard path.contains(where: { $0.alt != nil }) else { return nil }

        var best: (distance: Double, alt: Double)?
        for (a, b) in zip(path, path.dropFirst()) {
            let av = Geodesy.offset(of: a, from: p), bv = Geodesy.offset(of: b, from: p)
            let dx = bv.east - av.east, dy = bv.north - av.north
            let len2 = dx * dx + dy * dy
            // Projection of p (the origin, in this frame) onto segment a→b.
            let t = len2 > 0 ? max(0, min(1, -(av.east * dx + av.north * dy) / len2)) : 0
            let cx = av.east + t * dx, cy = av.north + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            guard let aAlt = a.alt ?? b.alt, let bAlt = b.alt ?? a.alt else { continue }
            let alt = aAlt + (bAlt - aAlt) * t
            if best == nil || d < best!.distance { best = (d, alt) }
        }
        return best?.alt
    }

    /// False for a card-only hole. Unknowable there, and false is the answer that
    /// does not silently end a hole that is still being played.
    public func isOnGreen(_ p: Coordinate) -> Bool {
        if green.polygon.count >= 3 { return Geodesy.contains(green.polygon, p) }
        guard let c = green.center else { return false }
        return Geodesy.distance(p, c) < 14
    }
}

/// A hole that is known to have coordinates, with every geometric answer
/// non-optional. Built by `Hole.geometry(tee:)`; renderers take this.
public struct HoleGeometry: Sendable, Hashable {
    public let hole: Hole
    public let tee: TeeBox
    public let teeAt: Coordinate
    public let greenCenter: Coordinate
    /// This end came from the hole's **centre line**, because no tee on the hole is
    /// placed. A real point on the ground, and still not a tee: it is the start of
    /// the way somebody traced, so it is where the hole begins rather than where a
    /// particular set of markers sits.
    public let teeInferred: Bool
    /// Likewise for the green end — the line's far end rather than a surveyed
    /// green centre. Front and back are still measured against `green.polygon`, so
    /// they simply do not appear when there is no outline.
    public let greenInferred: Bool

    public init(hole: Hole, tee: TeeBox, teeAt: Coordinate, greenCenter: Coordinate,
                teeInferred: Bool = false, greenInferred: Bool = false) {
        self.hole = hole; self.tee = tee; self.teeAt = teeAt; self.greenCenter = greenCenter
        self.teeInferred = teeInferred; self.greenInferred = greenInferred
    }

    /// Bearing tee → green. The heading both renderers orient to, so the tee is at
    /// the bottom of the screen and the green at the top.
    public var bearing: Double { Geodesy.bearing(from: teeAt, to: greenCenter) }

    /// Length along `line`, falling back to a straight tee→green measure. This is
    /// what the ground says, as opposed to what the card says.
    ///
    /// The endpoints are always the *current* tee and green, with `line` supplying
    /// only the shape in between. Otherwise moving a green in the editor would
    /// leave this number unchanged — and `lengthDisagreement`, the one check that
    /// catches a point dropped on the wrong hole, would never fire.
    public var measuredLength: Double {
        var path = [teeAt]
        if hole.line.count > 2 { path += hole.line.dropFirst().dropLast() }
        path.append(greenCenter)
        return zip(path, path.dropFirst()).reduce(0) { $0 + Geodesy.distance($1.0, $1.1) }
    }

    /// What to show: card first, ground second.
    public var length: Double { tee.distance ?? measuredLength }

    /// Metres by which a hand-placed or track-derived geometry disagrees with the
    /// printed card, or nil when there is no card number to check against.
    ///
    /// This is the cheapest correctness check the editor has: place a tee and a
    /// green centre, and if the card says 383 and the ground measures 340, one of
    /// the two is wrong *before* anyone walks onto the tee.
    public var lengthDisagreement: Double? {
        tee.distance.map { abs($0 - measuredLength) }
    }

    /// Front, centre and back measured from where the player is standing. Front is
    /// the nearest point of the green outline, back the furthest; centre is the
    /// stored centre. With no polygon this falls back to the stored front/back,
    /// and failing that to centre ± an assumed 12 m.
    public func distances(from p: Coordinate) -> GreenDistances {
        let centre = Geodesy.distance(p, greenCenter)
        if hole.green.polygon.count >= 3 {
            let ds = hole.green.polygon.map { Geodesy.distance(p, $0) }
            return GreenDistances(front: ds.min() ?? centre, center: centre, back: ds.max() ?? centre)
        }
        let front = hole.green.front.map { Geodesy.distance(p, $0) } ?? max(0, centre - 12)
        let back = hole.green.back.map { Geodesy.distance(p, $0) } ?? centre + 12
        return GreenDistances(front: min(front, back), center: centre, back: max(front, back))
    }

    /// The playing line, tee → green, with the current endpoints.
    ///
    /// Same construction `measuredLength` walks: `hole.line` supplies only the shape
    /// in between, so moving a tee or a green in the editor moves this too.
    public var playLine: [Coordinate] {
        var path = [teeAt]
        if hole.line.count > 2 { path += hole.line.dropFirst().dropLast() }
        path.append(greenCenter)
        return path
    }

    /// The point `metres` along `playLine` from the tee, clamped to the green end.
    ///
    /// **Along the line, not as the crow flies**, so on a dogleg it lands on the
    /// fairway rather than in the trees the corner cuts across — which is the whole
    /// difference between `measuredLength` and a straight tee→green measure, and the
    /// reason Corica hole 1 is 469 on the card and 426 to the green.
    public func point(along metres: Double) -> Coordinate {
        let path = playLine
        guard metres > 0 else { return teeAt }
        var walked = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let leg = Geodesy.distance(a, b)
            if walked + leg >= metres {
                let t = leg > 0 ? (metres - walked) / leg : 0
                return Geodesy.interpolate(a, b, t)
            }
            walked += leg
        }
        return greenCenter
    }

    /// Where a target goes when a **button** places it rather than a finger.
    ///
    /// *(X6, user 2026-08-28.)* A par 3 is one shot, so the only useful reference is
    /// a fraction of the way in — two thirds. A par 4 or 5 is a drive first, and 250
    /// yards is where the fairway marker would be, so it is measured **along the
    /// playing line**. Clamped short of the green, because a target on the putting
    /// surface is a target nobody was going to aim at.
    public var suggestedTarget: Coordinate {
        let toGreen = measuredLength
        if hole.par <= 3 { return point(along: toGreen * 2.0 / 3.0) }
        let drive = 250 * DistanceUnit.yards.toMetres
        return point(along: min(drive, toGreen * 0.85))
    }

    /// Two thirds of the way from a point to the centre of the green — where a
    /// **second** target goes when a button places it.
    public func towardGreen(from p: Coordinate, fraction: Double = 2.0 / 3.0) -> Coordinate {
        Geodesy.interpolate(p, greenCenter, fraction)
    }

    /// Every coordinate that must stay on screen.
    public var allPoints: [Coordinate] {
        var pts = [teeAt, greenCenter]
        pts += hole.line
        pts += hole.green.polygon
        pts += hole.fairway
        for h in hole.hazards { pts += h.polygon }
        return pts
    }
}

public struct GreenDistances: Sendable, Hashable {
    public var front: Double, center: Double, back: Double
    public init(front: Double, center: Double, back: Double) {
        self.front = front; self.center = center; self.back = back
    }
}

/// One course, one file. Lives outside `Sessions/` and — unlike a session — is
/// committable: it holds no voices and no credentials, and a course does not
/// change between rounds.
public struct Course: Codable, Sendable, Hashable, Identifiable {

    /// A file-name-safe id from a course's name — `"Corica Park South"` becomes
    /// `"corica-park-south"`.
    ///
    /// **In the package as of 2026-08-30**, because two importers now need it: the
    /// CLI's `course osm` and the app's course finder. It was `CourseImport.slug`
    /// inside `golfctl`, which nothing else can import, and a second copy in the app
    /// would be two id schemes that agree until the day they do not — at which point
    /// re-importing a card over an OSM file silently writes a second course.
    ///
    /// ASCII only, deliberately: a Korean course's name slugs to `"course"` and
    /// wants an explicit id, which is better than a file name the Files app and
    /// Finder disagree about.
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = ""
        var lastDash = true
        for ch in name.lowercased().unicodeScalars {
            if allowed.contains(ch) && ch.isASCII {
                out.unicodeScalars.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "course" : trimmed
    }
    /// Where the geometry came from. Load-bearing, not metadata: an OSM-derived
    /// file carries ODbL share-alike obligations, a track-derived one is ours
    /// outright, and mixing them silently is how a licence gets breached.
    public enum Source: String, Codable, Sendable {
        case track      // derived from our own recorded GPS — the primary path
        case survey     // walked with the MARK button
        case osm        // OpenStreetMap. ODbL.
        case traced     // hand-placed on imagery. See the note below.
        case card       // par/handicap/yardage imported from a published scorecard
        case api        // commercial course database
        case sample     // built in code, for previews and development
    }

    public var id: String
    public var name: String
    public var aliases: [String]
    public var source: Source
    public var attribution: String?
    /// The unit the source card printed, before normalisation to metres. Kept so
    /// that "actually those were yards" is a one-field fix rather than a re-import.
    public var cardUnit: DistanceUnit?
    public var updated: Millis?
    public var holes: [Hole]

    public init(id: String, name: String, aliases: [String] = [],
                source: Source, attribution: String? = nil,
                cardUnit: DistanceUnit? = nil,
                updated: Millis? = nil, holes: [Hole] = []) {
        self.id = id; self.name = name; self.aliases = aliases
        self.source = source; self.attribution = attribution
        self.cardUnit = cardUnit
        self.updated = updated; self.holes = holes
    }

    /// Matches the composite `id` first, then a bare `ref` — so `hole("7")` still
    /// works on a single-18 course, and `hole("황룡/3")` is unambiguous on a 27.
    public func hole(_ key: String) -> Hole? {
        holes.first { $0.id == key } ?? holes.first { $0.ref == key }
    }

    public func hole(nine: String?, ref: String) -> Hole? {
        holes.first { $0.nine == nine && $0.ref == ref }
    }

    /// Which hole a position is on — **a proposal, not a fact.**
    ///
    /// Returns the **1-based playing-order index**, which is what a scorecard
    /// column and `LogEntry.hole` mean. (`Hole.ref` is not a key — a 27 has three
    /// holes called "1" — so the index is the only thing that identifies a column.)
    ///
    /// *Why this is only a proposal.* Adjacent fairways on a real course run
    /// tens of metres apart, and a GPS fix is ±3–5 m at best and far worse under
    /// trees. The nearest hole to a point standing between two fairways is a coin
    /// toss, and no amount of geometry fixes that — it is the same wall that makes
    /// audio, not sensors, the thing that attributes a shot. So the answer is
    /// **stored on the log and left editable** rather than recomputed as if it
    /// were derived.
    ///
    /// Distance is to the nearest of the hole's tees, centre line and green,
    /// because a hole is a corridor and a golfer stands anywhere along it. Holes
    /// with no coordinates at all are skipped rather than treated as infinitely
    /// far — a card-only course simply has no answer here, which is why the return
    /// is optional.
    ///
    /// - Parameter limit: metres beyond which "nearest" stops meaning anything.
    ///   The default is generous: a hole is ~400 m long and a golfer in the trees
    ///   is legitimately 60 m off the line, but a fix in the car park should come
    ///   back nil rather than claim hole 1.
    public func nearestHole(to p: Coordinate, within limit: Double = 250)
        -> (index: Int, hole: Hole, distance: Double)?
    {
        var best: (index: Int, hole: Hole, distance: Double)?
        for (i, hole) in holes.enumerated() {
            var candidates: [Double] = []
            // The centre line is measured *perpendicular*, not to its vertices —
            // a hole is drawn in a handful of points and a golfer halfway down a
            // straight leg is nearest to the segment, not to either end of it.
            if hole.line.count >= 2 {
                candidates.append(Geodesy.distance(from: p, toPath: hole.line))
            }
            candidates.append(contentsOf: hole.line.map { Geodesy.distance(p, $0) })
            candidates.append(contentsOf: hole.tees.compactMap(\.at).map { Geodesy.distance(p, $0) })
            if let c = hole.green.center { candidates.append(Geodesy.distance(p, c)) }
            guard let d = candidates.min() else { continue }
            if best == nil || d < best!.distance {
                best = (i + 1, hole, d)
            }
        }
        guard let best, best.distance <= limit else { return nil }
        return best
    }

    /// Named nines in card order, empty for a course that does not name them.
    public var nines: [String] {
        var seen: [String] = []
        for h in holes { if let n = h.nine, !seen.contains(n) { seen.append(n) } }
        return seen
    }

    public func holes(nine: String) -> [Hole] { holes.filter { $0.nine == nine } }

    /// Apply a freshly imported card **without discarding geometry**.
    ///
    /// Re-importing after the club corrects its website must not wipe out tees and
    /// greens someone placed by hand — that work costs far more than the card does.
    /// Card numbers win; coordinates survive; holes the new card does not mention
    /// stay put, so importing one nine of a 27 does not delete the other two.
    public func merging(card new: Course) -> Course {
        var result = self
        result.name = new.name
        result.aliases = Array(Set(aliases).union(new.aliases)).sorted()
        result.cardUnit = new.cardUnit
        result.updated = new.updated

        var merged: [Hole] = []
        for n in new.holes {
            guard var kept = holes.first(where: { $0.id == n.id }) else {
                merged.append(n); continue
            }
            let oldTees = kept.tees
            kept.par = n.par
            kept.handicap = n.handicap
            kept.handicapWomen = n.handicapWomen
            // Tee names are matched **case- and space-insensitively**, and that is
            // load-bearing: OSM tags a tee `black`, an American card prints
            // `BLACK`, and a hand-placed one is `Black`. An exact match silently
            // fails every one of those — every card tee lands with `at == nil` and
            // the geometry tees pile up beside them as duplicates, so the merge
            // reads as a success and throws away the coordinates it exists to keep.
            kept.tees = n.tees.map { fresh in
                var t = fresh
                let old = oldTees.first { TeeBox.sameTee($0.name, fresh.name) }
                t.at = old?.at
                // **`inferredName` survives the merge, and it must.** The card
                // confirms that the course *has* a white tee; it says nothing about
                // which polygon that is, and our name came from a rank in the length
                // order. Dropping the mark here would put a printed yardage under an
                // invented name with nothing on screen saying so — "no tee may answer
                // with another tee's numbers" arriving by the one road nobody
                // watches. `HoleGeometry.lengthDisagreement` is then the check that
                // catches a mis-ranked tee, which is exactly what it is for.
                t.inferredName = old?.inferredName
                return t
            }
            // A tee that exists only in the old file — hand-placed or from OSM,
            // never on the card — is kept rather than dropped.
            for old in oldTees where !kept.tees.contains(where: { TeeBox.sameTee($0.name, old.name) }) {
                kept.tees.append(old)
            }
            // `kept.source` is deliberately NOT reassigned. Under the US flow the
            // ordinary file is OSM geometry with a website card imported over it,
            // and a hole can only record one source — so the *stricter* one wins.
            // Overwriting `.osm` with `.card` here would erase the ODbL obligation
            // on the very hole that carries it.
            merged.append(kept)
        }
        for o in holes where !merged.contains(where: { $0.id == o.id }) { merged.append(o) }
        result.holes = merged
        // Keep the more specific provenance rather than claiming the merged file
        // is one source: it is genuinely mixed, and that is the normal case.
        result.source = hasGeometry ? source : new.source
        return result
    }

    /// Holes that carry a card but no coordinates. What the editor exists to empty.
    public var holesWithoutGeometry: [Hole] { holes.filter { !$0.hasGeometry } }
    public var hasGeometry: Bool { holes.contains { $0.hasGeometry } }
}
