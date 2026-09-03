import Foundation
import GolfSessionFormat

/// Applying `ShotRenumber` to a round on disk.
///
/// **A free function over a `SessionFolder`, not a method on `RoundDocument`**,
/// because a marker is edited from two screens that hold different things. The
/// round screen has a `RoundDocument`; the hole view deliberately does not — it
/// appends through a `JSONLWriter` so a replay does not rewrite `scorecard.json`
/// under every edit — and both have to renumber the same way or the rule depends on
/// which screen the golfer happened to be looking at.
///
/// Every amendment goes off the **chain head read from disk**, one row at a time.
/// Two writers grow these chains — `LogPlacement` appends a converged coordinate —
/// so superseding the copy this function computed its shifts over would fork the
/// chain and drop whatever the radio had just found. The shift map is worked out
/// once; the rows it names are re-read as they are written.
enum ShotEditing {

    /// Renumber a player's other shots after `log` takes `shot`.
    static func assigned(_ shot: Int, to log: LogEntry, in folder: SessionFolder) {
        guard let player = log.player else { return }
        let logs = folder.readAll(.log, as: LogEntry.self)
        apply(ShotRenumber.assigning(shot, to: log.id, player: player,
                                     hole: log.hole, in: logs), in: folder)
    }

    /// Renumber a player's other shots after `log` stops being one — deleted, or
    /// its number cleared.
    ///
    /// Returns the player and hole whose **score** is now one stroke light, or nil
    /// when the row was not a numbered shot. The score itself is left to the caller
    /// *(user, 2026-09-03: "if it's holed out, hole score decrease by 1")*: a score
    /// is a journal act, and the two screens journal it through different objects.
    @discardableResult
    static func removed(_ log: LogEntry, in folder: SessionFolder)
    -> (player: String, hole: Int)? {
        guard let player = log.player, let shot = log.shot else { return nil }
        let logs = folder.readAll(.log, as: LogEntry.self)
        apply(ShotRenumber.removing(shot, id: log.id, player: player,
                                    hole: log.hole, in: logs), in: folder)
        return log.hole.map { (player, $0) }
    }

    /// **Order does not matter, and that is a property of the map rather than of
    /// this loop.** Every entry is an *absolute* new number worked out against one
    /// pre-edit snapshot — never `head.shot + 1` — so two rows swapping places, or a
    /// dictionary iterating in whatever order it likes, land on the same result.
    private static func apply(_ shifts: [String: Int], in folder: SessionFolder) {
        for (id, shot) in shifts {
            guard let head = LogStore.head(ofChainFrom: id, in: folder),
                  let next = head.edited(shot: .some(shot)) else { continue }
            _ = try? LogStore.shared.append(next, to: folder)
        }
    }
}
