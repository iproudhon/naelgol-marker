import SwiftUI
import GolfSessionFormat
import GolfCourse
import GolfMap

/// Marker · Round · Location — the three controls, at the bottom of both screens.
///
/// **One view used by the scorecard and the hole view, because two would drift.**
/// The scorecard and the hole view are the two places a golfer is looking during a
/// round, and X1 asks for the same three buttons on each; building them twice means
/// the day one of them gains a state the other does not, and the app tells you two
/// different things about the same round depending on which screen you are on.
///
/// > It lives in the app target and is handed to `HoleScreen` through its
/// > `bottomBar` slot. `HoleScreen` is in `GolfMap`, and Marker needs
/// > `RoundViewModel`, `LiveTranscript` and `LogStore` — a package that draws a
/// > hole must not import the capture stack. Same rule that keeps
/// > `GolfReconstruction` off WhisperKit.
///
/// **Buttons, deliberately, and nothing gesture-driven.** The hole view has exactly
/// one drag gesture and it classifies itself; four competing gestures is what
/// shipped first and left nothing on the hole movable at all. A bar of buttons does
/// not enter that arbitration, and it must stay that way.
@MainActor
struct MarkerBar: View {
    @ObservedObject var model: RoundViewModel
    @ObservedObject var live: LiveLocation

    /// Which round this bar is for, when it is on a screen that has one. The hole
    /// view can be opened with no round at all, and then Marker starts one.
    var roundID: String?
    /// Opens the Marker sheet. Held by the caller, because the sheet needs the
    /// screen's own document to write through.
    var onMarker: () -> Void
    /// Ends the running round. Nil only where there is no round at all.
    var onEndRound: (() -> Void)?
    /// Reopens the round this screen is about — the other half of the toggle.
    /// `RoundSession.resume()` clears `meta.end`, so the round reads as unfinished
    /// again while it runs, which is what it is.
    var onStartRound: (() -> Void)?

    @State private var showLocation = false
    #if DEBUG
    /// The panel is behind a tap and there are no scripted taps here, so without
    /// this it can only be reviewed by describing it. `-marker.sheet location`.
    private var seedLocation: Bool { DemoSeed.openSheet == "location" }
    #endif
    @State private var confirmEnd = false

    private var isLive: Bool {
        model.isRecording && (roundID == nil || model.sessionName == roundID)
    }

    var body: some View {
        HStack(spacing: 8) {
            marker
            round
            location
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .popover(isPresented: $showLocation) { locationPanel }
        #if DEBUG
        .onAppear { if seedLocation { showLocation = true } }
        #endif
        // **Ending a round is confirmed, and the old control did not have to be.**
        // It said "End round" in red; this one says "Round" in green, because its
        // first job is to report that a round *is* running. A button whose label is
        // a noun must not do something irreversible-looking on one tap.
        .confirmationDialog("End this round?", isPresented: $confirmEnd,
                            titleVisibility: .visible) {
            Button("End round", role: .destructive) { onEndRound?() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("The card and everything recorded stays. Marker reopens the round if there is more to add — the scores usually get said on the way to the car park.")
        }
    }

    // MARK: - Marker

    /// **The one input control.** It replaced a record button and a text box sitting
    /// side by side, which asked the golfer to decide between speaking and typing
    /// before they had said anything. X1's "either recording and live transcription,
    /// or input box with the keyboard, with recording turned on" is one surface with
    /// both on it, not two modes needing a chooser — so this button opens that sheet
    /// and the sheet starts listening.
    private var marker: some View {
        Button(action: onMarker) {
            Label(model.isListening ? "Listening" : "Marker",
                  systemImage: model.isListening ? "waveform" : "plus.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isListening ? .red : .accentColor)
    }

    // MARK: - Round

    /// Whether the round is in progress — X1's "In Play", renamed so the three read
    /// as nouns and so it uses the app's own word for the thing it names.
    ///
    /// It does not offer to *start* one here: a round needs a roster and a course,
    /// which is `NewRoundView`'s job, and a one-tap start from the hole view would
    /// produce rounds with neither. What it does is end a running one and say, at a
    /// glance, whether the microphone has somewhere to write.
    /// **A toggle, on and off** *(user, 2026-08-28: "when it's off, no way to turn
    /// it on now")*. It was a report with an action bolted to one of its two states,
    /// so a round that had ended left a dead label and the only way back was the
    /// Marker button, which does not say that is what it does.
    ///
    /// On means recording; off reopens. It does not *create* a round — that needs a
    /// roster and a course, which is `NewRoundView`'s job, and a one-tap start from
    /// the hole view would produce rounds with neither. Every screen that shows this
    /// bar was reached through a round, so there is always one to reopen.
    @ViewBuilder private var round: some View {
        let label = Label(isLive ? "Round" : "Round off",
                          systemImage: isLive ? "flag.fill" : "flag.slash")
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 46)

        if isLive, onEndRound != nil {
            Button { confirmEnd = true } label: { label }
                .buttonStyle(.bordered)
                .tint(.green)
        } else if let onStartRound, !isLive {
            Button(action: onStartRound) { label }
                .buttonStyle(.bordered)
                .tint(.secondary)
        } else {
            // Live but this screen cannot end it, or no round at all. Still states
            // which of the two it is: that is the button's first job.
            label.foregroundStyle(isLive ? .green : .secondary)
        }
    }

    // MARK: - Location

    /// X2, and X1's third button — they are one feature.
    ///
    /// **Mode and phase are two different claims and the button shows both.** Off /
    /// Slow / Fast is what the radio is doing; Searching / Stabilising / Locked is
    /// whether the number is worth clubbing off. A first fix arrives quickly and can
    /// be hundreds of metres out, so a control that said only "location is on" would
    /// be telling the truth and still be useless.
    private var location: some View {
        Button { showLocation = true } label: {
            Label(live.enabled ? live.state.mode.label : "Off",
                  systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private var symbol: String {
        guard live.enabled else { return "location.slash" }
        switch live.state.phase {
        case .locked:      return "location.fill"
        case .stabilizing: return "location"
        case .searching:   return "location.magnifyingglass"
        case .blocked:     return "location.slash.fill"
        case .off:         return "location.slash"
        }
    }

    private var tint: Color {
        guard live.enabled else { return .secondary }
        switch live.state.phase {
        case .locked:      return .green
        case .stabilizing: return .yellow
        case .searching:   return .orange
        case .blocked:     return .red
        case .off:         return .secondary
        }
    }

    /// The accuracy, in the unit the rest of the app is showing.
    ///
    /// `TrackingState.summary` renders metres, which is right for a log and wrong
    /// here — storage is metres everywhere and display is yards by default, and a
    /// control the golfer reads is display.
    private var accuracyText: String? {
        guard let a = live.state.accuracy, a >= 0 else { return nil }
        let unit = DistanceUnit(rawValue:
            UserDefaults.standard.string(forKey: "marker.distanceUnit") ?? "") ?? .yards
        return "± " + DistanceDisplay(unit: unit).text(a)
    }

    /// **Scrolling, and a fixed width** *(user, 2026-09-03: "location dialog size
    /// doesn't fit")*. A popover is sized from its content and then **clipped** by
    /// the space between the button and the edge of the display — it does not
    /// shrink its text and it does not scroll on its own, so the bottom rows simply
    /// were not there. This one is anchored to a control on the bottom bar, which is
    /// the worst case for that. The width is explicit because `minWidth` leaves the
    /// ideal width to be inferred from the longest sentence in it, which is the
    /// other half of the same measurement.
    private var locationPanel: some View {
        ScrollView {
            locationBody
        }
        // Only scrolls when it has to, so the ordinary case still looks like a
        // panel rather than a scroll view.
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    private var locationBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Location tracking", isOn: Binding(
                get: { live.enabled },
                set: { live.setEnabled($0) }))
                .font(.headline)

            Text(live.enabled
                 ? "On: a slow fix keeps running, in the background, so a hole opens with a distance already on it. The hole view asks for a fast one while it is on screen."
                 : "Off: no position at all. Anything you say or type is still recorded — it just has no coordinate, and the map cannot show where you are.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Tracking").foregroundStyle(.secondary)
                    Text(live.enabled ? live.state.mode.label : "Off").bold()
                }
                GridRow {
                    Text("Fix").foregroundStyle(.secondary)
                    Text(live.state.phase.label).bold()
                }
                if let accuracyText {
                    GridRow {
                        Text("Range").foregroundStyle(.secondary)
                        Text(accuracyText).bold().monospacedDigit()
                    }
                }
            }
            .font(.subheadline)

            if live.state.phase == .blocked {
                Text("Permission has not been granted. Settings → Privacy → Location Services.")
                    .font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isRecording {
                Text("A round is recording, so the round's own recorder owns the radio and this feed stands down. The status above is the recorder's.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
