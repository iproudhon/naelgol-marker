#if os(iOS)
import SwiftUI
import NaelvolPose

/// How a skeleton is painted. One place, so the overlay drawn over a live preview
/// and the one drawn over a played-back frame cannot drift into two skeletons
/// that disagree.
public struct PoseStyle: Sendable {
    public var face = Color(red: 1, green: 0.5, blue: 0)
    public var left = Color(red: 0, green: 0.5, blue: 0.5)
    public var right = Color(red: 0.5, green: 0, blue: 0.5)
    /// The hands on the club, in red, because it is the one point a golfer is
    /// actually reading.
    public var wrist = Color.red
    public var bone = Color.gray
    public var dotRadius: CGFloat = 5
    public var lineWidth: CGFloat = 2
    public var minimumScore: Float = 0.3

    public init() {}

    public func color(for part: GolferPart) -> Color {
        switch PoseSkeleton.group(of: part) {
        case .face: return face
        case .left: return left
        case .right: return right
        case .wrist: return wrist
        }
    }
}

/// The skeleton, drawn in a `Canvas` over whatever is behind it.
///
/// **The pose is in the frame's pixel coordinates**, so the view is told the
/// frame's size and scales — the same rule as the hole view's projection: draw
/// through one mapping or a tap lands somewhere other than the finger.
public struct PoseOverlay: View {
    public var pose: Golfer?
    /// Earlier poses, drawn faded: the freeze/ghost stack.
    public var ghosts: [Golfer]
    public var frameSize: CGSize
    public var style: PoseStyle

    public init(pose: Golfer?, ghosts: [Golfer] = [], frameSize: CGSize, style: PoseStyle = PoseStyle()) {
        self.pose = pose
        self.ghosts = ghosts
        self.frameSize = frameSize
        self.style = style
    }

    public var body: some View {
        Canvas { context, size in
            guard frameSize.width > 0, frameSize.height > 0 else { return }
            // Aspect-fit, matching `.resizeAspect` on the layer underneath.
            let scale = min(size.width / frameSize.width, size.height / frameSize.height)
            let dx = (size.width - frameSize.width * scale) / 2
            let dy = (size.height - frameSize.height * scale) / 2
            func project(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * scale + dx, y: p.y * scale + dy)
            }
            for (index, ghost) in ghosts.enumerated() {
                // Older ghosts are fainter, so a stack reads as a sequence rather
                // than as a crowd.
                let opacity = 0.15 + 0.25 * Double(index + 1) / Double(max(1, ghosts.count))
                draw(ghost, in: &context, project: project, opacity: opacity)
            }
            if let pose { draw(pose, in: &context, project: project, opacity: 1) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ golfer: Golfer, in context: inout GraphicsContext,
                      project: (CGPoint) -> CGPoint, opacity: Double) {
        var bones = Path()
        for bone in PoseSkeleton.bones {
            let a = golfer[bone.from], b = golfer[bone.to]
            guard a.score >= style.minimumScore, b.score >= style.minimumScore else { continue }
            bones.move(to: project(a.pt))
            bones.addLine(to: project(b.pt))
        }
        context.stroke(bones, with: .color(style.bone.opacity(opacity)), lineWidth: style.lineWidth)

        for part in PoseSkeleton.drawOrder {
            let point = golfer[part]
            guard point.score >= style.minimumScore else { continue }
            let center = project(point.pt)
            let r = style.dotRadius / 2
            let rect = CGRect(x: center.x - r, y: center.y - r, width: style.dotRadius, height: style.dotRadius)
            context.fill(Path(ellipseIn: rect), with: .color(style.color(for: part).opacity(opacity)))
        }
    }
}
#endif
