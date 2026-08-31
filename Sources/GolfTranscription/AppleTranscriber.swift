#if canImport(Speech)
import Foundation
import AVFoundation
import Speech
import GolfSessionFormat

/// Apple's on-device path: `SpeechAnalyzer` + `SpeechTranscriber`, iOS/macOS 26.
///
/// The iOS 26 floor is the reason the `SFSpeechRecognizer` fork is dead (PLAN §4):
/// `SpeechAnalyzer` is built for long-form audio and has no ~1-minute session cap,
/// which is what made the old API painful for a 4.5-hour round.
///
/// **One analyzer, one module per language.** A `SpeechTranscriber` is bound to a
/// single locale at construction, so bilingual capture is not a setting — it is two
/// modules attached to the same `SpeechAnalyzer`, reading the same audio, each
/// emitting its own stream of results. Verified 2026-08-27 on a Korean→English→
/// Korean fixture: both produce output, and they disagree in useful ways.
/// research-live-transcription.md §0.
///
/// The availability gate lives here, on the conformance, and never on
/// `Transcriber` — the package floor stays iOS 16 / macOS 13.
@available(iOS 26, macOS 26, *)
public struct AppleTranscriber: Transcriber {
    public static let id = "apple"

    public init() {}

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Locales with an installed on-device model, plus whatever can be downloaded.
    public static func supportedLocale(for identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    /// Every requested locale that resolves to a real recognizer, in the order
    /// asked for, deduplicated by the *canonical* identifier — `en-US` and `en_US`
    /// are one recognizer, and constructing both would double the cost of the pass
    /// and every line in the transcript.
    public static func resolveLocales(_ requested: [String]) async -> [Locale] {
        var seen = Set<String>(), out: [Locale] = []
        for id in requested {
            guard let l = await supportedLocale(for: id) else { continue }
            if seen.insert(TranscriptCoverage.canonicalLocale(l.identifier)).inserted {
                out.append(l)
            }
        }
        return out
    }

    /// A `SpeechTranscriber` per locale, configured identically.
    ///
    /// Explicit options rather than a preset: `audioTimeRange` is what puts a word
    /// on the session clock at all, and `transcriptionConfidence` is what lets a
    /// low-confidence line be shown as one rather than asserted. No volatile
    /// results — this is a file, not a live caption, and a partial hypothesis
    /// rewritten three times is not a transcript row.
    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    public func effectiveLocales(for context: TranscriptionContext) async -> [String] {
        await Self.resolveLocales(context.locales)
            .map { TranscriptCoverage.canonicalLocale($0.identifier) }
    }

    public func transcribe(file: URL, context: TranscriptionContext)
        async throws -> TranscriptionResult
    {
        let locales = await Self.resolveLocales(context.locales)
        guard !locales.isEmpty else {
            throw TranscriptionError.noLocaleAvailable(context.locales)
        }
        let modules = locales.map(Self.module(for:))
        try await Self.ensureModels(for: modules)

        // **Measured 2026-08-27: this changed nothing.** Supplied both ways —
        // `setContext` after construction and passed to the initialiser as here —
        // over synthetic speech containing words the recognizer demonstrably gets
        // wrong ("Chungmin" → "Chungman", "Naelgol" → "Nielgal"). Output was
        // byte-identical with the strings supplied and with none. The cause is
        // known: contextual strings are honoured by `DictationTranscriber` and
        // ignored by `SpeechTranscriber`. Not our bug.
        //
        // Kept anyway: it costs nothing and would apply to a `DictationTranscriber`
        // module. **But nothing may depend on it.** Since diarization was cut, a
        // spoken name is the only attribution signal there is, so the correction
        // has to happen further down, in the model step, by matching a mangled name
        // against the roster phonetically rather than exactly.
        let analysisContext = AnalysisContext()
        if !context.contextualStrings.isEmpty {
            analysisContext.contextualStrings = [.general: context.contextualStrings]
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: file)
        } catch {
            throw TranscriptionError.audioUnreadable(file, underlying: "\(error)")
        }

        // The file initialiser consumes the file itself, so there is no
        // `start(inputAudioFile:)` afterwards — that pair would read as if it
        // analysed the file twice, and "every utterance landed twice" is a bug
        // that looks like a chatty foursome. Verified: one pass, no duplicates.
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile, modules: modules,
            analysisContext: analysisContext, finishAfterFile: true)

        // Every module is drained concurrently, and all of them must be: `results`
        // completes only once the analyzer has finished, and the analyzer does not
        // finish while any module's stream is unread. Draining them in sequence
        // deadlocks the second one behind the first.
        let collector = Task { () throws -> [Utterance] in
            try await withThrowingTaskGroup(of: [Utterance].self) { group in
                for (locale, module) in zip(locales, modules) {
                    group.addTask {
                        var out: [Utterance] = []
                        for try await result in module.results {
                            let tag = TranscriptCoverage.canonicalLocale(locale.identifier)
                            if let u = Self.utterance(from: result, locale: tag) {
                                out.append(u)
                            }
                        }
                        return out
                    }
                }
                var all: [Utterance] = []
                for try await lines in group { all.append(contentsOf: lines) }
                return all
            }
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        // Sorted by time and *then* by locale, so the two accounts of one moment sit
        // next to each other in the file rather than being read as one recognizer
        // stuttering.
        let utterances = try await collector.value.sorted {
            $0.t0 != $1.t0 ? $0.t0 < $1.t0 : ($0.locale ?? "") < ($1.locale ?? "")
        }
        return TranscriptionResult(utterances: utterances,
                                   locales: locales.map(\.identifier))   // canonicalised by init
    }

    // MARK: - Result mapping

    /// One finalized `Result` becomes one `Utterance`.
    ///
    /// Times are **offsets inside this file**, in milliseconds — the caller maps
    /// them onto the session clock, because only it knows which `AudioSegment`
    /// this file is. See `AudioTimeline`.
    ///
    /// `speaker` stays nil. Diarization was cut on 2026-08-26: attribution is
    /// content-only. The field remains so the format need not change if
    /// diarization ever arrives for free.
    static func utterance(from result: SpeechTranscriber.Result,
                          locale: String) -> Utterance? {
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(result.range.end)
        let t0 = Millis((max(0, start) * 1000).rounded())
        let t1 = Millis((max(max(0, start), end) * 1000).rounded())

        return Utterance(t0: t0, t1: t1, speaker: nil, text: text,
                         conf: meanConfidence(of: result.text), locale: locale)
    }

    /// Mean of the per-run confidences, weighted by how much text each run covers.
    /// An unweighted mean lets a one-word run the recognizer was unsure about drag
    /// a whole confident sentence down, or the reverse.
    static func meanConfidence(of text: AttributedString) -> Double? {
        var weighted = 0.0, weight = 0.0
        for run in text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let n = Double(text[run.range].characters.count)
            guard n > 0 else { continue }
            weighted += c * n
            weight += n
        }
        return weight > 0 ? weighted / weight : nil
    }

    // MARK: - Model assets

    /// The speech model is a downloadable asset, not part of the OS image. A first
    /// run on a machine that has never used it must fetch it — surfaced as an error
    /// rather than silently producing an empty transcript.
    ///
    /// Asked for all modules at once, because that is one download request instead
    /// of one per language, and on a course there may be no signal for a second.
    static func ensureModels(for modules: [SpeechTranscriber]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory
                .assetInstallationRequest(supporting: modules) else { return }
            try await request.downloadAndInstall()
        case .unsupported:
            throw TranscriptionError.modelUnavailable(
                "no on-device speech model for "
                + modules.flatMap { $0.selectedLocales.map(\.identifier) }
                    .joined(separator: ", "))
        @unknown default:
            return
        }
    }
}
#endif
