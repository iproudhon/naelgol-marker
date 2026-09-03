#if os(iOS)
import AVFoundation
import Combine
import CoreMotion
import Foundation
import NaelvolCore
import NaelvolPose
import UIKit
import os

/// The camera, and everything that happens while it is open.
///
/// Deliberately **not** a view controller: it publishes state and hands out an
/// `AVCaptureVideoPreviewLayer`, and `NaelvolUI` wraps that in the one
/// `UIViewRepresentable` this package needs.
@MainActor
public final class SwingCaptureSession: NSObject, ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var options: [CaptureOption] = []
    @Published public private(set) var current: CaptureOption?
    /// **The front camera is mirrored** *(user, 2026-09-01)*, preview and recording alike: a
    /// selfie preview that is not mirrored feels reversed to everyone, and a recording that
    /// disagrees with the preview it was framed in is worse. Note what it costs — a mirrored
    /// swing shows a right-hander swinging left-handed — which is why it follows the camera
    /// rather than being a setting somebody can leave on for the back camera.
    @Published public private(set) var isMirrored = false
    /// The rotation the connection is applying, in degrees, so the preview layer can be set the
    /// same way. 0 is the sensor's own landscape; 90 is portrait.
    @Published public private(set) var rotationAngle: CGFloat = 90
    @Published public private(set) var failure: String?
    /// What the trigger is doing, so the screen can say so. A gesture with no
    /// feedback is one people repeat because they cannot tell it is working.
    @Published public private(set) var triggerState: TriggerState = .off
    /// The most recent frame, already throttled, for a live pose overlay. Nil
    /// unless `poseHandler` is set.
    @Published public private(set) var lastPose: Golfer?

    public enum TriggerState: Equatable, Sendable { case off, watching, arming }

    /// Why capture cannot start right now, in a sentence. **Refusing while the
    /// round holds the microphone is a decision, not a bug**: one microphone, and
    /// an `AVCaptureSession` with an audio input starting under a live
    /// `AVAudioEngine` tap either interrupts the burst — which closes a segment —
    /// or fails silently. The host supplies this; naelvol never inspects the
    /// audio session and never sets its category.
    public var isBlocked: (() -> String?)?
    /// Where a finished recording goes. Injected so the library does not decide
    /// the host's directory layout.
    public var nextURL: (() throws -> URL)?
    /// What the swing is about, asked for at the moment recording starts.
    public var contextProvider: (() -> SwingContext)?
    /// Where the phone is, if the host has a fix. **naelvol owns no
    /// `CLLocationManager`** — this app has been burned twice by a second radio.
    public var fixProvider: (() -> SwingLocation?)?
    /// Called with a finished recording's URL.
    public var onFinished: ((URL) -> Void)?
    /// Runs pose estimation on a throttled preview frame. The estimator lives in
    /// the host, because the engine is in another package.
    public var poseHandler: ((CVPixelBuffer) -> Golfer?)?

    /// How many preview frames out of every second reach the pose overlay and the
    /// triggers. **A parameter, not a constant to guess once**: at 240 fps a
    /// request per frame is not affordable, and what is affordable has not been
    /// measured on a phone.
    public var analysisHz: Double = 10
    public var wantsLivePose = false
    public var wantsGestureTrigger = false
    public var recordsAudio = true

    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "naelvol.capture.session")
    private let outputQueue = DispatchQueue(label: "naelvol.capture.output")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// Everything the camera's own queue touches, in one object it owns.
    ///
    /// **The frame path never reaches back into the actor.** At 240 fps a hop to
    /// the main actor per frame is the one thing that cannot keep up, and
    /// `MainActor.assumeIsolated` off the camera queue is a crash rather than a
    /// shortcut. State the delegate needs is pushed into `pipeline` when it
    /// changes; results come back the other way as one hop per *analysed* frame.
    private let pipeline: FramePipeline
    private var timer: Timer?

    private let defaults: UserDefaults
    private let optionKey = "naelvol.capture.option"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pipeline = FramePipeline()
        super.init()
        pipeline.onResult = { [weak self] golfer, outcome in
            Task { @MainActor in self?.handle(golfer: golfer, outcome: outcome) }
        }
    }

    /// Push the settings the camera queue reads. Called whenever one changes;
    /// cheap, and it keeps every cross-queue read behind one lock.
    public func syncSettings() {
        pipeline.update(wantsLivePose: wantsLivePose, wantsGestureTrigger: wantsGestureTrigger,
                        analysisHz: analysisHz, poseHandler: poseHandler)
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: - Lifecycle

    public func start() {
        options = CameraCatalog.options()
        let remembered = defaults.string(forKey: optionKey)
        let option = options.first { $0.id == remembered } ?? options.first
        guard let option else {
            failure = "This device has no camera naelvol can use."
            return
        }
        select(option)
    }

    public func select(_ option: CaptureOption) {
        current = option
        defaults.set(option.id, forKey: optionKey)
        let wantsAudio = recordsAudio
        // Read on the main actor and handed over: `UIDevice.current.orientation` is main-actor
        // state, and the session queue is not it.
        let angle = Self.rotationAngle(for: UIDevice.current.orientation)
        sessionQueue.async { [weak self] in self?.configure(option, audio: wantsAudio, angle: angle) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pipeline.gravity.stop()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isRunning = false }
        }
    }

    private nonisolated func configure(_ option: CaptureOption, audio wantsAudio: Bool, angle: CGFloat) {
        guard let device = CameraCatalog.device(id: option.deviceID),
              option.formatIndex < device.formats.count else {
            Task { @MainActor in self.failure = "That camera is no longer available." }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority   // the chosen format decides, not a preset

        for input in session.inputs { session.removeInput(input) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            Task { @MainActor in self.videoInput = input }

            // **Audio is an input we add, and the app's audio session is never
            // touched.** `AVCaptureSession` configures it for us; the round
            // re-asserts its own `.record` category at the start of every burst,
            // which is what makes that safe. Capture is refused outright while a
            // burst is open — see `isBlocked`.
            if wantsAudio, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(input) {
                session.addInput(input)
                Task { @MainActor in self.audioInput = input }
            }
        } catch {
            session.commitConfiguration()
            Task { @MainActor in self.failure = error.localizedDescription }
            return
        }

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            // **Frames are dropped rather than queued.** A backlog at 240 fps is
            // an overlay that lags the golfer and a recording that never catches up.
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(pipeline, queue: outputQueue)
            session.addOutput(videoOutput)
        }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(pipeline, queue: outputQueue)
            session.addOutput(audioOutput)
        }

        // **Rotation and mirroring are both the connection's job, and they have to be, because
        // the two do not commute.** Mirroring flips about the connection's *own* vertical axis,
        // so a horizontal flip applied to a landscape buffer that is then rotated 90° into
        // portrait by a writer transform comes out flipped **top to bottom** — the recording is
        // upside down instead of side-swapped. Setting the orientation here puts the flip in the
        // same space as the picture, and the writer's transform is then identity.
        let mirror = option.position == .front
        if let connection = videoOutput.connection(with: .video) {
            Self.orient(connection, angle: angle, mirrored: mirror)
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = device.formats[option.formatIndex]
            // Both bounds pinned to the chosen rate, or the camera drops to 30 in
            // low light — silently, in the one mode the feature exists for.
            let duration = CMTime(value: 1, timescale: CMTimeScale(option.frameRate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            os_log("naelvol: could not pin the frame rate: %{public}@", type: .error,
                   String(describing: error))
        }

        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        Task { @MainActor in
            self.isRunning = true
            self.isMirrored = mirror
            self.rotationAngle = angle
            self.failure = nil
            self.pipeline.gravity.start()
        }
    }

    // MARK: - Recording

    public func toggleRecording() {
        if isRecording { Task { await finish() } } else { begin() }
    }

    public func begin() {
        if let reason = isBlocked?() {
            failure = reason
            return
        }
        guard isRunning, let nextURL else { return }
        do {
            let url = try nextURL()
            var context = contextProvider?() ?? SwingContext()
            if context.tags.isEmpty { context.tags = [] }
            let meta = SwingMeta(context: context, location: fixProvider?())
            // Identity: the connection already delivers the picture upright and, on the front
            // camera, mirrored. A rotation here as well would turn it twice.
            let transform = CGAffineTransform.identity
            try pipeline.recorder.start(url: url,
                                        videoSettings: videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov),
                                        transform: transform,
                                        audioSettings: recordsAudio
                                            ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
                                            : nil,
                                        meta: meta)
            isRecording = true
            elapsed = 0
            syncSettings()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.elapsed = CMTimeGetSeconds(self.pipeline.recorder.duration)
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    public func finish() async {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        let url = await pipeline.recorder.stop()
        elapsed = 0
        if let url { onFinished?(url) }
    }

    /// Degrees of rotation for a device orientation.
    ///
    /// **`UIDeviceOrientation.landscapeLeft` is the camera's landscape *right*** — the classic
    /// inversion, because the device orientation names which way the *device* turned and the
    /// video one names which way the picture must go back. `UIDevice` also reports face up, face
    /// down and unknown, which is what a phone on a bag stand reports most of the time, so
    /// anything unmatched falls back to portrait: the failure being a swing recorded on its side.
    nonisolated static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return 90
        }
    }

    /// Point a connection the right way up and, for the front camera, the right way round.
    ///
    /// **Mirroring is set *after* the rotation, on the same connection**, so the flip is about
    /// the picture's vertical axis — a side swap, not an upside-down one.
    nonisolated static func orient(_ connection: AVCaptureConnection, angle: CGFloat, mirrored: Bool) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            let orientation: AVCaptureVideoOrientation
            switch angle {
            case 0: orientation = .landscapeRight
            case 180: orientation = .landscapeLeft
            case 270: orientation = .portraitUpsideDown
            default: orientation = .portrait
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// Follow the phone as it is turned — **but never while recording**, because changing a
    /// connection's rotation changes the buffer dimensions, and an `AVAssetWriter` input that is
    /// handed a different size mid-file stops accepting frames.
    public func deviceRotated() {
        guard !isRecording else { return }
        let angle = Self.rotationAngle(for: UIDevice.current.orientation)
        guard angle != rotationAngle else { return }
        rotationAngle = angle
        let mirror = isMirrored
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.videoOutput.connection(with: .video) else { return }
            Self.orient(connection, angle: angle, mirrored: mirror)
        }
    }

    /// Flash the torch as a countdown, the way vipl does — the only feedback a
    /// golfer standing twenty metres away can see.
    public func flashTorch(count: Int, milliseconds: Int) {
        guard let device = videoInput?.device, device.hasTorch else { return }
        sessionQueue.async {
            for _ in 0..<count {
                try? device.lockForConfiguration()
                try? device.setTorchModeOn(level: 1)
                device.unlockForConfiguration()
                Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                try? device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
                Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
            }
        }
    }
}

extension SwingCaptureSession {
    /// One hop per *analysed* frame, not per frame.
    private func handle(golfer: Golfer?, outcome: XPoseTrigger.Outcome) {
        if wantsLivePose { lastPose = golfer }
        guard wantsGestureTrigger else {
            triggerState = .off
            return
        }
        switch outcome {
        case .idle:
            triggerState = .watching
        case .arming:
            triggerState = .arming
            flashTorch(count: 1, milliseconds: 60)
        case .fire:
            triggerState = .watching
            flashTorch(count: isRecording ? 2 : 3, milliseconds: 60)
            toggleRecording()
        }
    }
}

/// The camera queue's half of the session.
///
/// Its own object rather than a set of `nonisolated(unsafe)` properties, so what
/// crosses the queue boundary is a short list behind one lock instead of whatever
/// a delegate method happens to touch.
private final class FramePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                   AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let recorder = SwingRecorder()
    let gravity = GravitySource()
    private let handPose = HandPoseTrigger()
    private var xPose = XPoseTrigger()
    private var lastAnalysis = Date.distantPast

    private let lock = NSLock()
    private var wantsLivePose = false
    private var wantsGestureTrigger = false
    private var analysisHz: Double = 10
    private var poseHandler: ((CVPixelBuffer) -> Golfer?)?

    var onResult: ((Golfer?, XPoseTrigger.Outcome) -> Void)?

    func update(wantsLivePose: Bool, wantsGestureTrigger: Bool, analysisHz: Double,
                poseHandler: ((CVPixelBuffer) -> Golfer?)?) {
        lock.lock()
        self.wantsLivePose = wantsLivePose
        self.wantsGestureTrigger = wantsGestureTrigger
        self.analysisHz = analysisHz
        self.poseHandler = poseHandler
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        // **Written before anything is analysed.** A frame the recorder misses is
        // gone; a frame the overlay misses is one the golfer never notices.
        recorder.append(sampleBuffer, for: isVideo ? .video : .audio,
                        gravity: isVideo ? gravity.gravity : nil)
        guard isVideo, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        analyse(buffer)
    }

    private func analyse(_ buffer: CVPixelBuffer) {
        lock.lock()
        let live = wantsLivePose, gesture = wantsGestureTrigger, hz = analysisHz, handler = poseHandler
        lock.unlock()
        guard live || gesture else { return }

        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 1.0 / max(1, hz) else { return }
        lastAnalysis = now

        let golfer = handler?(buffer)
        var outcome = XPoseTrigger.Outcome.idle
        if gesture {
            if let golfer { outcome = xPose.update(golfer, now: now) }
            if outcome == .idle {
                switch handPose.update(buffer, now: now) {
                case .fire: outcome = .fire
                case .arming: outcome = .arming
                case .idle: break
                }
            }
        }
        onResult?(golfer, outcome)
    }
}

#endif
