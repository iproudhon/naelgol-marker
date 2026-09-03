#if os(iOS)
import AVFoundation
import SwiftUI
import NaelvolCapture

/// The camera's own layer, wrapped.
///
/// One of the three places this package uses UIKit at all — a preview layer, a
/// player layer and nothing else. Everything around them is SwiftUI.
public struct CameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession
    /// **Set explicitly rather than left automatic**, so the preview and the recording cannot
    /// disagree: the preview layer has its own connection, and a golfer framing a swing in a
    /// mirrored preview that records un-mirrored gets a clip that is reversed against what they
    /// were looking at.
    public let mirrored: Bool
    /// Degrees, matching the capture connection's. Set together with the mirroring, because a
    /// flip is about the *rotated* picture's vertical axis: mirror a landscape frame and then
    /// turn it into portrait and the result is upside down rather than side-swapped.
    public let rotationAngle: CGFloat

    public init(session: AVCaptureSession, mirrored: Bool = false, rotationAngle: CGFloat = 90) {
        self.session = session
        self.mirrored = mirrored
        self.rotationAngle = rotationAngle
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layer.session = session
        view.layer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        apply(to: view)
        return view
    }

    public func updateUIView(_ view: PreviewView, context: Context) {
        if view.layer.session !== session { view.layer.session = session }
        apply(to: view)
    }

    private func apply(to view: PreviewView) {
        guard let connection = view.layer.connection else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        }
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    /// A view **backed by** the preview layer rather than one that adds a
    /// sublayer: a sublayer has to be resized by hand on every layout pass, and
    /// the frame it misses is the one somebody is filming.
    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public override var layer: AVCaptureVideoPreviewLayer {
            super.layer as! AVCaptureVideoPreviewLayer
        }
    }
}
#endif
