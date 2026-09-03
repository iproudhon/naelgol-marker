import Foundation

/// Keeping a player's shot numbers in order when one of them is added, renumbered
/// or removed.
///
/// *(User, 2026-09-03: "when shot # changes, deleted or added, adjust shot numbers
/// of other markers for the same player and hole … do not rearrange hole … account
/// for missing, duplicated holes".)*
///
/// The numbers on a hole are not a tidy `1…n`. A marker filed from the Action
/// Button arrives with no number at all, two markers can end up on the same number,
/// and a number can be missing entirely because the shot it belonged to was never
/// logged. So the rules are stated over exactly what the user's examples show, and
/// **the two directions are deliberately not symmetric** — writing them in display
/// terms, where the tee shot is `T` and stored 2 reads `1`:
///
/// - `(T, 1, 1, 2)`, the first `1` renumbered to `2` → the old `2` becomes `3`.
/// - `(T, 1, 2)`, a `2` added → the old `2` becomes `3`.
/// - `(T, 1, 2, 4)`, the `2` removed → the `4` becomes `3`.
///
/// **Assigning pushes, and stops at the first gap.** Only the run of numbers
/// actually occupied from the new number upwards moves; the first free number ends
/// the cascade. A gap higher up is somebody's missing shot and moving it would
/// renumber a shot nobody touched.
///
/// **Removing decrements everything above it, gap or no gap.** Example three has a
/// gap at `3` and the `4` still comes down — a removal takes a stroke out of the
/// hole, so every later shot really is one earlier than it was.
///
/// **A renumber does not close the slot it left.** Example one moves a shot up and
/// the sequence keeps whatever it had below; nothing in the examples closes a
/// vacated number, and doing it would renumber twice for one edit.
///
/// A pure function over rows, returning `id → new shot number`, so the whole rule
/// is testable without a session folder and the caller is left with nothing but
/// `amendLog` per row. It reads `LogEntry.current`, never the raw file: a burst
/// grows by superseding and an edited log is a new row, so raw rows would count one
/// shot several times.
public enum ShotRenumber {

    /// Peers: the same player's numbered shots on the same hole, excluding the row
    /// being edited. **The hole is matched as it is, `nil` included** — a row with
    /// no hole is on no hole's sequence, and inventing one here would be the
    /// `holeSource` mistake in another hat.
    private static func peers(of id: String, player: String, hole: Int?,
                              in logs: [LogEntry]) -> [(id: String, shot: Int)] {
        current(logs).compactMap { log in
            guard log.id != id, log.player == player, log.hole == hole,
                  let shot = log.shot else { return nil }
            return (log.id, shot)
        }
    }

    private static func current(_ logs: [LogEntry]) -> [LogEntry] { LogEntry.current(logs) }

    /// The shifts to write **after** `id` takes shot number `shot` — whether it had
    /// no number before (an unassigned mark being claimed) or a different one.
    ///
    /// Empty when the number is free, which is the ordinary case: nothing is
    /// renumbered merely because a shot was filed at the end of the hole.
    public static func assigning(_ shot: Int, to id: String,
                                 player: String, hole: Int?,
                                 in logs: [LogEntry]) -> [String: Int] {
        let mine = peers(of: id, player: player, hole: hole, in: logs)
        let occupied = Set(mine.map(\.shot))
        guard occupied.contains(shot) else { return [:] }
        // The first free number at or above the new one ends the cascade.
        var free = shot
        while occupied.contains(free) { free += 1 }
        var shifts: [String: Int] = [:]
        for peer in mine where peer.shot >= shot && peer.shot < free {
            shifts[peer.id] = peer.shot + 1
        }
        return shifts
    }

    /// The shifts to write **after** `id`'s shot number goes away — the row deleted,
    /// or its number cleared. Every later shot comes down one.
    public static func removing(_ shot: Int, id: String,
                                player: String, hole: Int?,
                                in logs: [LogEntry]) -> [String: Int] {
        var shifts: [String: Int] = [:]
        for peer in peers(of: id, player: player, hole: hole, in: logs)
        where peer.shot > shot {
            shifts[peer.id] = peer.shot - 1
        }
        return shifts
    }
}
