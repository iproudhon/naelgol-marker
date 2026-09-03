import Foundation
import AVFoundation
import CoreGraphics

/// Every pose in one video, in time order.
///
/// **Alive by construction, unlike vipl's**, where whole-video extraction is
/// written and commented out at both call sites — a golf app whose pose path never
/// runs over a recorded swing is the thing being fixed.
///
/// A plain array, not a ring: a swing is seconds long, and the ring existed to
/// bound a live capture that this type is not used for. Poses are appended in
/// time order and looked up by binary search.
public final class PoseCollection: @unchecked Sendable {
    public private(set) var frames: [Golfer] = []
    public var minimumScore: Float

    public init(minimumScore: Float = 0.3) { self.minimumScore = minimumScore }

    public var count: Int { frames.count }
    public var startTime: Double { frames.first?.time ?? 0 }
    public var endTime: Double { frames.last?.time ?? 0 }
    public var duration: Double { endTime - startTime }
    public var isEmpty: Bool { frames.isEmpty }

    public func clear() { frames.removeAll(keepingCapacity: true) }

    /// Append a pose and derive its velocity and acceleration.
    ///
    /// Derivatives are computed **against the previous frames in which that joint
    /// was actually seen**, not against the previous frame: a joint the model lost
    /// for two frames would otherwise report an enormous velocity when it comes
    /// back, which is exactly the moment — the top of the backswing, impact — that
    /// a golfer is looking at.
    public func append(_ pose: Golfer) {
        var g = pose
        for part in GolferPart.allCases {
            let index = part.index
            var previous: (Golfer, GolferBodyPoint)?
            var earlier: (Golfer, GolferBodyPoint)?
            var i = frames.count - 1
            while i >= 0, earlier == nil {
                let candidate = frames[i]
                if candidate.score > minimumScore, let point = candidate.points[index],
                   point.score > minimumScore {
                    if previous == nil { previous = (candidate, point) }
                    else { earlier = (candidate, point) }
                }
                i -= 1
            }
            guard let (pg, pp) = previous, let point = g.points[index] else { continue }
            let dt = g.time - pg.time
            guard dt > 0 else { continue }
            let vx = (Double(point.pt.x) - Double(pp.pt.x)) / dt
            let vy = (Double(point.pt.y) - Double(pp.pt.y)) / dt
            g.points[index]?.vx = vx
            g.points[index]?.vy = vy
            // Acceleration needs a *third* frame, because it is the change in a
            // velocity that itself needed two. vipl's version reads the previous
            // point's `vx` while dividing by this frame's interval and never
            // checks that the third frame exists; both are fixed here.
            if let (eg, _) = earlier, pg.time > eg.time {
                g.points[index]?.ax = (vx - pp.vx) / dt
                g.points[index]?.ay = (vy - pp.vy) / dt
            }
        }
        frames.append(g)
    }

    /// The pose at a time, or the nearest one before it.
    ///
    /// `tolerance` is a **millisecond**, because a player's clock and a frame's
    /// presentation time agree to about that and an exact `==` on a `Double`
    /// never matches.
    public func pose(at time: Double, tolerance: Double = 0.001) -> Golfer? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count - 1, best: Int?
        while low <= high {
            let mid = (low + high) / 2
            let t = frames[mid].time
            if abs(t - time) <= tolerance { return frames[mid] }
            if t < time { best = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return best.map { frames[$0] }
    }

    public func index(at time: Double) -> Int? {
        guard let pose = pose(at: time) else { return nil }
        return frames.firstIndex { $0.time == pose.time }
    }

    /// Run an estimator over every frame of a video.
    ///
    /// Reads with `AVAssetReader` rather than seeking with an image generator:
    /// a 240 fps swing is a few hundred frames and a seek per frame is an order of
    /// magnitude slower. `progress` is called on the calling task, so a caller
    /// hopping to the main actor is what puts it on screen.
    public func load(asset: AVAsset, estimator: PoseEstimating,
                     validator: PoseValidator = PoseValidator(),
                     progress: ((Double) -> Void)? = nil) async throws {
        clear()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let (person, _) = try? estimator.estimateSinglePose(on: buffer) else { continue }
            var golfer = Golfer(person, time: time)
            golfer.time = time
            // **Invalid poses are dropped, not stored.** A frame where the model
            // found a spectator is worse than a gap: the gap is visible, the
            // spectator is a skeleton drawn over a golfer.
            if validator.isValid(golfer) { append(golfer) }
            if duration > 0 { progress?(min(1, time / duration)) }
        }
        progress?(1)
    }
}
