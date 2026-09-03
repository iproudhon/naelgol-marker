#if os(iOS)
import SwiftUI
import NaelvolCore

/// What to do with the gravity a recording carries.
///
/// vipl's four modes, kept and kept in this order, because it is a cycle a thumb walks through:
/// **none → grid → axis → tilt → none**. The distinction that matters is *what rotates*: in
/// `grid` the picture is left alone and the horizon is drawn tilted over it, in `axis` and `tilt`
/// the picture is rotated level and the horizon is upright or absent.
public enum GravityMode: String, CaseIterable, Sendable {
    case none, grid, axis, tilt

    public var label: String {
        switch self {
        case .none: return "Gravity off"
        case .grid: return "Tilted grid"
        case .axis: return "Level + grid"
        case .tilt: return "Level"
        }
    }

    public var symbol: String {
        switch self {
        case .none: return "circle"
        case .grid: return "grid"
        case .axis: return "level"
        case .tilt: return "rotate.right"
        }
    }

    public var next: GravityMode {
        let all = GravityMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// How far to rotate the *picture*. `grid` leaves it alone — that is the whole point of the
    /// mode: it shows how far off level the phone was.
    public func pictureRotation(roll: CGFloat?) -> CGFloat {
        guard let roll else { return 0 }
        switch self {
        case .none, .grid: return 0
        case .axis, .tilt: return -roll
        }
    }

    /// How far to rotate the *horizon*. In `axis` the picture has already been levelled, so the
    /// grid is upright; in `grid` it carries the tilt.
    public func gridRotation(roll: CGFloat?) -> CGFloat? {
        guard let roll else { return nil }
        switch self {
        case .none, .tilt: return nil
        case .grid: return roll
        case .axis: return 0
        }
    }
}

/// The horizon, the vertical, and a grid between them.
///
/// Drawn from the recording's own gravity track, so it says which way was down **when the swing
/// was filmed** — not which way is down now, which is a phone on a desk.
struct GravityOverlay: View {
    var rotation: CGFloat
    var color: Color = .green

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = max(size.width, size.height)
            let step = reach / 8

            var grid = Path()
            var index = -8
            while index <= 8 {
                let offset = CGFloat(index) * step
                grid.move(to: CGPoint(x: center.x - reach, y: center.y + offset))
                grid.addLine(to: CGPoint(x: center.x + reach, y: center.y + offset))
                grid.move(to: CGPoint(x: center.x + offset, y: center.y - reach))
                grid.addLine(to: CGPoint(x: center.x + offset, y: center.y + reach))
                index += 1
            }
            context.stroke(grid, with: .color(color.opacity(0.18)), lineWidth: 0.5)

            // The horizon and the vertical are drawn heavier than the grid: they are the two
            // lines a golfer actually reads a swing plane against.
            var axes = Path()
            axes.move(to: CGPoint(x: center.x - reach, y: center.y))
            axes.addLine(to: CGPoint(x: center.x + reach, y: center.y))
            axes.move(to: CGPoint(x: center.x, y: center.y - reach))
            axes.addLine(to: CGPoint(x: center.x, y: center.y + reach))
            context.stroke(axes, with: .color(color.opacity(0.75)), lineWidth: 1.5)
        }
        .rotationEffect(.radians(Double(rotation)))
        .allowsHitTesting(false)
    }
}

/// The golfer's silhouette, live or frozen.
struct MaskOverlay: View {
    /// Newest last. Older ones are fainter, so a stack reads as a sequence.
    var masks: [CGImage]
    var frameSize: CGSize
    var color: Color = .cyan

    var body: some View {
        Canvas { context, size in
            guard frameSize.width > 0, frameSize.height > 0 else { return }
            let scale = min(size.width / frameSize.width, size.height / frameSize.height)
            let drawn = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
            let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
            for (index, mask) in masks.enumerated() {
                let opacity = masks.count == 1 ? 0.55
                    : 0.2 + 0.35 * Double(index + 1) / Double(masks.count)
                var layer = context
                layer.opacity = opacity
                layer.draw(Image(decorative: mask, scale: 1, orientation: .up),
                           in: CGRect(origin: origin, size: drawn))
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}
#endif
