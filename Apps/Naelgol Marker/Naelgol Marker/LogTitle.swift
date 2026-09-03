import Foundation
import GolfSessionFormat
import GolfMap

/// What an entry is called on screen: `steve · Hole 4 · 4th: on in two`.
///
/// *(User, 2026-09-03: "Title for marker in marker editor and marker list —
/// `<player name>·<hole #>·<shot #>: <text>`".)*
///
/// **One composer, because the editor and the list must not disagree.** The editor
/// builds it from the fields as they currently stand — the title has to follow a
/// player being picked — and the list builds it from a row on disk; a second
/// implementation is two titles for one entry the first time somebody changes one.
///
/// **Every part is optional and an absent one takes its separator with it.** An
/// Action Button mark is a row with no player, no number and no text, so it reads
/// `Hole 4`, or `Entry` when even the hole is unknown. Stray middle dots around an
/// empty middle would say a field is missing without saying which.
enum LogTitle {

    /// The fields alone, middle-dot separated. Nil when the entry is about nothing
    /// yet, so a caller can fall back to the text.
    static func fields(player: String?, holeRef: String?, shot: Int?) -> String? {
        var parts: [String] = []
        if let player, !player.isEmpty { parts.append(player) }
        if let holeRef, !holeRef.isEmpty { parts.append("Hole \(holeRef)") }
        if let shot { parts.append(ordinal(shot)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The fields, then the sentence after a colon.
    ///
    /// The text is **whatever the golfer said or typed and nothing else** *(user,
    /// 2026-09-03: "no fillers like 'mark' or '14:1'")*. It used to carry a
    /// `"<hole>: <shot>"` prefix restating the fields, which is why this composer
    /// can now put the fields in front of it without saying everything twice.
    static func of(player: String?, holeRef: String?, shot: Int?,
                   text: String) -> String {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = fields(player: player, holeRef: holeRef, shot: shot) else {
            return said.isEmpty ? "Entry" : said
        }
        return said.isEmpty ? head : "\(head): \(said)"
    }

    /// `Tee`, `1st`, `2nd`, `3rd` … — the **display** number, so a title matches the
    /// circle drawn on the hole rather than the number in the file. `ShotName` owns
    /// the offset that makes stored 1 the tee shot.
    static func ordinal(_ shot: Int) -> String {
        guard let n = Int(ShotName.of(shot)) else { return "Tee" }
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11), (_, 12), (_, 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
