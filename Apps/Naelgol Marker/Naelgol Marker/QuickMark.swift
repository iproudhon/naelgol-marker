import Foundation
import CoreLocation
import GolfSessionFormat
import GolfCourse
#if canImport(UIKit)
import UIKit
#endif

/// "I am standing where something happened" — one button, no screen.
///
/// *(User, 2026-09-03: "a simple mark action, linked to the Action Button. When it
/// is clicked whether the app is running or not, it activates fast tracking, waits
/// till location tracking stabilized, and saves the location and time.")*
///
/// **A `LogEntry`, filed exactly the way the legend's shot button files one, with
/// the player and the shot number left off** *(user, 2026-09-03: "I want these
/// markers to work the same way as when I clicked player marker button, just
/// player, shot # unassigned" — reversing the same day's first answer, which was a
/// `Mark` in `marks.jsonl`)*. That sentence is the whole specification and it
/// decides everything: the row supersedes, converges, drags, taps, edits and is
/// read by extraction like any other log, because it **is** any other log.
/// `CourseView.addShot` is the model to keep it matched to.
///
/// What the reversal bought, and why the first answer was wrong: `marks.jsonl` is
/// ground truth, so a mark stored there reached no extraction pass; and `Mark` has
/// no id, so there was nothing for a drag to supersede and no way to assign a
/// player to one afterwards — which is the entire point of filing an unassigned
/// marker. `LogEntry.mark` is the discriminator, and `isUnassignedMark` is the
/// state the hole view draws as an empty ring.
///
/// **Written first, placed second**, which here is not the log rule copied over but
/// the truncation rule: the execution window iOS grants a background-launched
/// intent is finite and unmeasured on this device, so the row goes down the instant
/// the button is pressed and `LogPlacement.converge` appends the superseding
/// coordinate afterwards. A truncated run costs the *position*, not the mark —
/// `LogEntry.hasPosition` already treats a positionless row as a real answer.
enum QuickMark {

    /// How long to hold the radio waiting for a lock — **15 seconds by default, and
    /// settable from the scorecard's ••• menu** *(user, 2026-09-03, after the 30 s
    /// first answer of the same day: "keep the current behavior, but shorter window
    /// of 15 seconds. Make it configurable in the course's scorecard view")*.
    ///
    /// The number is a **trade the golfer owns**, which is why it is on screen. iOS
    /// ties the Action Button's run to the work this feature keeps alive, so the
    /// wait is also the window in which the *next* press can be swallowed: longer is
    /// a better single position and a worse chance of catching a quick second shot,
    /// and which of those matters more is not something the code can know.
    ///
    /// It is a ceiling, not a wait. `StableLocation.best` returns the moment
    /// `TrackingMonitor` reports a lock — three consecutive fixes inside
    /// `TrackingState.lockAccuracy` — which normally takes a handful of seconds.
    static let deadlineKey = "marker.mark.deadline"
    static let deadlineChoices: [Int] = [5, 10, 15, 30]
    static var deadline: TimeInterval {
        // `object(forKey:)` rather than `integer(forKey:)`: an unset key reads as
        // **0**, which would make every mark's wait expire before the radio answered.
        guard let stored = UserDefaults.standard.object(forKey: deadlineKey) as? Int,
              stored > 0 else { return 15 }
        return TimeInterval(stored)
    }

    /// The round an Action Button press writes into.
    ///
    /// **A durable pointer, because a background launch has no `RoundViewModel`.**
    /// `sessionName` lives in memory on a view model that a background-launched
    /// intent never constructs — the app's `WindowGroup` is not built. The only
    /// signal left on disk is `meta.end == nil`, and unfinished folders pile up
    /// from crashes (that is what `SessionIndex.unfinished` is *for*), so "the most
    /// recent unfinished round" would cheerfully mark into a round abandoned three
    /// weeks ago. Written when a round starts or is reopened, cleared when it stops.
    static let activeRoundKey = "marker.round.active"

    /// What the row says: **nothing** *(user, 2026-09-03: "text for marker — it's
    /// not must, empty string is fine, no fillers like 'mark' or '14:1'")*.
    ///
    /// A press is a position and a time. It said `"mark"` for one afternoon, which
    /// printed the same word on every ring on the hole and in every row of the list,
    /// and stood where a golfer's own sentence goes. What identifies the row is its
    /// fields, which is what `LogTitle` composes a title out of.
    ///
    /// **An empty text has to be constructed, not `make`d**: `LogEntry.make` refuses
    /// one, deliberately, because a *spoken* row with no words is a recogniser
    /// failure rather than an entry. This is a button press, and it is entered
    /// through `LogEntry.init`.
    static let text = ""

    /// Names this feature's radio window, so a second press can end the first
    /// press's wait without touching the Marker sheet's or an ordinary log's.
    static let tag = "quickmark"

    /// The convergence still holding the radio, if any.
    ///
    /// **One mark settles before the next begins** *(user, 2026-09-03: "what if the
    /// action button gets clicked before done — I want to finish the current marking
    /// and start a new marker")*. This is a correctness fix as much as a tidy-up:
    /// the wait runs for as long as `deadline` says and a golfer who presses twice has
    /// walked between the two presses, so a fix arriving late would place the *first*
    /// mark where the *second* was pressed — a coordinate nothing measured, looking
    /// exactly like one that was.
    ///
    /// **Two presses are still two marks.** Losing a press is worse than a duplicate
    /// ring, so the row is written before anything here is consulted; what is
    /// serialised is the radio, not the record.
    private static let gate = NSLock()
    private static var inFlight: Task<Void, Never>?

    /// Settle the mark already in flight — with the fix it has, not by throwing the
    /// wait away.
    ///
    /// Cancelling is what settles it: `LogPlacement.converge` installs a
    /// cancellation handler that ends the radio window and then goes on to write
    /// whatever it found. **Not awaited**, because this runs on the press's own
    /// thread and the new mark must not queue behind the old one's last write —
    /// which is the whole of the bug this file has been through twice.
    private static func finishInFlight() {
        gate.lock()
        let previous = inFlight
        inFlight = nil
        gate.unlock()
        previous?.cancel()
    }

    enum Outcome {
        /// The row is on disk. **The position is not in it yet** and may never be:
        /// the radio is still being asked, and `RoundScreen` is the backstop for a
        /// wait that gets suspended. The mark itself — a time, in this round — is
        /// the part that is guaranteed by the time this is returned.
        case marked
        /// Nothing could be written. Rare enough to be worth saying out loud rather
        /// than swallowing: the folder is unwritable.
        case failed
        /// No round is running, so there is nothing to mark. A no-op by request
        /// *(user: "if course is not running, it's no op")*.
        case noRound
    }

    /// The round currently open for marking, or nil.
    ///
    /// Both halves are checked: the pointer says which round, and `meta.end == nil`
    /// says it is still open. A pointer left behind by a process that was killed
    /// between `stopRound` and the write would otherwise keep a finished round
    /// accepting marks.
    static func activeRound() -> SessionFolder? {
        guard let name = UserDefaults.standard.string(forKey: activeRoundKey),
              !name.isEmpty else { return nil }
        let folder = SessionFolder(url: RoundViewModel.sessionsRoot
                                        .appendingPathComponent(name))
        guard let meta = try? folder.readMeta(), meta.end == nil else { return nil }
        return folder
    }

    static func setActiveRound(_ name: String?) {
        let d = UserDefaults.standard
        if let name { d.set(name, forKey: activeRoundKey) }
        else { d.removeObject(forKey: activeRoundKey) }
    }

    /// File a mark now. The position catches up.
    ///
    /// **Returns as soon as the row is on disk, and never waits for the radio**
    /// *(user, 2026-09-03: "another action button before done seems to fail or
    /// ignored — only the first one is there")*. This reverses the shape the file
    /// was written in, and the reason is measured on a phone: while `perform()` is
    /// running the system will not start another invocation of the same intent, so
    /// holding it for a thirty-second convergence made **every press during that
    /// window disappear**. A lost press is the one outcome this feature cannot have
    /// — it is worse than a duplicate ring and far worse than a mark with no
    /// coordinate, which is a state the whole design already carries.
    ///
    /// What keeps the coordinate coming anyway, in order: the convergence runs on in
    /// a retained task under a `beginBackgroundTask` assertion, which is what a
    /// background-launched app gets its runtime from; and if that is suspended
    /// before a fix lands, the row is simply an unplaced log, which is exactly what
    /// `RoundScreen`'s placement task exists to pick up. *(The 2026-08-27 Siri
    /// failure — a detached task torn down with nothing written — was a task with no
    /// assertion doing the whole job, including the write. The write is now done
    /// before this returns, so a teardown costs the position and never the mark.)*
    ///
    /// **A second press finishes the first** *(user, 2026-09-03)*: `finishInFlight`
    /// cancels it, which settles its radio window and lets it write the best fix it
    /// had. Not awaited — the new press must not queue behind the old one.
    ///
    /// **No hole is stamped and none is guessed.** `holeSource` stays nil, meaning
    /// `.fix`, so `LogPlacement` is free to fill it in from the position it finds.
    /// `addShot` writes `.user` because a hole view was on screen saying which hole
    /// the golfer was looking at; nothing is on screen here, and stamping the last
    /// hole anybody happened to open would put an unmeasured claim in a field that
    /// means "nearest hole to a measured fix".
    @MainActor
    @discardableResult
    static func record() -> Outcome {
        guard let folder = activeRound() else { return .noRound }

        // The row exists before the radio is asked for anything, so nothing below
        // this line can lose the press.
        let entry = LogEntry(text: text, source: .typed, mark: true)
        guard let written = try? LogStore.shared.append(entry, to: folder) else {
            return .failed
        }

        // Settle the previous press with what it has — see `finishInFlight`.
        finishInFlight()

        #if canImport(UIKit)
        // The phone is in a pocket and the app may not be on screen at all; without
        // an assertion the wait is suspended before the first fix arrives. Taken
        // here rather than inside the task so it is held from the moment the press
        // is handled, and ended by the task that owns it.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "mark.place")
        #endif

        let work = Task {
            // **The same convergence every other log goes through**, at this
            // button's own deadline. It appends the superseding row off the chain
            // head, derives the hole from the fix, and refuses a deleted or
            // hand-moved row — none of which is worth a second implementation here.
            await LogPlacement.converge(written, in: folder,
                                        within: deadline, tag: tag)
            // **Give the turn back when it ends up with no position.** `attempted`
            // is one convergence per log per launch, which is right for a backlog of
            // spoken sentences and wrong for a button somebody pressed *to get a
            // position*: a press made indoors, or one cut short by the next press
            // with nothing usable yet, would otherwise be refused by
            // `RoundScreen`'s backstop for the rest of the launch. **This used to
            // happen in `record`**, which inspected the outcome; it returns before
            // the answer exists now, so the check moved in here with it.
            //
            // It cannot loop: `isPlaced` reads position and accuracy only, so a
            // convergence that succeeds can never make this row a candidate again.
            let head = LogStore.head(ofChainFrom: written.id, in: folder) ?? written
            if !head.isDeleted, !LogPlacement.isPlaced(head) {
                LogPlacement.forget(head)
            }
            #if canImport(UIKit)
            await MainActor.run { UIApplication.shared.endBackgroundTask(bg) }
            #endif
        }
        gate.lock(); inFlight = work; gate.unlock()
        return .marked
    }
}
