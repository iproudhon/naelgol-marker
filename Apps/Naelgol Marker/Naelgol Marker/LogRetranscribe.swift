import Foundation
import Combine
import GolfSessionFormat
import GolfTranscription

/// Read one log entry's audio again, with a bigger model.
///
/// **Why per entry rather than per round.** Measured on this Mac,
/// `openai_whisper-small` decodes at 1.5–2.7× realtime and a phone is slower, so a
/// `large-v3` pass over a 4.5-hour round is hours of a hot phone. The same model
/// over the twenty seconds somebody actually said "Chungmin made bogey" is
/// seconds. That is the whole argument for this shape: the big model is
/// unaffordable continuously and cheap on demand, and the golfer already knows
/// which line came out wrong — they are looking at it.
///
/// So there are two models, not one setting: a small one that keeps up live, and a
/// big one that is used only when asked. See `WhisperModelPicker`.
///
/// **What it writes is a superseding row in `log.jsonl`** — the same mechanism as
/// an edit, for the same reason. Nothing is overwritten, `LogEntry.byID` keeps the
/// original readable so a proposal citing it still renders its evidence, and the
/// new id makes `ExtractionCoverage` re-read it, which is correct: the text
/// changed, and that is the point.
///
/// **It never writes `transcript.jsonl` or `transcript.coverage.json`.** A
/// sub-range pass is not a whole-segment pass; recording coverage for it would
/// mark segments transcribed that were only partly read, and a segment marked done
/// is never read again.
@MainActor
final class LogRetranscribe: ObservableObject {

    /// Chain-root ids currently being re-read, so a row can show a spinner and the
    /// menu item cannot be tapped twice into two competing superseding rows.
    @Published private(set) var running: Set<String> = []
    @Published var failure: String?

    /// The recorded audio behind a log, if any is readable yet.
    ///
    /// Empty means one of three things and the UI says which: the log was typed,
    /// it predates `LogEntry.tEnd`, or — the common one — it was spoken into the
    /// burst that is **still recording**. An `.m4a` still being written cannot be
    /// opened at all, so the answer is "not until you stop", not an error.
    nonisolated static func spans(for log: LogEntry, in folder: SessionFolder) -> [AudioSpan] {
        guard log.hasAudioSpan, let end = log.tEnd else { return [] }
        return AudioSpans.resolve(from: log.t, to: end,
                                  in: folder.readAll(.audio, as: AudioSegment.self))
    }

    func run(_ log: LogEntry, in folder: SessionFolder, model: String, players: [Player]) async {
        guard !running.contains(log.id) else { return }
        running.insert(log.id)
        failure = nil
        defer { running.remove(log.id) }

        do {
            let text = try await Self.transcribe(log, in: folder, model: model, players: players)
            guard let text, !text.isEmpty else {
                failure = "Heard nothing in that recording with "
                        + WhisperModels.prettyName(model) + "."
                return
            }
            // **Re-read the head from disk.** `LogPlacement` grows the same chain
            // when a fix converges, and this pass takes seconds — editing the copy
            // the view is holding would fork the chain and throw away whichever
            // side lost.
            guard let head = LogStore.head(ofChainFrom: log.id, in: folder),
                  var next = head.edited(text: text)
            else { return }
            // The language is re-derived from the new text, by script — the old
            // tag described the words the small model produced, which are the ones
            // being replaced.
            next.locale = ScriptLocale.detect(text).map(TranscriptCoverage.canonicalLocale)
                ?? next.locale
            try LogStore.shared.append(next, to: folder)
        } catch {
            failure = "\(error)"
        }
    }

    /// The heavy half: decoding, off the main actor.
    ///
    /// **Each span is transcribed on its own and only the text is joined.** A burst
    /// can cross a segment boundary — the stall watchdog rotates mid-burst and an
    /// interruption closes one — and the audio between two segments *does not
    /// exist*. Concatenating the samples would hand the decoder a join that never
    /// happened, inside a 30-second frame; joining the words is the honest version.
    nonisolated private static func transcribe(_ log: LogEntry, in folder: SessionFolder,
                                               model: String,
                                               players: [Player]) async throws -> String? {
        let spans = spans(for: log, in: folder)
        guard !spans.isEmpty else { return nil }
        let audio = try AudioExcerpt.samples(of: spans, in: folder)
        let transcriber = WhisperTranscriber(model: model)
        let context = TranscriptionContext.forRound(players: players)
        var pieces: [String] = []
        for samples in audio {
            let result = try await transcriber.transcribe(samples: samples, context: context)
            let piece = result.utterances
                .sorted { $0.t0 < $1.t0 }
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.joined(separator: " ")
    }
}
