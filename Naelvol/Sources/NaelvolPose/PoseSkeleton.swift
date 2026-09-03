import Foundation
import CoreGraphics

/// What a skeleton looks like, without knowing how anything is drawn.
///
/// The renderer lives in `NaelvolUI`; the *shape* lives here so the overlay drawn
/// over a live preview and the one drawn over a played-back frame cannot drift
/// apart into two skeletons that disagree.
public enum PoseSkeleton {
    /// Limbs and torso. The face is dots only: a five-point mesh over somebody's
    /// nose reads as noise at swing scale.
    public static let bones: [(from: GolferPart, to: GolferPart)] = [
        (.leftWrist, .leftElbow), (.leftElbow, .leftShoulder),
        (.leftShoulder, .rightShoulder),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.leftHip, .rightHip), (.rightHip, .rightShoulder),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    public enum Group: Sendable { case face, left, right, wrist }

    public static func group(of part: GolferPart) -> Group {
        switch part {
        case .nose, .leftEye, .rightEye, .leftEar, .rightEar: return .face
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle: return .left
        case .wrist: return .wrist
        default: return .right
        }
    }

    /// The joints a pose overlay draws, in draw order. **The synthetic wrist is
    /// last**, because it is the one point a golfer is actually reading and it must
    /// not be painted over by a hand.
    public static let drawOrder: [GolferPart] =
        GolferPart.allCases.filter { $0 != .wrist } + [.wrist]
}
