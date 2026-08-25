import Foundation
import AVFoundation
import GolfSessionFormat

/// Records a round's audio as a sequence of `AudioSegment`s.
///
/// Segmented rather than one long file because a 4.5-hour recording is certain
/// to be interrupted — a call, Siri, another app taking the microphone. Each
/// interruption closes a segment and the resume opens the next, so every sample
/// stays addressable on the session clock instead of drifting behind a single
/// whole-file offset.
///
/// Cross-platform on purpose: the same recorder runs on a Mac, which is how the
/// pipeline gets developed without a phone in the loop.
public final class AudioRecorder: NSObject, @unchecked Sendable {

    public struct Config: Sendable {
        /// 16 kHz mono: what speech ASR resamples to anyway, and a quarter the
        /// bytes of 44.1 kHz. Far-field intelligibility is limited by distance
        /// and wind, not by bandwidth above 8 kHz.
        public var sampleRate: Double = 16_000
        public var channels: Int = 1
        public var bitRate: Int = 32_000
        public var formatID: AudioFormatID = kAudioFormatMPEG4AAC
        public init() {}

        /// Recorded into meta.json so the Mac side knows what it is decoding.
        public var describedFormat: String {
            "m4a-aac-\(Int(sampleRate / 1000))k-\(channels == 1 ? "mono" : "stereo")-\(bitRate / 1000)kbps"
        }

        var settings: [String: Any] {
            [AVFormatIDKey: formatID,
             AVSampleRateKey: sampleRate,
             AVNumberOfChannelsKey: channels,
             AVEncoderBitRateKey: bitRate]
        }
    }

    public enum State: Sendable { case idle, recording, interrupted, stopped }

    private let folder: SessionFolder
    private let config: Config
    private let queue = DispatchQueue(label: "marker.audio")

    private var recorder: AVAudioRecorder?
    private var segmentIndex = -1
    private var current: AudioSegment?
    private var writer: JSONLWriter?
    private(set) public var state: State = .idle

    /// Fired when a segment opens or closes, for UI that shows recording health.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(folder: SessionFolder, config: Config = Config()) {
        self.folder = folder
        self.config = config
        super.init()
    }

    public var describedFormat: String { config.describedFormat }

    // MARK: - Permission

    public enum Permission: Sendable { case granted, denied, undetermined }

    /// Checked *before* `record()`, because an unauthorized `AVAudioRecorder
    /// .record()` blocks waiting on the TCC prompt instead of returning false.
    /// A recorder that hangs on a tee box is worse than one that says no.
    public static var permission: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// Prompts if the user has not been asked. Must be called from the
    /// foreground — the prompt cannot appear otherwise.
    public static func requestPermission() async -> Permission {
        if permission == .granted { return .granted }
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        return ok ? .granted : .denied
    }

    // MARK: - Lifecycle

    /// Must be called with the app in the foreground. iOS will not let an app
    /// *start* recording from the background (`AVAudioSession.ErrorCode
    /// .cannotStartRecording`, in force since iOS 12.4) — it will only let one
    /// continue. That is why a round is explicitly started by the user.
    public func start() throws {
        guard Self.permission == .granted else {
            throw AudioRecorderError.permissionDenied
        }
        try Self.configureSession()
        try queue.sync {
            guard state == .idle || state == .stopped else { return }
            try folder.create()
            if writer == nil { writer = try folder.writer(.audio) }
            try openSegment()
            state = .recording
        }
        onStateChange?(.recording)
        subscribeToInterruptions()
    }

    public func stop() {
        queue.sync {
            closeSegment(reason: "stop")
            state = .stopped
            try? writer?.close()
            writer = nil
        }
        unsubscribeFromInterruptions()
        onStateChange?(.stopped)
    }

    /// Segments written so far, including the open one (whose `t1` is nil).
    public func segments() -> [AudioSegment] {
        queue.sync { folder.readAll(.audio, as: AudioSegment.self) }
    }

    // MARK: - Segments

    private func openSegment() throws {
        segmentIndex += 1
        let name = SessionFolder.audioFileName(index: segmentIndex)
        let url = folder.url.appendingPathComponent(name)
        let r = try AVAudioRecorder(url: url, settings: config.settings)
        r.delegate = self
        guard r.record() else { throw AudioRecorderError.couldNotStart(url) }
        recorder = r
        current = AudioSegment(index: segmentIndex, file: name, t0: SessionClock.now())
    }

    /// The open segment's row is appended only when it closes, so it always
    /// carries a real `t1`. A crash mid-segment leaves the .m4a on disk with no
    /// index row — recoverable, and better than an index row that lies.
    private func closeSegment(reason: String) {
        recorder?.stop()
        recorder = nil
        guard var seg = current else { return }
        seg.t1 = SessionClock.now()
        seg.endReason = reason
        try? writer?.append(seg)
        try? writer?.sync()
        current = nil
    }

    // MARK: - Audio session

    #if os(iOS)
    /// **Required for background recording.** `UIBackgroundModes: audio` alone
    /// does nothing — the *session category* is what grants it. The default
    /// category is `.soloAmbient`, which neither records nor survives
    /// backgrounding, so without this the app records fine on the tee with the
    /// screen on and stops the instant the phone goes in a pocket. Which is the
    /// entire round.
    /// NO `.allowBluetooth`. A connected pair of AirPods would otherwise become
    /// the input route over HFP — narrowband, and beamformed hard at the wearer's
    /// own mouth. That records the phone's owner nicely while actively suppressing
    /// the other three players, which is exactly the capture the product depends
    /// on. The built-in mic is pinned for the same reason.
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    /// The input route actually in use, recorded into meta.json. Without it a
    /// round with unusable audio is indistinguishable from a round that proves
    /// the far-field premise wrong.
    static var currentRoute: String? {
        AVAudioSession.sharedInstance().currentRoute.inputs
            .map { $0.portType.rawValue }.joined(separator: "+")
    }
    #else
    static func configureSession() throws {}   // no AVAudioSession on macOS
    static var currentRoute: String? { nil }
    #endif

    // MARK: - Interruptions

    #if os(iOS)
    private func subscribeToInterruptions() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
    }
    private func unsubscribeFromInterruptions() {
        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            queue.sync {
                guard state == .recording else { return }
                closeSegment(reason: "interruption")
                state = .interrupted
            }
            onStateChange?(.interrupted)
        case .ended:
            // Resuming is best-effort: if the OS declines, the round continues
            // with a gap that the segment index makes explicit rather than hidden.
            queue.sync {
                guard state == .interrupted else { return }
                try? Self.configureSession()
                if (try? openSegment()) != nil { state = .recording }
            }
            onStateChange?(state)
        @unknown default: break
        }
    }
    #else
    private func subscribeToInterruptions() {}
    private func unsubscribeFromInterruptions() {}
    #endif
}

extension AudioRecorder: AVAudioRecorderDelegate {
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        queue.sync {
            closeSegment(reason: "error")
            if (try? openSegment()) == nil { state = .stopped }
        }
        onStateChange?(state)
    }
}

public enum AudioRecorderError: Error, CustomStringConvertible {
    case couldNotStart(URL)
    case permissionDenied

    public var description: String {
        switch self {
        case .couldNotStart(let url): return "AVAudioRecorder refused to start at \(url.path)"
        case .permissionDenied:
            return "microphone permission not granted — call AudioRecorder.requestPermission() "
                 + "from the foreground first (macOS CLI: run it from a terminal so the prompt can appear)"
        }
    }
}
