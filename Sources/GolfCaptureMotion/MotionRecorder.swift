import Foundation
import GolfSessionFormat
#if os(iOS)
import CoreMotion
#endif

/// Motion activity, step count, and **barometric altitude** for a round.
///
/// iOS-only, and that is the entire reason this target is separate from
/// `GolfCaptureCore`: `CMMotionActivityManager`, `CMPedometer`, and `CMAltimeter`
/// have no macOS counterpart, and keeping them out of the core is what lets the
/// recorder run on a Mac.
///
/// The altimeter is the important half. GNSS altitude is ±10–20 m — useless for
/// "this hole plays 8 m uphill". `CMAltimeter` relative altitude is ~0.3–1 m,
/// which is exactly the resolution that question needs (PLAN §5).
public final class MotionRecorder: @unchecked Sendable {

    private let folder: SessionFolder
    private let queue = DispatchQueue(label: "marker.motion")
    private var motionWriter: JSONLWriter?
    private var altitudeWriter: JSONLWriter?

    #if os(iOS)
    private let activity = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    #endif

    public private(set) var lastActivity: String = "unknown"
    public private(set) var lastRelativeAltitude: Double = 0
    public var onActivityChange: (@Sendable (String) -> Void)?

    public init(folder: SessionFolder) { self.folder = folder }

    /// What this device can actually provide. The barometer needs iPhone 6+,
    /// and motion activity needs the coprocessor — both must be checked, not
    /// assumed, and a device without them still records a usable round.
    public struct Availability: Sendable {
        public var motionActivity = false
        public var stepCounting = false
        public var relativeAltitude = false
        public var absoluteAltitude = false
    }

    public static var availability: Availability {
        var a = Availability()
        #if os(iOS)
        a.motionActivity = CMMotionActivityManager.isActivityAvailable()
        a.stepCounting = CMPedometer.isStepCountingAvailable()
        a.relativeAltitude = CMAltimeter.isRelativeAltitudeAvailable()
        if #available(iOS 15, *) {
            a.absoluteAltitude = CMAltimeter.isAbsoluteAltitudeAvailable()
        }
        #endif
        return a
    }

    public func start() throws {
        try folder.create()
        try queue.sync {
            if motionWriter == nil { motionWriter = try folder.writer(.motion) }
            if altitudeWriter == nil { altitudeWriter = try folder.writer(.altitude) }
        }
        #if os(iOS)
        startActivity()
        startPedometer()
        startAltimeter()
        #endif
    }

    public func stop() {
        #if os(iOS)
        activity.stopActivityUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        if #available(iOS 15, *) { altimeter.stopAbsoluteAltitudeUpdates() }
        #endif
        queue.sync {
            try? motionWriter?.close(); motionWriter = nil
            try? altitudeWriter?.close(); altitudeWriter = nil
        }
    }

    #if os(iOS)
    private func startActivity() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activity.startActivityUpdates(to: .main) { [weak self] a in
            guard let self, let a else { return }
            let name: String
            if a.stationary { name = "stationary" }
            else if a.walking { name = "walking" }
            else if a.running { name = "running" }
            else if a.automotive { name = "automotive" }   // a cart, on most courses
            else if a.cycling { name = "cycling" }
            else { name = "unknown" }
            let sample = MotionSample(t: SessionClock.millis(from: a.startDate),
                                      activity: name, confidence: a.confidence.rawValue)
            self.queue.sync { try? self.motionWriter?.append(sample) }
            if name != self.lastActivity {
                self.lastActivity = name
                self.onActivityChange?(name)
            }
        }
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let self, let data else { return }
            let sample = MotionSample(t: SessionClock.millis(from: data.endDate),
                                      activity: "pedometer", confidence: 0,
                                      steps: data.numberOfSteps.intValue,
                                      distance: data.distance?.doubleValue)
            self.queue.sync { try? self.motionWriter?.append(sample) }
        }
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // Relative altitude drifts with weather over 4.5 hours. Store the raw
            // sample and the pressure that produced it; re-anchoring per hole is
            // a reconstruction-side decision, and the correction strategy will
            // change (PLAN §5).
            let sample = AltitudeSample(t: SessionClock.now(),
                                        relative: data.relativeAltitude.doubleValue,
                                        pressureKPa: data.pressure.doubleValue)
            self.lastRelativeAltitude = sample.relative
            self.queue.sync { try? self.altitudeWriter?.append(sample) }
        }
        if #available(iOS 15, *), CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                let sample = AltitudeSample(t: SessionClock.millis(from: Date()),
                                            relative: self.lastRelativeAltitude,
                                            absolute: data.altitude,
                                            absoluteAccuracy: data.accuracy)
                self.queue.sync { try? self.altitudeWriter?.append(sample) }
            }
        }
    }
    #endif
}

#if canImport(GolfCaptureCore)
import GolfCaptureCore
extension MotionRecorder: SessionRecorder {}
#endif
