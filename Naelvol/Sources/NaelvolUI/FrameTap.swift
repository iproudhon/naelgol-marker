#if os(iOS)
import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

/// The frame the player is showing *right now*, as pixels.
///
/// The pose track is extracted ahead of time and looked up by time, but a person mask cannot be:
/// one silhouette per frame of a 240 fps clip is hundreds of megabytes. So the mask is computed
/// from the live frame, which means reaching into the player's own output.
///
/// **Driven by a `CADisplayLink` and throttled**, because `copyPixelBuffer` at display rate over
/// a slow-motion clip is the one thing that makes scrubbing stutter. `hz` is a parameter for the
/// same reason the capture path's is: what a phone can afford here is unmeasured.
@MainActor
final class FrameTap {
    var hz: Double = 12
    private(set) var isRunning = false

    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    private var link: CADisplayLink?
    private weak var item: AVPlayerItem?
    private var last = CFTimeInterval(0)
    private let handler: (CVPixelBuffer, CMTime) -> Void

    init(handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.handler = handler
    }

    func attach(to item: AVPlayerItem?) {
        detach()
        guard let item else { return }
        item.add(output)
        self.item = item
    }

    func detach() {
        stop()
        if let item { item.remove(output) }
        item = nil
    }

    func start() {
        guard !isRunning, item != nil else { return }
        isRunning = true
        let link = CADisplayLink(target: DisplayProxy { [weak self] in self?.tick() }, selector: #selector(DisplayProxy.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    /// Pull one frame **now**, whatever the throttle says — what a paused screen needs when a
    /// toggle is flipped or a step lands, since no display link tick will bring a new frame.
    @discardableResult
    func pullNow() -> Bool {
        guard let item else { return false }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) || true,
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return false }
        handler(buffer, time)
        return true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard now - last >= 1 / max(1, hz) else { return }
        last = now
        guard let item else { return }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        handler(buffer, time)
    }

    /// `CADisplayLink` retains its target, so the closure is held by this small proxy rather
    /// than by the tap — otherwise the tap can never be released and its player item stays alive
    /// with it.
    private final class DisplayProxy: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func fire() { body() }
    }
}
#endif
