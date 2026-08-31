#if canImport(SwiftUI)
import Foundation

/// What the markers layer is doing — **three states, not two** *(user, 2026-08-29:
/// "marker view toggle button: tri state — visible and interactive / visible half
/// transparent not-interactive / hidden")*.
///
/// The middle one is the interesting one, and it is not a cosmetic setting: a hole
/// can carry a dozen entries, each with a handle, and every one of them is a thing
/// a finger can pick up by accident while reaching for a target or the ground. Off
/// solves that by throwing the information away. `ghost` keeps what happened on the
/// hole *readable* while taking it out of the way of every gesture — which is what
/// a golfer wants while placing a putt line on a green covered in this afternoon's
/// entries.
///
/// **Half transparent is the whole of the affordance.** There is no other signal
/// that a marker has stopped responding, so the dimming is load-bearing in the same
/// way the simulated marker's orange dashes are: a control that looks live and is
/// not is worse than one that is plainly switched off.
public enum MarkerDisplay: String, CaseIterable, Sendable {
    /// Drawn, and a finger can pick one up.
    case on
    /// Drawn at half strength; nothing on this layer takes a touch.
    case ghost
    /// Not drawn at all — and the tracks go with them, since a line joining pills
    /// that are not there is a line between nothing and nothing.
    case off

    /// The cycle the button walks: on → ghost → off → on.
    public var next: MarkerDisplay {
        switch self {
        case .on: return .ghost
        case .ghost: return .off
        case .off: return .on
        }
    }

    public var isVisible: Bool { self != .off }
    public var isInteractive: Bool { self == .on }
    /// What the renderers draw the whole marker layer at.
    /// **0.8, not 0.45** *(user, 2026-08-30: "when inactive, opacity 80%")*.
    /// Ghost's job is to take the layer out of every gesture while keeping what
    /// happened on the hole readable, and at 0.45 the second half was losing.
    public var opacity: Double { self == .ghost ? 0.8 : 1 }

}
#endif
