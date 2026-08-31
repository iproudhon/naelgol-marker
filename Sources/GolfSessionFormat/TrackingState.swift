import Foundation

// Lives in `GolfSessionFormat` — the zero-dependency contract — rather than in
// `GolfCaptureCore`, because both halves need it: capture produces it and the hole
// view renders it. Putting it in the capture target would have made `GolfMap`, a
// renderer, depend on the audio and CoreLocation stack to draw a status dot.

/// How hard the phone is currently working for a position.
///
/// Two rates, not one, because the two jobs are different: standing on a tee reading
/// a yardage wants a fix a second, and a phone in a pocket between shots does not.
///
/// > **The recorded track is not duty-cycled.** `LocationRecorder` — the one that
/// > writes `gps.jsonl` for reconstruction — stays at full rate for the whole round,
/// > because PLAN §5 wants an honest baseline to measure any saving against. This
/// > applies to the *live* feed the hole view reads, which writes nothing.
public enum TrackingMode: String, Sendable, CaseIterable {
    /// Not asking for a position at all.
    case off
    /// Coarse and cheap — enough to know which hole you are on.
    case slow
    /// Best accuracy, every metre. What the hole view needs while it is on screen.
    case fast

    public var label: String {
        switch self {
        case .off: return "Off"
        case .slow: return "Slow"
        case .fast: return "Fast"
        }
    }
}

/// Whether a position is worth believing yet.
///
/// Exists because "location is on" and "location is usable" are different claims and
/// the app was making only the first. A first fix arrives fast and can be 500 m out;
/// showing a yardage off it looks like the app works and is wrong by a hole.
public struct TrackingState: Sendable, Equatable {

    public enum Phase: String, Sendable {
        /// Not tracking.
        case off
        /// Tracking, but permission has not been granted.
        case blocked
        /// Tracking, no acceptable fix yet.
        case searching
        /// Fixes arriving, but not yet consistently good enough to trust.
        case stabilizing
        /// Settled. Distances on screen mean what they say.
        case locked

        public var label: String {
            switch self {
            case .off: return "Off"
            case .blocked: return "No permission"
            case .searching: return "Searching"
            case .stabilizing: return "Stabilising"
            case .locked: return "Locked"
            }
        }
    }

    public var mode: TrackingMode = .off
    public var phase: Phase = .off
    /// Horizontal accuracy of the most recent accepted fix, in metres.
    public var accuracy: Double?
    public var fixCount = 0
    /// When the last accepted fix arrived, for staleness.
    public var lastFixAt: Millis?

    public init() {}

    /// A fix has to be at least this good to count toward a lock. Roughly a
    /// half-club: past this, front-versus-centre stops being a real distinction.
    public static let lockAccuracy: Double = 15
    /// How many consecutive good fixes before the reading is called settled. One
    /// good fix is routinely followed by a bad one while the radio is still warming.
    public static let lockRun = 3
    /// After this long with nothing, a lock is no longer a lock — under trees or in
    /// a pocket the last fix can be minutes old and still be displayed as current.
    public static let staleAfter: TimeInterval = 20

    public var isUsable: Bool { phase == .locked || phase == .stabilizing }

    public var summary: String {
        switch phase {
        case .off, .blocked: return phase.label
        case .searching: return "\(mode.label) · \(phase.label)"
        default:
            let acc = accuracy.map { " ±\(Int($0.rounded()))m" } ?? ""
            return "\(mode.label) · \(phase.label)\(acc)"
        }
    }
}

/// Turns a stream of fixes into a `TrackingState`. Pure and synchronous so the rule
/// — what counts as settled — is testable without a radio.
public struct TrackingMonitor: Sendable {
    public private(set) var state = TrackingState()
    private var goodRun = 0

    public init() {}

    public mutating func setMode(_ mode: TrackingMode) {
        state.mode = mode
        if mode == .off {
            state = TrackingState()
        } else if state.phase == .off {
            state.phase = .searching
        }
    }

    public mutating func setBlocked(_ blocked: Bool) {
        if blocked {
            state.phase = .blocked
            goodRun = 0
        } else if state.phase == .blocked {
            state.phase = state.mode == .off ? .off : .searching
        }
    }

    /// - Parameter accuracy: horizontal accuracy in metres. Negative means the fix
    ///   is invalid, which CoreLocation does report.
    public mutating func accept(accuracy: Double, at now: Millis) {
        guard state.phase != .blocked, state.mode != .off else { return }
        guard accuracy >= 0 else { return }
        state.fixCount += 1
        state.accuracy = accuracy
        state.lastFixAt = now
        if accuracy <= TrackingState.lockAccuracy {
            goodRun += 1
        } else {
            goodRun = 0
        }
        state.phase = goodRun >= TrackingState.lockRun ? .locked : .stabilizing
    }

    /// Call on a timer as well as on each fix: a lock that stops being fed has to
    /// decay, or a stale position keeps being presented as current.
    public mutating func tick(now: Millis) {
        guard state.mode != .off, state.phase != .blocked else { return }
        guard let last = state.lastFixAt else { return }
        let age = Double(now - last) / 1000
        if age > TrackingState.staleAfter {
            goodRun = 0
            state.phase = .searching
            state.accuracy = nil
        }
    }
}
