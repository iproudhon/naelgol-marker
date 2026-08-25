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
/// Duty cycling (PLAN §5 — motion-gated GPS, 3–7× less receiver time) is
/// deliberately *not* here yet. Phase 1 records continuously so there is an
/// honest baseline to measure the saving against.
public final class LocationRecorder: NSObject, @unchecked Sendable {

    public struct Config: Sendable {
        public var accuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        /// Metres. 0 would flood the log while standing on a tee.
        public var distanceFilter: CLLocationDistance = 1
        /// Drop fixes worse than this; a 100 m fix is worse than no fix when the
        /// question is which side of a fairway someone stood on.
        public var maxHorizontalAccuracy: CLLocationAccuracy = 50
        public init() {}
    }

    private let manager = CLLocationManager()
    private let folder: SessionFolder
    private let config: Config
    private let queue = DispatchQueue(label: "marker.location")
    private var writer: JSONLWriter?

    public private(set) var lastFix: GPSFix?
    public private(set) var rejectedForAccuracy = 0
    public var onFix: (@Sendable (GPSFix) -> Void)?
    public var onAuthorizationChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    public init(folder: SessionFolder, config: Config = Config()) {
        self.folder = folder
        self.config = config
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = config.accuracy
        manager.distanceFilter = config.distanceFilter
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
        manager.startUpdatingLocation()
        return true
    }

    public func stop() {
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
