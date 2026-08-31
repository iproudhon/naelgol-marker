#if canImport(SwiftUI)
import Foundation
import GolfCourse

/// How distances are **shown**. Storage stays metres, always.
///
/// `TeeBox.distance`, `Geodesy`, `HoleGeometry` and every course file are metres
/// and stay metres — the unit is applied at the last moment, where a number is
/// turned into text. That is the same firewall `DistanceUnit` already enforces at
/// import: a card is normalised to metres once, and the unit it was printed in is
/// kept as provenance rather than as a live representation.
///
/// **Yards by default**, matching `DistanceUnit.assumedWhenUnstated` and the
/// American courses this is aimed at.
public struct DistanceDisplay: Sendable, Equatable {
    public var unit: DistanceUnit

    public static let `default` = DistanceDisplay(unit: DistanceUnit.assumedWhenUnstated)

    public init(unit: DistanceUnit = DistanceUnit.assumedWhenUnstated) {
        self.unit = unit
    }

    /// Metres in, display units out — still a number, for callers that need to
    /// compare or lay out rather than print.
    public func value(_ metres: Double) -> Double { metres / unit.toMetres }

    /// The number a golfer reads, rounded to whole units.
    ///
    /// Whole units on purpose: a decimal implies a precision no GPS fix has (±3–5 m
    /// is ±3–5 yd), and nobody clubs off a tenth of a yard.
    public func number(_ metres: Double) -> String {
        "\(Int(value(metres).rounded()))"
    }

    /// `M` or `YD` — what goes next to the number, never inside it.
    public var symbol: String { unit == .metres ? "M" : "YD" }

    public func text(_ metres: Double) -> String { "\(number(metres)) \(symbol)" }

    /// Nil in, an em dash out. A missing distance must read as missing rather than
    /// as zero — a card-only tee with no card number is the normal case.
    public func text(_ metres: Double?) -> String {
        metres.map(text) ?? "— \(symbol)"
    }

    /// The unit written out, as it reads under a hole number: `222 Yard`.
    public var word: String { unit == .metres ? "Metre" : "Yard" }
    public func spelled(_ metres: Double?) -> String {
        metres.map { "\(number($0)) \(word)" } ?? "— \(word)"
    }

    // MARK: - Elevation

    /// The elevation suffix that follows a distance: `.~334▲1`.
    ///
    /// **`<dist>.<plays like><arrow><elevation>`** *(user, 2026-08-30, restating the
    /// order: the adjusted distance comes first and the rise trails it)*. The two
    /// distances sit together because they are the same quantity twice — what it
    /// measures and what it plays — and the rise is the *reason*, which reads after
    /// the number rather than in front of it.
    ///
    /// **One formatter, because the same expression is drawn in four places** — the
    /// main distance, both target legs, and the leg between two shot markers. Four
    /// hand-built strings is four chances for one of them to round differently or
    /// point the arrow the wrong way.
    ///
    /// **`~` marks the plays-like number and nothing else.** The rise is *measured*
    /// — 3DEP lidar, 10 cm spec — and is printed bare; the plays-like figure is a
    /// model, so it carries the same mark `CardYardage` puts on a measured length
    /// standing in for a card number. A different quantity, not a substitute. It
    /// also stops `333.334` reading as a decimal. research-elevation.md §5.
    ///
    /// **No unit.** The unit is stated once, in the caption under the big number;
    /// every other number on the hole is bare.
    ///
    /// Nil when there is no terrain, and **also when the rise rounds to nothing**:
    /// `.~353▲0` beside `353` is three claims that all say the same thing, and the
    /// plays-like number it offers is the distance it is already sitting next to.
    /// Nil is what makes the suffix mean "this shot is not flat".
    public func plays(rise: Double?, distance metres: Double,
                      factor: Double = 1) -> String? {
        guard let rise else { return nil }
        // **The arithmetic is done in the units the numbers are printed in.**
        // Doing it in metres and rounding afterwards puts three numbers on screen
        // that do not add up: a 0.49 m rise over 164 m rendered `180 ▲1 · ~180`,
        // because the rise rounds *up* to a yard and the plays-like distance
        // rounds *down* to the same 180. Caught by screenshot on Corica hole 1,
        // and it reads as an arithmetic error in the app rather than as rounding.
        // Since the model is 1:1 the display-unit sum is exact, so rounding first
        // makes `distance + rise = plays like` true by construction, on screen,
        // always.
        let up = (value(rise) * factor).rounded()
        guard abs(up) >= 1 else { return nil }
        let base = value(metres).rounded()
        return ".~\(Int(base + up))\(up > 0 ? "▲" : "▼")\(Int(abs(up)))"
    }

    /// The distance and its suffix as one run of text — `333.~334▲1`, or just
    /// `333` on flat ground. No space: the `.` is the separator.
    public func withPlays(_ metres: Double, rise: Double?, factor: Double = 1) -> String {
        number(metres) + (plays(rise: rise, distance: metres, factor: factor) ?? "")
    }

    public var other: DistanceDisplay {
        DistanceDisplay(unit: unit == .metres ? .yards : .metres)
    }
    public var label: String { unit == .metres ? "Metres" : "Yards" }
}
#endif
