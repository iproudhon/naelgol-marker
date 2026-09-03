#if os(iOS)
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import NaelvolCore
import NaelvolPose
import UIKit

/// Playing one swing, frame by frame.
///
/// The half of the player that is not a view: the `AVPlayer`, the trim range, the pose track and
/// the silhouettes over the video, the recording's own gravity, and the export that writes an
/// edit back.
@MainActor
public final class SwingPlayerModel: ObservableObject {
    @Published public private(set) var swing: Swing
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var frameRate: Double = 30
    @Published public private(set) var naturalSize: CGSize = .zero
    @Published public var currentTime: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public var rate: Float = 1
    @Published public var loops = true
    @Published public var muted = false

    // Overlays
    @Published public var showsPose = false
    @Published public var showsSegments = false
    @Published public private(set) var pose: Golfer?
    @Published public private(set) var ghosts: [Golfer] = []
    @Published public private(set) var mask: CGImage?
    @Published public private(set) var frozenMasks: [CGImage] = []
    @Published public private(set) var extracting = false
    @Published public private(set) var extractionProgress: Double = 0
    @Published public private(set) var segmenting = false

    // Gravity
    @Published public var gravityMode: GravityMode = .grid {
        didSet { UserDefaults.standard.set(gravityMode.rawValue, forKey: Self.gravityKey) }
    }

    @Published public private(set) var status: String?

    /// The trim range. Starts as the whole file; **an export takes exactly this**, so the loop
    /// the golfer set up is the clip they save.
    @Published public var lower: Double = 0
    @Published public var upper: Double = 0

    public let player = AVPlayer()
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var poses = PoseCollection()
    private var gravity = GravityTrack()
    private let segmenter = PersonSegmenter()
    private var frames: FrameTap?

    static let gravityKey = "naelvol.gravity.mode"
    static let mutedKey = "naelvol.player.muted"

    /// Runs pose estimation over the whole video. Supplied by the host, because the engine lives
    /// in another package.
    public var estimator: (() async -> PoseEstimating?)?
    /// Where a *new* file goes when the golfer saves a trim as a copy.
    public var nextURL: (() throws -> URL)?
    /// Told when *this* swing's file was rewritten, so the library re-reads that one row.
    public var onWrote: ((URL) -> Void)?
    /// Told when a **new** file was written — a rescan, not a reload.
    public var onWroteNew: ((URL) -> Void)?

    public init(swing: Swing) {
        self.swing = swing
        let stored = UserDefaults.standard.string(forKey: Self.gravityKey)
        gravityMode = stored.flatMap(GravityMode.init(rawValue:)) ?? .grid
        muted = UserDefaults.standard.bool(forKey: Self.mutedKey)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: - Loading

    public func load() async {
        let asset = AVURLAsset(url: swing.url)
        let item = AVPlayerItem(asset: asset)
        self.item = item
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        player.isMuted = muted

        if let seconds = try? await asset.load(.duration) {
            duration = CMTimeGetSeconds(seconds)
            if upper == 0 { upper = duration }
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 { frameRate = Double(rate) }
            if let size = try? await track.load(.naturalSize) {
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let applied = size.applying(transform)
                naturalSize = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
        }
        gravity = await GravityTrack.load(from: asset)

        let tap = FrameTap { [weak self] buffer, _ in
            guard let self else { return }
            Task { @MainActor in self.segment(buffer) }
        }
        tap.attach(to: item)
        frames = tap

        // A tenth of a *frame*, not a fixed interval: at 240 fps a 0.1 s observer reports a time
        // twenty-four frames stale, which is a pose overlay drawn over the wrong part of the swing.
        let interval = CMTime(seconds: max(0.004, 1 / (frameRate * 2)), preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            self.currentTime = seconds
            self.pose = self.showsPose ? self.poses.pose(at: seconds) : nil
            if self.isPlaying, self.rate > 0, seconds >= self.upper - 0.001 {
                if self.loops { self.seek(to: self.lower) } else { self.pause() }
            }
            // Reverse play runs off the *lower* end, and `AVPlayer` will not report a rate of
            // zero when it reaches the start — it simply stops delivering frames.
            if self.isPlaying, self.rate < 0, seconds <= self.lower + 0.001 {
                if self.loops { self.seek(to: self.upper) } else { self.pause() }
            }
        }
    }

    public func tearDown() {
        frames?.detach()
        frames = nil
    }

    public var hasGravity: Bool { !gravity.isEmpty }

    /// The recording's own roll at this instant — which way was down **when the swing was
    /// filmed**, not which way is down now.
    public func roll() -> CGFloat? { gravity.rollAngle(at: currentTime) }

    public var pictureRotation: CGFloat { gravityMode.pictureRotation(roll: roll()) }
    public var gridRotation: CGFloat? { gravityMode.gridRotation(roll: roll()) }

    // MARK: - Transport

    public func play() {
        if rate > 0, currentTime >= upper - 0.001 { seek(to: lower) }
        if rate < 0, currentTime <= lower + 0.001 { seek(to: upper) }
        player.rate = rate
        isPlaying = true
        if showsSegments { frames?.start() }
    }

    public func pause() {
        player.pause()
        isPlaying = false
        frames?.stop()
        // A paused screen gets no display-link ticks, so the silhouette for the frame that is
        // actually up has to be asked for explicitly.
        if showsSegments { frames?.pullNow() }
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    public func setRate(_ value: Float) {
        rate = value
        if isPlaying { player.rate = value }
    }

    /// Reverse, at whatever speed is set. Refused when the item cannot do it rather than
    /// silently doing nothing — an `AVPlayerItem` over a codec with sparse keyframes reports
    /// `canPlayReverse == false` and simply stalls.
    public func playBackwards() {
        guard item?.canPlayReverse == true else {
            status = "This clip cannot play backwards."
            return
        }
        setRate(-abs(rate == 0 ? 1 : rate))
        play()
    }

    public func playForwards() {
        setRate(abs(rate == 0 ? 1 : rate))
        play()
    }

    public func toggleMuted() {
        muted.toggle()
        player.isMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
    }

    /// Seeks are **serialised and exact**. A scrub at 240 fps issues seeks faster than they
    /// complete, and a tolerant seek lands on the nearest sync sample — which, in a file with
    /// sparse keyframes, is a different part of the swing.
    private var seeking = false
    private var pendingSeek: Double?

    public func seek(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        currentTime = clamped
        guard !seeking else {
            pendingSeek = clamped
            return
        }
        seeking = true
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.seeking = false
            self.pose = self.showsPose ? self.poses.pose(at: clamped) : nil
            if self.showsSegments, !self.isPlaying { self.frames?.pullNow() }
            if let next = self.pendingSeek {
                self.pendingSeek = nil
                self.seek(to: next)
            }
        }
    }

    public func step(frames count: Int) {
        pause()
        seek(to: currentTime + Double(count) / frameRate)
    }

    // MARK: - Range

    /// vipl's range presets, kept: a window **around the playhead**, in seconds before and after.
    /// A swing is found by scrubbing to impact and then taking a couple of seconds either side,
    /// which is two drags of a handle otherwise.
    public static let rangePresets: [(before: Double, after: Double)] =
        [(0.3, 0.2), (1.75, 1.5), (2.0, 5.0)]

    public func applyRange(before: Double, after: Double) {
        lower = max(0, currentTime - before)
        upper = min(duration, currentTime + after)
    }

    public func resetRange() {
        lower = 0
        upper = duration
    }

    public var isTrimmed: Bool {
        upper > lower && (lower > 0.001 || upper < duration - 0.001)
    }

    // MARK: - Overlays

    /// Extract poses for the whole clip, once, in the background.
    public func extractPoses() async {
        guard !extracting, poses.isEmpty else { return }
        guard let estimator = await estimator?() else {
            status = "No pose model on this phone yet."
            return
        }
        extracting = true
        extractionProgress = 0
        defer { extracting = false }
        let asset = AVURLAsset(url: swing.url)
        let collection = PoseCollection()
        do {
            try await collection.load(asset: asset, estimator: estimator) { [weak self] progress in
                Task { @MainActor in self?.extractionProgress = progress }
            }
            poses = collection
            pose = poses.pose(at: currentTime)
            status = collection.isEmpty ? "No golfer found in this clip." : nil
        } catch {
            status = error.localizedDescription
        }
    }

    /// Turn the skeleton on, reading the clip's poses the first time.
    ///
    /// **Extraction is not automatic**: it decodes every frame, and somebody who opened a clip to
    /// watch it should not pay for that. But it has to happen *here* — the toggle is the only
    /// place that says the golfer wants poses — and the pose is assigned immediately, because a
    /// paused frame is how this screen is used and nothing else would set one until the next scrub.
    public func setShowsPose(_ on: Bool) async {
        showsPose = on
        guard on else {
            pose = nil
            return
        }
        if poses.isEmpty { await extractPoses() }
        refreshPose()
    }

    public func refreshPose() {
        pose = showsPose ? poses.pose(at: currentTime) : nil
    }

    /// Turn the silhouette on. Unlike poses this is **never precomputed**: one mask per frame of
    /// a 240 fps clip is hundreds of megabytes, so it is cut from the frame that is up.
    public func setShowsSegments(_ on: Bool) {
        showsSegments = on
        if on {
            if isPlaying { frames?.start() } else { frames?.pullNow() }
        } else {
            frames?.stop()
            mask = nil
        }
    }

    private func segment(_ buffer: CVPixelBuffer) {
        guard showsSegments, !segmenting else { return }
        segmenting = true
        let segmenter = self.segmenter
        Task.detached(priority: .userInitiated) {
            let cut = segmenter.mask(for: buffer)
            await MainActor.run {
                self.segmenting = false
                if let cut { self.mask = cut }
            }
        }
    }

    /// Freeze the current pose into the ghost stack. **Ghosts are a comparison, so they are
    /// capped**: past half a dozen the screen is a crowd and the swing under it is invisible.
    public func freezePose() {
        guard let pose else {
            status = "Turn the pose on first."
            return
        }
        ghosts.append(pose)
        if ghosts.count > 6 { ghosts.removeFirst() }
    }

    /// Freeze the current silhouette. Together with the pose this is vipl's "Freeze" — the two
    /// are separate because the body is what shows a change of posture and the skeleton is what
    /// shows a change of plane, and a golfer usually wants one of them.
    public func freezeBody() {
        guard let mask else {
            status = "Turn segments on first."
            return
        }
        frozenMasks.append(mask)
        if frozenMasks.count > 4 { frozenMasks.removeFirst() }
    }

    public func freezeBoth() {
        freezePose()
        freezeBody()
    }

    public func resetOverlays() {
        ghosts.removeAll()
        frozenMasks.removeAll()
        status = nil
    }

    /// What the mask overlay draws: every frozen silhouette, and the live one last.
    public var visibleMasks: [CGImage] {
        var out = frozenMasks
        if showsSegments, let mask { out.append(mask) }
        return out
    }

    // MARK: - Editing

    /// Write the trimmed range out.
    ///
    /// The export itself is `SwingExport.trim` in `NaelvolCore`, where a test can reach it — the
    /// rules that matter (passthrough unless a composition, and the source's metadata carried
    /// across) are the ones that go wrong silently.
    public func exportTrim(asNewFile: Bool) async {
        guard upper > lower else { return }
        let destination: URL
        do {
            destination = asNewFile ? try (nextURL?() ?? { throw SwingSourceError.readOnly }())
                                    : FileManager.default.temporaryDirectory
                                        .appendingPathComponent("naelvol-trim-\(UUID().uuidString).mov")
        } catch {
            status = error.localizedDescription
            return
        }

        do {
            try await SwingExport.trim(swing.url, range: lower...upper, to: destination)
        } catch {
            status = error.localizedDescription
            return
        }

        if asNewFile {
            // **A new file, so the library rescans rather than reloading a row**: there is no row
            // for a file that did not exist a moment ago, and reloading the original leaves the
            // copy invisible until somebody pulls to refresh.
            onWroteNew?(destination)
            status = "Saved as \(destination.lastPathComponent)."
        } else {
            // Replacing the file being played: the item has to go first, or the player holds a
            // file that no longer exists and renders black.
            frames?.detach()
            player.replaceCurrentItem(with: nil)
            do {
                try SwingMetadata.replace(swing.url, with: destination)
                onWrote?(swing.url)
                lower = 0
                upper = 0
                await load()
                status = "Trimmed."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    public func update(swing: Swing) { self.swing = swing }

    public func clearStatus() { status = nil }

    // MARK: - Info

    /// What the file says about itself. vipl prints this as raw JSON; the fields are the same
    /// ones, named.
    public var info: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("File", swing.url.lastPathComponent))
        if let created = swing.created {
            rows.append(("Filmed", created.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(("Duration", Swing.durationText(duration)))
        if naturalSize != .zero {
            rows.append(("Size", "\(Int(naturalSize.width))×\(Int(naturalSize.height))"))
        }
        rows.append(("Frame rate", "\(Int(frameRate.rounded())) fps"))
        rows.append(("Bytes", ByteCountFormatter.string(fromByteCount: swing.fileSize, countStyle: .file)))
        let context = swing.meta.context
        if let course = context.courseName ?? context.courseID { rows.append(("Course", course)) }
        if let hole = context.holeLabel { rows.append(("Hole", hole)) }
        if let player = context.playerName { rows.append(("Player", player)) }
        if !context.tags.isEmpty { rows.append(("Tags", context.tags.joined(separator: ", "))) }
        if let note = context.note, !note.isEmpty { rows.append(("Note", note)) }
        if let location = swing.meta.location {
            rows.append(("Location", String(format: "%.5f, %.5f", location.latitude, location.longitude)))
        }
        rows.append(("Gravity", hasGravity ? "recorded" : "none"))
        // Said out loud, because a swing filmed in vipl carries no naelvol payload and the
        // difference explains every empty field above it.
        if swing.meta.isForeign { rows.append(("Record", "read from another app's description")) }
        return rows
    }

    /// Where the swing was filmed, for the Maps button.
    public var mapsURL: URL? {
        guard let location = swing.meta.location else { return nil }
        return URL(string: "http://maps.apple.com/?ll=\(location.latitude),\(location.longitude)&q=Swing")
    }
}
#endif
