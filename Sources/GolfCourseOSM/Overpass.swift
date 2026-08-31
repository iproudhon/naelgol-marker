import Foundation
import GolfCourse

/// Talking to Overpass. The assembly lives in `GolfCourse.OSMCourse`, which has no
/// network in it and is therefore testable; this target is only the query and the
/// socket — the same split as `CourseImport` versus `CourseCard`.
///
/// **Its own target as of 2026-08-30, because the app needs it too** *(user: "For
/// course OSM gps data, I want to search and download from the app")*. It used to
/// live in `Sources/golfctl`, which is an executable and therefore cannot be
/// imported by anything. The alternative was to put `URLSession` into `GolfCourse`
/// and give up the sentence above — the one property that keeps the assembly
/// testable with no network at all.
public enum CourseOSM {

    /// Public Overpass instances are a shared free resource with a rate limit, and
    /// a course import is a handful of queries a year. Be polite and identify
    /// ourselves rather than looking like a scraper.
    public static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    public static let userAgent = "naelgol-marker/0.1 (golf course geometry import)"

    public enum Where {
        case bbox(s: Double, w: Double, n: Double, e: Double)
        case around(lat: Double, lon: Double, radius: Double)
        case name(String)
    }

    public struct Site: Identifiable, Sendable {
        public var name: String
        public var bbox: (s: Double, w: Double, n: Double, e: Double)
        /// Stable enough for a list: two facilities never share a name *and* a
        /// bounding box.
        public var id: String { "\(name)|\(bbox.s),\(bbox.w)" }
    }

    // MARK: - Queries

    /// Every `golf=*` feature in a box. `out geom;` returns the full node list
    /// inline, which is what makes green outlines and hazard polygons possible in
    /// one round trip — `out center` would give only a point and throw the outline
    /// `Hole.distances(from:)` measures against.
    public static func featuresQuery(_ b: (s: Double, w: Double, n: Double, e: Double)) -> String {
        """
        [out:json][timeout:180];
        (
          way["golf"](\(b.s),\(b.w),\(b.n),\(b.e));
          relation["golf"](\(b.s),\(b.w),\(b.n),\(b.e));
        );
        out geom;
        """
    }

    public static func featuresQuery(lat: Double, lon: Double, radius: Double) -> String {
        """
        [out:json][timeout:180];
        (
          way["golf"](around:\(radius),\(lat),\(lon));
          relation["golf"](around:\(radius),\(lat),\(lon));
        );
        out geom;
        """
    }

    /// Find the facility by name, so `--name "Corica Park"` works without anyone
    /// looking up coordinates. Two steps rather than one because the golf features
    /// themselves are unnamed — only the enclosing `leisure=golf_course` polygon
    /// carries the facility name, and its bounds are what the second query needs.
    public static func siteQuery(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        [out:json][timeout:120];
        (
          way["leisure"="golf_course"]["name"~"\(escaped)",i];
          relation["leisure"="golf_course"]["name"~"\(escaped)",i];
        );
        out tags bb;
        """
    }

    // MARK: - Transport

    /// How many times a request is sent before the failure is reported.
    ///
    /// **Overpass's public instance fails transiently, and often** *(measured
    /// 2026-08-30 while chasing "search is failing")*: four of seven identical
    /// requests for one 1.4 km box came back **504**, and the body says why —
    /// `Dispatcher_Client::request_read_and_idx::timeout. The server is probably too
    /// busy to handle your request.` That is a load condition on a free shared
    /// service, not a query that is too big, and a plain retry a second later
    /// succeeded every time. So retry, and do not tell the golfer to narrow an area
    /// that was never the problem.
    static let attempts = 3

    /// Grows, because a busy dispatcher is busy for a moment rather than an instant.
    static func backoff(afterAttempt n: Int) -> Duration { .seconds(n * 2) }

    public static func run(_ query: String) async throws -> Data {
        var last: Error = Failure.overpassBusy
        for attempt in 1...attempts {
            do { return try await send(query) }
            catch let e as Failure {
                last = e
                guard e.isTransient, attempt < attempts else { throw e }
                try? await Task.sleep(for: backoff(afterAttempt: attempt))
            }
        }
        throw last
    }

    private static func send(_ query: String) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        req.timeoutInterval = 200

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            // 429 and 504 are Overpass's rate limiter and its own timeout, and they
            // are the two a golfer will actually hit. Say which rather than dumping
            // a wall of HTML.
            switch http.statusCode {
            case 429: throw Failure.rateLimited
            case 504: throw classify(text)
            default: throw Failure.http(http.statusCode, String(text.prefix(400)))
            }
        }
        return data
    }

    /// A 504 is two different faults wearing one status code, and the advice for them
    /// is opposite. The body distinguishes them, so read it: a *dispatcher* timeout
    /// means the server is loaded and the answer is to wait, while a *query* timeout
    /// means the area really is too big and the answer is `--radius` or `--bbox`.
    /// Advising a narrower area for a busy server sends the golfer to shrink a box
    /// that was already 1.4 km across.
    static func classify(_ body: String) -> Failure {
        let b = body.lowercased()
        if b.contains("dispatcher_client") || b.contains("too busy") { return .overpassBusy }
        return .overpassTimeout
    }

    public struct SiteResponse: Decodable {
        struct Bounds: Decodable {
            let minlat: Double, minlon: Double, maxlat: Double, maxlon: Double
        }
        struct El: Decodable {
            let tags: [String: String]?
            let bounds: Bounds?
        }
        let elements: [El]
    }

    /// **Nominatim first, Overpass second** *(2026-08-30, after the user asked
    /// whether the search being slow was expected)*. Measured: the Overpass name
    /// query is a regex over every golf course on the planet and took 12.5 s before
    /// returning **504**, its own timeout; Nominatim answered the same question in
    /// 0.72 s with the bounding box the feature query needs. See `Nominatim`.
    ///
    /// The old query stays as the fallback rather than being deleted: it asks OSM
    /// directly, so a course the geocoder has not indexed — or has indexed under a
    /// different name — is still findable. A geocoder failure must not become "this
    /// course is not in OpenStreetMap", which is the message that sends somebody off
    /// to trace a hole by hand.
    ///
    /// **"Found nothing" and "could not be asked" are different answers, and
    /// collapsing them named the wrong service** *(2026-08-30)*. This was
    /// `try? await Nominatim.sites(…)`, so any geocoder failure — no signal, a TLS
    /// interception, a rate limit — fell straight through to the planet-wide Overpass
    /// regex, which then timed out and reported *"Overpass timed out. Narrow the
    /// area."* for a fault in a different service that has no area to narrow.
    public static func sites(named name: String) async throws -> [Site] {
        var geocoder: Error?
        do {
            let quick = try await Nominatim.sites(named: name)
            if !quick.isEmpty { return quick }
        } catch { geocoder = error }

        do { return try await sitesViaOverpass(named: name) }
        catch {
            if let geocoder { throw Failure.geocoder(geocoder.localizedDescription) }
            throw error
        }
    }

    static func sitesViaOverpass(named name: String) async throws -> [Site] {
        let data = try await run(siteQuery(name))
        let decoded = try JSONDecoder().decode(SiteResponse.self, from: data)
        return decoded.elements.compactMap { el in
            guard let b = el.bounds else { return nil }
            return Site(name: el.tags?["name"] ?? name,
                        // A course polygon's own bounds clip the tees and bunkers
                        // that sit just outside it, so widen by roughly 200 m.
                        bbox: (s: b.minlat - 0.002, w: b.minlon - 0.0025,
                               n: b.maxlat + 0.002, e: b.maxlon + 0.0025))
        }
    }

    public static func features(_ target: Where) async throws -> (Data, String?) {
        switch target {
        case .bbox(let s, let w, let n, let e):
            return (try await run(featuresQuery((s, w, n, e))), nil)
        case .around(let lat, let lon, let r):
            return (try await run(featuresQuery(lat: lat, lon: lon, radius: r)), nil)
        case .name(let n):
            let found = try await sites(named: n)
            guard let site = found.first else { throw Failure.noSite(n) }
            // **No `print` here any more.** This is a library now; the CLI reports
            // the other matches itself, and a UI lists them for the golfer to pick
            // from rather than silently taking the first.
            return (try await run(featuresQuery(site.bbox)), site.name)
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case rateLimited
        case overpassBusy
        case overpassTimeout
        case http(Int, String)
        case noSite(String)
        /// The geocoder could not be reached, and the Overpass fallback failed too.
        /// Carries the message rather than the error so `Failure` stays `Equatable`;
        /// nothing downstream inspects the underlying error, it prints it.
        case geocoder(String)

        /// Worth sending again. The dispatcher being busy is a moment in the life of
        /// a free shared server; a query timeout and an HTTP error are not.
        public var isTransient: Bool {
            switch self {
            case .overpassBusy, .rateLimited: return true
            default: return false
            }
        }

        public var description: String {
            switch self {
            case .overpassBusy:
                return "Overpass is too busy right now — it is a free shared service. "
                     + "Tried \(CourseOSM.attempts) times. Wait a moment and search again."
            case .rateLimited:
                return "Overpass is rate-limiting this IP. It is a free shared service — "
                     + "wait a minute and re-run."
            case .overpassTimeout:
                return "Overpass timed out. Narrow the area (--radius or --bbox)."
            case .http(let code, let body):
                return "Overpass returned HTTP \(code): \(body)"
            case .geocoder(let why):
                return "could not reach the place-name search (\(why)), "
                     + "and the OpenStreetMap fallback failed too. Check the connection."
            case .noSite(let n):
                return "no leisure=golf_course named like '\(n)' in OSM. Try --at lat,lon "
                     + "--radius 2000, or a shorter name."
            }
        }
    }
}
