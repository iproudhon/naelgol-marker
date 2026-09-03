import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import Vision

/// The golfer cut out of the frame — vipl's "segments" and "freeze body".
///
/// **Vision, not the DeepLabV3 model vipl carries.** `VNGeneratePersonSegmentationRequest` needs
/// no model file, is newer than the DeepLab build, and is a *different* engine from the pose
/// path — so shipping it cannot disturb the "same keypoints as vipl" gate, which is the one
/// thing this port is measured against.
public final class PersonSegmenter: @unchecked Sendable {
    /// `.balanced` rather than `.accurate`: a silhouette is stacked as a ghost and looked at
    /// against another silhouette, and the accurate level costs several times as much for an
    /// edge nobody is reading at that size.
    public var quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced

    private let request = VNGeneratePersonSegmentationRequest()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var running = false

    public init() {}

    /// A mask the size of the frame: white where the person is, black elsewhere.
    ///
    /// Returns nil rather than throwing when it is already busy — the same rule as `MoveNet`:
    /// the overlay wants the *latest* frame, and a queue of stale masks is a silhouette that
    /// lags the swing.
    public func mask(for pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard !running else { return nil }
        running = true
        defer { running = false }

        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return nil }

        // The mask comes back at the model's own resolution, so it is scaled to the frame here
        // rather than at draw time: the overlay is aligned to the *frame*, and a mask that
        // carries its own size would need a second mapping nothing else uses.
        let mask = CIImage(cvPixelBuffer: result.pixelBuffer)
        let frame = CIImage(cvPixelBuffer: pixelBuffer).extent
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: frame.width / mask.extent.width,
            y: frame.height / mask.extent.height))
        return context.createCGImage(scaled, from: frame)
    }
}
