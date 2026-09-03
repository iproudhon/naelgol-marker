#if os(iOS)
import CoreMotion
import Foundation

/// Which way is down, sampled while filming.
///
/// Written into the movie as a **timed metadata track**, one sample per video
/// frame, so a swing filmed on a phone leaning against a bag can be levelled on
/// playback. This is the only reason the recorder is an `AVAssetWriter` rather
/// than `AVCaptureMovieFileOutput`, which cannot write one.
public final class GravitySource {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    public private(set) var gravity: CMAcceleration?

    public init() {}

    public var isAvailable: Bool { motion.isDeviceMotionAvailable }

    public func start(hz: Double = 30) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / hz
        motion.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            self?.gravity = motion.gravity
        }
    }

    public func stop() {
        motion.stopDeviceMotionUpdates()
        gravity = nil
    }

    /// `"x y z"`, the format vipl writes and its player reads. Kept identical so
    /// a naelvol recording levels correctly in vipl and the other way round.
    public static func string(_ g: CMAcceleration) -> String {
        String(format: "%f %f %f", g.x, g.y, g.z)
    }

    public static func parse(_ text: String) -> CMAcceleration? {
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return CMAcceleration(x: parts[0], y: parts[1], z: parts[2])
    }
}
#endif
