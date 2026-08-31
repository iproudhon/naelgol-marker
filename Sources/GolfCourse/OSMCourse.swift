import Foundation
import GolfSessionFormat

/// Build a `Course` from OpenStreetMap golf features.
///
/// **Why this exists, and why it did not for a while.** The first measurement of
/// OSM golf coverage was taken over Korea, found 597 `golf=hole` ways across 28
/// courses (~3%), and concluded geometry had to come from our own recorded track.
/// Re-measured over the US on 2026-08-26: **150,178 hole ways covering ~7,900
/// courses — about half of every facility in the country**, with `ref` on 98% and
/// `par` on 89%. For the primary market OSM is not a long shot, it is the first
/// thing to check. research-course-map.md §2.1.
///
/// > **ODbL.** Everything produced here is derived from the OpenStreetMap
/// > database and carries share-alike obligations on redistribution. The file is
/// > stamped `Course.Source.osm` with an attribution string, and in the US that
/// > stamp will be on *most* files rather than a rare one. Private use
/// > distributes nothing and so discharges nothing; the obligation returns intact
/// > the moment a file leaves the group.
///
/// **Nothing in OSM links a green to a hole.** There is no relation, no shared
/// `ref` — at Corica Park 32 greens and 100 tee polygons carry no hole number at
/// all, and the site's 27 holes reuse refs 1–9 across two courses. So every
/// association here is geometric, every one is exclusive (a green belongs to one
/// hole), and everything that fails to associate is *reported* rather than
/// swallowed into a nil. A silently mis-assigned green renders a hole that passes
/// every structural check and reads a club and a half wrong.
public enum OSMCourse {

    // MARK: - Overpass elements

    /// One element of an Overpass `out geom;` response.
    ///
    /// A way carries `geometry`; a **multipolygon relation** carries `members`, each
    /// with its own geometry and a role. `coordinates` answers for both, so nothing
    /// downstream has to know which kind of element drew a fairway.
    public struct Element: Decodable, Sendable {
        public struct Point: Decodable, Sendable {
            public let lat: Double
            public let lon: Double
        }
        /// One way of a multipolygon, as `out geom;` delivers it.
        public struct Member: Decodable, Sendable {
            public let type: String
            public let role: String?
            public let geometry: [Point]?
        }
        public let type: String
        public let id: Int
        public let tags: [String: String]
        public let geometry: [Point]?
        public let members: [Member]?

        /// The outline, whether this is a way or a multipolygon relation.
        ///
        /// **`role == "outer"` only, and that is not a detail.** Coyote Creek's 28
        /// fairway relations carry 28 outer members and **32 inner** ones — the
        /// bunkers and greens cut out of the fairway. Concatenating every member
        /// draws a spike from the outer ring across to the inner one and back, which
        /// renders as a fairway with a bite taken out of it in the wrong direction.
        /// The inner rings are dropped rather than modelled: `Hole.fairway` is a
        /// single ring, the layers cut out of it are drawn *on top of* it anyway, and
        /// an island of rough inside a fairway changes no number the golfer acts on.
        public var coordinates: [Coordinate] {
            if let geometry, !geometry.isEmpty {
                return geometry.map { Coordinate(lat: $0.lat, lon: $0.lon) }
            }
            let outer = (members ?? [])
                .filter { ($0.role ?? "outer") == "outer" }
                .map { ($0.geometry ?? []).map { Coordinate(lat: $0.lat, lon: $0.lon) } }
                .filter { $0.count >= 2 }
            return OSMCourse.stitch(outer)
        }
        public var golf: String? { tags["golf"] }
    }

    /// Join a multipolygon's outer ways into one ring.
    ///
    /// One member is the ordinary case — every fairway relation at Coyote Creek — and
    /// then this is the identity. More than one means the ring was drawn as several
    /// ways, which OSM allows and which arrive in **no particular order and in either
    /// direction**, so they are chained end to end and reversed as needed. Anything
    /// that will not chain returns the longest piece alone rather than a ring with a
    /// jump in it: a partial outline is visibly a partial outline, where a jump looks
    /// like a surveyed shape and is not.
    static func stitch(_ rings: [[Coordinate]]) -> [Coordinate] {
        guard rings.count > 1 else { return rings.first ?? [] }
        /// A metre and a half — below the 3–5 m a GPS fix resolves and far below the
        /// 1 m simplification, but wide enough for two ways that share a node and
        /// disagree in the last decimal place.
        let tolerance = 1.5
        func meets(_ a: Coordinate, _ b: Coordinate) -> Bool {
            Geodesy.distance(a, b) <= tolerance
        }
        var remaining = Array(rings.dropFirst())
        var out = rings[0]
        while !remaining.isEmpty {
            guard let end = out.last else { break }
            var joined = false
            for (i, piece) in remaining.enumerated() {
                guard let head = piece.first, let tail = piece.last else { continue }
                if meets(end, head) { out += piece.dropFirst(); remaining.remove(at: i); joined = true; break }
                if meets(end, tail) { out += piece.dropLast().reversed(); remaining.remove(at: i); joined = true; break }
            }
            if !joined { return rings.max { $0.count < $1.count } ?? out }
        }
        return out
    }

    private struct Response: Decodable { let elements: [Element] }

    public static func elements(from data: Data) throws -> [Element] {
        try JSONDecoder().decode(Response.self, from: data).elements
    }

    // MARK: - Reach limits

    /// How far an association may reach, in metres. Deliberately generous: a hole
    /// way is often drawn tee-centre to green-front rather than centre to centre,
    /// and a tee complex on a par 5 runs 80 m from the tips to the forward tee.
    /// Generosity is safe *because assignment is exclusive and reported* — an
    /// over-long reach shows up as a hole claiming a neighbour's green, which the
    /// length check catches, rather than as a missing green nobody notices.
    public struct Reach: Sendable {
        public var green: Double = 130
        public var tee: Double = 110
        /// The cap for a tee whose own label names its hole. Wider than `tee`,
        /// because at that point distance is only a sanity bound: Coyote Creek's
        /// "Hole 1 Red" sits **112 m** from hole 1's tee end — two metres past the
        /// ordinary reach — and dropping it for that would throw away the forward
        /// tee of a hole OSM labels unambiguously. Anything landing beyond `tee` is
        /// reported, never silent.
        public var namedTee: Double = 300
        public var hazard: Double = 70
        public var fairway: Double = 90
        /// How far a cart path may sit from a hole and still be drawn on it. Tighter
        /// than the rest: a path is decoration, and a wrong one is a line drawn
        /// across a hole it does not serve.
        public var path: Double = 60
        /// Douglas–Peucker tolerance for traced outlines, in metres.
        ///
        /// **One metre is below one pixel.** A hole is drawn about 400 m tall in
        /// roughly 700 points, so the vector view resolves 0.6 m — and a GPS fix is
        /// ±3–5 m, so nothing downstream can see finer than this either. Corica's
        /// 132 bunkers arrive as 4,610 vertices and 197 KB of the 240 KB file, all
        /// of it detail no screen and no fix can resolve. Greens get the same
        /// treatment but they are small and barely shrink, which is the point:
        /// the tolerance is absolute, so it removes only what was already invisible.
        public var simplify: Double = 1.0
        public init() {}
    }

    // MARK: - Report

    /// What did not fit. Printed, never discarded — see the type note above.
    public struct Report: Sendable {
        public var holesWithoutGreen: [String] = []
        public var holesWithoutTee: [String] = []
        public var greensUnassigned = 0
        public var teesUntagged = 0
        /// Untagged tee polygons adopted and named from the length order, with the
        /// ramp they were named against. Said out loud because nothing surveyed
        /// those names — see `TeeBox.inferredName`.
        public var teesNamedByLength: (count: Int, ramp: [String])?
        public var teesUnassigned = 0
        public var practiceGreensSkipped = 0
        /// Holes where a tee colour sits at a wildly different length from where
        /// that colour sits on the rest of the course. See `Candidate.teeAnomalies`.
        public var teeAnomalies: [String] = []
        /// Elements that carried no usable outline — a relation whose members did
        /// not arrive, or a "polygon" of one point.
        public var relationsUnreadable: [String: Int] = [:]
        /// Set when `golf:course:name` and the routing walk disagree about how the
        /// site divides. Not an error — the tag is followed — but the one place a
        /// wrong partition would otherwise be invisible.
        public var splitDisagreement: String?

        public var lines: [String] {
            var out: [String] = []
            if !holesWithoutGreen.isEmpty {
                out.append("no green found for hole(s) \(holesWithoutGreen.joined(separator: ", "))")
            }
            if !holesWithoutTee.isEmpty {
                out.append("no tee found for hole(s) \(holesWithoutTee.joined(separator: ", "))")
            }
            if greensUnassigned > 0 { out.append("\(greensUnassigned) green(s) matched no hole") }
            if let n = teesNamedByLength {
                out.append("\(n.count) tee(s) had no `tee` colour and were named from their "
                           + "length order (\(n.ramp.joined(separator: "/"))) — check them "
                           + "against the card")
            }
            if teesUntagged > 0 {
                out.append("\(teesUntagged) practice or driving-range tee polygon(s) dropped")
            }
            if teesUnassigned > 0 { out.append("\(teesUnassigned) tee(s) matched no hole") }
            if practiceGreensSkipped > 0 {
                out.append("\(practiceGreensSkipped) practice/putting green(s) skipped")
            }
            if let splitDisagreement { out.append(splitDisagreement) }
            out += teeAnomalies
            if !relationsUnreadable.isEmpty {
                // Worth naming rather than counting: at Corica every fairway but two
                // is a multipolygon, so "26 fairway" is the difference between "the
                // fairway layer is thin here" and "the importer lost the fairways".
                let what = relationsUnreadable.sorted { $0.value > $1.value }
                    .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                out.append("no usable outline on: \(what)")
            }
            return out
        }
    }

    // MARK: - Candidate

    /// One course found at the site. A site is very often more than one: Corica
    /// Park is an 18 plus a par-3 nine, and 27- and 36-hole facilities are the
    /// reason `Hole.ref` is not a key.
    public struct Candidate: Sendable {
        public var name: String?
        public var holes: [Hole]
        public var report: Report

        public var refs: [String] { holes.map(\.ref) }
        public var par: Int { holes.reduce(0) { $0 + $1.par } }
        /// True when every hole carries a stroke index and the set is a valid
        /// 1…n permutation. **This is the free ground truth at a multi-course
        /// site**: at Corica `handicap` is tagged on exactly the 18 and on none of
        /// the par-3 nine, so it independently confirms whatever the ref-chaining
        /// decided (see `split`).
        public var handicapIsPermutation: Bool {
            let hs = holes.compactMap(\.handicap)
            return hs.count == holes.count && Set(hs) == Set(1...holes.count)
        }
        /// Sum of measured tee→green length over the holes that have both, and the
        /// count behind it. The honest check on association: a crossed green makes
        /// a structurally perfect file with nonsense distances, and only the
        /// numbers show it (`DistanceUnit.plausibility`).
        public func measuredTotal(tee: String? = nil) -> (metres: Double, holes: Int) {
            var total = 0.0, n = 0
            for h in holes {
                let t = tee.flatMap { h.tee(named: $0) }
                guard let g = h.geometry(tee: t) else { continue }
                total += g.measuredLength; n += 1
            }
            return (total, n)
        }

        public func course(id: String, name: String? = nil,
                           updated: Millis? = nil) -> Course {
            Course(id: id, name: name ?? self.name ?? id,
                   source: .osm,
                   attribution: attributionText,
                   updated: updated, holes: holes)
        }
    }

    public static let attributionText =
        "© OpenStreetMap contributors — ODbL, https://www.openstreetmap.org/copyright"

    // MARK: - Assembly

    /// Every course found among `elements`, largest first.
    public static func candidates(in elements: [Element],
                                  reach: Reach = Reach()) -> [Candidate] {
        var report = Report()

        // **Ways and multipolygon relations alike** *(2026-08-30)*. `Element
        // .coordinates` resolves both, so nothing below has to know which kind of
        // element drew a fairway — which is the whole of the fix, because at Coyote
        // Creek **every one of the 28 fairways is a relation** and only 12 stray
        // polygons are ways. The old `filter { $0.type == "way" }` was reported as
        // "multipolygon relations skipped (ways only): 28 fairway" and read like a
        // parser gap; it was half a parser gap and half a one-word query bug — see
        // `CourseOSM.featuresQuery`.
        let areas = elements.filter { $0.coordinates.count >= 2 }
        for e in elements where e.coordinates.count < 2 {
            report.relationsUnreadable[e.golf ?? e.type, default: 0] += 1
        }

        // Hole centre-lines. Two points minimum or there is no line to orient.
        let holeWays = areas.filter { $0.golf == "hole" }
        guard !holeWays.isEmpty else { return [] }

        // Greens, minus the practice ones. A named green at a golf course is
        // almost always a practice green — real greens are unnamed because the
        // hole beside them carries the number.
        var greens: [(centre: Coordinate, polygon: [Coordinate])] = []
        for w in areas where w.golf == "green" {
            if isPractice(w.tags["name"]) { report.practiceGreensSkipped += 1; continue }
            let poly = w.coordinates
            guard poly.count >= 3, let c = Geodesy.centroid(poly) else { continue }
            greens.append((c, poly))
        }

        // Tees. An untagged tee polygon is dropped rather than named "tee": the
        // untagged ones at a real site are the driving range and the practice
        // area, and a phantom tee is worse than a missing one — it can become
        // `defaultTee` and put the camera in the wrong place.
        var tees: [(centre: Coordinate, name: String, label: String?, inferred: Bool)] = []
        // A driving range is full of `golf=tee` polygons that are not a hole's tee,
        // and now that untagged ones are adopted they are the thing standing between
        // this and a phantom tee winning `Hole.defaultTee`.
        let ranges = areas.filter { $0.golf == "driving_range" }.map(\.coordinates)
        for w in areas where w.golf == "tee" {
            guard let c = Geodesy.centroid(w.coordinates) else { continue }
            let label = w.tags["name"]
            // `yellow;3` — a tee shared between two courses. The colour is the part
            // a group says out loud; the hole number after it is noise here.
            let raw = w.tags["tee"]?.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            if let raw, !raw.isEmpty {
                tees.append((c, raw.lowercased(), label, false))
                continue
            }
            // **Untagged tees are adopted** *(user decision, 2026-08-30)*. This used
            // to be `continue`, on the rule that "an untagged tee is dropped, not
            // named 'tee'". The rule was written when the cost looked like a thin
            // tee column; at Coyote Creek the cost is **107 of 112 polygons and 16
            // of 18 holes with no tee at all**, which is the hole view falling back
            // to a centre line on a course OSM describes well. What survives of the
            // old rule is everything that kept a phantom tee out: a practice or
            // range polygon is still refused, the reach still applies, and the name
            // is marked inferred all the way to the screen.
            if isPractice(label) || ranges.contains(where: { inside(c, $0) }) {
                report.teesUntagged += 1
                continue
            }
            tees.append((c, "", label, true))
        }

        // Orientation. A `golf=hole` way is conventionally drawn tee → green, but
        // that is a convention and a reversed way renders the hole backwards with
        // the camera facing the tee. Decide it from the data instead: whichever
        // end sits nearer a green *is* the green end.
        var drafts: [Draft] = holeWays.map { w in
            let line = w.coordinates
            let a = line.first!, b = line.last!
            let dA = greens.map { Geodesy.distance(a, $0.centre) }.min() ?? .infinity
            let dB = greens.map { Geodesy.distance(b, $0.centre) }.min() ?? .infinity
            let reversed = dA < dB
            return Draft(way: w, line: reversed ? line.reversed() : line)
        }

        // Exclusive nearest-first assignment, greens then tees. Greedy over all
        // pairs sorted by distance: the closest pair in the whole site is certainly
        // right, and taking it removes both from contention. Nearest-per-hole
        // independently would let two holes claim one green.
        assignGreens(&drafts, greens, reach: reach.green, tolerance: reach.simplify,
                     report: &report)
        assignTees(&drafts, tees, reach: reach.tee, namedReach: reach.namedTee,
                   report: &report)

        for w in areas where w.golf == "fairway" {
            let poly = w.coordinates
            guard poly.count >= 3, let c = Geodesy.centroid(poly) else { continue }
            if let i = nearestHole(to: c, in: drafts, within: reach.fairway),
               drafts[i].fairway.isEmpty {
                drafts[i].fairway = simplify(poly, tolerance: reach.simplify)
            }
        }
        for w in areas where w.golf == "bunker" || w.golf == "water_hazard" {
            let poly = w.coordinates
            guard poly.count >= 3, let c = Geodesy.centroid(poly) else { continue }
            guard let i = nearestHole(to: c, in: drafts, within: reach.hazard) else { continue }
            drafts[i].hazards.append(Hazard(kind: w.golf == "bunker" ? .bunker : .water,
                                            polygon: simplify(poly, tolerance: reach.simplify)))
        }

        // Cart paths *(user decision, 2026-08-30)*. Clipped per vertex rather than
        // assigned whole: a path runs the length of one hole and then carries on to
        // the next, so "nearest hole to the midpoint" would draw a neighbour's path
        // across this hole and drop this hole's own. Runs of fewer than two
        // consecutive vertices are dropped — a single point is not a path.
        for w in areas where w.golf == "cartpath" {
            for (i, run) in clip(w.coordinates, to: drafts, within: reach.path) {
                drafts[i].paths.append(simplify(open: run, tolerance: reach.simplify))
            }
        }

        return split(drafts, report: &report).map { group in
            var c = Candidate(name: courseName(of: group), holes: group.map(\.hole),
                              report: report)
            // **Per group, not per site.** These were computed over every draft
            // before the split, so a candidate that has all its tees still listed
            // "no tee found for hole(s) 1, 2, 2, 3 …" — the duplicates being the
            // *other* course at the site. In `golfctl` that is a confusing line; in
            // `CourseFinder` `report.lines` **is** the row a golfer reads in front of
            // Save, which is the one place an import that reads a club and a half
            // wrong is supposed to be caught. A check that cries wolf about holes
            // that are fine is a check nobody reads.
            c.report.holesWithoutGreen = group.filter { $0.green == nil }.map(\.ref)
                .sorted { refOrder($0) < refOrder($1) }
            c.report.holesWithoutTee = group.filter { $0.tees.isEmpty }.map(\.ref)
                .sorted { refOrder($0) < refOrder($1) }
            // **Appended, not assigned.** `assignTees` already records the tees it
            // placed from their own label past the ordinary reach, and overwriting
            // here threw those away — a report that exists to be read, deleted one
            // line after it was written.
            c.report.teeAnomalies += teeAnomalies(in: c.holes)
            return c
        }
        .sorted { $0.holes.count > $1.holes.count }
    }

    /// What to call this course, given what OSM calls the *site* and what it calls
    /// the course.
    ///
    /// **A group name is often a bare suffix, and on its own it is not a name**
    /// *(2026-08-30)*. Coyote Creek's `golf:course:name` reads `Tournament Course`,
    /// which slugs to `tournament-course` — a file id that would collide with the
    /// tournament course of every other facility on earth. The site name
    /// ("Coyote Creek Golf Club Tournament Course") already contains it, so that is
    /// the answer there; where it does not, the two are joined, with the site's
    /// generic tail ("Golf Course", "Golf Club", "Golf Links") dropped first so
    /// Corica reads "Corica Park South Course" rather than "Corica Park Golf Course
    /// South Course".
    public static func displayName(course: String?, site: String?) -> String? {
        guard let course, !course.isEmpty else { return site }
        guard let site, !site.isEmpty else { return course }
        if site.range(of: course, options: [.caseInsensitive]) != nil { return site }
        var stem = site
        if let r = stem.range(of: "\\s+golf\\s+(course|club|links)\\s*$",
                              options: [.regularExpression, .caseInsensitive]) {
            stem = String(stem[stem.startIndex..<r.lowerBound])
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? course : "\(stem) \(course)"
    }

    /// The name of the course these holes belong to, if any feature on any of them
    /// carried one. Per-group and not per-site: a site polygon is called "Corica
    /// Park Golf Course" and covers both courses, which names neither.
    private static func courseName(of group: [Draft]) -> String? {
        var counts: [String: Int] = [:]
        for d in group { for n in d.names { counts[n, default: 0] += 1 } }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: - Splitting a site into courses

    /// Partition holes into courses by matching each hole number to a routing.
    ///
    /// Needed because refs repeat: a 27 has three holes called "1", and nothing in
    /// OSM says which is which.
    ///
    /// **Not a greedy chain.** The obvious algorithm — start at a hole 1, keep
    /// taking the nearest next-numbered tee — was tried first and it silently
    /// walked out of one course into the other at Corica Park, producing a
    /// confident "18 holes, par 63" made of a par-3 nine and a real back nine. The
    /// courses at a site are geographically interleaved, so a per-hole decision has
    /// no way to see that it has crossed over.
    ///
    /// So decide a whole hole *number* at once instead. At each ref every candidate
    /// is matched to a routing, one each, choosing the assignment that minimises
    /// total green-to-next-tee walk. Both of Corica's hole 10s are considered
    /// against both hole 9s together, and the pairing that makes two short walks
    /// beats the one that makes a short walk and a long one.
    ///
    /// **Verify the result anyway.** `Candidate.handicapIsPermutation` and
    /// `measuredTotal` are independent checks and `golfctl course osm` runs both:
    /// this is a draft the user amends, and a silently wrong partition is the one
    /// failure that looks like success.
    ///
    /// **OSM sometimes just says, and when it does that beats geometry**
    /// *(2026-08-30)*. `golf:course:name` is on all 28 hole ways at Coyote Creek —
    /// `Tournament Course` 18, `Valley Course` 10 — where the walk matching, given
    /// only ten holes of a neighbouring course clipped by the bounding box, produced
    /// **two spurious candidates of 7 and 3**. A surveyor's statement is evidence and
    /// a minimum-walk assignment is an inference, so the tag wins; the walk stays as
    /// the answer wherever the tag is absent, which is most of the world.
    ///
    /// **All or nothing.** The tag is used only when *every* hole carries one:
    /// partitioning on a partial tagging would put the tagged holes in named groups
    /// and quietly lose the rest, which is the shape of failure this whole file is
    /// written against.
    static func split(_ drafts: [Draft], report: inout Report) -> [[Draft]] {
        let byWalk = split(drafts)
        guard let tagged = byCourseName(drafts) else { return byWalk }
        if signature(tagged) != signature(byWalk) {
            report.splitDisagreement =
                "OSM tags these as \(tagged.count) course(s) — "
                + tagged.map { "\($0.count) hole(s)" }.joined(separator: ", ")
                + " — where the routing walk found \(byWalk.count). Following the tags."
        }
        return tagged
    }

    /// Groups as `golf:course:name` states them, or nil when any hole lacks the tag.
    /// Ordered by hole number inside a group and by size between them, so the result
    /// is comparable with the walk's.
    static func byCourseName(_ drafts: [Draft]) -> [[Draft]]? {
        var groups: [String: [Draft]] = [:]
        for d in drafts {
            guard let n = d.way.tags["golf:course:name"]?
                    .trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
            var d = d
            // Harvested like a tee's label, so `courseName(of:)` picks it up — it is
            // the best name available for the group and it is on every hole of it.
            d.names.append(n)
            groups[n, default: []].append(d)
        }
        guard !groups.isEmpty else { return nil }
        return groups.values
            .map { $0.sorted { refOrder($0.ref) < refOrder($1.ref) } }
            .sorted { $0.count > $1.count }
    }

    /// Set-of-sets identity, so two partitions compare regardless of order.
    private static func signature(_ groups: [[Draft]]) -> Set<Set<Int>> {
        Set(groups.map { Set($0.map(\.way.id)) })
    }

    static func split(_ drafts: [Draft]) -> [[Draft]] {
        guard !drafts.isEmpty else { return [] }
        var byRef: [Int: [Int]] = [:]
        for (i, d) in drafts.enumerated() { byRef[refOrder(d.ref), default: []].append(i) }

        var routings: [[Int]] = []
        for ref in byRef.keys.sorted() {
            let candidates = byRef[ref]!
            if routings.isEmpty { routings = candidates.map { [$0] }; continue }
            let picks = match(candidates, to: routings, drafts: drafts)
            for (candidate, routing) in picks {
                if let routing { routings[routing].append(candidate) }
                else { routings.append([candidate]) }
            }
        }
        return routings.map { $0.map { drafts[$0] } }
    }

    /// A routing walks green → next tee, and that walk is short. Longer than this
    /// and the two holes are not consecutive on the same course, however tidily
    /// their numbers follow each other — so opening a *new* routing costs this much
    /// and any real walk beats it.
    static let maxWalk: Double = 350

    /// Minimum-cost assignment of this ref's candidates to routings, one each.
    /// Brute force: a site has at most four courses, so at most a few dozen
    /// assignments, and an exact answer beats a heuristic that can cross courses.
    private static func match(_ candidates: [Int], to routings: [[Int]],
                              drafts: [Draft]) -> [(Int, Int?)] {
        // Slots: every existing routing, plus one "new routing" slot per candidate
        // so a course that genuinely starts here is representable.
        let slots: [Int?] = routings.indices.map { Optional($0) }
            + candidates.map { _ -> Int? in nil }
        func cost(_ candidate: Int, _ slot: Int?) -> Double {
            guard let r = slot, let last = routings[r].last else { return maxWalk }
            return walk(drafts[last], drafts[candidate])
        }

        var best: [(Int, Int?)] = []
        var bestCost = Double.infinity
        var used = Set<Int>()
        var current: [(Int, Int?)] = []
        func recurse(_ i: Int, _ soFar: Double) {
            if soFar >= bestCost { return }
            if i == candidates.count { bestCost = soFar; best = current; return }
            for (si, slot) in slots.enumerated() where !used.contains(si) {
                used.insert(si)
                current.append((candidates[i], slot))
                recurse(i + 1, soFar + cost(candidates[i], slot))
                current.removeLast()
                used.remove(si)
            }
        }
        recurse(0, 0)
        return best
    }

    /// Green of one hole to tee of the next — the caddie's walk, and the only
    /// signal in the data about which holes belong to the same routing.
    private static func walk(_ from: Draft, _ to: Draft) -> Double {
        Geodesy.distance(from.green?.center ?? from.line.last!, to.line.first!)
    }

    // MARK: - Internals

    public struct Draft {
        var way: Element
        /// Always tee → green, whatever direction the way was drawn in.
        var line: [Coordinate]
        var green: Green?
        var tees: [TeeBox] = []
        var fairway: [Coordinate] = []
        var hazards: [Hazard] = []
        var paths: [[Coordinate]] = []
        /// Course names harvested from the features that landed on this hole —
        /// `South Course hole 1` sits on a tee polygon, not on the hole way, so the
        /// only way to know which course it names is to see which hole took it.
        var names: [String] = []

        var ref: String { way.tags["ref"] ?? "?" }
        var teeEnd: Coordinate { line.first! }
        var greenEnd: Coordinate { line.last! }

        var hole: Hole {
            // The line's endpoints are where the *way* stops, which is not where
            // the tee box and the green centre are. Substitute the real ones so
            // `HoleGeometry.measuredLength` measures the hole and not the tracing.
            var path = line
            if let t = tees.first(where: { $0.at != nil })?.at { path[0] = t }
            if let c = green?.center { path[path.count - 1] = c }
            return Hole(ref: ref,
                        par: Int(way.tags["par"] ?? "") ?? 4,
                        handicap: Int(way.tags["handicap"] ?? ""),
                        tees: tees,
                        green: green ?? Green(),
                        line: path,
                        fairway: fairway,
                        hazards: hazards,
                        paths: paths)
        }
    }

    private static func assignGreens(_ drafts: inout [Draft],
                                     _ greens: [(centre: Coordinate, polygon: [Coordinate])],
                                     reach: Double, tolerance: Double, report: inout Report) {
        var pairs: [(d: Int, g: Int, m: Double)] = []
        for (di, d) in drafts.enumerated() {
            for (gi, g) in greens.enumerated() {
                let m = Geodesy.distance(d.greenEnd, g.centre)
                if m <= reach { pairs.append((di, gi, m)) }
            }
        }
        pairs.sort { $0.m < $1.m }
        var takenHole = Set<Int>(), takenGreen = Set<Int>()
        for p in pairs where !takenHole.contains(p.d) && !takenGreen.contains(p.g) {
            drafts[p.d].green = Green(center: greens[p.g].centre,
                                      polygon: simplify(greens[p.g].polygon, tolerance: tolerance))
            takenHole.insert(p.d); takenGreen.insert(p.g)
        }
        report.greensUnassigned = greens.count - takenGreen.count
    }

    private static func assignTees(_ drafts: inout [Draft],
                                   _ tees: [(centre: Coordinate, name: String, label: String?,
                                             inferred: Bool)],
                                   reach: Double, namedReach: Double,
                                   report: inout Report) {
        var used = 0
        for t in tees {
            // **A tee that names its hole is assigned to that hole** *(2026-08-30)*.
            // Coyote Creek's five named tees read "Hole 1 Black" … "Hole 1 Red", and
            // proximity put four of them on hole 1 and the red one on **hole 13** —
            // an ordinary-looking file where anyone playing the reds is a hole out.
            // A surveyor writing the number down beats a centroid being nearest, so
            // when a label states a hole only that hole is eligible; if it is then
            // out of reach the tee is dropped and counted, rather than silently
            // falling back to the guess this exists to overrule.
            let stated = t.label.flatMap(holeNumber(in:))
            let eligible = stated.map { n in
                drafts.indices.filter { refOrder(drafts[$0].ref) == n }
            } ?? Array(drafts.indices)
            let cap = stated == nil ? reach : namedReach
            guard let di = eligible.min(by: {
                Geodesy.distance(t.centre, drafts[$0].teeEnd)
                    < Geodesy.distance(t.centre, drafts[$1].teeEnd)
            }) else { continue }
            let away = Geodesy.distance(t.centre, drafts[di].teeEnd)
            guard away <= cap else { continue }
            if away > reach, let label = t.label {
                report.teeAnomalies.append(
                    "'\(label)' placed on hole \(drafts[di].ref) from its own label, "
                    + "\(Int(away.rounded())) m from the hole's tee end")
            }
            used += 1
            if let label = t.label, let base = stripHoleSuffix(label) {
                drafts[di].names.append(base)
            }
            // One colour per hole. A tee complex sometimes has two polygons for the
            // same colour; keep whichever sits nearer this hole's tee end. An
            // *unnamed* tee is exempt: they all carry the empty name at this point,
            // so deduplicating on it would collapse a whole tee complex into one.
            if !t.inferred,
               let existing = drafts[di].tees.firstIndex(where: { $0.name == t.name }) {
                let old = drafts[di].tees[existing].at!
                if Geodesy.distance(t.centre, drafts[di].teeEnd)
                    < Geodesy.distance(old, drafts[di].teeEnd) {
                    drafts[di].tees[existing].at = t.centre
                }
            } else {
                drafts[di].tees.append(TeeBox(name: t.name, at: t.centre,
                                              inferredName: t.inferred ? true : nil))
            }
        }
        report.teesUnassigned = tees.count - used
        // Longest first, so `Hole.defaultTee`'s fallbacks and the CLI table read in
        // the order a card prints them rather than in Overpass's order.
        for i in drafts.indices {
            let end = drafts[i].greenEnd
            drafts[i].tees.sort {
                Geodesy.distance($0.at ?? end, end) > Geodesy.distance($1.at ?? end, end)
            }
        }
        nameInferredTees(&drafts, report: &report)
    }

    /// Give an adopted, untagged tee a name from its place in the length order.
    ///
    /// **The ramp is chosen once for the whole course, from the modal number of tees
    /// per hole.** Choosing it per hole would make the third-longest tee "white" on a
    /// five-tee hole and "red" on a three-tee one, so a golfer who picked white would
    /// be on a different set of markers from hole to hole — and `marker.tee.<course>`
    /// remembers a *name*, so the hole view would lose its yardages wherever that
    /// name did not exist. One ramp, indexed by rank, means rank 0 is black
    /// everywhere, which is what a course does.
    ///
    /// A name a *tagged* tee on the hole already uses is skipped rather than
    /// duplicated: two tees called "blue" is one tee as far as `TeeBox.id` and
    /// `Hole.tee(named:)` are concerned.
    private static func nameInferredTees(_ drafts: inout [Draft], report: inout Report) {
        // **The widest set of adopted tees on any one hole, not the modal total.**
        // Two failures came out of getting this wrong, both from real files: the
        // modal *total* at Coyote Creek is 4, so the one hole with five adopted tees
        // got `tee 5`; and at Corica the holes with adopted tees are the par-3 nine
        // with one each, so the ramp was a single entry and anything longer would
        // have been `black`, `tee 2`, `tee 3`. `TeePalette` then reads those as
        // non-colour names and blends neighbours, and `marker.tee.<courseID>`
        // persists the string. Sizing to the widest hole costs a course whose deepest
        // hole has five tees nothing — the shorter holes simply stop early — and
        // removes `tee N` outright on both real courses.
        // Counted as **every** tee on the widest such hole, not only the adopted
        // ones: a ramp entry a tagged tee already holds is skipped, so a hole with a
        // tagged black and one adopted tee needs two entries to name one tee. Sized
        // to the adopted count alone, Corica's ramp was `["black"]`, black was taken,
        // and the adopted tee came out as **`tee 2`** — the exact name this sizing
        // exists to prevent, reached from the other side.
        let widest = drafts.filter { $0.tees.contains { $0.inferredName == true } }
            .map(\.tees.count).max() ?? 0
        guard widest > 0 else { return }
        let ramp = TeeBox.ramp(of: widest)
        var named = 0
        for i in drafts.indices {
            let taken = Set(drafts[i].tees.filter { $0.inferredName != true }
                                          .map { $0.name.lowercased() })
            var next = 0
            for j in drafts[i].tees.indices where drafts[i].tees[j].inferredName == true {
                while next < ramp.count && taken.contains(ramp[next]) { next += 1 }
                drafts[i].tees[j].name = next < ramp.count ? ramp[next] : "tee \(next + 1)"
                next += 1
                named += 1
            }
        }
        if named > 0 {
            report.teesNamedByLength = (count: named, ramp: ramp)
        }
    }

    private static func nearestHole(to c: Coordinate, in drafts: [Draft],
                                    within reach: Double) -> Int? {
        guard let i = drafts.indices.min(by: {
            Geodesy.distance(from: c, toPath: drafts[$0].line)
                < Geodesy.distance(from: c, toPath: drafts[$1].line)
        }) else { return nil }
        return Geodesy.distance(from: c, toPath: drafts[i].line) <= reach ? i : nil
    }

    /// Holes where a tee colour is out of position relative to the rest of the
    /// course — the one association error the length and permutation checks miss.
    ///
    /// **Found on the very first real import.** At Corica Park, `yellow` is the
    /// shortest tee on sixteen holes and the *longest* on holes 8 and 17, where a
    /// yellow polygon 64 m behind the black tee was the nearest yellow to that
    /// hole's tee end. Every structural check passes, the black-tee length matches
    /// the raw way to the metre, and anyone playing yellows gets another tee's
    /// number and a camera framed from the wrong box.
    ///
    /// Geometry alone cannot tell a legitimate back tee from a neighbour's tee that
    /// happens to sit behind this one. **Colour convention can**: a course uses a
    /// colour at the same relative length on every hole. So rank the colours by
    /// length per hole and flag any hole where a colour lands two or more places
    /// from its own median rank.
    ///
    /// This **reports and does not correct**. Which polygon is right is a question
    /// about the ground, and the file is a draft the user amends — silently
    /// deleting a tee that turned out to be real is the worse error.
    static func teeAnomalies(in holes: [Hole]) -> [String] {
        // Compared **pairwise**, not by rank and not by length share. Rank is not
        // comparable across holes (one has five tees, its neighbour three), and a
        // share of the back tee cascades: the moment a stray tee becomes the
        // longest on a hole, every other tee on that hole looks short and four
        // false alarms follow the one real fault. Whether black plays longer than
        // yellow, though, is the same answer on every hole of a course — and it is
        // exactly the fact a misassigned tee breaks.
        struct Pair: Hashable { let a: String, b: String }
        var votes: [Pair: (aLonger: Int, total: Int)] = [:]
        var perHole: [(ref: String, lengths: [String: Double])] = []

        for h in holes {
            guard let g = h.green.center else { continue }
            var lengths: [String: Double] = [:]
            for t in h.tees { if let at = t.at { lengths[t.name] = Geodesy.distance(at, g) } }
            guard lengths.count >= 2 else { continue }
            perHole.append((h.ref, lengths))
            let names = lengths.keys.sorted()
            for i in names.indices {
                for j in (i + 1)..<names.count {
                    let p = Pair(a: names[i], b: names[j])
                    var v = votes[p] ?? (0, 0)
                    v.total += 1
                    if lengths[names[i]]! > lengths[names[j]]! { v.aLonger += 1 }
                    votes[p] = v
                }
            }
        }

        // A convention needs enough holes to be a convention, and near-unanimity to
        // be worth calling a violation. Two colours a club sets at the same length
        // will split ~50/50 and are correctly never flagged.
        var settled: [Pair: Bool] = [:]
        // The anomalies dilute their own majority — two bad holes out of twelve is
        // 83%, so a 0.85 bar hides exactly the fault it is looking for. 0.8 over at
        // least six holes: a real convention holds on nearly every hole, and two
        // colours a club sets equal split near 50/50 and stay unsettled.
        for (p, v) in votes where v.total >= 6 {
            let share = Double(v.aLonger) / Double(v.total)
            if share >= 0.8 { settled[p] = true } else if share <= 0.2 { settled[p] = false }
        }

        var out: [String] = []
        for (ref, lengths) in perHole {
            var blame: [String: Int] = [:]
            var detail: [String] = []
            for (p, aLonger) in settled {
                guard let la = lengths[p.a], let lb = lengths[p.b] else { continue }
                guard (la > lb) != aLonger else { continue }
                let (longHere, shortHere) = la > lb ? (p.a, p.b) : (p.b, p.a)
                blame[longHere, default: 0] += 1
                detail.append("\(longHere) plays longer than \(shortHere) here")
            }
            guard let (name, _) = blame.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })
            else { continue }
            out.append(String(format: "hole %@: the %@ tee is out of order — %@, and it is the "
                              + "other way round on the rest of the course. A neighbouring hole's "
                              + "tee was probably picked up; %@ measures %.0f m here. Check it in "
                              + "the editor before playing that tee.",
                              ref, name, detail.sorted().joined(separator: ", "),
                              name, lengths[name] ?? 0))
        }
        return out.sorted { refOrder(String($0.dropFirst(5))) < refOrder(String($1.dropFirst(5))) }
    }

    /// Douglas–Peucker on a closed ring, run on the local plane.
    ///
    /// The centroid is computed from the **full** ring before this runs, so
    /// simplifying can never move a green centre — the number a golfer acts on is
    /// unaffected by a decision about how much outline to keep.
    static func simplify(_ ring: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard tolerance > 0, ring.count > 4 else { return ring }
        let closed = ring.first!.lat == ring.last!.lat && ring.first!.lon == ring.last!.lon
        let open = closed ? Array(ring.dropLast()) : ring
        guard let origin = open.first, open.count > 3 else { return ring }
        let pts = open.map { Geodesy.offset(of: $0, from: origin) }

        // A ring has no natural endpoints, so split it at the vertex furthest from
        // the first and simplify the two halves. Running DP on a ring directly
        // collapses it — first and last are the same point, so every vertex sits
        // zero distance from the degenerate baseline.
        func far(_ a: (east: Double, north: Double), _ b: (east: Double, north: Double)) -> Double {
            let dx = b.east - a.east, dy = b.north - a.north
            return (dx * dx + dy * dy).squareRoot()
        }
        let pivot = pts.indices.max { far(pts[0], pts[$0]) < far(pts[0], pts[$1]) } ?? pts.count - 1
        var keep = Set<Int>([0, pivot])

        func dp(_ lo: Int, _ hi: Int) {
            guard hi > lo + 1 else { return }
            let a = pts[lo], b = pts[hi]
            let dx = b.east - a.east, dy = b.north - a.north
            let len: Double = (dx * dx + dy * dy).squareRoot()
            var worst = lo, worstD = 0.0
            for i in (lo + 1)..<hi {
                let p = pts[i]
                let d = len > 0
                    ? abs(dy * (p.east - a.east) - dx * (p.north - a.north)) / len
                    : far(a, p)
                if d > worstD { worstD = d; worst = i }
            }
            guard worstD > tolerance else { return }
            keep.insert(worst)
            dp(lo, worst); dp(worst, hi)
        }
        dp(0, pivot)
        dp(pivot, pts.count - 1)
        keep.insert(pts.count - 1)

        var out = keep.sorted().map { open[$0] }
        // A polygon needs three corners to be a polygon; below that keep the ring.
        guard out.count >= 3 else { return ring }
        if closed, let f = out.first { out.append(f) }
        return out
    }

    /// A green called "Practice Putting Green" is not hole 4's green.
    private static func isPractice(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.contains("practice") || n.contains("putting") || n.contains("chipping")
    }

    // MARK: - Geometry helpers

    /// Is `c` inside the ring `poly`? Ray casting in degrees, which is exact enough
    /// for "is this tee polygon part of the driving range" at any latitude a golf
    /// course sits at.
    static func inside(_ c: Coordinate, _ poly: [Coordinate]) -> Bool {
        guard poly.count >= 3 else { return false }
        var hit = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.lat > c.lat) != (b.lat > c.lat) {
                let x = (b.lon - a.lon) * (c.lat - a.lat) / (b.lat - a.lat) + a.lon
                if c.lon < x { hit.toggle() }
            }
            j = i
        }
        return hit
    }

    /// Cut a polyline into the runs that belong to each hole.
    ///
    /// A cart path is drawn as one way running the length of several holes, so
    /// assigning the whole thing to one hole draws a neighbour's path across this
    /// hole and loses this hole's own. Each *vertex* picks its nearest hole instead,
    /// and consecutive vertices agreeing on one make a run. A run of one point is
    /// dropped — a path needs two ends, the same rule `PlayerTrack` follows.
    ///
    /// The joins are deliberately left open rather than extended to the boundary:
    /// the gap is a metre or two of path at the point where two holes are equally
    /// near, which is invisible, and inventing a crossing point would be inventing
    /// survey.
    static func clip(_ line: [Coordinate], to drafts: [Draft],
                     within reach: Double) -> [(Int, [Coordinate])] {
        var out: [(Int, [Coordinate])] = []
        var current: Int?
        var run: [Coordinate] = []
        func flush() {
            if let i = current, run.count >= 2 { out.append((i, run)) }
            run = []
        }
        for c in line {
            let owner = nearestHole(to: c, in: drafts, within: reach)
            if owner != current { flush(); current = owner }
            if owner != nil { run.append(c) }
        }
        flush()
        return out
    }

    /// Douglas–Peucker for an *open* line. `simplify(_:tolerance:)` is for rings and
    /// splits at the far vertex first because a ring's endpoints are the same point;
    /// a path has real ends and must keep both.
    static func simplify(open line: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard tolerance > 0, line.count > 2, let origin = line.first else { return line }
        let pts = line.map { Geodesy.offset(of: $0, from: origin) }
        var keep = Set([0, line.count - 1])
        func dp(_ lo: Int, _ hi: Int) {
            guard hi > lo + 1 else { return }
            let a = pts[lo], b = pts[hi]
            let dx = b.east - a.east, dy = b.north - a.north
            let len = (dx * dx + dy * dy).squareRoot()
            var worst = lo, worstD = 0.0
            for i in (lo + 1)..<hi {
                let p = pts[i]
                let d = len > 0
                    ? abs(dy * (p.east - a.east) - dx * (p.north - a.north)) / len
                    : ((p.east - a.east) * (p.east - a.east)
                       + (p.north - a.north) * (p.north - a.north)).squareRoot()
                if d > worstD { worstD = d; worst = i }
            }
            guard worstD > tolerance else { return }
            keep.insert(worst); dp(lo, worst); dp(worst, hi)
        }
        dp(0, line.count - 1)
        return keep.sorted().map { line[$0] }
    }

    /// Numeric order for a ref, so "9A" sorts beside 9 and "?" sorts last.
    static func refOrder(_ ref: String) -> Int {
        Int(ref.prefix { $0.isNumber }) ?? Int.max
    }

    /// The hole a tee's label names, if it names one.
    ///
    /// **The first standalone number in the label, not the word "hole"**, because the
    /// word is not reliable: Coyote Creek's white tee is tagged `Holw 1 White`. A
    /// surveyor's typo must not cost the hole number sitting right beside it, and the
    /// number is the part that carries the meaning. Bounded at 36 so a range marker
    /// or a year cannot be read as a hole.
    static func holeNumber(in label: String) -> Int? {
        guard let r = label.range(of: "\\b\\d{1,2}\\b", options: .regularExpression),
              let n = Int(label[r]), (1...36).contains(n) else { return nil }
        return n
    }

    private static func stripHoleSuffix(_ name: String) -> String? {
        guard let r = name.range(of: "\\s+hole\\s+\\d+\\s*$",
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let base = String(name[name.startIndex..<r.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? nil : base
    }
}
