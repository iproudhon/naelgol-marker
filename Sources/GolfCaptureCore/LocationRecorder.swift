import Foundation
import CoreLocation
import GolfSessionFormat

/// Streams `GPSFix` into gps.jsonl for the length of a round.
///
/// Uses the classic `CLLocationManagerDelegate` rather than iOS 17's
/// `CLLocationUpdate.liveUpdates()` so this target keeps the package's low
/// platform floor and still runs on macOS. Background survival on iOS comes
/// from `allowsBackgroundLocationUpdates` plus the `location` background mode;
/// `CLBackgroundActivitySession` is gated separately below.
///
/// **The recorded track is duty-cycled too** *(user decision, 2026-08-26, TODO 16;
/// implemented 2026-08-27)*. It used to run at `kCLLocationAccuracyBest` for the
/// whole round so PLAN §5 would have an honest full-rate baseline to measure a
/// saving against. That baseline round is not going to be collected, so **the
/// saving here is an estimate and must never be quoted as a measurement** — there
/// is no before-number and there never will be.
///
/// A round therefore tracks **slow** by default and goes **fast** only where dense
/// positions are actually worth their power: while a hole view is open, and for the
/// convergence window right after a recording burst, which is where the shots are.
/// The visible cost is that `gps.jsonl` is now too coarse between those moments to
/// derive course geometry from — the track is dense around bursts and sparse in
/// between, on purpose, and someone will eventually wonder why.
public final class LocationRecorder: NSObject, @unchecked Sendable {

    public struct Config: Sendable {
        /// Fast mode — what the hole view and a just-recorded log need.
        public var accuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        /// Metres. 0 would flood the log while standing on a tee.
        public var distanceFilter: CLLocationDistance = 1
        /// Slow mode. Coarse enough to say which hole, cheap enough to leave on
        /// for four and a half hours.
        public var slowAccuracy: CLLocationAccuracy = kCLLocationAccuracyNearestTenMeters
        public var slowDistanceFilter: CLLocationDistance = 25
        /// Drop fixes worse than this; a 100 m fix is worse than no fix when the
        /// question is which side of a fairway someone stood on.
        ///
        /// **Unchanged by the mode.** A slow fix is a cheaper *request*, not a
        /// licence to write a worse *answer* — the reason a 100 m fix is useless
        /// has nothing to do with how it was asked for.
        public var maxHorizontalAccuracy: CLLocationAccuracy = 50
        /// Where a round starts. Slow: a golfer walking to the first tee is not
        /// doing anything a metre of precision would record.
        public var startMode: TrackingMode = .slow
        public init() {}
    }

    private let manager = CLLocationManager()
    private let folder: SessionFolder
    private let config: Config
    private let queue = DispatchQueue(label: "marker.location")
    private var writer: JSONLWriter?

    public private(set) var lastFix: GPSFix?
    /// What the radio is being asked for. `.off` only before `startTracking` and
    /// after `stop`.
    public private(set) var mode: TrackingMode = .off
    public private(set) var rejectedForAccuracy = 0
    public var onFix: (@Sendable (GPSFix) -> Void)?
    public var onAuthorizationChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    public init(folder: SessionFolder, config: Config = Config()) {
        self.folder = folder
        self.config = config
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = config.slowAccuracy
        manager.distanceFilter = config.slowDistanceFilter
    }

    /// Change what the radio is being asked for, without interrupting the track.
    ///
    /// **Never `.off` here.** A round with the microphone shut still has to know
    /// roughly where it is — that is what puts a hole number on a log — and there
    /// is no state in which stopping the track while the round runs is right.
    /// `stop()` is how a round's track ends.
    public func setMode(_ next: TrackingMode) {
        guard next != .off, next != mode, mode != .off else { return }
        mode = next
        apply(next)
    }

    private func apply(_ next: TrackingMode) {
        switch next {
        case .fast:
            manager.desiredAccuracy = config.accuracy
            manager.distanceFilter = config.distanceFilter
        case .slow, .off:
            manager.desiredAccuracy = config.slowAccuracy
            manager.distanceFilter = config.slowDistanceFilter
        }
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// CoreLocation needs a real bundle. A bare command-line binary has no
    /// bundle identifier, and `startUpdatingLocation()` there hangs rather than
    /// failing — so the Mac recorder records audio and marks, and the GPS track
    /// comes from the phone. Detecting it beats hanging.
    public static var isAvailableInThisProcess: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Always-authorization is what survives a pocketed phone for 4.5 hours.
    /// iOS only offers it *after* WhenInUse has been granted, and the status does
    /// not change until the user answers — so the escalation has to happen in the
    /// delegate callback, not on the next line. Doing it inline (ask WhenInUse,
    /// then immediately check for `.authorizedWhenInUse`) silently never escalates.
    public func requestAuthorization() {
        wantsAlways = true
        escalateAuthorization()
    }

    private var wantsAlways = false

    private func escalateAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        #if os(iOS)
        case .authorizedWhenInUse:
            guard wantsAlways else { return }
            wantsAlways = false          // ask once; nagging gets the app rejected
            manager.requestAlwaysAuthorization()
        #endif
        default:
            break
        }
    }

    /// - Returns: false if this process cannot use CoreLocation at all
    ///   (an unbundled CLI). The round still records; it just has no track.
    @discardableResult
    public func startTracking() throws -> Bool {
        guard Self.isAvailableInThisProcess else { return false }
        try folder.create()
        try queue.sync {
            if writer == nil { writer = try folder.writer(.gps) }
        }
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false   // a golfer stands still a lot
        manager.activityType = .fitness
        #endif
        mode = config.startMode == .off ? .slow : config.startMode
        apply(mode)
        manager.startUpdatingLocation()
        return true
    }

    public func stop() {
        mode = .off
        manager.stopUpdatingLocation()
        queue.sync {
            try? writer?.close()
            writer = nil
        }
    }
}

extension LocationRecorder: CLLocationManagerDelegate {
    public func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            guard loc.horizontalAccuracy >= 0,
                  loc.horizontalAccuracy <= config.maxHorizontalAccuracy else {
                queue.sync { rejectedForAccuracy += 1 }
                continue
            }
            let fix = GPSFix(
                t: SessionClock.millis(from: loc.timestamp),
                lat: loc.coordinate.latitude,
                lon: loc.coordinate.longitude,
                alt: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                hAcc: loc.horizontalAccuracy,
                vAcc: loc.verticalAccuracy >= 0 ? loc.verticalAccuracy : nil,
                speed: loc.speed >= 0 ? loc.speed : nil,
                course: loc.course >= 0 ? loc.course : nil)
            queue.sync {
                try? writer?.append(fix)
                lastFix = fix
            }
            onFix?(fix)
        }
    }

    /// Where the WhenInUse → Always escalation actually happens.
    public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        escalateAuthorization()
        onAuthorizationChange?(m.authorizationStatus)
    }

    public func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // Transient failures are normal under tree cover; CoreLocation recovers
        // on its own and stopping here would end the round's track.
    }
}
