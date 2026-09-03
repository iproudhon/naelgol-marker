import Foundation
import CoreGraphics

/// A `BodyPart` plus the one joint MoveNet does not report: the **wrist**, the
/// midpoint of the two hands, which is where a club is actually held.
public enum GolferPart: Int, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
    case wrist

    public var index: Int { rawValue }
}

/// One joint at one instant: where it is, how fast it is moving, and how fast that
/// is changing.
///
/// `pt` and `orgPt` are separate because a smoothed or interpolated position is
/// still a claim about a *measured* one — the same distinction the app draws
/// everywhere between a fix and a hand-placed point. Validity is judged on
/// `orgPt`, never on the smoothed value.
public struct GolferBodyPoint: Hashable, Sendable {
    public var part: GolferPart = .nose
    public var vx: Double = 0
    public var vy: Double = 0
    public var ax: Double = 0
    public var ay: Double = 0
    public var pt: CGPoint = .zero
    public var orgPt: CGPoint = .zero
    public var score: Float = 0

    public init() {}

    public init(_ p: KeyPoint) {
        part = GolferPart(rawValue: p.bodyPart.position) ?? .nose
        pt = p.coordinate
        orgPt = p.coordinate
        score = p.score
    }
}

/// A pose, as this app means it: MoveNet's 17 joints, the synthetic wrist, and
/// `unit` — the hip-to-knee distance, which is the only scale a single camera can
/// establish without knowing how far away the golfer is standing.
public struct Golfer: Hashable, Sendable {
    public var time: Double = 0
    public var points: [GolferBodyPoint?] = Array(repeating: nil, count: GolferPart.allCases.count)
    /// Distance between the hip midpoint and the knee midpoint. **Every threshold
    /// that is a length is expressed in units of this**, or it stops being true
    /// the moment the phone is a metre closer.
    public var unit: Double = 0
    public var score: Float = 0

    public init() {}

    public init(_ p: Person, time: Double = 0) {
        self.time = time
        for (index, _) in BodyPart.allCases.enumerated() where index < p.keyPoints.count {
            points[index] = GolferBodyPoint(p.keyPoints[index])
        }
        score = p.score

        let hip = leftHip.orgPt.midPoint(to: rightHip.orgPt)
        let knee = leftKnee.orgPt.midPoint(to: rightKnee.orgPt)
        var w = GolferBodyPoint(p.keyPoints[BodyPart.rightWrist.position])
        w.part = .wrist
        // **The weaker of the two hands**, not the average: a wrist midpoint is
        // only as trustworthy as the hand the model was least sure of.
        w.score = min(leftWrist.score, rightWrist.score)
        w.orgPt = leftWrist.orgPt.midPoint(to: rightWrist.orgPt)
        w.pt = w.orgPt
        wrist = w
        unit = hip.distance(to: knee)
    }

    public subscript(part: GolferPart) -> GolferBodyPoint {
        get { points[part.index] ?? GolferBodyPoint() }
        set { points[part.index] = newValue }
    }

    public var nose: GolferBodyPoint { get { self[.nose] } set { self[.nose] = newValue } }
    public var leftEye: GolferBodyPoint { get { self[.leftEye] } set { self[.leftEye] = newValue } }
    public var rightEye: GolferBodyPoint { get { self[.rightEye] } set { self[.rightEye] = newValue } }
    public var leftEar: GolferBodyPoint { get { self[.leftEar] } set { self[.leftEar] = newValue } }
    public var rightEar: GolferBodyPoint { get { self[.rightEar] } set { self[.rightEar] = newValue } }
    public var leftShoulder: GolferBodyPoint { get { self[.leftShoulder] } set { self[.leftShoulder] = newValue } }
    public var rightShoulder: GolferBodyPoint { get { self[.rightShoulder] } set { self[.rightShoulder] = newValue } }
    public var leftElbow: GolferBodyPoint { get { self[.leftElbow] } set { self[.leftElbow] = newValue } }
    public var rightElbow: GolferBodyPoint { get { self[.rightElbow] } set { self[.rightElbow] = newValue } }
    public var leftWrist: GolferBodyPoint { get { self[.leftWrist] } set { self[.leftWrist] = newValue } }
    public var rightWrist: GolferBodyPoint { get { self[.rightWrist] } set { self[.rightWrist] = newValue } }
    public var leftHip: GolferBodyPoint { get { self[.leftHip] } set { self[.leftHip] = newValue } }
    public var rightHip: GolferBodyPoint { get { self[.rightHip] } set { self[.rightHip] = newValue } }
    public var leftKnee: GolferBodyPoint { get { self[.leftKnee] } set { self[.leftKnee] = newValue } }
    public var rightKnee: GolferBodyPoint { get { self[.rightKnee] } set { self[.rightKnee] = newValue } }
    public var leftAnkle: GolferBodyPoint { get { self[.leftAnkle] } set { self[.leftAnkle] = newValue } }
    public var rightAnkle: GolferBodyPoint { get { self[.rightAnkle] } set { self[.rightAnkle] = newValue } }
    public var wrist: GolferBodyPoint { get { self[.wrist] } set { self[.wrist] = newValue } }
}

/// Is this a golfer at address, or is it the model finding a person in a tree?
///
/// **Ported from vipl unchanged.** It is tuned against real swings, and every rule
/// in it is a shape a body actually has: shoulders above knees, knees above
/// ankles, and the two hands together on a club. Loosening it is a measurement,
/// not an edit.
public struct PoseValidator: Sendable {
    /// vipl's `PoserConstants.minimumScore`.
    public var minimumScore: Float

    public init(minimumScore: Float = 0.3) { self.minimumScore = minimumScore }

    public func isValid(_ g: Golfer) -> Bool {
        if g.score < minimumScore
            || g.leftHip.score < minimumScore || g.rightHip.score < minimumScore
            || g.leftKnee.score < minimumScore || g.rightKnee.score < minimumScore
            || (g.leftAnkle.score < minimumScore && g.rightAnkle.score < minimumScore) {
            return false
        }

        // `y` grows downward, so "below" is a larger y. Only judged when both
        // joints were confidently seen — an unseen ankle must not fail a pose.
        func isBelow(_ a: GolferBodyPoint, _ b: GolferBodyPoint) -> Bool {
            a.score >= minimumScore && b.score >= minimumScore && a.orgPt.y > b.orgPt.y
        }
        if isBelow(g.rightShoulder, g.rightKnee) || isBelow(g.rightShoulder, g.leftKnee)
            || isBelow(g.leftShoulder, g.rightKnee) || isBelow(g.leftShoulder, g.leftKnee)
            || isBelow(g.rightKnee, g.rightAnkle) || isBelow(g.rightKnee, g.leftAnkle)
            || isBelow(g.leftKnee, g.rightAnkle) || isBelow(g.leftKnee, g.leftAnkle) {
            return false
        }

        // Both hands on the club: a third of a hip-to-knee apart at most. **In
        // units, not pixels** — the same swing filmed from twice as far away is
        // the same swing.
        if g.leftWrist.score >= minimumScore, g.rightWrist.score >= minimumScore,
           g.unit > 0, g.leftWrist.orgPt.distance(to: g.rightWrist.orgPt) > g.unit / 3.0 {
            return false
        }
        return true
    }
}

extension CGPoint {
    public func midPoint(to other: CGPoint) -> CGPoint {
        CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
    }

    public func distance(to other: CGPoint) -> Double {
        let dx = Double(x - other.x), dy = Double(y - other.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
