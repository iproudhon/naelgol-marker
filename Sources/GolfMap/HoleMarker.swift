#if canImport(SwiftUI)
import Foundation
import SwiftUI
import GolfCourse

/// One recorded entry, drawn where it was said.
///
/// *(X7, user 2026-08-28: "show markers in gps hole view with icon and abbreviated
/// string".)*
///
/// **A view type, not a `LogEntry`.** `GolfMap` must not know what a log is — that
/// lives in `GolfSessionFormat` and drags the whole session format into the target
/// that draws a hole. The app flattens a log into this: a position, a symbol, and
/// as much text as fits.
public struct HoleMarker: Identifiable, Sendable, Hashable {
    /// The log's own id, so a drag can be routed back to the row it came from.
    public let id: String
    public var at: Coordinate

    /// SF Symbol, or **nil for most entries** *(X13, user 2026-08-28: "no need to
    /// show keyboard or record icon")*.
    ///
    /// It used to say how the entry was captured — a waveform or a keyboard — which
    /// is a fact about the *app*, not about the round, repeated on every pill on the
    /// hole. What earns an icon is being a **shot**: a golfer scanning the hole is
    /// looking for where somebody played from, and the entries that answer that are
    /// the ones with a player and a number on them.
    public var symbol: String?
    /// Already abbreviated by the caller. See `abbreviate`.
    public var label: String
    /// Which shot of the player's hole this is, when it is a shot at all.
    public var shot: Int?
    /// The player's **display name**, resolved by the app — `HoleMarker` is a view
    /// type and a roster id would render as an id.
    public var player: String?
    /// Which player's colour to draw it in, so a pill and the line through it agree.
    /// Nil for an entry that belongs to nobody in particular.
    public var colorIndex: Int?

    /// A marker nobody has claimed yet — the Action Button's.
    ///
    /// **It is a shot marker with nothing assigned to it** *(user, 2026-09-03: "I
    /// want these markers to work the same way as when I clicked player marker
    /// button, just player, shot # unassigned")*. Same slot, same handle, same tap,
    /// same drag — the flag changes only what is *drawn* inside the circle, which
    /// is nothing. A pill would read the same word on every one of them, and the
    /// empty ring is the only thing on the layer that says *this has no player and
    /// no number yet*.
    ///
    /// It stops being true the moment somebody assigns a player and a shot, at
    /// which point the marker becomes an ordinary numbered circle. That transition
    /// is the whole reason for filing one, so nothing here may make a mark harder
    /// to pick up than the shot it is about to become.
    public var isMark: Bool = false

    public init(id: String, at: Coordinate, symbol: String? = nil, label: String,
                shot: Int? = nil, player: String? = nil, colorIndex: Int? = nil,
                isMark: Bool = false) {
        self.id = id; self.at = at; self.symbol = symbol; self.label = label
        self.shot = shot; self.player = player; self.colorIndex = colorIndex
        self.isMark = isMark
    }

    /// What the pill reads: `1 · steve` for a shot, the abbreviated sentence
    /// otherwise. The number leads because it is what orders the hole.
    ///
    /// **The shot is named, not numbered** *(user, 2026-08-29: "marker shows shot #
    /// it's sitting on — tee off: T, #1: 1, #2: 2")*. A marker sits on the lie a
    /// shot was played from, and the first of those is the tee — so it reads `T`
    /// and the one after it reads `1`. `ShotName` owns the offset; the stored
    /// number is untouched.
    public var title: String {
        guard let shot else { return label }
        return ShotName.of(shot)
    }

    /// A shot is drawn as a **numbered circle**, not as a pill.
    ///
    /// *(User, 2026-08-30: "no club icon or name. Just show shot # in circle.
    /// Color is good enough to distinguish.")* The pill used to read
    /// `[golfer] 1 · steve`, which is three claims about one dot — and two of them
    /// are already made by the colour it is drawn in and by the legend that names
    /// the colours. On a hole with a foursome's worth of shots on it, the names
    /// were most of the ink.
    public var isShot: Bool { shot != nil }

    public var tint: Color? { colorIndex.map(HoleStyle.playerColor) }

    /// The line joining a run of marks, resolved against what is actually drawn.
    ///
    /// *(User, 2026-09-03: "draw lines between unassigned marks using thin line,
    /// ordered by entered time".)*
    ///
    /// **The order is the caller's and the ids are the caller's.** `GolfMap` has no
    /// clock — a `HoleMarker` carries no timestamp, and inventing one here would mean
    /// either a new field nothing else reads or ordering by position, which is a
    /// different claim entirely. Which marks belong to the hole on screen is the
    /// app's question too, since a `HoleMarker` has no hole on it either.
    ///
    /// Ids that are not on screen are skipped rather than treated as a break, so a
    /// mark hidden by any future filter closes the line up instead of splitting it
    /// into two lines that look like two runs.
    ///
    /// `moving` is the marker being dragged right now: its leg follows the finger,
    /// the same way a shot's track does. **Keyed by id**, which a mark has and a
    /// `PlayerTrack.Shot` does not — see `drawnTracks`, which has to match on the
    /// coordinate for want of one.
    public static func line(_ ids: [String], in markers: [HoleMarker],
                            moving: (id: String, at: Coordinate)? = nil) -> [Coordinate] {
        guard ids.count >= 2 else { return [] }
        let byID = Dictionary(markers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let points = ids.compactMap { id -> Coordinate? in
            guard let m = byID[id] else { return nil }
            return moving?.id == id ? moving?.at : m.at
        }
        return points.count >= 2 ? points : []
    }

    /// The first few words, on one line.
    ///
    /// **Words, not characters.** A hard character cut lands mid-word and reads as
    /// corrupted text rather than as an abbreviation; cutting at a word boundary
    /// reads as a beginning. A hole with a dozen entries on it is a busy screen, and
    /// the label is there to let a golfer recognise which entry it is, not to be
    /// read.
    public static func abbreviate(_ text: String, limit: Int = 22) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        var out = ""
        for word in clean.split(separator: " ") {
            if out.count + word.count + 1 > limit { break }
            out += out.isEmpty ? String(word) : " " + word
        }
        return (out.isEmpty ? String(clean.prefix(limit)) : out) + "…"
    }
}
#endif
