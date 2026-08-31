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

    public init(id: String, at: Coordinate, symbol: String? = nil, label: String,
                shot: Int? = nil, player: String? = nil, colorIndex: Int? = nil) {
        self.id = id; self.at = at; self.symbol = symbol; self.label = label
        self.shot = shot; self.player = player; self.colorIndex = colorIndex
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
