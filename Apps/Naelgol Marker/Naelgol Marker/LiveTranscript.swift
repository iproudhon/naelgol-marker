import Foundation
import AVFoundation
import Combine
import GolfSessionFormat
import GolfCourse
import GolfTranscription

/// What the microphone is hearing, while it is hearing it.
///
/// **A display and input feed. It is never the transcript.** The authoritative
/// transcript is `SessionTranscriber` over the closed `.m4a` segments — that pass
/// sees each segment whole, which is a strictly better recognition problem than a
/// sliding window, and it is the artifact Phase 2's ASR comparison is run over.
/// Nothing here writes `transcript.jsonl`.
///
/// What it *does* write is `log.jsonl`: a committed phrase becomes a `LogEntry`
/// with `source: .spoken`, which is what that case has always meant and the same
/// stream the typed box writes to. A log is an observation, not ground truth, so it
/// is model-visible by design and no firewall is crossed.
///
/// **The engine is WhisperKit** *(user decision, 2026-08-27)*, multilingual,
/// never told a language and never asked to translate — see `WhisperDecoding`.
/// Whisper is a batch model, so "live" is `WhisperLiveTranscriber` re-decoding a
/// rolling window and committing at a silence. Consequences visible on screen:
/// words appear a beat behind the speaker and **get rewritten as more context
/// arrives**. That is the model working. It is also why a hypothesis is drawn
/// dimmed and italic and never stored — a hypothesis rendered like a fact is the
/// same failure as a simulated position drawn like a GPS fix.
@MainActor
final class LiveTranscript: ObservableObject {

    /// Recording and transcribing fail **separately**, and saying so is the point.
    /// A burst records its `.m4a` whatever the recognizer is doing; that file is
    /// what the batch pass needs, and losing the round to save the subtitle is the
    /// wrong trade.
    enum Status: Equatable {
        case off
        /// Getting ready. `downloading` distinguishes "reading half a gigabyte off
        /// the disk" (seconds) from "fetching it over the network" (minutes, and
        /// impossible on a course with no signal) — two very different waits that
        /// look identical if the pane just says "loading".
        case preparing(model: String, downloading: Bool)
        case listening(String)
        /// Stop was tapped and the decoder is finishing the last phrase. Seconds,
        /// not instant, because Whisper decodes a whole window per pass.
        case finishing
        case unavailable(String)
    }

    @Published private(set) var status: Status = .off

    /// The running hypothesis. **Display only** — replaced on every pass and never
    /// written anywhere.
    @Published private(set) var hypothesis = ""
    /// Language of the last thing decoded, as Whisper detected it. Nil until then.
    @Published private(set) var detected: String?

    /// How many phrases this burst has added to its entry. The visible proof that
    /// a round with the phone in a pocket is actually capturing something.
    @Published private(set) var heard = 0

    private var transcriber: WhisperLiveTranscriber?

    /// **One log entry per recording, not per phrase** *(user decision,
    /// 2026-08-27)*. A burst is one thing the golfer did — they pressed record,
    /// said what happened, and stopped — so it reads as one row rather than as
    /// however many times they paused for breath.
    ///
    /// Grown by **superseding**, not by buffering until Stop: the row appears on
    /// screen with the first phrase, and a round that dies mid-burst keeps what was
    /// already said. `LogEntry.current` collapses the chain for display, so the
    /// timeline shows one row that gets longer.
    ///
    /// **The head is re-read from disk before each extension**, because
    /// `LogPlacement` grows the same chain — see `LogStore.head(ofChainFrom:in:)`.
    private var burstLogID: String?
    private var burstText = ""

    /// Chain roots this recogniser has written since `beginMarkerSession()`.
    ///
    /// **The Marker sheet's Cancel needs them and nothing else does.** A phrase is
    /// committed to `log.jsonl` the instant it finalises — that is deliberate, so a
    /// round that dies mid-burst keeps what was said — so Cancel cannot un-write
    /// them and has to *tombstone* them instead *(user decision, 2026-08-28:
    /// "delete what the burst wrote")*. `burstLogID` alone is not enough: it is
    /// cleared when a burst ends, and one visit to the sheet can open and close
    /// several.
    private(set) var markerSessionEntries: [String] = []

    /// Start counting again — called when the Marker sheet opens.
    func beginMarkerSession() { markerSessionEntries = [] }

    /// Start listening over audio someone else is already recording.
    ///
    /// - Returns: the running recognizer and the format its buffers must be in.
    /// - Parameter fix: where the phone is **and how good that is**, asked at the
    ///   moment a phrase commits rather than captured now — a burst runs for
    ///   minutes. The accuracy is not decoration: `LogEntry.isPlaced` reads
    ///   `hAcc ?? .infinity`, so a coordinate without one leaves every spoken log
    ///   in the convergence backlog asking the radio for a position it already had.
    func start(folder: SessionFolder,
               players: [Player],
               model: String,
               fix: @escaping @MainActor () -> (Coordinate, Double)?)
    async throws -> (WhisperLiveTranscriber, AVAudioFormat) {
        hypothesis = ""
        detected = nil
        heard = 0
        // Saying which wait this is beats a silent minute that reads as the button
        // not working — and a download on the first tee is a thing the user can
        // act on (go back to the car park, or pick a smaller model).
        if await WhisperEngine.shared.isLoaded(model: model) {
            status = .listening(model)
        } else {
            status = .preparing(model: model,
                                downloading: !WhisperEngine.isDownloaded(model))
        }

        let live = WhisperLiveTranscriber(model: model)
        let context = TranscriptionContext.forRound(players: players)
        let format: AVAudioFormat
        do {
            format = try await live.start(context: context) { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.receive(line, folder: folder, fix: fix)
                }
            }
        } catch {
            status = .unavailable("\(error)")
            throw error
        }
        transcriber = live
        status = .listening(model)
        return (live, format)
    }

    /// Stop, committing whatever is still in the window.
    ///
    /// The tail of the window is an uncommitted hypothesis at the moment the
    /// microphone stops, and dropping it looks exactly like the recognizer missing
    /// the end of a hole — which is when scores get said.
    func stop() async {
        let live = transcriber
        transcriber = nil
        if live != nil { status = .finishing }
        await live?.finish()
        hypothesis = ""
        status = .off
        // The next burst is a new entry. Reset after the drain, so the last phrase
        // still lands in the entry it belongs to.
        burstLogID = nil
        burstText = ""
    }

    private func receive(_ line: LiveLine,
                         folder: SessionFolder,
                         fix: @MainActor () -> (Coordinate, Double)?) {
        let text = line.utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let locale = line.utterance.locale { detected = locale }

        guard line.isFinal else {
            hypothesis = text
            return
        }
        hypothesis = ""
        guard !text.isEmpty else { return }

        do {
            if let rootID = burstLogID {
                try extend(rootID: rootID, with: text, until: line.utterance.t1,
                           folder: folder)
            } else {
                try begin(text, line: line, folder: folder, fix: fix)
            }
            heard += 1
        } catch {
            NSLog("live transcript: log append failed: \(error)")
        }
    }

    /// The first phrase of a burst: a new row.
    ///
    /// **No hole.** `LogEntry.hole` means "nearest hole to a measured fix", and
    /// stamping the hole the card happens to be showing would put a second,
    /// unmeasured meaning in one field — the `defaultTee` trap again.
    /// `LogPlacement` fills in position and hole afterwards, the same path the typed
    /// box takes: written first, placed second.
    ///
    /// Stamped with the phrase's own start on the session clock, not `now`:
    /// `LiveAudioClock` has already mapped it, and Whisper commits a phrase seconds
    /// after it was said. The entry keeps that first timestamp however long it grows
    /// — it is when the golfer started talking.
    private func begin(_ text: String, line: LiveLine, folder: SessionFolder,
                       fix: @MainActor () -> (Coordinate, Double)?) throws {
        let here = fix()
        guard let entry = try LogStore.shared.append(text, source: .spoken, to: folder,
                                                     coordinate: here?.0,
                                                     accuracy: here?.1,
                                                     locale: line.utterance.locale,
                                                     at: line.utterance.t0,
                                                     until: line.utterance.t1)
        else { return }
        burstLogID = entry.id
        burstText = text
        markerSessionEntries.append(entry.id)
    }

    /// Every later phrase: a superseding row carrying the whole entry so far.
    ///
    /// **A note for whoever builds the extraction pass.** Every supersede is a new
    /// id, and `ExtractionCoverage` is keyed on the row id precisely so an edited
    /// log is re-read. A growing burst entry therefore looks like a new log on every
    /// phrase, and a pass triggered per arrival would re-read the whole accumulated
    /// text each time — the runaway shape that file exists to prevent. Extraction
    /// should read a burst entry when the burst **ends**, not while it grows.
    private func extend(rootID: String, with phrase: String, until tEnd: Millis,
                        folder: SessionFolder) throws {
        guard let head = LogStore.head(ofChainFrom: rootID, in: folder) else { return }
        burstText = burstText.isEmpty ? phrase : burstText + " " + phrase
        guard var next = head.edited(text: burstText) else { return }
        // **`t` stays; `tEnd` advances.** The entry began when the golfer started
        // talking and now runs to the end of what they have said so far, so
        // `[t, tEnd]` names the whole burst's audio — pauses included, because the
        // recording includes them too. This is what a re-transcribe reads back.
        next.tEnd = max(tEnd, head.tEnd ?? tEnd)
        // **Re-read the language from the whole entry.** The tag was set from the
        // first phrase, and an entry that spans a burst can span both languages —
        // it should describe what it now contains, not how it started.
        next.locale = ScriptLocale.detect(burstText).map(TranscriptCoverage.canonicalLocale)
            ?? next.locale
        let written = try LogStore.shared.append(next, to: folder)
        // Follow our own chain from the row we just wrote, so the next extension
        // starts from it rather than from the original root.
        burstLogID = written.id
    }
}
