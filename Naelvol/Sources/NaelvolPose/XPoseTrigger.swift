import Foundation
import CoreGraphics

/// Starting and stopping a recording from across the tee, by crossing your arms.
///
/// **The only way to record yourself alone**, which is most of the time. Pure
/// logic on purpose — it takes poses and a clock and returns a state, so the rule
/// that decides whether somebody is standing there with their arms crossed is
/// testable without a camera.
public struct XPoseTrigger: Sendable {
    /// How long the pose must be held. Short enough not to be a chore, long
    /// enough that an arm swung across the body on the way to address does not
    /// start a recording.
    public var holdDuration: TimeInterval = 0.5
    /// How long after a fire the trigger stays deaf. Without it the same held
    /// pose fires again on the next frame, and the recording starts and stops
    /// twelve times a second.
    public var refractoryPeriod: TimeInterval = 3.0
    public var minimumScore: Float = 0.3

    private(set) var heldSince: Date?
    private(set) var lastFired: Date?

    public init() {}

    public enum Outcome: Equatable, Sendable {
        /// Nothing is happening.
        case idle
        /// The pose is being held. Report it — a trigger with no feedback is a
        /// gesture people repeat because they cannot tell it is working. vipl
        /// flashes the torch here.
        case arming
        /// Held long enough. Start or stop.
        case fire
    }

    public mutating func update(_ golfer: Golfer, now: Date = Date()) -> Outcome {
        if let lastFired, now.timeIntervalSince(lastFired) <= refractoryPeriod { return .idle }

        let parts: [GolferBodyPoint] = [golfer.leftWrist, golfer.leftElbow, golfer.leftShoulder,
                                        golfer.rightWrist, golfer.rightElbow, golfer.rightShoulder]
        guard parts.allSatisfy({ $0.score >= minimumScore }) else {
            heldSince = nil
            return .idle
        }
        guard XPoseTrigger.isCrossed(golfer) else {
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

    public mutating func reset() {
        heldSince = nil
        lastFired = nil
    }

    /// Both wrists between the shoulders, both elbows further out than the
    /// wrists, hands raised above the elbows, and the whole thing narrow — arms
    /// crossed in front of the chest. `y` grows downward.
    public static func isCrossed(_ g: Golfer) -> Bool {
        let leftShoulder = g.leftShoulder.pt, rightShoulder = g.rightShoulder.pt
        let leftWrist = g.leftWrist.pt, rightWrist = g.rightWrist.pt
        let leftElbow = g.leftElbow.pt, rightElbow = g.rightElbow.pt

        let minX = min(leftShoulder.x, rightShoulder.x)
        let maxX = max(leftShoulder.x, rightShoulder.x)
        guard minX < leftWrist.x, leftWrist.x < maxX, minX < rightWrist.x, rightWrist.x < maxX else {
            return false
        }
        guard abs(leftShoulder.x - leftElbow.x) < abs(leftShoulder.x - leftWrist.x),
              abs(rightShoulder.x - rightElbow.x) < abs(rightShoulder.x - rightWrist.x) else {
            return false
        }
        guard min(leftWrist.y, rightWrist.y) < max(leftElbow.y, rightElbow.y) else { return false }
        // The hands are together relative to the shoulders — an X, not a shrug.
        return leftShoulder.distance(to: rightShoulder) > leftWrist.distance(to: rightWrist) * 3
    }
}
