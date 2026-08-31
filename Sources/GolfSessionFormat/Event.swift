import Foundation

/// One thing that happened in a round: a shot, a score, a penalty, a note.
///
/// **Mixed provenance, and that is the whole point of this type.** An event is
/// either something the model proposed from the transcript or something a human
/// typed, and those two are not interchangeable:
///
/// - `.model` — a proposal. It is a draft the user amends (PLAN §3), it carries a
///   confidence and the evidence behind it, and it **may be fed back to the model**
///   as context on a later call.
/// - `.user` — typed or corrected by a person. That is **GROUND TRUTH**, in exactly
///   the sense `Mark` and `Correction` are, and it must never enter an evidence
///   bundle or a prompt.
///
/// The trap this exists to close: incremental extraction naturally feeds the events
/// so far back as context for the next window. Do that without filtering and the
/// answer key is in the model input — silently, because `GolfReconstruction`
/// depends on this module and nothing in the compiler will stop it. Any bundle
/// builder touching `events.jsonl` **must** filter with ``Event/modelVisible(_:)``.
public struct Event: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A ball was struck.
        case shot
        /// A hole score, announced or entered.
        case score
        case penalty
        /// The group moved to a different hole.
        case holeChange
        /// Free text worth keeping that makes no structured claim.
        case note
        /// Where the flag was cut, on the hole in `hole`, at `lat`/`lon`.
        ///
        /// *(User, 2026-08-28: "pin location should be draggable, this one doesn't
        /// get saved into db. but will be saved as event, so that replay should be
        /// able to use it, and copy of events should include this info.")*
        ///
        /// **An event and not the course file, deliberately.** A pin is cut fresh
        /// every morning: it is a fact about *this round*, where the course file is
        /// a fact about the course, and writing it there would make every later
        /// round inherit one afternoon's flag position. Replay reads it here with
        /// everything else that happened, and anything that copies or exports the
        /// round's events carries it along for free.
        ///
        /// `.user` provenance like anything a person asserts, which also keeps it
        /// out of prompts. That costs nothing today — extraction has never been
        /// given the pin — and if a pin ever *should* reach the model it will be
        /// through the same door course geometry uses, an export, rather than by
        /// weakening the firewall.
        case pin
    }

    /// Where this event came from. See the type documentation — this is a firewall,
    /// not a label.
    public enum Provenance: String, Codable, Sendable {
        /// Proposed by extraction. May be fed back to the model as context.
        case model
        /// Typed or corrected by a human. GROUND TRUTH — never in a prompt.
        case user
    }

    public var id: String
    /// When it happened, on the session clock — not when it was recorded.
    public var t: Millis
    public var kind: Kind
    public var provenance: Provenance

    public var player: String?
    public var hole: Int?
    public var club: String?
    public var strokes: Int?
    public var lie: String?
    public var lat: Double?, lon: Double?

    /// What was said, or what the user typed.
    public var text: String?
    /// Model confidence, 0...1. Always nil for `.user` — a person who typed it is
    /// not expressing a probability, and a confidence on a fact invites code that
    /// treats the two the same.
    public var confidence: Double?
    /// `Utterance.t0` of each transcript line this rests on, so the user can see
    /// *why* the model proposed it.
    public var evidence: [Millis]
    /// `LogEntry.id` of each log this rests on — the same idea as `evidence`, for
    /// the stream that replaced the transcript as the app's primary input.
    ///
    /// A separate field rather than a widened `evidence`, because the two are
    /// addressed differently: a transcript line is found by its start time, a log
    /// by its id. Optional so that an `events.jsonl` written before logs existed
    /// still decodes — it is not a meaningful nil, just an older file.
    public var logs: [String]?
    /// The event id this replaces. A correction supersedes rather than rewrites —
    /// the sequence is the labeled error set, the same reasoning as `Correction`.
    public var supersedes: String?

    public init(id: String, t: Millis, kind: Kind, provenance: Provenance,
                player: String? = nil, hole: Int? = nil, club: String? = nil,
                strokes: Int? = nil, lie: String? = nil,
                lat: Double? = nil, lon: Double? = nil,
                text: String? = nil, confidence: Double? = nil,
                evidence: [Millis] = [], logs: [String]? = nil,
                supersedes: String? = nil) {
        self.id = id; self.t = t; self.kind = kind; self.provenance = provenance
        self.player = player; self.hole = hole; self.club = club
        self.strokes = strokes; self.lie = lie
        self.lat = lat; self.lon = lon
        self.text = text
        self.confidence = provenance == .user ? nil : confidence
        self.evidence = evidence; self.logs = logs; self.supersedes = supersedes
    }

    /// An event a person added **by hand, after extraction ran** — a correction in
    /// the shape of an addition, and therefore ground truth.
    ///
    /// **This is no longer what the input box produces** *(2026-08-27)*. Free text
    /// typed during a round is an *observation* and goes to `log.jsonl` as a
    /// `LogEntry`, the same stream Siri writes to, because extraction has to be
    /// able to read it. Routing the box through here would put the app's entire
    /// input behind the firewall and leave the model with nothing.
    ///
    /// Lives here rather than in the view so it can be *tested* — the SwiftUI
    /// wrapper needs a finger, and this is the half where a mistake would be
    /// silent. Provenance is not a parameter on purpose: **what a person asserts
    /// against a proposal is ground truth**, and an argument is an invitation to
    /// pass `.model`.
    ///
    /// It stays a `.note` carrying the raw text. Turning "steve made a 5 on 7"
    /// into a structured `.score` is a model call and it lands with the extraction
    /// pass; a regex here would be a second, worse parser for the real one to
    /// disagree with.
    public static func typed(_ text: String, hole: Int? = nil,
                             at t: Millis = SessionClock.now(),
                             id: String = UUID().uuidString.prefix(8).lowercased()
                             ) -> Event? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Event(id: id, t: t, kind: .note, provenance: .user,
                     hole: hole, text: trimmed)
    }

    /// The row a user writes when deleting a proposal: an amendment that
    /// **supersedes** rather than a line removed, because the sequence is the
    /// labelled error set.
    public static func deletion(of event: Event, at t: Millis = SessionClock.now(),
                                id: String = UUID().uuidString.prefix(8).lowercased()
                                ) -> Event {
        Event(id: id, t: event.t, kind: event.kind, provenance: .user,
              player: event.player, hole: event.hole, text: event.text,
              supersedes: event.id)
    }

    /// True for anything a person authored. Ground truth; see the type docs.
    public var isGroundTruth: Bool { provenance == .user }

    /// The only events that may be shown to the model. **Every bundle builder that
    /// reads `events.jsonl` goes through here** — the filter is one line, and
    /// leaving it out is invisible until an accuracy number is quietly wrong.
    public static func modelVisible(_ events: [Event]) -> [Event] {
        events.filter { $0.provenance == .model }
    }

    /// Latest-wins collapse for display: an event that has been superseded is
    /// hidden by whatever replaced it. The superseded rows stay on disk — the
    /// *sequence* is what `GolfEval` consumes.
    public static func current(_ events: [Event]) -> [Event] {
        let replaced = Set(events.compactMap(\.supersedes))
        return events.filter { !replaced.contains($0.id) }.sorted { $0.t < $1.t }
    }
}
