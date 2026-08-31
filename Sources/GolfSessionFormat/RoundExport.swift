import Foundation

/// A round, or one row of it, as **JSON** — what the Copy buttons put on the
/// clipboard *(user, 2026-08-29: "'copy' event and 'copy whole round' should
/// construct json with all the data, including location, player name, hole #,
/// time, etc.")*.
///
/// **Why it replaced the plain text.** `LogTranscript.text` renders
/// `0:12:04  steve made par` — which is what a person reads, and is missing every
/// field the round actually turns on: where the golfer was standing, which player
/// the row is filed under, which hole, whether the hole was measured or chosen,
/// what the recogniser heard it in. A transcript pasted into a model is the whole
/// point of the button, and a model cannot recover any of that from the sentence.
///
/// **In the package, for the same reason `LogTranscript` is.** The selection is
/// the part that goes quietly wrong: the round screen's timeline *hides* a log an
/// event cites, so exporting the list on screen would drop precisely the sentences
/// extraction succeeded on and look complete doing it. This reads the rows.
///
/// **It resolves the player's display name and keeps the id.** `LogEntry.player`
/// stores a `Player.id`, which is not what anybody reading the JSON expects to see
/// — and dropping the id in favour of the name would break the join back to the
/// round, since a rename changes one and not the other.
///
/// The firewall is unchanged: this exports `log.jsonl` and `events.jsonl`, both of
/// which are model-visible by design. `Mark`, `Scorecard` and `Correction` are
/// ground truth and are deliberately not here.
public enum RoundExport {

    /// One log row, with every field it carries.
    ///
    /// Times are given three ways on purpose: `t` is the session clock and the
    /// only one anything joins on, `time` is ISO 8601 so a human can read it, and
    /// `elapsed` is what the row on screen says. A copy that disagreed with the
    /// screen would be the first thing anybody noticed.
    public static func log(_ l: LogEntry, players: [Player] = [],
                           start: Millis, holeRef: String? = nil) -> [String: Any] {
        var o: [String: Any] = [
            "id": l.id,
            "t": l.t,
            "time": iso(l.t),
            "elapsed": LogTranscript.elapsed(l.t, from: start),
            "text": l.text,
            "source": l.source.rawValue,
        ]
        if let tEnd = l.tEnd {
            o["tEnd"] = tEnd
            o["timeEnd"] = iso(tEnd)
            o["elapsedEnd"] = LogTranscript.elapsed(tEnd, from: start)
        }
        if let lat = l.lat, let lon = l.lon {
            var pos: [String: Any] = ["lat": lat, "lon": lon]
            if let a = l.hAcc { pos["accuracy"] = a }
            o["position"] = pos
        }
        if let h = l.hole {
            o["hole"] = h
            // The hole *label* is what the card prints — "황룡/3" on a Korean 27 —
            // and it is not derivable from the playing index without the course,
            // which this target deliberately does not know about. Passed in.
            if let holeRef { o["holeRef"] = holeRef }
            o["holeSource"] = (l.holeSource ?? .fix).rawValue
        }
        if let p = l.player {
            o["player"] = p
            o["playerName"] = players.first { $0.id == p }?.name ?? p
        }
        if let s = l.shot { o["shot"] = s }
        if let loc = l.locale { o["locale"] = loc }
        if let s = l.supersedes { o["supersedes"] = s }
        return o
    }

    /// One event row. `logs` and `evidence` are kept because they are what makes a
    /// proposal checkable — an event with its citations stripped is an assertion.
    public static func event(_ e: Event, players: [Player] = [],
                             start: Millis, holeRef: String? = nil) -> [String: Any] {
        var o: [String: Any] = [
            "id": e.id,
            "t": e.t,
            "time": iso(e.t),
            "elapsed": LogTranscript.elapsed(e.t, from: start),
            "kind": e.kind.rawValue,
            "provenance": e.provenance.rawValue,
        ]
        if let p = e.player {
            o["player"] = p
            o["playerName"] = players.first { $0.id == p }?.name ?? p
        }
        if let h = e.hole {
            o["hole"] = h
            if let holeRef { o["holeRef"] = holeRef }
        }
        if let c = e.club { o["club"] = c }
        if let s = e.strokes { o["strokes"] = s }
        if let l = e.lie { o["lie"] = l }
        if let lat = e.lat, let lon = e.lon { o["position"] = ["lat": lat, "lon": lon] }
        if let t = e.text { o["text"] = t }
        if let c = e.confidence { o["confidence"] = c }
        if !e.evidence.isEmpty { o["evidence"] = e.evidence }
        if let l = e.logs, !l.isEmpty { o["logs"] = l }
        if let s = e.supersedes { o["supersedes"] = s }
        return o
    }

    /// The whole round, or one hole of it.
    ///
    /// - Parameters:
    ///   - hole: the playing index the copy is filtered to, or nil for the round.
    ///     Filtering follows the screen's rule: **a row with no hole belongs to
    ///     every hole**, because nil means the fix failed rather than that the row
    ///     is about nothing.
    ///   - holeRefs: playing index → the label the card prints, supplied by the
    ///     app because this target has no course.
    public static func round(logs: [LogEntry], events: [Event] = [],
                             players: [Player] = [], course: String? = nil,
                             start: Millis, end: Millis? = nil,
                             hole: Int? = nil, holeRefs: [Int: String] = [:]) -> [String: Any] {
        let ls = LogTranscript.onHole(logs, hole: hole)
        let es = events.filter { hole == nil || $0.hole == hole || $0.hole == nil }
        var o: [String: Any] = [
            "start": start,
            "startTime": iso(start),
            "players": players.map { ["id": $0.id, "name": $0.name, "aliases": $0.aliases] },
            "logs": ls.sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
                .map { log($0, players: players, start: start,
                           holeRef: $0.hole.flatMap { holeRefs[$0] }) },
            "events": es.sorted { $0.t == $1.t ? $0.id < $1.id : $0.t < $1.t }
                .map { event($0, players: players, start: start,
                             holeRef: $0.hole.flatMap { holeRefs[$0] }) },
        ]
        if let course { o["course"] = course }
        if let end {
            o["end"] = end
            o["endTime"] = iso(end)
        }
        if let hole {
            o["hole"] = hole
            if let ref = holeRefs[hole] { o["holeRef"] = ref }
        }
        return o
    }

    /// Pretty-printed, **sorted keys**: a clipboard is diffed and eyeballed, and a
    /// dictionary's iteration order is not stable between runs. `withoutEscapingSlashes`
    /// so a course name with a slash in it stays readable.
    public static func string(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func iso(_ t: Millis) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
    }
}
