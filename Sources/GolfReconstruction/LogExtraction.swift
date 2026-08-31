import Foundation
import GolfSessionFormat

/// Turning a hole's worth of logs into proposed events — the half that can be
/// tested without a model.
///
/// The model call itself lives in the app, because `FoundationModels` needs
/// iOS 26 and this package's floor is iOS 16 (CLAUDE.md: one platform floor, in
/// `Package.swift`). What is here is everything that can be wrong *deterministically*:
/// which rows go into the prompt, how they are written down, and how a proposal
/// becomes an `Event`. Same split as `Event.typed` — the logic in the package where
/// it has a test, the wrapper where it needs a device.
///
/// **The firewall, in one sentence:** the only thing this reads is `log.jsonl`, and
/// every row of that file is an observation. `Mark`, `Scorecard`, `Correction` and
/// `Event.provenance == .user` are not reachable from here and must never become
/// so — see `Event` and CLAUDE.md.
public enum LogExtraction {

    /// One thing the model claims happened. **Deliberately not an `Event`**: an
    /// `Event` carries provenance, and a value decoded straight from a model
    /// response must not be able to arrive claiming `.user`. Conversion is
    /// `events(from:)` below, which stamps `.model` and nothing else.
    public struct Proposal: Codable, Sendable, Equatable {
        public var kind: String
        public var player: String?
        public var club: String?
        public var strokes: Int?
        public var lie: String?
        public var text: String?
        public var confidence: Double?
        /// `LogEntry.id` values this rests on.
        public var logs: [String]

        public init(kind: String, player: String? = nil, club: String? = nil,
                    strokes: Int? = nil, lie: String? = nil, text: String? = nil,
                    confidence: Double? = nil, logs: [String] = []) {
            self.kind = kind; self.player = player; self.club = club
            self.strokes = strokes; self.lie = lie; self.text = text
            self.confidence = confidence; self.logs = logs
        }
    }

    // MARK: - Prompt

    /// What the model is told about the job, once per session.
    ///
    /// The two rules in here are the product's, not the model's: **propose rather
    /// than omit** (PLAN §3 — a wrong shot costs one tap to delete, a missing one
    /// is invisible), and **match names fuzzily**. The second is not a nicety:
    /// diarization was cut, so a spoken name is the *only* attribution signal, and
    /// Siri mangles names with no `contextualStrings` knob to reach for. An exact
    /// match against the roster loses the shot outright.
    ///
    /// - Parameter glossary: what a golfer means by a word the dictionary defines
    ///   differently, keyed by what is *said*. **Injected rather than imported**:
    ///   the list lives in `GolfVocabulary`, which is in `GolfTranscription`, and
    ///   importing that here would drag WhisperKit into the one target whose whole
    ///   point is being model- and framework-agnostic. A caller holding both wires
    ///   them together; a caller that does not loses only the slang.
    ///
    ///   It carries most of its weight in Korean, where the collisions are **not
    ///   misrecognitions**: Whisper transcribes 고구마 perfectly and it means
    ///   *sweet potato* to anyone not standing beside a golf bag. Given as
    ///   context, never as a substitution — several entries are single syllables
    ///   that occur constantly in ordinary speech, so a mechanical rewrite would
    ///   corrupt sentences that had nothing to do with golf.
    public static func instructions(players: [Player],
                                    glossary: [String: String] = [:]) -> String {
        let roster = players.map { "- \($0.name) (id: \($0.id))" }.joined(separator: "\n")

        // Sorted, so the same roster produces the same prompt twice. A prompt that
        // reorders itself defeats caching and makes two runs incomparable.
        let terms = glossary.keys.sorted()
            .map { "- \($0) = \(glossary[$0]!)" }
            .joined(separator: "\n")
        let slang = terms.isEmpty ? "" : """


            On a course these mean something a dictionary does not say. Read them \
            this way when the surrounding sentence is about golf, and ignore the \
            entry when it plainly is not — some of them are ordinary syllables:
            \(terms)
            """

        return """
        You read a golfer's spoken notes from one hole and list what happened.

        The players:
        \(roster.isEmpty ? "- (nobody named; leave player empty)" : roster)

        Rules:
        - Match a spoken name against the list above PHONETICALLY, not exactly. The \
        notes were dictated and names come back misheard — "Chungman" is "Chungmin", \
        "Dave three" may be "Dave", "스티브" is Steve. Return the player's id.
        - Propose an event you are unsure of rather than leaving it out, and say so \
        in the confidence. A wrong one costs the golfer a tap; a missing one is \
        invisible.
        - kind is one of: shot, score, penalty, holeChange, note.
        - A note is for anything that makes no claim about strokes — keep it, do not \
        invent structure for it.
        - confidence is 0 to 1.
        - logs must list the id of every note the event rests on, so the golfer can \
        see why you proposed it.
        - Do not invent a score that was not said. If nobody announced one, there is \
        no score event.\(slang)
        """
    }

    /// The logs for one hole, written for the model.
    ///
    /// Times are **relative to the start of the hole** rather than epoch millis:
    /// the model does not need a wall clock, order and spacing are what carry
    /// meaning, and 13-digit numbers are pure token cost against a ~4,096-token
    /// window.
    public static func prompt(logs: [LogEntry], hole: Int?, par: Int? = nil) -> String {
        let ordered = logs.sorted { $0.t < $1.t }
        let base = ordered.first?.t ?? 0
        let lines = ordered.map { log in
            let secs = Int((log.t - base) / 1000)
            return "[\(log.id) @\(secs)s] \(log.text)"
        }.joined(separator: "\n")

        var header = "Hole \(hole.map(String.init) ?? "unknown")"
        if let par { header += ", par \(par)" }
        return """
        \(header)

        \(lines)
        """
    }

    // MARK: - Proposals -> Events

    /// Stamp proposals as `.model` events on the session clock.
    ///
    /// **Provenance is not a parameter.** Everything that comes out of here is a
    /// proposal, by construction — there is no argument to pass `.user` to, which
    /// is the same reason `Event.typed` has none in the other direction.
    ///
    /// An event is timed from the **first log it cites**, not from "now": the
    /// golfer said it when they said it, and stamping the extraction run would put
    /// every shot on a hole at the same instant, in the order the model happened
    /// to list them.
    public static func events(from proposals: [Proposal],
                              logs: [LogEntry],
                              hole: Int?,
                              fallbackTime: Millis = SessionClock.now(),
                              id: () -> String = { UUID().uuidString.prefix(8).lowercased() }
                              ) -> [Event] {
        let byID = Dictionary(logs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return proposals.map { p in
            let cited = p.logs.compactMap { byID[$0] }.sorted { $0.t < $1.t }
            let anchor = cited.first
            // A coordinate only when the citation has one. Falling back to another
            // log's position would place a shot where a different sentence was
            // spoken — `LogEntry.hasPosition` exists so nil stays a real answer.
            return Event(id: id(),
                         t: anchor?.t ?? fallbackTime,
                         kind: kind(p.kind),
                         provenance: .model,
                         player: p.player,
                         hole: hole ?? anchor?.hole,
                         club: p.club,
                         strokes: p.strokes,
                         lie: p.lie,
                         lat: anchor?.lat, lon: anchor?.lon,
                         text: p.text,
                         confidence: p.confidence.map { min(max($0, 0), 1) },
                         logs: cited.isEmpty ? nil : cited.map(\.id))
        }
    }

    /// Unknown kinds become `.note` rather than being dropped.
    ///
    /// A model that answers "putt" or "approach" has still observed something
    /// real, and the sentence is in `text`. Dropping the row would lose the log's
    /// only trace on the events list, which is exactly the "invisible missing
    /// shot" the propose-don't-omit rule exists to avoid.
    static func kind(_ raw: String) -> Event.Kind {
        Event.Kind(rawValue: raw.trimmingCharacters(in: .whitespaces)) ?? .note
    }

    // MARK: - Grouping

    /// Logs grouped by the hole they were filed on, in playing order, with
    /// unattributed logs under `nil`.
    ///
    /// Extraction runs **per hole**, one `LanguageModelSession` each: the
    /// on-device model's context is ~4,096 tokens including its own output, so a
    /// whole round does not fit — and a fresh session per hole also means one bad
    /// hole cannot poison the next.
    public static func byHole(_ logs: [LogEntry]) -> [(hole: Int?, logs: [LogEntry])] {
        var buckets: [Int?: [LogEntry]] = [:]
        for log in logs { buckets[log.hole, default: []].append(log) }
        return buckets
            .map { (hole: $0.key, logs: $0.value.sorted { $0.t < $1.t }) }
            .sorted { a, b in
                switch (a.hole, b.hole) {
                case let (x?, y?): return x < y
                case (nil, _): return false      // unattributed last
                case (_, nil): return true
                }
            }
    }
}
