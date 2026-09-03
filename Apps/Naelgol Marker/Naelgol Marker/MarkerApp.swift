import SwiftUI

@main
struct MarkerApp: App {
    @StateObject private var model = RoundViewModel()

    /// **App-wide, not per screen.** X2 asks for slow tracking that keeps running in
    /// the background, which a `@StateObject` owned by `CourseView` cannot do: it is
    /// created when the course screen appears and torn down when it goes away, so
    /// the radio would stop the moment the golfer looked at anything else and the
    /// preference would mean nothing. One feed, one radio, one status — which is
    /// also what makes the Location button read the same on both screens.
    @StateObject private var live = LiveLocation()

    /// Swing video — browsing, capture, playback. **App-wide for the same reason
    /// `live` is**: the library is scanned once and three screens open the same
    /// one, and a per-screen `@StateObject` would rescan every folder each time a
    /// golfer opened the list from a different place.
    @StateObject private var swings = SwingFeature()

    /// Screenshot support only — see `DemoSeed`. Empty without the launch argument.
    private let initialPath: [RoundsListView.Route] = {
        #if DEBUG
        DemoSeed.seedIfRequested()
        if DemoSeed.wantsNewRound { return [.newRound] }
        return DemoSeed.openRound.map { [RoundsListView.Route.round($0)] } ?? []
        #else
        return []
        #endif
    }()

    var body: some Scene {
        WindowGroup {
            RoundsListView(model: model, live: live, initial: initialPath)
                .environmentObject(swings)
                .environmentObject(swings.services)
                // **Handover lives here, not on a screen.** While a round records,
                // `LocationRecorder` owns the radio and this feed stands down: two
                // managers asking for the same position is twice the power for one
                // answer. It used to be driven by `CourseView`, so it only happened
                // if the golfer opened the hole view — a round spent entirely on the
                // scorecard ran both radios all afternoon, and the Location button
                // there showed whatever this feed last saw rather than what the
                // recorder was doing.
                .onChange(of: model.isRecording, initial: true) { _, recording in
                    live.standDown(recording)
                }
                // The recorder's fixes drive the same indicator, at the recorder's
                // real rate, so "Slow" and "Fast" mean one thing on every screen.
                .onChange(of: model.fixAccuracy) { _, acc in
                    if let acc, model.isRecording {
                        live.adopt(accuracy: acc, mode: model.trackMode)
                    }
                }
                // naelvol asks the app two standing questions — where am I, and
                // may I open the camera right now — and this is where they are
                // answered, once, for every screen. The *catalog* is refreshed at
                // each entry point instead, because each already holds the course
                // library and the round whose roster the sheet should offer.
                .task { swings.bind(model: model, live: live) }
        }
    }
}
