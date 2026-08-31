import Foundation
import AVFoundation
import WhisperKit
import GolfSessionFormat

/// One line of live output, from whichever engine produced it.
///
/// `isFinal == false` is a hypothesis that will be revised — show it, never store
/// it, and never hand it to the model step as fact.
public struct LiveLine: Sendable {
    public var utterance: Utterance
    public var isFinal: Bool
    public init(utterance: Utterance, isFinal: Bool) {
        self.utterance = utterance
        self.isFinal = isFinal
    }
}

/// Whisper, while the round is still being played.
///
/// **Whisper is a batch model and this is the wrapper that makes it look live.**
/// It reads a fixed 30-second frame and decodes it whole; there is no partial
/// output in the architecture. So this keeps a rolling window of the audio since
/// the last commit, re-decodes it every pass, and publishes the result as a
/// *hypothesis* that is replaced by the next pass. Words appear a beat behind the
/// speaker and get rewritten as context arrives — that is Whisper working, not a
/// bug, and it is why volatile lines are drawn dimmed and never stored.
///
/// **A phrase is committed at a silence, not at a timer.** Trailing quiet is what
/// a sentence boundary sounds like, so a commit there yields one log per utterance
/// instead of one per arbitrary window. `maxWindow` is the backstop for the golfer
/// who does not pause: it commits before the window reaches Whisper's 30-second
/// frame, because past that the model silently drops the oldest audio.
///
/// Fed from `AudioRecorder`'s tap — the same one writing the `.m4a` — so the file
/// and the recognizer never disagree about what was said.
public final class WhisperLiveTranscriber: @unchecked Sendable {
    public static let id = "whisperkit-live"

    public typealias Line = LiveLine

    public struct Config: Sendable {
        public var sampleRate: Double = 16_000
        /// Whisper needs something to chew on; below this a pass is noise.
        public var minSeconds: Double = 1.0
        /// Commit by here whatever happens. Comfortably under Whisper's 30 s frame,
        /// past which the model drops the oldest audio without saying so.
        public var maxWindowSeconds: Double = 14
        /// Trailing quiet that ends a phrase.
        public var silenceSeconds: Double = 0.7
        /// Leading non-speech longer than this is dropped before decoding rather
        /// than handed to the model.
        public var maxLeadingSilence: Double = 0.3
        public init() {}
    }

    private let config: Config
    private let model: String
    private let lock = NSLock()

    /// See `WhisperVAD` for why this exists and why its threshold is relative.
    private let vad = WhisperVAD()

    /// Samples since the last commit, at `config.sampleRate`.
    private var window: [Float] = []
    /// Absolute index of `window[0]` in the burst's delivered audio, so a committed
    /// phrase can still be placed on the session clock after the window slides.
    private var windowStartSample: Int = 0
    private var clock = LiveAudioClock(sampleRate: 16_000)
    private var running = false
    private var loop: Task<Void, Never>?

    /// The last hypothesis published, so an unchanged pass does not re-publish and
    /// make the caption flicker.
    private var lastVolatile = ""

    // **There is deliberately no `locales` property.** The Apple path has one
    // because it resolves a fixed set of recognizers up front; Whisper detects per
    // phrase, so the only honest answer is per line — and `Utterance.locale`
    // already carries it. A property here would have to be written from the decode
    // task and read from the main one, which is a data race in a class that is
    // `@unchecked Sendable` precisely because every other shared field is locked.

    public init(model: String = WhisperModels.defaultID, config: Config = Config()) {
        self.model = model
        self.config = config
    }

    /// The format buffers must be supplied in.
    ///
    /// Whisper's own: 16 kHz mono float. It happens to be what the `.m4a` is
    /// written at too, but ask rather than assume — the recorder runs a converter
    /// per consumer for exactly this reason.
    public static func inputFormat(sampleRate: Double = 16_000) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                      channels: 1, interleaved: false)
    }

    /// Load the model and start the decode loop.
    ///
    /// - Parameter onLine: called off the main actor. Volatile lines arrive roughly
    ///   once a pass; a final line arrives at a silence or at `maxWindowSeconds`.
    @discardableResult
    public func start(context: TranscriptionContext,
                      onLine: @escaping @Sendable (Line) -> Void) async throws -> AVAudioFormat {
        let kit = try await WhisperEngine.shared.kit(model: model)
        guard let format = Self.inputFormat(sampleRate: config.sampleRate) else {
            throw TranscriptionError.modelUnavailable("no 16 kHz mono float format")
        }
        lock.lock()
        window = []
        windowStartSample = 0
        clock = LiveAudioClock(sampleRate: config.sampleRate)
        lastVolatile = ""
        running = true
        lock.unlock()

        loop = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.decodeLoop(kit: kit, onLine: onLine)
        }
        return format
    }

    /// Hand one buffer over. Called from the tap thread, so it only copies.
    public func append(_ buffer: AVAudioPCMBuffer, at sessionTime: Millis) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: n))
        lock.lock()
        clock.accept(frames: n, at: sessionTime)
        window.append(contentsOf: samples)
        lock.unlock()
    }

    /// Stop, committing whatever is still in the window.
    ///
    /// The last phrase of a burst is a hypothesis at the moment the microphone
    /// stops, and dropping it looks exactly like the recognizer missing the end of
    /// a hole — which is when scores get said.
    public func finish() async {
        lock.lock(); running = false; lock.unlock()
        await loop?.value
        loop = nil
    }

    public func cancel() async {
        lock.lock(); running = false; window = []; lock.unlock()
        loop?.cancel()
        loop = nil
    }

    // MARK: - The loop

    private func decodeLoop(kit: WhisperKit, onLine: @Sendable (Line) -> Void) async {
        while true {
            let (snapshot, startSample, stillRunning) = snapshotWindow()
            let seconds = Double(snapshot.count) / config.sampleRate

            if !stillRunning {
                // Final pass: commit everything left, however short.
                if seconds >= 0.4 {
                    await decode(kit: kit, snapshot: snapshot, startSample: startSample,
                                 commitAll: true, onLine: onLine)
                }
                return
            }
            guard seconds >= config.minSeconds else {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            await decode(kit: kit, snapshot: snapshot, startSample: startSample,
                         commitAll: false, onLine: onLine)
            if Task.isCancelled { return }
        }
    }

    private func snapshotWindow() -> ([Float], Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (window, windowStartSample, running)
    }

    private func decode(kit: WhisperKit, snapshot: [Float], startSample: Int,
                        commitAll: Bool, onLine: @Sendable (Line) -> Void) async {
        let seconds = Double(snapshot.count) / config.sampleRate

        // **Nothing was said. Do not ask the model what was said.** This is the
        // gate, and it is most of the fix: a quiet window handed to Whisper does
        // not come back empty, it comes back with "Thank you." Keep a short tail so
        // a phrase starting at this instant is not thrown away with the silence.
        guard let speechStart = vad.speechStart(snapshot, sampleRate: config.sampleRate) else {
            if !commitAll {
                let keep = Int(config.silenceSeconds * config.sampleRate)
                dropWindow(upToSample: max(0, snapshot.count - keep), from: startSample)
            }
            publishVolatile("", startSample: startSample, onLine: onLine)
            return
        }

        // **Leading non-speech is dropped rather than decoded**, because it is what
        // the language detector reads. Done by advancing the window itself, so the
        // sample offsets everything else is computed from stay true — trimming a
        // *copy* before decoding would shift every timestamp silently, which is the
        // accumulation bug `AudioTimeline` exists to prevent, one level down.
        // `speechStart` already includes a pre-roll, so a soft onset survives.
        if !commitAll,
           Double(speechStart) / config.sampleRate > config.maxLeadingSilence {
            dropWindow(upToSample: speechStart, from: startSample)
            publishVolatile("", startSample: startSample, onLine: onLine)
            return
        }

        // A phrase ends where speech stops, answered by the same detector that
        // gates the pass rather than by a second, differently-calibrated one.
        let quiet = vad.trailingSilence(snapshot, sampleRate: config.sampleRate)
            >= config.silenceSeconds
        let shouldCommit = commitAll || quiet || seconds >= config.maxWindowSeconds

        let options = WhisperDecoding.options(volatile: !shouldCommit)
        guard let results = try? await kit.transcribe(audioArray: snapshot,
                                                      decodeOptions: options)
        else { return }

        // **Each result carries its own detected language.** A pass over a long
        // window comes back as several results — Whisper decides per 30-second
        // frame — so taking `results.first`'s language for all of them tagged
        // Korean phrases `en` whenever the first frame happened to resolve that
        // way. Pair each segment with the result it came from.
        let tagged = results.flatMap { result in
            result.segments
                .filter { !$0.text.trimmed.isEmpty }
                // A quiet window does not come back empty — it comes back with a
                // short confident fabrication. See `WhisperSilence`.
                .filter { !WhisperSilence.isNotSpeech($0) }
                .map { (segment: $0, language: result.language) }
        }
        let segments = tagged.map(\.segment)
        let language = tagged.last?.language

        guard !segments.isEmpty else {
            // Nothing heard. If the window has run long or gone quiet, throw it
            // away rather than re-decoding silence for the rest of the round.
            if shouldCommit { dropWindow(upToSample: snapshot.count, from: startSample) }
            publishVolatile("", startSample: startSample, onLine: onLine)
            return
        }

        if shouldCommit {
            // Everything up to the last segment's end becomes a log. Whichever way
            // the commit was triggered, the audio behind it has been decoded with
            // the full fallback ladder and is not coming back.
            for item in tagged {
                guard let u = utterance(from: item.segment, startSample: startSample,
                                        language: item.language) else { continue }
                onLine(Line(utterance: u, isFinal: true))
            }
            // **Drop to the end of what was just committed, and keep nothing
            // behind it.** An earlier version kept a second of tail "for context",
            // which meant a second of *already committed* audio stayed in the
            // window, was decoded again on the next pass, and was committed again —
            // duplicate log rows, visible in the app as one phrase filed twice.
            // There is nothing to lose by dropping it: a commit happens at a
            // silence, so the boundary is silence, and the backstop commit takes
            // every segment including the last.
            let consumed = Int(Double(segments.last!.end) * config.sampleRate)
            dropWindow(upToSample: max(0, min(snapshot.count, consumed)),
                       from: startSample)
            publishVolatile("", startSample: startSample, onLine: onLine)
        } else {
            publishVolatile(segments.map { $0.text.trimmed }.joined(separator: " "),
                            startSample: startSample, language: language,
                            span: (segments.first!.start, segments.last!.end),
                            onLine: onLine)
        }
    }

    /// Publish the running hypothesis, but only when it has actually changed —
    /// a caption that re-renders identical text several times a second reads as
    /// flicker rather than as listening.
    private func publishVolatile(_ text: String, startSample: Int,
                                 language: String? = nil,
                                 span: (Float, Float) = (0, 0),
                                 onLine: @Sendable (Line) -> Void) {
        lock.lock()
        let changed = text != lastVolatile
        lastVolatile = text
        lock.unlock()
        guard changed else { return }
        let t0 = sessionTime(startSample: startSample, offset: Double(span.0)) ?? 0
        let t1 = sessionTime(startSample: startSample, offset: Double(span.1)) ?? t0
        let tag = ScriptLocale.resolve(text: text, modelSaid: language)
        onLine(Line(utterance: Utterance(t0: t0, t1: max(t0, t1), text: text,
                                         locale: tag.map(TranscriptCoverage.canonicalLocale)),
                    isFinal: false))
    }

    private func utterance(from s: TranscriptionSegment, startSample: Int,
                           language: String?) -> Utterance? {
        let text = s.text.trimmed
        guard !text.isEmpty else { return nil }
        guard let t0 = sessionTime(startSample: startSample, offset: Double(s.start)),
              let t1 = sessionTime(startSample: startSample, offset: Double(s.end))
        else { return nil }
        // **The script the line is written in, not what the model reported.** See
        // `ScriptLocale`: Whisper's per-frame language is wrong often enough on
        // short or noisy windows to have been the user's bug report, and the text
        // itself answers the question without ambiguity.
        let tag = ScriptLocale.resolve(text: text, modelSaid: language)
        return Utterance(t0: t0, t1: max(t0, t1), speaker: nil, text: text,
                         conf: Double(exp(s.avgLogprob)),
                         locale: tag.map(TranscriptCoverage.canonicalLocale))
    }

    /// A window offset, in seconds from the window's own start, as a session time.
    ///
    /// The window slides, so the offset is rebased onto the burst's *delivered*
    /// audio first — `LiveAudioClock` then absorbs any gap in delivery rather than
    /// averaging it away. Same rule as `AudioTimeline`, one layer up: stamp, never
    /// accumulate.
    private func sessionTime(startSample: Int, offset seconds: Double) -> Millis? {
        lock.lock(); defer { lock.unlock() }
        let absolute = Double(startSample) / config.sampleRate + max(0, seconds)
        return clock.sessionTime(analyzerOffset: absolute)
    }

    private func dropWindow(upToSample n: Int, from startSample: Int) {
        lock.lock(); defer { lock.unlock() }
        // The window may have grown since the snapshot; drop by count, not by
        // replacing, or the samples that arrived mid-decode are lost.
        let alreadyDropped = windowStartSample - startSample
        // Clamped, not guarded. Bailing out when the requested drop exceeded what
        // the window holds left committed audio in place to be committed again —
        // the same duplicate the `keepTail` removal above is about.
        let drop = min(max(0, n - alreadyDropped), window.count)
        guard drop > 0 else { return }
        window.removeFirst(drop)
        windowStartSample += drop
    }

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
