import XCTest
import WhisperKit
@testable import GolfTranscription

/// The three rules the engine was chosen under *(user, 2026-08-27)*: WhisperKit,
/// multilingual, **no translation**, and **never told a language**.
final class WhisperOptionsTests: XCTestCase {

    /// **The one that was actually wrong.** `task` is not a switch the decoder
    /// reads — it is expressed as the `<|transcribe|>` token in the prefill, so
    /// with `usePrefillPrompt = false` it becomes a value nothing acts on.
    /// Measured that day: Korean came back detected as `ko` and rendered in fluent
    /// English ("스티브가 버디를 했어요" → "Steve did a Buddy"). Translation, from
    /// the setting meant to forbid it, under the right language tag.
    func testTranscribeIsActuallyEnforcedAndNotJustRequested() {
        for volatile in [true, false] {
            let o = WhisperDecoding.options(volatile: volatile)
            XCTAssertEqual(o.task, .transcribe, "translation is never wanted")
            XCTAssertTrue(o.usePrefillPrompt,
                          "without the prefill, task: .transcribe is inert and Whisper translates")
        }
    }

    /// Never pinned, and detection turned on explicitly — the two go together or
    /// the first does nothing. `detectLanguage` defaults to `!usePrefillPrompt`,
    /// which with the prefill on is `false`, which prefills `<|en|>` and drops
    /// Korean in silence.
    func testLanguageIsNeverSpecifiedAndDetectionIsOn() {
        for volatile in [true, false] {
            let o = WhisperDecoding.options(volatile: volatile)
            XCTAssertNil(o.language, "the round is bilingual; pinning one loses the other")
            XCTAssertTrue(o.detectLanguage)
        }
    }

    /// A partial pass exists to put words on screen while someone is still talking,
    /// so it must not spend time on fallbacks it will re-run in half a second. The
    /// committing pass keeps the full ladder, because that output is kept.
    func testTheVolatilePassIsCheaperThanTheCommittingOne() {
        XCTAssertEqual(WhisperDecoding.options(volatile: true).temperatureFallbackCount, 0)
        XCTAssertGreaterThan(WhisperDecoding.options(volatile: false).temperatureFallbackCount, 0)
    }

    /// **English-only builds cannot produce Korean at all, and the failure is
    /// silence** — indistinguishable from nobody having spoken. They are never
    /// offered, so the picker cannot be used to lose half a round by accident.
    func testEnglishOnlyAndDistilledBuildsAreNeverOffered() {
        XCTAssertFalse(WhisperModels.isMultilingual("openai_whisper-small.en"))
        XCTAssertFalse(WhisperModels.isMultilingual("openai_whisper-tiny.en"))
        XCTAssertFalse(WhisperModels.isMultilingual("openai_whisper-base_en"))
        XCTAssertFalse(WhisperModels.isMultilingual("distil-whisper_distil-large-v3"))

        XCTAssertTrue(WhisperModels.isMultilingual("openai_whisper-small"))
        XCTAssertTrue(WhisperModels.isMultilingual("openai_whisper-large-v3-v20240930_turbo"))
        XCTAssertTrue(WhisperModels.isMultilingual(WhisperModels.defaultID))
    }

    /// The fallback list is what a course with no signal renders, so it must obey
    /// the same rule as the fetched one.
    func testTheOfflineFallbackListIsMultilingualToo() {
        XCTAssertFalse(WhisperModels.fallback.isEmpty)
        for m in WhisperModels.fallback {
            XCTAssertTrue(WhisperModels.isMultilingual(m.id), "\(m.id) is English-only")
        }
        XCTAssertTrue(WhisperModels.fallback.contains { $0.id == WhisperModels.defaultID },
                      "the default must be offerable offline")
    }

    /// A cache keyed on `"whisperkit"` alone would serve `tiny`'s transcript for a
    /// `large-v3` run and report the round already done — the trap
    /// `TranscriptCoverage.transcriber` exists to close, one level in.
    func testCoverageIdentityCarriesTheModel() {
        XCTAssertNotEqual(WhisperTranscriber(model: "openai_whisper-tiny").runID,
                          WhisperTranscriber(model: "openai_whisper-small").runID)
        XCTAssertTrue(WhisperTranscriber(model: "openai_whisper-tiny").runID
                        .contains("openai_whisper-tiny"))
    }

    /// Whisper is told nothing and decides per frame, so the set that "ran" is one
    /// pass with detection on. Reporting `en_US`/`ko_KR` would claim a per-language
    /// guarantee it does not make; reporting what it *detected* would key the cache
    /// on what the golfers happened to say, so a quiet round re-transcribes forever.
    func testEffectiveLocalesAreAutoNotTheRequestedPair() async {
        let locales = await WhisperTranscriber()
            .effectiveLocales(for: TranscriptionContext(locales: ["en-US", "ko-KR"]))
        XCTAssertEqual(locales, ["auto"])
    }

    /// **String surgery, checked against every name the repo actually publishes.**
    /// The tokenizer is a separate download from a different repo, so getting this
    /// wrong fails only when there is no network — i.e. on the first tee, never at
    /// the desk. Names carry a turbo marker, a release date and a quantised size in
    /// varying combinations.
    func testTokenizerBaseNameForEveryPublishedVariant() {
        let expected: [String: String] = [
            "openai_whisper-tiny": "tiny",
            "openai_whisper-base": "base",
            "openai_whisper-small": "small",
            "openai_whisper-large-v2": "large-v2",
            "openai_whisper-large-v2_949MB": "large-v2",
            "openai_whisper-large-v2_turbo": "large-v2",
            "openai_whisper-large-v2_turbo_955MB": "large-v2",
            "openai_whisper-large-v3": "large-v3",
            "openai_whisper-large-v3_947MB": "large-v3",
            "openai_whisper-large-v3_turbo": "large-v3",
            "openai_whisper-large-v3_turbo_954MB": "large-v3",
            "openai_whisper-large-v3-v20240930": "large-v3",
            "openai_whisper-large-v3-v20240930_626MB": "large-v3",
            "openai_whisper-large-v3-v20240930_turbo": "large-v3",
            "openai_whisper-large-v3-v20240930_turbo_632MB": "large-v3",
        ]
        for (variant, base) in expected {
            XCTAssertEqual(WhisperEngine.baseName(variant), base, "for \(variant)")
        }
    }

    /// A variant with weights but no tokenizer must report **not** downloaded:
    /// answering yes sends the loader down the `download: false` path with a config
    /// that cannot work, and it fails when the button is pressed rather than while
    /// there is still signal to fix it.
    func testAModelWithNoWeightsIsNotDownloaded() {
        XCTAssertFalse(WhisperEngine.isDownloaded("openai_whisper-not-a-real-variant"))
    }

    /// **Whisper invents speech out of silence and a golf round is mostly
    /// silence.** Observed in the app on the gap between two takes: `"Bye."` — a
    /// short, confident, entirely fabricated line, which without this filter
    /// becomes a `LogEntry` the extraction pass reads as something a golfer said.
    func testSilenceHallucinationsAreRejected() {
        // The shape of a fabrication: the model says "probably not speech" and is
        // not confident in what it wrote anyway.
        XCTAssertTrue(WhisperSilence.isHallucinatedSilence(noSpeechProb: 0.95,
                                                           avgLogprob: -1.8))
    }

    /// **Both halves are required**, and each alone rejects something real.
    /// `noSpeechProb` alone throws away someone talking two fairways away — which
    /// is this product's hard case, not an edge case. `avgLogprob` alone throws
    /// away unusual but genuine phrasing, which on a golf course is most of it.
    func testQuietSpeechAndOddPhrasingBothSurvive() {
        XCTAssertFalse(WhisperSilence.isHallucinatedSilence(noSpeechProb: 0.9,
                                                            avgLogprob: -0.3),
                       "quiet but confidently transcribed — a distant player")
        XCTAssertFalse(WhisperSilence.isHallucinatedSilence(noSpeechProb: 0.1,
                                                            avgLogprob: -1.9),
                       "clearly speech, oddly worded — most golf talk")
    }

    /// **Whisper describes audio it cannot transcribe, because its training data
    /// is subtitles.** `skipSpecialTokens` does not touch these — they are ordinary
    /// generated text, not `<|…|>` control tokens. Seen in the app as a log row
    /// reading exactly `[BLANK_AUDIO]`.
    func testCaptionAnnotationsAreNotSpeech() {
        for t in ["[BLANK_AUDIO]", "[MUSIC]", "(wind blowing)", "♪", " ... ", ""] {
            XCTAssertTrue(WhisperSilence.isAnnotation(t), "\(t) is an annotation")
        }
    }

    /// The test is "the whole line is one bracketed aside", so a real sentence that
    /// happens to contain brackets still gets filed.
    func testASentenceContainingBracketsIsStillSpeech() {
        XCTAssertFalse(WhisperSilence.isAnnotation("Steve made par (finally)."))
        XCTAssertFalse(WhisperSilence.isAnnotation("[Steve] and [Dave] are away"))
        XCTAssertFalse(WhisperSilence.isAnnotation("스티브가 버디를 했어요."))
    }

    /// **The bug that made the app re-download half a gigabyte on every launch,
    /// twice reported.** `HubApi` appends its `huggingface` path component *only*
    /// when `downloadBase` is nil:
    ///
    ///     if let downloadBase { self.downloadBase = downloadBase }
    ///     else { self.downloadBase = documents.appending(component: "huggingface") }
    ///
    /// …and then resolves a repo to `<downloadBase>/models/<repo>`. Passing a bare
    /// Application Support directory therefore wrote to `<base>/models/…` while this
    /// code looked in `<base>/huggingface/models/…`, so the cache was never found.
    /// These two assertions are the shape of `HubApi.localRepoLocation`; if the
    /// library changes it, this fails here rather than on a phone.
    func testDownloadBaseCarriesTheHuggingfaceComponent() {
        XCTAssertEqual(WhisperEngine.downloadBase.lastPathComponent, "huggingface")
        XCTAssertEqual(WhisperEngine.downloadBase.deletingLastPathComponent().path,
                       WhisperEngine.supportDirectory.path)
    }

    /// The canonical destination for a variant with nothing on disk anywhere:
    /// `<downloadBase>/models/<repo>/<variant>`.
    func testTheCanonicalModelFolderMatchesTheHubLayout() {
        let variant = "openai_whisper-not-a-real-variant"
        let expected = WhisperEngine.downloadBase
            .appendingPathComponent("models/\(WhisperEngine.repo)/\(variant)")
        XCTAssertEqual(WhisperEngine.modelFolder(variant).standardizedFileURL.path,
                       expected.standardizedFileURL.path)
        XCTAssertFalse(WhisperEngine.hasWeights(variant))
    }
}
