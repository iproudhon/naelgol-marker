#if canImport(SwiftUI)
import Foundation

/// What a shot is **called** on screen, as against what it is stored as.
///
/// *(User, 2026-08-29: "marker shows shot # it's sitting on — tee off: T, #1: 1,
/// #2: 2, #3/holeout: 3"; and "player name <shot count> shows next shot when not
/// holed out: T -> 1 -> 2 -> ...".)*
///
/// A golfer does not call the drive "shot 1" — it is the tee shot, and the shot
/// after it is the first one that gets a number. So the stored sequence 1, 2, 3, 4
/// is *displayed* T, 1, 2, 3. The two are the same sequence and the offset is one.
///
/// **Storage is untouched, deliberately.** `LogEntry.shot` stays 1-based and so do
/// `LogEntry.nextShot`, the Marker sheet's stepper, the `"7: 2 drive…"` log prefix
/// and `RoundExport`. Renumbering the stored field would ripple into the extraction
/// pass's input and into every round already on disk, to change what a pill reads.
/// This is a formatter, and it lives where the two things that render a shot number
/// can both reach it — a second copy is two answers that can disagree, which is the
/// `defaultTee` trap.
public enum ShotName {
    /// The name of the **stored** shot number `n`. `1` is the tee shot.
    public static func of(_ n: Int) -> String { n <= 1 ? "T" : "\(n - 1)" }
}
#endif
