#if os(iOS)
import SwiftUI

/// Two handles and the span between them: the trim range, and the loop.
///
/// SwiftUI rather than a wrapped `UISlider` pair — the handles have to be
/// draggable independently and the *span* has to be draggable as a unit, which is
/// three gestures a stock slider does not have.
public struct RangeSlider: View {
    @Binding public var lower: Double
    @Binding public var upper: Double
    public var bounds: ClosedRange<Double>
    /// Where playback is now, drawn as a hairline inside the span.
    public var playhead: Double?
    public var onScrub: ((Double) -> Void)?

    private let handleWidth: CGFloat = 22

    public init(lower: Binding<Double>, upper: Binding<Double>, bounds: ClosedRange<Double>,
                playhead: Double? = nil, onScrub: ((Double) -> Void)? = nil) {
        self._lower = lower
        self._upper = upper
        self.bounds = bounds
        self.playhead = playhead
        self.onScrub = onScrub
    }

    private var span: Double { max(bounds.upperBound - bounds.lowerBound, 0.0001) }

    private func x(_ value: Double, width: CGFloat) -> CGFloat {
        CGFloat((min(max(value, bounds.lowerBound), bounds.upperBound) - bounds.lowerBound) / span) * width
    }

    private func value(at px: CGFloat, width: CGFloat) -> Double {
        bounds.lowerBound + Double(min(max(px, 0), width) / max(width, 1)) * span
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)

                Rectangle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: max(0, x(upper, width: width) - x(lower, width: width)), height: 26)
                    .offset(x: x(lower, width: width))
                    // Dragging the span scrubs, which is what a thumb reaches for
                    // first; the handles below own the ends.
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        onScrub?(value(at: g.location.x, width: width))
                    })

                if let playhead {
                    Rectangle().fill(.primary).frame(width: 1.5, height: 30)
                        .offset(x: x(playhead, width: width))
                        .allowsHitTesting(false)
                }

                handle(at: x(lower, width: width))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        lower = min(value(at: g.location.x, width: width), upper - 0.05)
                        onScrub?(lower)
                    })
                handle(at: x(upper, width: width))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        upper = max(value(at: g.location.x, width: width), lower + 0.05)
                        onScrub?(upper)
                    })
            }
            .frame(height: 34)
        }
        .frame(height: 34)
    }

    private func handle(at position: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: 10, height: 30)
            // The drawn handle is 10 points; the grabbable one is more than
            // twice that, because a gloved thumb on a phone in the sun is not a
            // mouse pointer.
            .frame(width: handleWidth, height: 40)
            .contentShape(Rectangle())
            .offset(x: position - handleWidth / 2)
    }
}
#endif
