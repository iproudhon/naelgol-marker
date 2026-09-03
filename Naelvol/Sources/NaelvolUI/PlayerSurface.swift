#if os(iOS)
import AVFoundation
import SwiftUI

/// The video, and nothing else.
///
/// Backed by `AVPlayerLayer` rather than SwiftUI's `VideoPlayer`, for two reasons
/// this app cannot do without: no transport controls of its own (the ones below
/// are frame-accurate and `VideoPlayer`'s are not), and a layer whose frame the
/// pose overlay can be aligned to exactly.
public struct PlayerSurface: UIViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) { self.player = player }

    public func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .black
        view.layer.player = player
        view.layer.videoGravity = .resizeAspect
        return view
    }

    public func updateUIView(_ view: SurfaceView, context: Context) {
        if view.layer.player !== player { view.layer.player = player }
    }

    public final class SurfaceView: UIView {
        public override class var layerClass: AnyClass { AVPlayerLayer.self }
        public override var layer: AVPlayerLayer { super.layer as! AVPlayerLayer }
    }
}
#endif
