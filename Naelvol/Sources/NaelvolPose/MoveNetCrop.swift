import Foundation
import CoreGraphics

/// A rectangle in **normalised** image coordinates, 0…1.
public struct RectF: Hashable, Sendable {
    public var left: CGFloat
    public var top: CGFloat
    public var right: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: CGFloat { right - left }
    public var height: CGFloat { bottom - top }
    public var rect: CGRect { CGRect(x: left, y: top, width: width, height: height) }

    public func scaled(width imageWidth: CGFloat, height imageHeight: CGFloat) -> CGRect {
        CGRect(x: left * imageWidth, y: top * imageHeight,
               width: width * imageWidth, height: height * imageHeight)
    }
}

/// MoveNet's smart cropping, which is the reason the model tracks a moving golfer
/// at all: each frame is cropped to a square around the previous frame's hips, so
/// the 192- or 256-pixel input is spent on the body rather than on the car park.
///
/// **Pure arithmetic, deliberately on this side of the interpreter wall** — it is
/// the part with real logic in it, and it is testable on a Mac where the engine is
/// not. Ported from Google's sample with its behaviour intact, including the one
/// thing that looks wrong (see `bodyDistances`).
public struct MoveNetCrop: Sendable {
    public var torsoExpansionRatio: CGFloat = 1.9
    public var bodyExpansionRatio: CGFloat = 1.2
    public var minCropKeyPointScore: Float = 0.2

    public init() {}

    /// The whole image padded to a square. Used for the first frame and whenever
    /// the torso is not confidently visible.
    public func initialRegion(imageWidth: CGFloat, imageHeight: CGFloat) -> RectF {
        guard imageWidth > 0, imageHeight > 0 else { return RectF(left: 0, top: 0, right: 1, bottom: 1) }
        if imageWidth > imageHeight {
            let width = imageHeight / imageWidth
            let xMin = ((imageWidth - imageHeight) / 2) / imageWidth
            return RectF(left: xMin, top: 0, right: xMin + width, bottom: 1)
        } else {
            let height = imageWidth / imageHeight
            let yMin = ((imageHeight - imageWidth) / 2) / imageHeight
            return RectF(left: 0, top: yMin, right: 1, bottom: yMin + height)
        }
    }

    /// Where to crop the *next* frame, from this frame's keypoints.
    public func nextRegion(keyPoints: [KeyPoint], imageWidth: CGFloat, imageHeight: CGFloat) -> RectF {
        guard torsoVisible(keyPoints) else {
            return initialRegion(imageWidth: imageWidth, imageHeight: imageHeight)
        }
        let centerX = (keyPoints[BodyPart.leftHip.position].coordinate.x
                       + keyPoints[BodyPart.rightHip.position].coordinate.x) / 2
        let centerY = (keyPoints[BodyPart.leftHip.position].coordinate.y
                       + keyPoints[BodyPart.rightHip.position].coordinate.y) / 2

        let d = distances(keyPoints: keyPoints, centerX: centerX, centerY: centerY)
        var half = [d.maxTorsoX * torsoExpansionRatio, d.maxTorsoY * torsoExpansionRatio,
                    d.maxBodyX * bodyExpansionRatio, d.maxBodyY * bodyExpansionRatio].max() ?? 0
        half = min(half, [centerX, imageWidth - centerX, centerY, imageHeight - centerY].max() ?? 0)

        if half > max(imageWidth, imageHeight) / 2 {
            return initialRegion(imageWidth: imageWidth, imageHeight: imageHeight)
        }
        let cornerX = centerX - half, cornerY = centerY - half, length = half * 2
        return RectF(left: max(cornerX, 0) / imageWidth,
                     top: max(cornerY, 0) / imageHeight,
                     right: min((cornerX + length) / imageWidth, 1),
                     bottom: min((cornerY + length) / imageHeight, 1))
    }

    /// One shoulder **and** one hip seen confidently. Less than that and a crop
    /// around "the hips" is a crop around a guess.
    public func torsoVisible(_ keyPoints: [KeyPoint]) -> Bool {
        guard keyPoints.count >= BodyPart.allCases.count else { return false }
        let hips = keyPoints[BodyPart.leftHip.position].score > minCropKeyPointScore
            || keyPoints[BodyPart.rightHip.position].score > minCropKeyPointScore
        let shoulders = keyPoints[BodyPart.leftShoulder.position].score > minCropKeyPointScore
            || keyPoints[BodyPart.rightShoulder.position].score > minCropKeyPointScore
        return hips && shoulders
    }

    struct Distances { var maxTorsoX: CGFloat; var maxTorsoY: CGFloat; var maxBodyX: CGFloat; var maxBodyY: CGFloat }

    func distances(keyPoints: [KeyPoint], centerX: CGFloat, centerY: CGFloat) -> Distances {
        let torso = [BodyPart.leftShoulder, .rightShoulder, .leftHip, .rightHip].map { $0.position }
        let maxTorsoX = torso.map { abs(centerX - keyPoints[$0].coordinate.x) }.max() ?? 0
        let maxTorsoY = torso.map { abs(centerY - keyPoints[$0].coordinate.y) }.max() ?? 0

        // **Google's sample filters `score < minCropKeyPointScore` here** — the
        // *un*confident points — where the name and every other use say it means
        // the confident ones. Kept exactly as it is, because vipl runs this and
        // the gate for this port is producing vipl's keypoints, not producing
        // better ones. Changing it is a measurement with a before and an after.
        let body = keyPoints.filter { $0.score < minCropKeyPointScore }
        let maxBodyX = body.map { abs(centerX - $0.coordinate.x) }.max() ?? 0
        let maxBodyY = body.map { abs(centerY - $0.coordinate.y) }.max() ?? 0

        return Distances(maxTorsoX: maxTorsoX, maxTorsoY: maxTorsoY, maxBodyX: maxBodyX, maxBodyY: maxBodyY)
    }
}
