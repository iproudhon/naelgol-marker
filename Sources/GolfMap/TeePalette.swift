#if canImport(SwiftUI)
import SwiftUI
import GolfCourse

/// What colour to draw each tee.
///
/// **Resolved in length order, longest first, not by name alone.** A tee's colour
/// is a statement about how far back it plays, so the ordering is the input and the
/// name is only a shortcut when it happens to be a colour. That is why this is a
/// function over the *whole set* of tees and not a `name -> Color` lookup: a tee
/// called `Members` has no colour of its own, but it has an unambiguous place in
/// the order, and that place is what tells the golfer what it is.
///
/// The rule, decided 2026-08-26 (TODO item 5):
///
/// 1. A name that *is* a colour resolves to that colour. `yellow` ≡ `gold`.
/// 2. If **no** name is a colour, assign `standard` spread evenly across however
///    many tees there are.
/// 3. If **some** are colours, a non-colour tee blends its resolved neighbours in
///    the ordering — so `Members` between `blue` and `white` renders blue-white:
///    distinct from both, never colliding with a colour already in use, and it
///    reads as "between those two in length", which is all it has to say.
public enum TeePalette {

    /// The standard American ramp, **longest to shortest**.
    ///
    /// Red last because red is the forward tee on virtually every American card and
    /// gold is the senior tee between white and red. Degrades cleanly: five tees
    /// give the common black/blue/white/gold/red, four give black/blue/white/red.
    /// **The names come from `TeeBox.standardRamp`**, which is also what the OSM
    /// importer assigns to an untagged tee from its place in the length order. Two
    /// lists would drift, and the drift would be a course whose "blue" tee is
    /// painted green.
    public static let standard: [(name: String, color: Color)] = zip(
        TeeBox.standardRamp,
        [Color(red: 0.106, green: 0.114, blue: 0.129),
         Color(red: 0.180, green: 0.435, blue: 0.788),
         Color(red: 0.965, green: 0.969, blue: 0.976),
         Color(red: 0.208, green: 0.588, blue: 0.353),
         Color(red: 0.898, green: 0.714, blue: 0.184),
         Color(red: 0.831, green: 0.235, blue: 0.235)]
    ).map { (name: $0, color: $1) }

    /// Names that resolve directly, including the synonyms real data uses.
    /// `yellow` is what OSM tags at Corica; `gold` is what the card prints.
    static let named: [String: Color] = {
        var m: [String: Color] = [:]
        for s in standard { m[s.name] = s.color }
        m["yellow"] = m["gold"]
        m["silver"] = Color(red: 0.741, green: 0.765, blue: 0.796)
        m["grey"] = m["silver"]; m["gray"] = m["silver"]
        m["orange"] = Color(red: 0.902, green: 0.494, blue: 0.133)
        m["purple"] = Color(red: 0.537, green: 0.365, blue: 0.788)
        m["pink"] = Color(red: 0.925, green: 0.475, blue: 0.686)
        m["bronze"] = Color(red: 0.706, green: 0.451, blue: 0.243)
        m["copper"] = m["bronze"]
        return m
    }()

    /// A name reduced to a bare colour word: `Blue Tees` → `blue`, `BLACK` → `black`.
    static func colorWord(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "\\s+tees?$", with: "", options: [.regularExpression])
            .trimmingCharacters(in: .whitespaces)
    }

    static func directColor(_ name: String) -> Color? { named[colorWord(name)] }

    /// Colours for one hole's tees, keyed by tee name.
    ///
    /// - Parameter greenCenter: what "longest" is measured against. Nil falls back
    ///   to the card distance, and then to the order the tees sit in the file — a
    ///   tee with neither a coordinate nor a card number has no place in the
    ///   ordering and must not silently claim one.
    public static func colors(for tees: [TeeBox], greenCenter: Coordinate?) -> [String: Color] {
        guard !tees.isEmpty else { return [:] }
        let ordered = ordering(tees, greenCenter: greenCenter)
        var out: [String: Color] = [:]

        // Where each tee's colour is known outright.
        var resolved: [Color?] = ordered.map { directColor($0.name) }

        if resolved.allSatisfy({ $0 == nil }) {
            // (2) Nothing named a colour — lay the standard ramp over the set.
            for (i, tee) in ordered.enumerated() {
                out[tee.name] = rampColor(index: i, of: ordered.count)
            }
            return out
        }

        // (3) Fill the gaps from the neighbours that *are* known.
        for i in resolved.indices where resolved[i] == nil {
            let before = (0..<i).reversed().first { resolved[$0] != nil }
            let after = ((i + 1)..<resolved.count).first { resolved[$0] != nil }
            switch (before, after) {
            case let (b?, a?):
                let t = Double(i - b) / Double(a - b)
                resolved[i] = blend(resolved[b]!, resolved[a]!, t)
            case let (b?, nil):
                // Past the shortest known colour — lean it toward the forward end.
                resolved[i] = blend(resolved[b]!, standard.last!.color, 0.5)
            case let (nil, a?):
                // Behind the longest known colour — lean it toward the back end.
                resolved[i] = blend(resolved[a]!, standard.first!.color, 0.5)
            case (nil, nil):
                resolved[i] = rampColor(index: i, of: ordered.count)
            }
        }
        for (i, tee) in ordered.enumerated() { out[tee.name] = resolved[i]! }
        return out
    }

    /// Tees longest-first. Measured length wins over the card number, because a
    /// card can be missing and geometry is what is being drawn.
    static func ordering(_ tees: [TeeBox], greenCenter: Coordinate?) -> [TeeBox] {
        func length(_ t: TeeBox) -> Double? {
            if let c = greenCenter, let at = t.at { return Geodesy.distance(at, c) }
            return t.distance
        }
        let placed = tees.filter { length($0) != nil }
            .sorted { length($0)! > length($1)! }
        // A tee with no length keeps its position in the file rather than being
        // dropped or sorted to an end it did not earn.
        guard placed.count != tees.count else { return placed }
        var rest = placed
        var out: [TeeBox] = []
        for t in tees {
            if length(t) == nil { out.append(t) } else if !rest.isEmpty { out.append(rest.removeFirst()) }
        }
        return out
    }

    /// The i-th of n tees along the standard ramp, endpoints included.
    static func rampColor(index i: Int, of n: Int) -> Color {
        guard n > 1 else { return standard.first!.color }
        let pos = Double(i) / Double(n - 1) * Double(standard.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, standard.count - 1)
        return blend(standard[lo].color, standard[hi].color, pos - Double(lo))
    }

    static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let (ar, ag, ab) = components(a), (br, bg, bb) = components(b)
        return Color(red: ar + (br - ar) * t,
                     green: ag + (bg - ag) * t,
                     blue: ab + (bb - ab) * t)
    }

    #if canImport(UIKit)
    static func components(_ c: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
    #elseif canImport(AppKit)
    static func components(_ c: Color) -> (Double, Double, Double) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
    }
    #else
    static func components(_ c: Color) -> (Double, Double, Double) { (0.5, 0.5, 0.5) }
    #endif

    /// An outline for a tee marker, so `white` does not vanish on a light green and
    /// `black` does not vanish into the rough. Picked from the fill's own
    /// luminance rather than fixed, because the palette now contains blends nobody
    /// chose by hand.
    public static func outline(for fill: Color) -> Color {
        let (r, g, b) = components(fill)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? Color.black.opacity(0.65) : Color.white.opacity(0.8)
    }
}
#endif
