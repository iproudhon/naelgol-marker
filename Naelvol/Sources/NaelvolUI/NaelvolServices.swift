#if os(iOS)
import Foundation
import NaelvolCore
import NaelvolPose

/// Everything naelvol needs from its host, in one object.
///
/// **This is the seam.** Nothing in naelvol imports the host's types; the host
/// fills these in from its own — a `Course` becomes a `SwingCatalog.Course`, a
/// live fix becomes a `SwingLocation`, a round in progress becomes a sentence
/// explaining why capture is refused. Lifting this package into its own
/// repository changes nothing on this side.
@MainActor
public final class NaelvolServices: ObservableObject {
    /// Courses, holes and players the edit sheet offers. Empty is ordinary.
    @Published public var catalog: SwingCatalog

    /// Why capture cannot start right now, or nil.
    ///
    /// **Capture is refused while the round is recording** *(user, 2026-08-31)*:
    /// one microphone, and a capture session starting under a live audio tap
    /// either interrupts the burst or fails silently. The host owns that state;
    /// naelvol only prints the sentence.
    public var captureBlocked: () -> String? = { nil }

    /// Where the phone is. naelvol owns no `CLLocationManager`.
    public var fix: () -> SwingLocation? = { nil }

    /// A loaded MoveNet, if the host has one. Nil is ordinary — the models are
    /// not shipped inside this package and a phone may not have them yet.
    ///
    /// **Two hooks, because the two jobs have opposite constraints** — the same
    /// split as the two Whisper models. `estimator` reads one recorded clip once,
    /// with somebody watching, so it can be the bigger model; `liveEstimator`
    /// decodes continuously behind a preview and has to be the small one.
    public var estimator: () async -> PoseEstimating? = { nil }
    public var liveEstimator: () async -> PoseEstimating? = { nil }

    public init(catalog: SwingCatalog = .empty) {
        self.catalog = catalog
    }
}
#endif
