import Foundation
import AVFoundation
import GolfSessionFormat

/// Somewhere for live audio to go while it is also being written to disk.
///
/// **The tap is the scarce resource, not the audio.** One `AVAudioEngine` input tap
/// feeds every consumer: the `.m4a` and, when one is attached, whatever wants the
/// samples as they arrive — live transcription, a level meter. Asking the OS for a
/// second capture path is two radios' worth of power for one microphone, and on iOS
/// it does not work at all.
///
/// Carries its own `format` because the file's format is not the consumer's:
/// `SpeechAnalyzer` names the format it wants, and it is not the 16 kHz mono the
/// `.m4a` is written in. The recorder runs a converter per consumer off the one tap
/// rather than making everyone agree.
public struct AudioTap: @unchecked Sendable {
    public let format: AVAudioFormat
    /// Called on the tap's own thread, in `format`, in order. Do not block: this is
    /// the same callback that writes the round to disk.
    public let receive: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    public init(format: AVAudioFormat,
                receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.format = format
        self.receive = receive
    }
}

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
///
/// **Built on `AVAudioEngine` and not `AVAudioRecorder`, and the reason is live
/// transcription.** `AVAudioRecorder` exposes no buffers at all — the samples go
/// from the microphone into the file and are never visible — so a round could only
/// be transcribed after a segment *closed*, which for an uninterrupted round means
/// after the eighteenth hole. Every speech engine, Apple's or anyone else's, needs
/// the same `installTap`; swapping the recognizer would not have avoided this
/// rewrite. research-live-transcription.md §1.
///
/// The `.m4a` keeps being written regardless of whether anything is listening. It
/// is the durable record, and Phase 2 compares two ASR paths over the same audio —
/// a round that was only ever transcribed live is a comparison that can never be
/// run again.
public final class AudioRecorder: NSObject, @unchecked Sendable {

    public struct Config: Sendable {
        /// 16 kHz mono: what speech ASR resamples to anyway, and a quarter the
        /// bytes of 44.1 kHz. Far-field intelligibility is limited by distance
        /// and wind, not by bandwidth above 8 kHz.
        public var sampleRate: Double = 16_000
        public var channels: Int = 1
        public var bitRate: Int = 32_000
        public var formatID: AudioFormatID = kAudioFormatMPEG4AAC

        /// How long a silence from the tap counts as a fault rather than a quiet
        /// foursome.
        ///
        /// **A tap that stops delivering buffers fails silently** — engine running,
        /// no error, no callback (an unanswered developer-forum report has this
        /// happening after a phone-call interruption, which is precisely the event
        /// this recorder is built around). There is no notification for it, so the
        /// only detector is the absence of buffers. Generous, because a genuinely
        /// stalled tap stays stalled and the cost of noticing late is seconds,
        /// while the cost of a false positive is a spurious segment boundary.
        public var stallTimeout: TimeInterval = 10

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

        /// The PCM the file is written from, and what the tap is converted to.
        var pcmFormat: AVAudioFormat? {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                          channels: AVAudioChannelCount(channels), interleaved: false)
        }
    }

    public enum State: Sendable { case idle, recording, interrupted, stopped }

    private let folder: SessionFolder
    private let config: Config
    private let queue = DispatchQueue(label: "marker.audio")

    /// Guards everything the tap callback touches. **Not `queue`**: the tap runs on
    /// the audio thread, and calling `queue.sync` from it would park a real-time
    /// callback behind whatever else the serial queue is doing.
    private let tapLock = NSLock()

    /// **Lazy, so that a `recordAudio: false` round builds no audio machinery
    /// at all.** The app stopped recording on 2026-08-27 and now constructs a
    /// `RoundSession` that never starts this recorder; an eagerly-built
    /// `AVAudioEngine` in an app with no `NSMicrophoneUsageDescription` is a
    /// question nobody should have to keep re-answering.
    private lazy var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileConverter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var listener: (tap: AudioTap, converter: AVAudioConverter)?
    private var lastBufferAt: Date?
    private var stallTimer: DispatchSourceTimer?
    private var tapInstalled = false

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

    /// Checked *before* `record()`, because an unauthorized capture blocks waiting
    /// on the TCC prompt instead of returning false. A recorder that hangs on a tee
    /// box is worse than one that says no.
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

    // MARK: - Live listener

    /// Attach a consumer of live audio. At most one; attaching replaces.
    ///
    /// Safe to call before or during a round — a listener attached mid-round starts
    /// receiving at the next buffer, and one attached before `start()` receives from
    /// the first. Detaching does not touch the file.
    public func listen(_ tap: AudioTap?) {
        tapLock.lock()
        defer { tapLock.unlock() }
        // **Both, or detaching does not detach.** `stopEngine` deliberately keeps
        // the listener's *request* in `pendingListener` so a restart re-attaches
        // it across an interruption — but a recording *burst* ends with the engine
        // stopped and the listener already moved there, so clearing only
        // `listener` left the finished burst's tap armed. The next `start()` then
        // fed live buffers into a `LiveTranscriber` whose analyzer had already
        // been finalised: no output, and nothing anywhere saying why.
        guard let tap else { listener = nil; pendingListener = nil; return }
        // The converter needs the tap's real format, which only exists once the
        // engine has been started. Before that, remember the request and build it
        // when the tap goes in.
        if let inFormat = tapFormat, let c = AVAudioConverter(from: inFormat, to: tap.format) {
            listener = (tap, c)
        } else {
            pendingListener = tap
        }
    }
    private var pendingListener: AudioTap?

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
            try startEngine()
            try openSegment()
            state = .recording
        }
        onStateChange?(.recording)
        subscribeToInterruptions()
        startStallWatchdog()
    }

    /// Stop recording and hand the microphone back.
    ///
    /// **Restartable, and that is now a used property rather than a latent one.**
    /// Recording is off by default and driven by a button *(user decision,
    /// 2026-08-27)*, so a round is a series of bursts: `start()` guards on
    /// `.idle || .stopped`, `segmentIndex` keeps counting, and the `audio.jsonl`
    /// writer reopens `O_APPEND`. Each burst is therefore its own segment, and the
    /// silence between two bursts is a **real gap in time** — exactly what the
    /// segment format exists to express, and what `AudioTimeline` refuses to
    /// accumulate away.
    public func stop() {
        stopStallWatchdog()
        queue.sync {
            stopEngine()
            closeSegment(reason: "stop")
            state = .stopped
            try? writer?.close()
            writer = nil
        }
        unsubscribeFromInterruptions()
        deactivateSession()
        onStateChange?(.stopped)
    }

    /// Continue numbering after whatever this folder already holds.
    ///
    /// **Required before recording into a round that has already recorded.**
    /// `segmentIndex` starts at -1 so a fresh round opens `audio-000.m4a`; a
    /// reopened one would otherwise overwrite it, and with it the audio of the
    /// round the user is trying to add to. Takes files *and* index rows into
    /// account — see `SessionFolder.lastAudioIndex`.
    public func adoptExistingSegments() {
        queue.sync {
            guard let last = folder.lastAudioIndex() else { return }
            segmentIndex = max(segmentIndex, last)
        }
    }

    /// Segments written so far, including the open one (whose `t1` is nil).
    public func segments() -> [AudioSegment] {
        queue.sync { folder.readAll(.audio, as: AudioSegment.self) }
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // A zero sample rate means the session is not live yet — capturing a tap
        // against it throws deep inside CoreAudio with nothing that names the cause.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputFormat
        }
        guard let pcm = config.pcmFormat,
              let converter = AVAudioConverter(from: inFormat, to: pcm) else {
            throw AudioRecorderError.noConverter(from: "\(inFormat)", to: "\(config.sampleRate) Hz")
        }

        tapLock.lock()
        tapFormat = inFormat
        fileConverter = converter
        if let pending = pendingListener,
           let c = AVAudioConverter(from: inFormat, to: pending.format) {
            listener = (pending, c)
            pendingListener = nil
        }
        lastBufferAt = Date()
        tapLock.unlock()

        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, when in
            self?.handle(buffer, at: when)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioRecorderError.engineFailed("\(error)")
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        tapLock.lock()
        fileConverter = nil
        tapFormat = nil
        // Keep the listener's *request* so a restart re-attaches it, but drop the
        // converter, which is bound to a format that may not come back the same.
        if let l = listener { pendingListener = l.tap; listener = nil }
        tapLock.unlock()
    }

    /// One tap buffer: to the file always, to the listener if there is one.
    ///
    /// Runs on the audio thread. Both conversions and the file write happen under
    /// `tapLock` so a segment rotation cannot swap the file out mid-write.
    private func handle(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        tapLock.lock()
        lastBufferAt = Date()
        let inFormat = buffer.format
        if let converter = fileConverter, let file {
            if let out = Self.convert(buffer, with: converter, from: inFormat) {
                try? file.write(from: out)
            }
        }
        let listening = listener
        tapLock.unlock()

        // Delivered outside the lock: a consumer that blocks must not be able to
        // stall the write of the round to disk.
        if let listening, let out = Self.convert(buffer, with: listening.converter,
                                                 from: inFormat) {
            listening.tap.receive(out, when)
        }
    }

    /// One buffer through one converter.
    ///
    /// `.noDataNow` and not `.endOfStream` on the second callback: the stream is not
    /// over, this buffer is. Saying end-of-stream would finalise the resampler and
    /// every later buffer would convert against a reset filter, which is audible as
    /// a click at every tap boundary — about twelve times a second.
    public static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                               from inFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    // MARK: - Segments

    private func openSegment() throws {
        segmentIndex += 1
        let name = SessionFolder.audioFileName(index: segmentIndex)
        let url = folder.url.appendingPathComponent(name)
        let f = try AVAudioFile(forWriting: url, settings: config.settings)
        tapLock.lock()
        file = f
        tapLock.unlock()
        current = AudioSegment(index: segmentIndex, file: name, t0: SessionClock.now())
    }

    /// The open segment's row is appended only when it closes, so it always
    /// carries a real `t1`. A crash mid-segment leaves the .m4a on disk with no
    /// index row — recoverable, and better than an index row that lies.
    ///
    /// **Releasing the `AVAudioFile` is what finalises the file, and it has to
    /// happen before this returns.** `AVAudioRecorder.stop()` gave that for free;
    /// an `AVAudioFile` does not. Measured 2026-08-27: an AAC `.m4a` whose
    /// `AVAudioFile` was still alive fails to open at all —
    /// `ExtAudioFileOpenURL` returns `wave` / -50 — and the encoder's last frames
    /// are missing even from a file that does open. The Transcribe button runs
    /// immediately after `stop()`, and "transcription only ever sees closed
    /// segments" assumes closed means readable.
    private func closeSegment(reason: String) {
        tapLock.lock()
        file = nil          // finalises: ExtAudioFileDispose runs here, synchronously
        let last = lastBufferAt
        tapLock.unlock()
        guard var seg = current else { return }
        seg.t1 = Self.endTime(lastBuffer: last, notBefore: seg.t0)
        seg.endReason = reason
        try? writer?.append(seg)
        try? writer?.sync()
        current = nil
    }

    /// **A segment ends when its last sample arrived, not when the code noticed.**
    ///
    /// Measured 2026-08-27 against a faked dead tap: the watchdog waits
    /// `stallTimeout` before acting, so stamping `now` gave a segment that claimed
    /// 18.0 s while holding 6 s of audio — the twelve silent seconds landed *inside*
    /// a window the session clock says is continuous recording. Everything derived
    /// from `t1 - t0` then lies: `AudioTimeline.duration`, the realtime factor, and
    /// any later "was the microphone live at this moment" question. Same rule as
    /// `SessionIndex.closeOut`, which stamps the last evidence rather than the
    /// present.
    ///
    /// Floored at the segment's own `t0`, for the segment that opened and received
    /// nothing at all — a restart immediately followed by a stop. A `t1` before `t0`
    /// is a negative duration, which reads as corruption rather than as silence.
    static func endTime(lastBuffer: Date?, notBefore t0: Millis) -> Millis {
        guard let lastBuffer else { return t0 }
        let stamp = Millis((lastBuffer.timeIntervalSince1970 * 1000).rounded())
        return max(t0, min(stamp, SessionClock.now()))
    }

    /// Close the open segment and open the next without stopping the engine.
    ///
    /// Cheap in a way it was not before: the tap keeps running and only the
    /// destination file changes, so rotation costs one file close and one open
    /// rather than a capture teardown. Nothing else in the app calls this yet — it
    /// is what a timed rotation would use to make a segment readable during a
    /// round.
    public func rotateSegment(reason: String = "rotate") {
        queue.sync {
            guard state == .recording else { return }
            closeSegment(reason: reason)
            try? openSegment()
        }
    }

    // MARK: - Stall watchdog

    /// **Treats "no buffer recently" as a fault**, because that is the only
    /// symptom a dead tap has. See `Config.stallTimeout`.
    ///
    /// Recovery is a full engine restart and a new segment, not a retry of the same
    /// one: the samples between the last buffer and the restart do not exist, and
    /// writing what comes next into the same file would put a gap inside a segment
    /// that the session clock says is continuous. A segment boundary is how this
    /// format says "time passed here".
    private func startStallWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.stallTimeout, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        stallTimer = timer
        timer.resume()
    }

    private func stopStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkForStall() {
        // Disarmed while interrupted: the tap is *supposed* to be silent during a
        // phone call, and restarting the engine under the interruption would fight
        // the OS for the microphone every two seconds.
        guard state == .recording else { return }
        tapLock.lock()
        let last = lastBufferAt
        tapLock.unlock()
        guard let last, Date().timeIntervalSince(last) > config.stallTimeout else { return }

        closeSegment(reason: "stall")
        stopEngine()
        if (try? startEngine()) != nil, (try? openSegment()) != nil {
            state = .recording
        } else {
            state = .stopped
        }
        onStateChange?(state)
    }

    // MARK: - Audio session

    #if os(iOS)
    /// **Required for background recording.** `UIBackgroundModes: audio` alone
    /// does nothing — the *session category* is what grants it. The default
    /// category is `.soloAmbient`, which neither records nor survives
    /// backgrounding, so without this the app records fine on the tee with the
    /// screen on and stops the instant the phone goes in a pocket. Which is the
    /// entire round.
    ///
    /// `.record` and not `.playAndRecord`: this app never plays anything back
    /// during a round, and `.playAndRecord` would take over the output route as
    /// well — silencing or ducking whatever the group has on.
    ///
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

    /// Give the microphone back between bursts.
    ///
    /// **This did not matter until recording became a toggle.** `.record` silences
    /// every other app's playback, and an audio session is only ever deactivated
    /// explicitly — so with a button-driven recorder, the first burst would kill
    /// the group's music and it would stay dead for the rest of the round, with
    /// the orange microphone indicator lit the whole time the app claims not to be
    /// listening. A control that looks like it is recording while it is not is the
    /// same failure as a simulated position drawn like a fix.
    ///
    /// `.notifyOthersOnDeactivation` is what actually resumes the other app.
    /// Best-effort: a deactivation that fails costs a burst of silenced music, and
    /// throwing here would fail a `stop()` that has already written the file.
    static func deactivateSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
    #else
    static func configureSession() throws {}   // no AVAudioSession on macOS
    static var currentRoute: String? { nil }
    static func deactivateSession() {}
    #endif

    private func deactivateSession() { Self.deactivateSession() }

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

    /// An interruption stops the engine as well as the session, so resuming is a
    /// restart and not an unpause — the tap has to go back in.
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            queue.sync {
                guard state == .recording else { return }
                stopEngine()
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
                if (try? startEngine()) != nil, (try? openSegment()) != nil {
                    state = .recording
                }
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

public enum AudioRecorderError: Error, CustomStringConvertible {
    case couldNotStart(URL)
    case permissionDenied
    case noInputFormat
    case noConverter(from: String, to: String)
    case engineFailed(String)

    public var description: String {
        switch self {
        case .couldNotStart(let url): return "could not open an audio file at \(url.path)"
        case .permissionDenied:
            return "microphone permission not granted — call AudioRecorder.requestPermission() "
                 + "from the foreground first (macOS CLI: run it from a terminal so the prompt can appear)"
        case .noInputFormat:
            return "the audio input reports no usable format — the audio session is not active, "
                 + "or there is no input device"
        case .noConverter(let from, let to):
            return "no converter from \(from) to \(to)"
        case .engineFailed(let why): return "AVAudioEngine would not start: \(why)"
        }
    }
}
