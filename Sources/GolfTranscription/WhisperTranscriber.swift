import Foundation
import WhisperKit
import GolfSessionFormat

/// Whisper over a closed `.m4a` — the authoritative pass.
///
/// The live wrapper re-decodes a sliding window and publishes hypotheses; this
/// sees each segment whole, which is a strictly better recognition problem and is
/// the artifact Phase 2's ASR comparison is run over. Same engine, same three
/// rules (`WhisperDecoding.options`), different job.
///
/// **`language` is never set, here or anywhere.** Whisper detects per 30-second
/// frame, so a round that switches language between holes is handled; a round that
/// switches *inside* one frame is decided by whichever language dominates it. That
/// is the known cost of this engine and no setting here changes it — pinning a
/// language would make it worse by silently dropping the other one.
public struct WhisperTranscriber: Transcriber {
    public static let id = "whisperkit"

    public let model: String

    public init(model: String = WhisperModels.defaultID) {
        self.model = model
    }

    /// **Carries the model, because a cache that could not tell `tiny` from
    /// `large-v3` would serve one model's transcript for the other's run.** Exactly
    /// the reason `TranscriptCoverage` records the transcriber at all: re-running
    /// with a better model must re-transcribe, not report the round already done.
    public var runID: String { "\(Self.id)-\(model)" }

    /// **`auto`, and that is the honest answer.** Every other transcriber here is
    /// told which locales to run and can report which ones resolved. Whisper is
    /// told nothing on purpose and decides per frame, so the set that "ran" is one
    /// pass with detection on. Reporting `["en_US", "ko_KR"]` would claim a
    /// per-language guarantee this engine does not make; reporting the detected
    /// languages would make the cache key depend on what the golfers happened to
    /// say, so a quiet round would re-transcribe forever.
    public func effectiveLocales(for context: TranscriptionContext) async -> [String] {
        ["auto"]
    }

    public func transcribe(file: URL,
                           context: TranscriptionContext) async throws -> TranscriptionResult {
        let kit = try await loadKit()

        // **The result type is never named.** WhisperKit has its own
        // `TranscriptionResult` and so do we; inside this module ours shadows
        // theirs, and `WhisperKit.TranscriptionResult` does not disambiguate it
        // either, because `WhisperKit` is both the module and a class. Everything
        // stays inside this `do` so the type is only ever inferred; do not "tidy"
        // this by hoisting an annotated `let` out of it. `TranscriptionSegment`
        // collides with nothing, which is why the mapping below can be a function.
        var utterances: [Utterance] = []
        do {
            let results = try await kit.transcribe(
                audioPath: file.path,
                decodeOptions: WhisperDecoding.options(volatile: false))
            for result in results {
                utterances += lines(result.segments, modelSaid: result.language)
            }
        } catch {
            throw TranscriptionError.audioUnreadable(file, underlying: "\(error)")
        }

        return TranscriptionResult(utterances: utterances.sorted { $0.t0 < $1.t0 },
                                   locales: ["auto"])
    }

    /// Transcribe samples already in hand — 16 kHz mono float, `AudioExcerpt`'s
    /// output.
    ///
    /// This is how one log entry gets read again by a bigger model. It is a
    /// deliberately *narrower* thing than a file pass and must stay that way:
    /// **nothing here touches `transcript.jsonl` or `transcript.coverage.json`.**
    /// A sub-range pass is not a whole-segment pass, and recording coverage for it
    /// would mark segments transcribed that were only partly read — which is the
    /// exact failure that file exists to prevent, since a segment marked done is
    /// never re-read and nothing anywhere would say why the middle is missing.
    ///
    /// Times in the result are offsets **within the samples given**, as everywhere
    /// else; the caller owns the mapping back onto the session clock.
    public func transcribe(samples: [Float],
                           context: TranscriptionContext) async throws -> TranscriptionResult {
        guard samples.count > Int(AudioExcerpt.sampleRate * 0.1) else {
            return TranscriptionResult(utterances: [], locales: ["auto"])
        }
        let kit = try await loadKit()
        var utterances: [Utterance] = []
        do {
            // **The roster, and nothing else, as decoder context.** This is the one
            // pass where it is safe: the entry has already been transcribed once by
            // the live model, so nothing about the language decision here is
            // load-bearing, and names are the whole reason anyone asks for a second
            // read. See `WhisperDecoding.namePrompt`.
            var options = WhisperDecoding.options(volatile: false)
            options.promptTokens = WhisperDecoding.namePrompt(context.names,
                                                              tokenizer: kit.tokenizer)
            let results = try await kit.transcribe(
                audioArray: samples,
                decodeOptions: options)
            for result in results {
                utterances += lines(result.segments, modelSaid: result.language)
            }
        } catch {
            throw TranscriptionError.modelUnavailable("WhisperKit \(model): \(error)")
        }
        return TranscriptionResult(utterances: utterances.sorted { $0.t0 < $1.t0 },
                                   locales: ["auto"])
    }

    private func loadKit() async throws -> WhisperKit {
        do { return try await WhisperEngine.shared.kit(model: model) }
        catch { throw TranscriptionError.modelUnavailable("WhisperKit \(model): \(error)") }
    }

    /// One decoded frame's segments as utterances.
    ///
    /// **`modelSaid` is that frame's own detected language, never the first
    /// frame's.** A pass over a long window comes back as several results, one per
    /// 30-second frame, each having decided a language for itself; taking
    /// `results.first`'s tagged Korean phrases `en` whenever the opening frame
    /// happened to resolve that way.
    private func lines(_ segments: [TranscriptionSegment], modelSaid: String?) -> [Utterance] {
        segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Silence comes back as a confident fabrication, not as nothing.
            // See `WhisperSilence`.
            guard !WhisperSilence.isNotSpeech(seg) else { return nil }
            // Offsets **within this input**, milliseconds from its first sample.
            // The caller owns the mapping onto the session clock, because only it
            // knows which `AudioSegment` this audio came from.
            let t0 = Millis((Double(max(0, seg.start)) * 1000).rounded())
            let t1 = Millis((Double(max(max(0, seg.start), seg.end)) * 1000).rounded())
            // The script the line is written in, not what the model reported —
            // see `ScriptLocale`.
            let locale = ScriptLocale.resolve(text: text, modelSaid: modelSaid)
            return Utterance(t0: t0, t1: t1, speaker: nil, text: text,
                             conf: Double(exp(seg.avgLogprob)),
                             locale: locale.map(TranscriptCoverage.canonicalLocale))
        }
    }
}
