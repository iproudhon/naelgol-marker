import Foundation
import AVFoundation

/// Writing a trimmed copy of a swing.
///
/// **In `NaelvolCore` rather than beside the player**, so the rule below is
/// pinned by a test on a Mac: the player lives in an iOS-only target, and an
/// export that quietly re-encodes or quietly drops the course and hole is exactly
/// the kind of thing that is only noticed a week later on a phone.
public enum SwingExport {
    /// Export `range` of `url` to `destination`.
    ///
    /// **Passthrough unless a composition forces otherwise.** vipl exports every
    /// trim through `HEVCHighestQuality`, which re-encodes — and a 240 fps clip is
    /// the one property the swing exists for, put through a preset that need not
    /// preserve it.
    ///
    /// **The source's metadata is carried across explicitly.** A trim that loses
    /// the course and hole leaves a clip nobody can find again, and there is no
    /// index to recover it from: the file is the record.
    public static func trim(_ url: URL, range: ClosedRange<Double>, to destination: URL,
                            composition: AVVideoComposition? = nil) async throws {
        let asset = AVURLAsset(url: url)
        let preset = composition == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHEVCHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SwingMetadataError.exportUnavailable
        }
        export.outputURL = destination
        export.outputFileType = .mov
        export.videoComposition = composition
        export.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        export.metadata = (try? await asset.load(.metadata)) ?? []
        await export.export()
        if let error = export.error {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw SwingMetadataError.exportFailed(export.status)
        }
    }
}
