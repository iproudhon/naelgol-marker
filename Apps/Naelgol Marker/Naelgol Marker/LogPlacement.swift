import Foundation
import CoreLocation
import GolfSessionFormat
import GolfCourse
#if canImport(UIKit)
import UIKit
#endif

/// Placing a log **after** it has already been accepted.
///
/// *(User decision, 2026-08-27: "add it to entry and show, then in the background
/// converge to get stabilized location, then update it with that location info".)*
///
/// **The two halves are separate on purpose.** Recording what was said must never
/// wait on GPS — the golfer has spoken a sentence and is walking away — so the log
/// is written with whatever fix is already warm, or with none. A first fix arrives
/// fast and can be hundreds of metres out, which on adjacent fairways is the
/// difference between two holes, so the *good* fix is worth waiting for and cannot
/// be waited for inline. This is the wait, moved off the critical path.
///
/// The result is a **superseding `LogEntry`**, never a mutation:
/// `JSONLWriter` opens `O_APPEND` and structurally cannot rewrite a line, and the
/// original row is the record of what was actually known at the time.
///
/// **Driven by the foreground app.** `RoundScreen` converges when it sees an
/// unplaced log, holding a `beginBackgroundTask` for the duration. *(This was
/// originally attempted inside the Siri intent's `perform()` and could not work:
/// a detached task there races the teardown of the background-launched instance,
/// so the radio stopped half way with nothing written. The intent is gone —
/// scrapped 2026-08-27 — and the shape it forced is the right one anyway, because
/// it is reachable in the simulator.)*
enum LogPlacement {

    /// Fixes worse than this are not worth superseding a log for. A GPS fix is
    /// ±3–5 m at best and adjacent fairways run tens of metres apart; a 60 m fix
    /// names a hole by coin toss, which is exactly the false confidence
    /// `Course.nearestHole`'s own doc warns about.
    static let usableAccuracy: Double = 25

    /// How long to keep the radio on. `TrackingState.lockRun` fixes inside
    /// `TrackingState.lockAccuracy` normally settle in a handful of seconds; this
    /// is the ceiling, not the expectation.
    static let deadline: TimeInterval = 15

    /// Logs already attempted in this run of the app.
    ///
    /// **Belt to the braces below.** A convergence that finds no fix leaves the log
    /// exactly as it was, so it stays in `unplaced` and the next trigger walks the
    /// whole backlog again — fifteen seconds of radio per log, repeatedly, for a
    /// round indoors. One attempt per log per launch is enough; the golfer who
    /// wants another can move it by hand.
    private static var attempted = Set<String>()

    /// Converge on a stable fix and append the superseding row.
    ///
    /// Does nothing — deliberately, and quietly — when the log already has a good
    /// fix, when nothing better arrives, or when the round has ended in the
    /// meantime. A log that stays unplaced is a visible, labelled state on screen
    /// (`no hole`), not an error.
    /// - Parameter within: how long to hold the radio. Defaults to `deadline`; the
    ///   Action Button passes `QuickMark.deadline` because a deliberate request for
    ///   a position is worth waiting longer for than a sentence spoken in passing.
    /// - Parameter tag: names the radio window this convergence opens, so a later
    ///   caller can cut it short — see `StableLocation.settleNow`. Cancelling this
    ///   task settles that window **and keeps whatever it had found**, rather than
    ///   throwing the wait away: a fix good enough to write is good enough to write
    ///   early.
    static func converge(_ log: LogEntry, in folder: SessionFolder,
                         within seconds: TimeInterval = deadline,
                         tag: String? = nil) async {
        // **The hole is not a retry condition, and treating it as one was an
        // infinite loop.** `Course.nearestHole` declines beyond 250 m, so a
        // perfectly good fix taken anywhere but on a mapped hole resolves to nil —
        // which is *every* log made while testing, and any log made walking
        // between fairways. The old guard read `acc <= usable && hole != nil`, so
        // such a log stayed "unplaced" after being placed: a superseding row was
        // appended, the log signature changed, the task refired, and it converged
        // again. Forever, and each lap also refired the extraction pass that hung
        // off the same signature. Reported from the device 2026-08-27.
        //
        // A log is placed when it **has a position good enough to place it**. What
        // that position resolves to is a proposal and may legitimately be nothing.
        if isPlaced(log) { return }
        guard attempted.insert(log.id).inserted else { return }

        // **An attempt that never ran does not count as an attempt.** The
        // reservation is taken up front so two passes cannot converge the same log
        // at once, but the screen's placement task is cancelled and restarted
        // whenever the unplaced set changes — and during a recording burst that is
        // often. Without giving the reservation back, a log torn down before the
        // radio ever ran would be marked attempted and **never placed at all**,
        // which is silent and permanent. Returned only when nothing was tried; a
        // convergence that ran and found nothing has genuinely had its turn, which
        // is the whole reason `attempted` exists.
        var ranTheRadio = false
        defer { if !ranTheRadio { attempted.remove(log.id) } }
        if Task.isCancelled { return }

        #if canImport(UIKit)
        // The golfer puts the phone back in their pocket the moment the sentence
        // is recorded, so the convergence has to survive the screen going off.
        let task = await UIApplication.shared.beginBackgroundTask(withName: "log.place")
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
        #endif

        // **Cancellation settles the wait; it does not abandon it.** A second
        // Action Button press cancels the first press's convergence, and the right
        // answer there is to stop waiting and write the best fix so far — the
        // golfer is walking away from the position this row is about.
        let best = await withTaskCancellationHandler {
            await StableLocation.best(within: seconds, tag: tag)
        } onCancel: {
            StableLocation.settleNow(tag: tag)
        }
        ranTheRadio = true
        guard let fix = best,
              fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= usableAccuracy
        else { return }

        // **The row may not be what it was when the wait started** *(user,
        // 2026-09-03: "what if the user deletes or moves while it's in flight")*.
        // Up to thirty seconds pass here, with the marker on screen the whole time
        // and every gesture on it available: a drag, an edit, a delete. So the
        // superseding row is built off the **chain head read from disk**, which is
        // the rule everywhere else and which this function had been quietly
        // breaking — writing off the stale copy would fork the chain, and
        // `LogEntry.current` keeps *both* heads, so a deleted mark came back and a
        // dragged one appeared twice.
        let head = LogStore.head(ofChainFrom: log.id, in: folder) ?? log

        // Deleted, moved by hand, or already better — all three refusals live in
        // the package, where a test can reach them.
        guard head.acceptsConvergedFix(accuracy: fix.horizontalAccuracy,
                                       startedFrom: log.id) else { return }

        let coordinate = Coordinate(lat: fix.coordinate.latitude,
                                    lon: fix.coordinate.longitude)
        // Derived only when nobody has said otherwise — `LogEntry.placed` is what
        // enforces it, so the rule holds for every caller and not just this one.
        let hole = LogStore.hole(at: coordinate, folder: folder)
        // Off the head, so an edit made during the wait — a player assigned to the
        // mark, a sentence corrected, a hole chosen — survives being placed.
        let placed = head.placed(lat: coordinate.lat, lon: coordinate.lon,
                                 hAcc: fix.horizontalAccuracy, hole: hole)
        try? LogStore.shared.append(placed, to: folder)
    }

    /// Give a log its turn back.
    ///
    /// **The `attempted` bargain is wrong for a hardware button.** One attempt per
    /// launch is the right trade for a backlog of spoken sentences — "the golfer
    /// who wants another can move it by hand" — but somebody who pressed the Action
    /// Button pressed it *to get a position*, and a press made indoors or under
    /// trees would otherwise be marked attempted for the rest of the launch, with
    /// `RoundScreen`'s backstop task refusing it too. That would make
    /// `QuickMark.deadline` a one-shot.
    ///
    /// **Not a loop.** `isPlaced` looks at position and accuracy only, so a
    /// convergence that succeeds can never make this log a candidate again — that
    /// is the structural property the 2026-08-27 infinite loop was fixed by, and it
    /// is untouched. What this reopens is bounded by the placement task refiring,
    /// which happens when the unplaced set changes, not on a timer.
    static func forget(_ log: LogEntry) { attempted.remove(log.id) }

    /// True when this log has a position good enough to place something from.
    /// **Says nothing about `hole`** — see `LogEntry.isPlaced(within:)`, where the
    /// condition lives so a test can reach it.
    static func isPlaced(_ log: LogEntry) -> Bool {
        log.isPlaced(within: usableAccuracy)
    }

    /// Every log in this round still worth converging for.
    ///
    /// Recomputed from the *current* versions, so a log already superseded by a
    /// placed row drops out and nothing converges twice.
    static func unplaced(_ logs: [LogEntry]) -> [LogEntry] {
        LogEntry.current(logs).filter { !isPlaced($0) && !attempted.contains($0.id) }
    }
}

/// A fix worth acting on, rather than the first one CoreLocation offers.
///
/// Taking whatever CoreLocation offers first and giving up in a couple of seconds
/// is the right trade for the moment a sentence lands — it must not block. This is
/// the opposite trade, run afterwards: keep the radio
/// on, feed every fix to `TrackingMonitor`, and return once it reports a **lock**
/// — `TrackingState.lockRun` fixes inside `TrackingState.lockAccuracy` — or the
/// deadline expires, whichever comes first. Using the same monitor the hole view
/// uses means "good enough to club off" has one definition in this app.
enum StableLocation {

    /// - Parameter tag: an optional name for this window, so `settleNow(tag:)` can
    ///   end **this** wait without touching anyone else's. Untagged waits — the
    ///   Marker sheet's settle, an ordinary log's convergence — are never cut short
    ///   by somebody else's button press.
    static func best(within seconds: TimeInterval, tag: String? = nil) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            Delegate.begin(deadline: seconds, tag: tag) { continuation.resume(returning: $0) }
        }
    }

    /// End every wait carrying `tag` **now**, each returning the best fix it has
    /// found so far *(user, 2026-09-03: "what if the action button gets clicked
    /// before done — I want to finish the current marking and start a new marker")*.
    ///
    /// **Not a cancellation.** The wait resumes normally with whatever it has, so
    /// the mark it belongs to is placed as well as it can be from where it was
    /// pressed. Letting it run on is the thing that cannot be allowed: the golfer
    /// has already walked to the next position, and a fix arriving twenty seconds
    /// late would stamp *that* coordinate onto the previous mark — the same class
    /// of error as substituting the last known position for a missing one.
    static func settleNow(tag: String?) {
        guard let tag else { return }
        for d in Delegate.live(tag: tag) { d.settle() }
    }

    private final class Delegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        /// Every wait currently holding the radio, so a tagged one can be found and
        /// ended early. Removed on `complete()`, which every exit goes through.
        private static let registry = NSLock()
        private static var running: [Delegate] = []

        static func live(tag: String) -> [Delegate] {
            registry.lock(); defer { registry.unlock() }
            return running.filter { $0.tag == tag }
        }

        private var tag: String?
        private let manager = CLLocationManager()
        private let lock = NSLock()
        private var done = false
        private var finish: ((CLLocation?) -> Void)?
        private var monitor = TrackingMonitor()
        private var best: CLLocation?

        /// **The delegate owns itself until it answers.**
        ///
        /// `CLLocationManager.delegate` is a **weak** reference, so without a
        /// self-reference ARC may release this at its last use — not at end of
        /// scope — and the continuation is then never resumed, with no callback
        /// and no error anywhere. That bug cost a whole device session
        /// *(2026-08-27)*.
        private var keepAlive: Delegate?

        static func begin(deadline: TimeInterval, tag: String? = nil,
                          finish: @escaping (CLLocation?) -> Void) {
            let d = Delegate()
            d.finish = finish
            d.tag = tag
            d.keepAlive = d
            if tag != nil {
                registry.lock(); running.append(d); registry.unlock()
            }
            d.start(deadline: deadline)
        }

        /// Answer now with the best fix so far. Idempotent — `complete()` is
        /// guarded by `done`, so a settle racing the deadline resolves once.
        func settle() { complete() }

        private func start(deadline: TimeInterval) {
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            let status = manager.authorizationStatus
            guard status == .authorizedAlways || status == .authorizedWhenInUse else {
                // Never prompts. A permission dialog thrown mid-round is one
                // nobody is looking at, blocking a log that still needs writing.
                return complete()
            }
            monitor.setMode(.fast)
            #if os(iOS)
            // **Without this the background path delivers nothing at all, and says
            // nothing about it.** Invisible in the foreground — which is the only
            // place this ran until the Action Button existed — but an intent
            // launched with the app in the background gets no fixes unless the
            // manager is told it may run there. Guarded on Always because iOS
            // throws on setting it otherwise; with only WhenInUse the wait simply
            // times out and the mark keeps the timestamp it was written with, which
            // is `Mark`'s designed-for case.
            manager.allowsBackgroundLocationUpdates =
                manager.authorizationStatus == .authorizedAlways
            // A stationary golfer is exactly when iOS decides to pause updates, and
            // a paused manager never resumes inside a fifteen-second wait.
            manager.pausesLocationUpdatesAutomatically = false
            #endif
            manager.startUpdatingLocation()
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [self] in
                complete()
            }
        }

        private func complete() {
            lock.lock()
            guard !done else { return lock.unlock() }
            done = true
            if tag != nil {
                Self.registry.lock()
                Self.running.removeAll { $0 === self }
                Self.registry.unlock()
            }
            let f = finish
            let result = best
            finish = nil
            lock.unlock()
            manager.stopUpdatingLocation()
            f?(result)
            // A run loop turn later, or dropping the last reference inside a
            // CoreLocation callback deallocates the manager mid-call.
            DispatchQueue.main.async { [self] in
                manager.delegate = nil
                keepAlive = nil
            }
        }

        func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
            for loc in locs where loc.horizontalAccuracy > 0 {
                if best == nil || loc.horizontalAccuracy < best!.horizontalAccuracy {
                    best = loc
                }
                monitor.accept(accuracy: loc.horizontalAccuracy, at: SessionClock.now())
            }
            if monitor.state.phase == .locked { complete() }
        }

        func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
            // Keep whatever has already arrived — a later failure does not
            // invalidate an earlier good fix.
            complete()
        }
    }
}
