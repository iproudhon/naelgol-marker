import Foundation
import AVFoundation
import CoreGraphics

/// Which way was down, frame by frame, read back off a recording.
///
/// The capture side writes one sample per video frame into a timed metadata
/// track; this reads them all at load, because a swing is seconds long and a
/// lookup per frame through `AVPlayerItemMetadataOutput` arrives *after* the frame
/// it describes.
public struct GravityTrack: Sendable {
    /// naelvol's key, shared with the recorder so the two cannot drift.
    public static let key = "com.naelgol.naelvol.gravity"
    public static let identifier = AVMetadataIdentifier(rawValue: "mdta/\(key)")
    /// vipl writes its gravity under a `common` title item. Read too, so a swing
    /// filmed in vipl levels here.
    public static let viplIdentifier = AVMetadataIdentifier.commonIdentifierTitle

    public struct Sample: Sendable {
        public let time: Double
        public let x: Double
        public let y: Double
        public let z: Double
    }

    public private(set) var samples: [Sample] = []

    public init(samples: [Sample] = []) { self.samples = samples }

    public var isEmpty: Bool { samples.isEmpty }

    public static func load(from asset: AVAsset) async -> GravityTrack {
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata),
              let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return GravityTrack() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return GravityTrack() }
        reader.add(output)
        reader.startReading()

        var samples: [Sample] = []
        while let buffer = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            guard let group = try? AVTimedMetadataGroup(sampleBuffer: buffer) else { continue }
            for item in group.items {
                guard item.identifier == identifier || item.identifier == viplIdentifier,
                      let text = item.stringValue else { continue }
                let parts = text.split(separator: " ").compactMap { Double($0) }
                guard parts.count == 3 else { continue }
                samples.append(Sample(time: time, x: parts[0], y: parts[1], z: parts[2]))
            }
        }
        return GravityTrack(samples: samples)
    }

    public func sample(at time: Double) -> Sample? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count - 1, best: Int?
        while low <= high {
            let mid = (low + high) / 2
            if samples[mid].time <= time { best = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return samples[best ?? 0]
    }

    /// How far the phone was rolled, in radians, for levelling the picture.
    ///
    /// **Only the x/y components matter.** A phone lying flat has gravity almost
    /// entirely in z, where roll is undefined — so a reading that flat reports
    /// nil rather than a number that spins with the noise.
    public func rollAngle(at time: Double) -> CGFloat? {
        guard let s = sample(at: time) else { return nil }
        let magnitude = (s.x * s.x + s.y * s.y).squareRoot()
        guard magnitude > 0.2 else { return nil }
        return CGFloat(atan2(s.x, -s.y))
    }
}
