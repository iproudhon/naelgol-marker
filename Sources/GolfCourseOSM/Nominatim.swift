import Foundation

/// Name → bounding box, the fast way.
///
/// **Measured 2026-08-30, which is why this exists** *(user: "search is very slow. is
/// this expected?" — yes, and it did not have to be)*. Searching Overpass by name
/// means a **regex over every `leisure=golf_course` way and relation on the planet**,
/// with no bounding box to narrow it: `"Corica Park"` took **12.5 s and then returned
/// 504** — Overpass timing itself out — against **0.72 s** from Nominatim, which
/// answered with the facility, its `leisure=golf_course` tags and exactly the bounding
/// box the feature query needs. Nominatim is a geocoder with an index built for this
/// question; Overpass is a query engine being asked to scan.
///
/// Overpass is still what fetches the geometry — that part *is* a spatial query and it
/// is fast once there is a box. And `CourseOSM.sites(named:)` still falls back to the
/// old query if this one finds nothing, because a course whose name is mistagged for
/// the geocoder may still be in OSM.
///
/// **Usage policy**, and it is a condition rather than etiquette: at most one request
/// a second, and a real `User-Agent` naming the app. The ladder below can send three,
/// so it sleeps between them; a course import is a handful of queries a year here, so
/// the extra second on the failing path costs nothing.
enum Nominatim {
    static let endpoint = "https://nominatim.openstreetmap.org/search"

    /// Nominatim's own rate limit. Only paid on the second and third rungs.
    static let politePause: Duration = .milliseconds(1100)

    private struct Result: Decodable {
        let name: String?
        let display_name: String?
        let category: String?
        let type: String?
        /// `[south, north, west, east]`, as strings.
        let boundingbox: [String]?
    }

    // MARK: - What the golfer typed

    /// A typed search split into a name and a place.
    ///
    /// **This split is the whole fix for the reported failure** *(user, 2026-08-30:
    /// "search is failing: I was looking for Coyote Creek Tournament Course in Morgan
    /// Hill, CA")*. Measured against the live geocoder, free-form `q`:
    ///
    /// | typed | golf results |
    /// |---|---|
    /// | `Coyote Creek Tournament Course in Morgan Hill, CA` | **0 of 0** |
    /// | `Coyote Creek Tournament Course, Morgan Hill, CA` | **0 of 0** |
    /// | `Coyote Creek` | **0** golf, of 18 — every one a *river* |
    /// | `Coyote Creek Tournament Course` | 1 |
    ///
    /// Free-form parsing has to guess which words are the name and which are the
    /// place, and on a course name ending in a common noun ("… Course") it guesses
    /// wrong and returns nothing at all. Structured search does not guess: the name
    /// goes in `amenity` and the place in `city`/`state`. The same two failing
    /// strings return the right course, first hit, that way.
    struct Query {
        var name: String
        var city: String?
        var state: String?

        /// `"<name> in <city>, <state>"` and `"<name>, <city>, <state>"` both parse.
        /// A bare name stays a bare name — most searches are one — and anything with
        /// more parts than that keeps the tail in `city`, which Nominatim tolerates.
        init(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var head = trimmed
            var tail: [String] = []
            if let r = trimmed.range(of: "\\s+in\\s+", options: [.regularExpression, .caseInsensitive]) {
                head = String(trimmed[trimmed.startIndex..<r.lowerBound])
                tail = String(trimmed[r.upperBound...]).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            } else if trimmed.contains(",") {
                let parts = trimmed.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                head = parts[0]
                tail = Array(parts.dropFirst())
            }
            name = head.trimmingCharacters(in: .whitespaces)
            tail = tail.filter { !$0.isEmpty }
            city = tail.first
            state = tail.count > 1 ? tail.dropFirst().joined(separator: ", ") : nil
        }

        /// The place, flattened back into words — for the free-form rungs, which take
        /// one string and do their own parsing.
        var place: String {
            [city, state].compactMap { $0 }.joined(separator: " ")
        }
    }

    // MARK: - Search

    /// Golf facilities matching `name`, as boxes ready for the feature query.
    ///
    /// **Three rungs, in measured order**, stopping at the first that returns a golf
    /// course:
    ///
    /// 1. **Structured** — `amenity=<name>`, `city`/`state` from the place. Strictly
    ///    better than free-form on everything tried here: it is the only rung that
    ///    finds `Coyote Creek Tournament Course` at all.
    /// 2. **The `golf course` special phrase** — `q = "golf course <name> <place>"`.
    ///    Nominatim reads a leading category phrase as a filter, so this is what
    ///    rescues a *name that is not the course's OSM name*: `Coyote Creek` alone
    ///    returns eighteen rivers, and `golf course Coyote Creek` returns six courses
    ///    including both of the ones the golfer meant.
    /// 3. **Plain free-form** — what this used to do alone. Kept last rather than
    ///    deleted: it is the rung that matches a `display_name` the other two do not.
    ///
    /// Returns an empty array when the geocoder simply knows nothing, and **throws**
    /// when it could not be asked. The caller must be able to tell those apart — a
    /// network failure here used to fall silently through to the planet-wide Overpass
    /// regex, which then reported *"Overpass timed out, narrow the area"* for what was
    /// a geocoder problem in a different service.
    static func sites(named name: String) async throws -> [CourseOSM.Site] {
        let q = Query(name)
        let place = q.place

        var items: [URLQueryItem] = [URLQueryItem(name: "amenity", value: q.name)]
        if let city = q.city { items.append(URLQueryItem(name: "city", value: city)) }
        if let state = q.state { items.append(URLQueryItem(name: "state", value: state)) }
        let structured = try await search(items, fallbackName: q.name)
        if !structured.isEmpty { return structured }

        try? await Task.sleep(for: politePause)
        let phrase = "golf course \(q.name) \(place)".trimmingCharacters(in: .whitespaces)
        let category = try await search([URLQueryItem(name: "q", value: phrase)],
                                       fallbackName: q.name)
        if !category.isEmpty { return category }

        try? await Task.sleep(for: politePause)
        return try await search([URLQueryItem(name: "q", value: name)], fallbackName: q.name)
    }

    /// One request, filtered to `leisure=golf_course`.
    ///
    /// Filtered rather than trusting the query: a search for a course name also
    /// matches the road, the neighbourhood and the bus stop named after it — and at
    /// Coyote Creek, the *river* the course is named for, eighteen times. A bus stop's
    /// bounding box is a point, which fetches nothing and looks exactly like a course
    /// that is not mapped.
    private static func search(_ items: [URLQueryItem],
                               fallbackName: String) async throws -> [CourseOSM.Site] {
        var c = URLComponents(string: endpoint)!
        c.queryItems = items + [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "20"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(CourseOSM.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CourseOSM.Failure.http(http.statusCode, "nominatim")
        }
        return try JSONDecoder().decode([Result].self, from: data).compactMap { r in
            guard r.category == "leisure", r.type == "golf_course",
                  let b = r.boundingbox, b.count == 4,
                  let s = Double(b[0]), let n = Double(b[1]),
                  let w = Double(b[2]), let e = Double(b[3])
            else { return nil }
            // Widened by roughly 200 m, the same as the Overpass path: a course
            // polygon's own bounds clip the tees and bunkers that sit just outside it.
            return CourseOSM.Site(name: r.name ?? r.display_name ?? fallbackName,
                                  bbox: (s: s - 0.002, w: w - 0.0025,
                                         n: n + 0.002, e: e + 0.0025))
        }
    }
}
