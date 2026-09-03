import AppIntents
import Foundation

/// The Action Button.
///
/// *(User, 2026-09-03: "add a simple mark action, and link that action to the
/// action button on iPhone".)*
///
/// **The Action Button cannot target an app — it targets a *Shortcut*.** So the
/// path is `AppIntent` → `AppShortcut` → Settings ▸ Action Button ▸ Shortcut, and
/// the `AppShortcut` below is what makes this appear in that list at all. Nothing
/// here needs an extension: an `AppIntent` declared in the app target runs **in the
/// app's own process**, which is the only way it can reach `QuickMark`, the session
/// folder and the location manager.
///
/// **`openAppWhenRun = false` is the whole feature** *(user: "when app is not
/// foreground and action button is clicked, is that possible to track location
/// without even loading app foreground?")*. The answer is yes: iOS launches or
/// wakes the app **in the background**, runs `perform()`, and never builds the
/// `WindowGroup`. Two consequences shape everything:
///
/// - **Nothing from the UI exists.** No `RoundViewModel`, no `LiveLocation`, no
///   `SwingFeature`. `QuickMark` reads a `UserDefaults` pointer and the folder on
///   disk, and runs its own `CLLocationManager` — see `StableLocation`.
/// - **`perform()` returns the moment the row is on disk** *(user, 2026-09-03:
///   "another action button before done seems to fail or ignored")*. iOS will not
///   start a second invocation of an intent while the first is running, so holding
///   this for a thirty-second convergence swallowed every press in that window —
///   and a lost press is the one outcome this feature cannot have. The *write* is
///   still inline, which is what the 2026-08-27 Siri failure actually taught: that
///   intent detached the whole job, write included, and had nothing to show when it
///   was torn down. The position catches up under a `beginBackgroundTask`
///   assertion, with `RoundScreen`'s placement task as the backstop.
///
/// And the battery half of the request answers itself *(user: "when app is not in
/// foreground, I want the slow location tracking or none to save battery")*.
/// `StableLocation` runs a **third** manager at Best that stops the moment it has
/// an answer — the rule that `MarkerSheet` "names three managers and runs at most
/// two" — so `LiveLocation` and `LocationRecorder` keep whatever duty cycle they
/// were on and there is no fast mode to hand back. Nothing is escalated and
/// nothing has to be un-escalated, which is the failure mode `FastReason` exists
/// for.
struct MarkShotIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Shot"
    // One literal: `IntentDescription` takes a `LocalizedStringResource`, and a
    // `+` concatenation of two of those is not one.
    static var description = IntentDescription("File a marker where you are standing, in the round you are playing. Nobody is attached to it and it has no shot number — put those on it later by tapping it on the hole.")

    /// **False, or the whole point is lost.** Opening the app would put a screen in
    /// front of a golfer who pressed a hardware button with the phone in a pocket.
    static var openAppWhenRun: Bool = false

    /// Reported so a golfer can see what happened when they do look at the phone —
    /// including the two cases that are silent otherwise: no round running, and a
    /// mark written with no position.
    ///
    /// **The dialog is not the record.** The mark is on disk before this returns
    /// whatever it says.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await QuickMark.record() {
        case .noRound:
            // A no-op by request, but said out loud rather than swallowed: a
            // hardware button that silently does nothing is indistinguishable from
            // one that is broken.
            return .result(dialog: "No round is running.")
        case .failed:
            return .result(dialog: "Could not write the mark.")
        case .marked:
            // **Says the mark landed, never where.** This returns before the radio
            // has answered — see `QuickMark.record` — so a hole number here would be
            // a claim about a coordinate that does not exist yet.
            return .result(dialog: "Marked.")
        }
    }
}

/// What puts `MarkShotIntent` in Settings ▸ Action Button ▸ Shortcut.
///
/// **`\(.applicationName)` is required in every phrase** — App Intents refuses a
/// phrase without it at build time, so this is not decoration.
struct MarkerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkShotIntent(),
                    phrases: ["Mark a shot in \(.applicationName)",
                              "Mark in \(.applicationName)"],
                    shortTitle: "Mark Shot",
                    systemImageName: "mappin.and.ellipse")
    }
}
