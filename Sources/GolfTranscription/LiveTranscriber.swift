#if canImport(Speech)
import Foundation
import AVFoundation
import Speech
import GolfSessionFormat

/// Transcription while the round is still being played.
///
/// The same `SpeechAnalyzer` and the same two locale modules as `AppleTranscriber`,
/// fed from a live buffer stream instead of a file. What differs is not the engine
/// but where the samples come from: `AudioRecorder`'s tap, the same one writing the
/// `.m4a`.
///
/// **This is a display and event-extraction feed, not the transcript.** The
/// authoritative transcript is still produced by `SessionTranscriber` over the
/// closed `.m4a` files — that pass sees each segment whole, which is a better
/// recognition problem than a stream, and it is the artifact Phase 2's ASR
/// comparison is run over. A live pass that overwrote it would make that comparison
/// unrepeatable and would key the cache on audio nothing kept.
///
/// Volatile results **are** enabled here, unlike the file path. A live caption that
/// only appears when a phrase finalises looks like an app that is not listening;
/// a transcript file full of rewritten hypotheses is not a transcript. Same engine,
/// opposite answer, because the two are read by different things.
@available(iOS 26, macOS 26, *)
public final class LiveTranscriber: @unchecked Sendable {
    public static let id = "apple-live"

    /// One result as it arrives. **Shared with the Whisper path** — see `LiveLine`
    /// — so the two engines are interchangeable at the call site, which is what
    /// makes `--asr apple|whisperkit` a flag rather than a fork.
    public typealias Line = LiveLine

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var drain: Task<Void, Never>?
    /// Maps the analyzer's "delivered samples" clock back onto the session clock,
    /// absorbing gaps in delivery rather than compressing the round. See
    /// `LiveAudioClock`.
    private var clock = LiveAudioClock(sampleRate: 0)

    /// The locales that actually started. Empty until `start`.
    public private(set) var locales: [String] = []

    public init() {}

    /// The format buffers must be supplied in.
    ///
    /// **Asked of the analyzer, never assumed.** It is not the 16 kHz mono the
    /// `.m4a` is written in, so the recorder runs a second converter off the one tap
    /// rather than either side compromising.
    public static func inputFormat(for locales: [String]) async -> AVAudioFormat? {
        let resolved = await AppleTranscriber.resolveLocales(locales)
        guard !resolved.isEmpty else { return nil }
        return await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: resolved.map(AppleTranscriber.module(for:)))
    }

    /// Start listening. Returns the format `append` must be given.
    ///
    /// - Parameter onLine: called off the main actor as results arrive, per locale.
    @discardableResult
    public func start(context: TranscriptionContext,
                      onLine: @escaping @Sendable (Line) -> Void) async throws -> AVAudioFormat {
        let resolved = await AppleTranscriber.resolveLocales(context.locales)
        guard !resolved.isEmpty else {
            throw TranscriptionError.noLocaleAvailable(context.locales)
        }
        let modules = resolved.map { locale in
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
        try await AppleTranscriber.ensureModels(for: modules)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TranscriptionError.modelUnavailable("no analyzer input format for "
                + resolved.map(\.identifier).joined(separator: ", "))
        }

        let analysisContext = AnalysisContext()
        if !context.contextualStrings.isEmpty {
            analysisContext.contextualStrings = [.general: context.contextualStrings]
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: modules,
                                      analysisContext: analysisContext)
        // Loads the model before the first word rather than during it — otherwise
        // the opening drive is transcribed several seconds late, or not at all.
        try await analyzer.prepareToAnalyze(in: format)

        install(continuation: continuation, analyzer: analyzer,
                locales: resolved.map { TranscriptCoverage.canonicalLocale($0.identifier) },
                clock: LiveAudioClock(sampleRate: format.sampleRate))

        // Every module drained concurrently, for the same reason the file path does
        // it: the analyzer does not progress while a module's stream is unread, so
        // draining them in sequence deadlocks the second behind the first.
        let tags = self.locales
        drain = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (tag, module) in zip(tags, modules) {
                    group.addTask {
                        do {
                            for try await result in module.results {
                                guard let line = self?.line(from: result, locale: tag) else { continue }
                                onLine(line)
                            }
                        } catch {
                            // A module that dies takes its language with it and
                            // nothing else — the other locale keeps running.
                        }
                    }
                }
            }
        }
        return format
    }

    /// Hand one buffer to the recognizer.
    ///
    /// Called from `AudioRecorder`'s tap thread, so it must not block or allocate
    /// much: yielding to an `AsyncStream` continuation does neither.
    ///
    /// - Parameter sessionTime: when this buffer was captured, on the session clock.
    ///   Passed through as the buffer's start time rather than letting the analyzer
    ///   count samples, so that audio the tap never delivered reads as a gap instead
    ///   of pulling every later word earlier.
    public func append(_ buffer: AVAudioPCMBuffer, at sessionTime: Millis) {
        lock.lock()
        clock.accept(frames: Int(buffer.frameLength), at: sessionTime)
        let continuation = self.continuation
        lock.unlock()
        // **No `bufferStartTime`.** Measured 2026-08-27: stamping each buffer with
        // its wall-clock position produced one volatile word ("I") repeated and no
        // finalized results at all, over speech the same analyzer transcribes
        // cleanly when the times are left off. The analyzer keeps its own clock by
        // counting the samples it is given; supplying a second, jittering one makes
        // its input look overlapped. The session-clock mapping is done on the way
        // out instead, by `LiveAudioClock`.
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Stop and let the recognizer finish whatever it is mid-way through.
    public func finish() async {
        let (continuation, analyzer) = takeDown()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await drain?.value
        drain = nil
    }

    /// Drop everything without waiting — the round was cancelled, not ended.
    public func cancel() async {
        let (continuation, analyzer) = takeDown()
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        drain?.cancel()
        drain = nil
    }

    // MARK: - Synchronous state, so no lock is ever taken in an async context

    private func install(continuation: AsyncStream<AnalyzerInput>.Continuation,
                         analyzer: SpeechAnalyzer, locales: [String],
                         clock: LiveAudioClock) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
        self.analyzer = analyzer
        self.locales = locales
        self.clock = clock
    }

    private func takeDown() -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) {
        lock.lock()
        defer { lock.unlock() }
        let pair = (continuation, analyzer)
        continuation = nil
        analyzer = nil
        return pair
    }

    private var currentClock: LiveAudioClock {
        lock.lock()
        defer { lock.unlock() }
        return clock
    }

    /// Recognizer time back onto the session clock. The offset is the analyzer's own
    /// account of where in its input this text sits; `LiveAudioClock` says what
    /// instant that input arrived at.
    func line(from result: SpeechTranscriber.Result, locale: String) -> Line? {
        let clock = currentClock
        guard var utterance = AppleTranscriber.utterance(from: result, locale: locale),
              let t0 = clock.sessionTime(analyzerOffset: Double(utterance.t0) / 1000),
              let t1 = clock.sessionTime(analyzerOffset: Double(utterance.t1) / 1000)
        else { return nil }
        utterance.t0 = t0
        utterance.t1 = t1
        return Line(utterance: utterance, isFinal: result.isFinal)
    }
}
#endif
