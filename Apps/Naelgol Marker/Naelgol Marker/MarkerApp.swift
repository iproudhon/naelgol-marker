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
        }
    }
}
