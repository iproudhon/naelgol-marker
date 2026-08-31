import Foundation
import GolfSessionFormat

/// One audio file in, utterances out.
///
/// A protocol rather than a branch, because Phase 2 is a **measurement**: Apple's
/// on-device path and WhisperKit are run over the same audio and compared
/// (`golfctl --asr apple|whisperkit`). Two implementations behind one type is what
/// makes that a runtime flag.
///
/// **Deliberately not `@available`-gated.** The package floor is iOS 16 / macOS 13
/// and the Apple implementation needs 26; putting the availability on the protocol
/// would drag the whole target up. It goes on the conformance instead.
public protocol Transcriber: Sendable {
    /// Stable identity of the *implementation*.
    static var id: String { get }

    /// Identity written into `TranscriptCoverage`, which is `id` plus anything
    /// that changes the output.
    ///
    /// **An instance member, because for some engines the model is a runtime
    /// choice.** Whisper's variant is picked by the user, and a cache keyed on
    /// `"whisperkit"` alone would serve `tiny`'s transcript for a `large-v3` run
    /// and report the round already done — the same trap the transcriber field
    /// exists to close, one level in. Defaulted, so an engine with one model does
    /// not have to think about it.
    var runID: String { get }

    /// Transcribe one file.
    ///
    /// Times in the returned utterances are **offsets within this file**, in
    /// milliseconds from its first sample — not session-clock times. The caller
    /// owns the mapping, because only it knows which `AudioSegment` this file is.
    /// See `AudioTimeline`.
    func transcribe(file: URL, context: TranscriptionContext) async throws -> TranscriptionResult

    /// Which of `context.locales` this transcriber can actually run, resolved
    /// **before** any audio is read.
    ///
    /// The driver needs this up front rather than after the first segment, because
    /// it is what the cache is keyed on: a device with no Korean model produces an
    /// English-only transcript, and comparing the *request* against that coverage
    /// would re-transcribe the whole round on every pass while still never
    /// producing Korean. Defaulted, so a transcriber with nothing to resolve does
    /// not have to think about it.
    func effectiveLocales(for context: TranscriptionContext) async -> [String]
}

public extension Transcriber {
    var runID: String { Self.id }

    func effectiveLocales(for context: TranscriptionContext) async -> [String] {
        context.locales
    }
}

/// What one file's pass produced.
///
/// Carries `locales` as well as the lines because **a bilingual pass can half
/// succeed**: the round asks for English and Korean and the device has only the
/// English model. Returning the lines alone would let the caller record the
/// *request* as coverage and mark the segment done, so the Korean half would never
/// run again and nothing would show it was missing.
///
/// `locales` is "these recognizers ran over this audio", **not** "these recognizers
/// produced text". A quiet stretch yields nothing in either language and is still
/// fully transcribed — the same distinction `TranscriptCoverage` exists to make.
public struct TranscriptionResult: Sendable {
    public var utterances: [Utterance]
    /// Canonical (`"en_US"`), sorted.
    public var locales: [String]

    public init(utterances: [Utterance], locales: [String]) {
        self.utterances = utterances
        self.locales = TranscriptCoverage.canonical(locales)
    }
}

/// What the recognizer is told about the round before it starts.
///
/// **This is now load-bearing rather than a nicety.** Diarization was cut, so
/// attribution is content-only — the model works out who did what purely from what
/// was said. That collapses if "Steve" comes back as "steep" and "I'm hitting
/// seven" as "I'm hitting Kevin". Biasing the recognizer toward the names actually
/// spoken and the closed vocabulary of golf is the cheapest defence available.
public struct TranscriptionContext: Sendable {
    /// Every language the round is expected to be played in, BCP-47.
    ///
    /// **Plural because one locale cannot cover a bilingual round, and the failure
    /// is silent.** Measured 2026-08-27: `en_US` does not garble Korean speech, it
    /// *drops* it — absence, not error. `ko_KR` transcribes both but turns
    /// 보기 (bogey) into 고기 (meat). Both recognizers run over the same audio and
    /// both transcripts are kept, tagged by `Utterance.locale`; their errors are
    /// uncorrelated, and reconciling them is the model step's job, not this
    /// layer's. research-live-transcription.md §0.
    public var locales: [String]
    /// Everything the recognizer should expect to hear: player names and their
    /// aliases, clubs, scoring terms, lies.
    public var contextualStrings: [String]

    /// Just the roster — every name the group actually says out loud.
    ///
    /// **Separate from `contextualStrings` because Whisper's version of this knob
    /// is a language signal, and the vocabulary is the dangerous half.**
    /// `DecodingOptions.promptTokens` conditions the decoder on prior text, so a
    /// couple of hundred English golf words is evidence that the audio is English
    /// — the inverse of the bug that was reported twice ("I said English and it
    /// came out Korean", one language stuck across a whole burst). Names are short
    /// and, in a bilingual roster, written in both scripts, so they carry the
    /// attribution signal without carrying a verdict about the language.
    ///
    /// Which matters more here than it would anywhere else: diarization was cut,
    /// so a spoken name is the **only** attribution signal there is.
    public var names: [String]

    /// The default is the pair, not the phone's language: a group that speaks only
    /// English loses nothing but a little battery, while a group that switches
    /// mid-sentence loses half the round.
    public static let defaultLocales = ["en-US", "ko-KR"]

    public init(locales: [String] = TranscriptionContext.defaultLocales,
                contextualStrings: [String] = [],
                names: [String] = []) {
        self.locales = locales
        self.contextualStrings = contextualStrings
        self.names = names
    }

    /// The round's own vocabulary: every name the group actually says out loud,
    /// plus golf's closed vocabulary.
    public static func forRound(players: [Player],
                                locales: [String] = TranscriptionContext.defaultLocales,
                                extra: [String] = []) -> TranscriptionContext {
        // `allNames`, not `name` — a player called only "형" by one friend and
        // "스티브" by another is attributable by those and by nothing else.
        let names = dedupe(players.flatMap(\.allNames))
        return TranscriptionContext(
            locales: locales,
            contextualStrings: dedupe(names + GolfVocabulary.all + extra),
            names: names)
    }

    private static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs {
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case unsupportedPlatform(String)
    case localeUnsupported(String)
    case modelUnavailable(String)
    case audioUnreadable(URL, underlying: String)
    case noLocaleAvailable([String])

    public var description: String {
        switch self {
        case .unsupportedPlatform(let s): return "transcription unavailable: \(s)"
        case .localeUnsupported(let l): return "no on-device model for locale \(l)"
        case .modelUnavailable(let s): return "speech model unavailable: \(s)"
        case .audioUnreadable(let u, let e): return "cannot read \(u.lastPathComponent): \(e)"
        case .noLocaleAvailable(let ls):
            return "no on-device speech model for any of \(ls.joined(separator: ", "))"
        }
    }
}
