#if os(iOS)
import Foundation
import Vision
import CoreVideo
import CoreGraphics

/// An open palm held up to the camera, as a second way to start a recording.
///
/// Cheaper to perform than the X pose and readable from further away, but the
/// same rule: **held**, not glimpsed, and deaf for a few seconds afterwards. It
/// runs Vision rather than MoveNet, so it works before any model is loaded.
///
/// **Throttled by the caller.** At 240 fps a request per frame is not affordable
/// and is not needed for a gesture somebody holds for half a second.
public final class HandPoseTrigger {
    public var holdDuration: TimeInterval = 0.5
    public var refractoryPeriod: TimeInterval = 3.0
    public var minimumConfidence: Float = 0.5

    private let request: VNDetectHumanHandPoseRequest
    private var heldSince: Date?
    private var lastFired: Date?

    public enum Outcome: Equatable, Sendable { case idle, arming, fire }

    public init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
    }

    public func update(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                       now: Date = Date()) -> Outcome {
        if let lastFired, now.timeIntervalSince(lastFired) <= refractoryPeriod { return .idle }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do { try handler.perform([request]) } catch { return .idle }

        let open = (request.results ?? []).contains { isOpenPalm($0) }
        guard open else {
            heldSince = nil
            return .idle
        }
        guard let since = heldSince else {
            heldSince = now
            return .arming
        }
        if now.timeIntervalSince(since) >= holdDuration {
            heldSince = nil
            lastFired = now
            return .fire
        }
        return .arming
    }

    public func reset() {
        heldSince = nil
        lastFired = nil
    }

    /// Every finger extended: each tip further from the wrist than that finger's
    /// middle joint. **Distance from the wrist, never "tip above joint"** — a
    /// palm shown to a phone lying on the ground is upside down in the image and
    /// a y-comparison calls it a fist.
    private func isOpenPalm(_ observation: VNHumanHandPoseObservation) -> Bool {
        guard let wrist = try? observation.recognizedPoint(.wrist),
              wrist.confidence > minimumConfidence else { return false }
        let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.thumbTip, .thumbMP), (.indexTip, .indexPIP), (.middleTip, .middlePIP),
            (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        var extended = 0
        for (tipName, jointName) in fingers {
            guard let tip = try? observation.recognizedPoint(tipName),
                  let joint = try? observation.recognizedPoint(jointName),
                  tip.confidence > minimumConfidence, joint.confidence > minimumConfidence else { continue }
            let tipDistance = hypot(tip.location.x - wrist.location.x, tip.location.y - wrist.location.y)
            let jointDistance = hypot(joint.location.x - wrist.location.x, joint.location.y - wrist.location.y)
            if tipDistance > jointDistance { extended += 1 }
        }
        // Four of five, not five: a thumb is often occluded by the palm itself.
        return extended >= 4
    }
}
#endif
