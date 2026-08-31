import Foundation
import CoreLocation
import Combine
import GolfSessionFormat
import GolfCaptureCore
import GolfCourse

/// The phone's position **outside a round**.
///
/// This exists because the hole view had no position at all unless a round was
/// recording: `LocationRecorder` is created by `RoundSession` and started by
/// `RoundViewModel.startRound()`, so opening the course screen to check a yardage
/// gave a permanently empty `here` and every distance fell back to the tee. That
/// looked exactly like "location is broken", and functionally it was.
///
/// > **Separate from `LocationRecorder` on purpose.** That one writes `gps.jsonl`
/// > for reconstruction and stays at full rate for the whole round — PLAN §5 wants
/// > an honest baseline before any duty-cycling saving is claimed. This one writes
/// > nothing, so it is free to drop to a cheap rate when nobody is looking at a
/// > hole. While a round is recording the recorder is authoritative and this feed
/// > stands down rather than running a second radio.
@MainActor
final class LiveLocation: NSObject, ObservableObject {
    @Published private(set) var here: Coordinate?
    /// The horizontal accuracy of the fix in `here`, in metres.
    ///
    /// Published beside the coordinate rather than folded into it, because the hole
    /// view draws it: **the ring around the position marker is this number**, and a
    /// position drawn without one claims a precision nothing measured. Nil whenever
    /// there is no fix — and deliberately *not* carried over from the last one, for
    /// the same reason the recorder never substitutes a last known position.
    @Published private(set) var accuracy: Double?
    @Published private(set) var state = TrackingState()

    /// The whole of X2: location off, or on *(user, 2026-08-28: "it's just about
    /// location off or on, not about tracing or journaling")*.
    ///
    /// **On means the radio runs slow, in the background, whether or not a round is
    /// recording** — so the hole view has a position the moment it opens instead of
    /// searching for one on the tee. It writes nothing: `gps.jsonl` belongs to a
    /// session, and this feed has no session. Off stops the radio outright, and a
    /// log written then is simply unplaced — `LogEntry.hasPosition` already treats
    /// that as a real answer rather than an error.
    ///
    /// Persisted, because it is a preference about the phone rather than about one
    /// round, and defaulted **on**: a golfer who opens the app on a course wants a
    /// yardage, and the first thing a fresh install would otherwise do is fail to
    /// give them one.
    @Published private(set) var enabled: Bool = UserDefaults.standard
        .object(forKey: LiveLocation.enabledKey) as? Bool ?? true

    static let enabledKey = "marker.location.enabled"

    private let manager = CLLocationManager()
    private var monitor = TrackingMonitor()
    private var ticker: Timer?
    /// Set while `RoundViewModel` owns the radio.
    private var standDown = false
    /// What the screen last asked for, so flipping `enabled` back on resumes at a
    /// sensible rate. **Not consulted by `standDown(false)`** — see there.
    private var wanted: TrackingMode = .slow

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        // **X2 starts at launch, not when a hole view first appears.** "On means
        // slow tracking even in the background" is not true of a feed that waits
        // for a screen — and the Location button read "Off" on the round screen
        // while the preference said on, which is the control lying about itself.
        //
        // It never *asks* here: `escalateAuthorization` returns early unless the
        // user has tapped the toggle, so an unauthorized launch starts nothing and
        // shows "No permission" rather than throwing a dialog at a golfer who has
        // not opened anything yet.
        if enabled { apply(.slow) }
    }

    /// The X2 toggle.
    ///
    /// Turning it **on** asks for permission if it has never been asked — the
    /// control is the one place in the app where the user has just said they want
    /// location, which is the only moment a prompt is not a surprise.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            requestAuthorization()
            apply(wanted)
        } else {
            apply(.off)
        }
    }

    /// Why this feed is being asked to run fast.
    ///
    /// **A set of reasons, not a mode two callers overwrite** *(2026-08-30)*. The
    /// hole view and the Marker sheet both want fast now, and `MarkerSheet.leave`
    /// dropped straight to slow — so closing the sheet took the hole view's fast
    /// tracking away underneath it, and the hole view never re-asserts because its
    /// `appear` already ran. Slow is what happens when nobody is asking.
    enum FastReason: Hashable {
        /// The GPS hole view is on screen *(user, 2026-08-30: "fast track when gps
        /// hole view is on screen, slow when not")*.
        case holeView
        /// The Marker sheet is open, or its placement window has not closed.
        case marker
    }

    private var fastReasons: Set<FastReason> = []

    func setFast(_ on: Bool, for reason: FastReason) {
        if on { fastReasons.insert(reason) } else { fastReasons.remove(reason) }
        track(fastReasons.isEmpty ? .slow : .fast)
    }

    /// Fast while a hole is on screen, slow otherwise. The distinction is the point:
    /// a golfer reading a yardage on a tee wants a fix a second; a phone in a pocket
    /// between shots does not, and asking for one all afternoon is what flattens the
    /// battery this app has to survive.
    ///
    /// **Slow does not mean foreground-only.** `allowsBackgroundLocationUpdates` is
    /// set whenever Always has been granted, and `pausesLocationUpdatesAutomatically`
    /// is off, so the feed keeps running with the phone in a pocket — which is where
    /// it spends most of a round *(user, 2026-08-30: "need background tracking as
    /// well in slow mode")*.
    func track(_ mode: TrackingMode) {
        // Remembered even when it cannot be acted on, so that standing back up after
        // a round — or switching X2 back on — resumes at the rate the screen on
        // display wants rather than dropping everything to slow.
        wanted = mode == .off ? .slow : mode
        guard !standDown, enabled else { return }
        apply(mode)
    }

    private func apply(_ mode: TrackingMode) {
        guard mode != .off else {
            manager.stopUpdatingLocation()
            // The radio is off, so the ring would be drawn around a position nothing
            // is measuring any more.
            accuracy = nil
            monitor.setMode(.off)
            state = monitor.state
            ticker?.invalidate(); ticker = nil
            return
        }
        switch mode {
        case .fast:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 1
        case .slow:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 25
        case .off:
            break
        }
        monitor.setMode(mode)
        monitor.setBlocked(isBlocked)
        state = monitor.state
        guard !isBlocked else { return }
        #if os(iOS)
        // "On means slow tracking **even in background**" (X2). This is the flag
        // that means it, together with `UIBackgroundModes: location`; iOS refuses
        // to set it without Always, so it is guarded rather than assumed.
        manager.allowsBackgroundLocationUpdates =
            manager.authorizationStatus == .authorizedAlways
        #endif
        manager.startUpdatingLocation()
        startTicker()
    }

    /// A lock that stops being fed has to decay on a clock, not only when the next
    /// fix happens to arrive — under trees the next fix may be minutes away.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.monitor.tick(now: SessionClock.now())
                self.state = self.monitor.state
            }
        }
    }

    private var isBlocked: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        case .notDetermined: return true
        default: return false
        }
    }

    /// **Always-authorization, escalated from the delegate callback rather than
    /// inline.** iOS offers Always only *after* WhenInUse is granted and the status
    /// does not change until the user answers, so asking for WhenInUse and checking
    /// on the next line silently never escalates. Same shape as
    /// `LocationRecorder.requestAuthorization`, and for the same reason: background
    /// tracking is what X2's "even in background" asks for.
    func requestAuthorization() {
        wantsAlways = true
        escalateAuthorization()
    }

    private var wantsAlways = false

    /// **Returns early unless the user has actually asked**, because assigning
    /// `CLLocationManager.delegate` fires `locationManagerDidChangeAuthorization`
    /// immediately — so without this guard the app throws a location dialog on
    /// launch, before anyone has touched anything. Same rule as
    /// `LocationPermissionMonitor.escalate()`, and it is easy to reintroduce:
    /// the prompt looks like it is coming from the toggle either way.
    private func escalateAuthorization() {
        guard wantsAlways else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        #if os(iOS)
        case .authorizedWhenInUse:
            wantsAlways = false          // ask once; nagging gets the app rejected
            manager.requestAlwaysAuthorization()
        #endif
        default:
            break
        }
    }

    /// While a round records, `LocationRecorder` owns the radio and feeds `here`
    /// through `RoundViewModel`. Two managers asking for Best simultaneously is
    /// twice the power for one position.
    func standDown(_ down: Bool) {
        standDown = down
        if down {
            manager.stopUpdatingLocation()
            ticker?.invalidate(); ticker = nil
        } else if enabled {
            // Standing back up matters as much as standing down: without this the
            // feed stays dark for the rest of the app's life after the first round
            // ends, which is the same silent-nil failure this class was written to
            // fix in the first place.
            //
            // **Back up at whatever is still being asked for, which is not the
            // same as replaying `wanted`.** The old rule here was "slow, never
            // `wanted`", and it was right about the bug: a `.fast` recorded while
            // the feed was stood down was a request from a screen that had since
            // gone, so replaying it left the radio at Best for the rest of the
            // app's life the moment a round ended. `fastReasons` fixes that at the
            // source rather than by throwing the request away — a reason is
            // *removed* by the screen that added it, so anything still in the set
            // is still on screen. Slow is what an empty set means.
            track(fastReasons.isEmpty ? .slow : .fast)
        }
    }

    /// Let the recorder's fixes drive the same indicator, so the status chip means
    /// the same thing whether or not a round is running.
    /// **The recorder's real mode, not a hardcoded `.fast`.**
    ///
    /// This stamped `.fast` on every adopted fix, so during a round the indicator
    /// read Fast on both screens whatever `LocationRecorder` was actually doing —
    /// and it is slow for all of a round except a burst. The chip and the Location
    /// button then reported the opposite of the truth for four hours, which is the
    /// same class of error as drawing a simulated position like a fix: the control
    /// looked like it was working and was describing something that was not
    /// happening.
    func adopt(accuracy: Double, mode: TrackingMode) {
        monitor.setMode(mode)
        monitor.accept(accuracy: accuracy, at: SessionClock.now())
        state = monitor.state
    }
}

extension LiveLocation: CLLocationManagerDelegate {
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        let acc = loc.horizontalAccuracy
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        Task { @MainActor in
            monitor.accept(accuracy: acc, at: SessionClock.now())
            state = monitor.state
            // A fix too poor to be worth a yardage is still worth *having* — it is
            // what tells the hole view which hole you are near. It is the phase, not
            // the position, that says how much to trust it.
            if acc >= 0 {
                here = Coordinate(lat: lat, lon: lon)
                accuracy = acc
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            // Escalation lives here and nowhere else: WhenInUse has only just been
            // granted at this point, and this is the first moment Always can be
            // asked for at all.
            escalateAuthorization()
            monitor.setBlocked(isBlocked)
            state = monitor.state
            guard !isBlocked, enabled else { return }
            #if os(iOS)
            manager.allowsBackgroundLocationUpdates =
                manager.authorizationStatus == .authorizedAlways
            #endif
            if state.mode != .off { manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Transient failures are normal under tree cover; CoreLocation recovers on
        // its own and stopping here would end the feed for the rest of the round.
    }
}
