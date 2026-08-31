import XCTest
@testable import GolfTranscription
@testable import GolfReconstruction
@testable import GolfSessionFormat

/// The round is bilingual, so the vocabulary has to be.
final class GolfVocabularyTests: XCTestCase {

    func testKoreanIsInTheVocabularyAtAll() {
        XCTAssertTrue(GolfVocabulary.all.contains("버디"))
        XCTAssertTrue(GolfVocabulary.all.contains("드라이버"))
        XCTAssertTrue(GolfVocabulary.all.contains("오비"))
    }

    /// A hole is said as a compound, not as a bare number.
    func testHoleAndStrokeCompoundsAreGenerated() {
        XCTAssertTrue(GolfVocabulary.Korean.numbers.contains("18번홀"))
        XCTAssertTrue(GolfVocabulary.Korean.numbers.contains("1번홀"))
        XCTAssertTrue(GolfVocabulary.Korean.numbers.contains("5타"))
    }

    func testEnglishOrdinalsAreThereBecauseAHoleIsSaidBothWays() {
        XCTAssertTrue(GolfVocabulary.numbers.contains("seventh"))
        XCTAssertTrue(GolfVocabulary.numbers.contains("seven"))
    }

    /// The point of the glossary. Whisper transcribes 고구마 **correctly**; it is
    /// the meaning that is wrong outside golf, so this is a model-step problem and
    /// not a recognizer one.
    func testTheSlangThatIsNotAMisrecognitionIsInTheGlossary() {
        for said in ["고구마", "따블", "트", "유틸", "오비", "quad", "snowman"] {
            XCTAssertNotNil(GolfVocabulary.synonyms[said], "\(said) is missing from the glossary")
        }
    }

    /// **Not a substitution table.** Several keys are ordinary Korean syllables,
    /// so a `replacingOccurrences` pass over a log would corrupt sentences that
    /// had nothing to do with golf. The values are explanations for a reader, not
    /// replacement tokens — which is why they are allowed to be phrases.
    func testTheGlossaryExplainsRatherThanReplaces() {
        let hybrid = GolfVocabulary.synonyms["고구마"] ?? ""
        XCTAssertTrue(hybrid.contains("하이브리드"))
        XCTAssertTrue(hybrid.count > "하이브리드".count,
                      "an explanation, not a token to swap in")
    }

    func testGlossaryLinesAreStableSoTwoRunsAreComparable() {
        XCTAssertEqual(GolfVocabulary.glossaryLines, GolfVocabulary.glossaryLines)
        XCTAssertEqual(GolfVocabulary.glossaryLines.count, GolfVocabulary.synonyms.count)
    }

    func testTheRoundsContextCarriesBothLanguagesAndTheRoster() {
        let context = TranscriptionContext.forRound(
            players: [Player(name: "steve")])
        XCTAssertTrue(context.contextualStrings.contains("steve"))
        XCTAssertTrue(context.contextualStrings.contains("버디"))
        XCTAssertTrue(context.contextualStrings.contains("birdie"))
    }

    /// **The separation that keeps the decoder prompt safe.** `promptTokens`
    /// conditions Whisper on prior text, so it is evidence about what language the
    /// audio is in — a couple of hundred English golf words in front of a Korean
    /// phrase pushes toward the bug the user reported twice. Only `names` reaches
    /// the prompt; `contextualStrings` keeps the whole vocabulary for engines where
    /// the knob is not a language signal.
    func testNamesAreSeparateFromTheVocabularyBecauseOnlyNamesReachTheDecoder() {
        let context = TranscriptionContext.forRound(
            players: [Player(name: "steve"),
                      Player(name: "dave")])
        XCTAssertEqual(Set(context.names), ["steve", "dave"])
        XCTAssertFalse(context.names.contains("birdie"),
                       "a golf word in the prompt is a vote for English")
        XCTAssertFalse(context.names.contains("버디"))
    }

    /// Two people typed with the same name is an ordinary roster, and a repeated
    /// term in a Whisper prompt is a nudge toward repeating it.
    func testNamesAreDedupedSoARepeatedNameDoesNotEatThePromptBudget() {
        let context = TranscriptionContext.forRound(
            players: [Player(name: "steve"),
                      Player(name: "STEVE")])
        XCTAssertEqual(context.names.count, 1)
    }

    func testAnEmptyRosterMeansNoPromptAtAll() {
        XCTAssertTrue(TranscriptionContext.forRound(players: []).names.isEmpty,
                      "a bare <|startofprev|> biases the model toward ending early")
    }

    // MARK: - Reaching the model step

    /// **Injected, never imported.** `GolfReconstruction` must not depend on
    /// `GolfTranscription` — that would drag WhisperKit into the one target whose
    /// point is being framework-agnostic — so the wiring is a parameter and this
    /// is the test that the two ends still meet.
    func testTheGlossaryReachesTheExtractionPrompt() {
        let text = LogExtraction.instructions(players: [Player(name: "steve")],
                                              glossary: GolfVocabulary.synonyms)
        XCTAssertTrue(text.contains("고구마"))
        XCTAssertTrue(text.contains("하이브리드"))
    }

    /// A caller that has no glossary loses only the slang — it must not leave a
    /// dangling header with nothing under it.
    func testNoGlossaryAddsNoSection() {
        let text = LogExtraction.instructions(players: [Player(name: "steve")])
        XCTAssertFalse(text.contains("dictionary does not say"))
    }

    func testTheGlossarySectionIsSortedSoThePromptIsStable() {
        let a = LogExtraction.instructions(players: [], glossary: GolfVocabulary.synonyms)
        let b = LogExtraction.instructions(players: [], glossary: GolfVocabulary.synonyms)
        XCTAssertEqual(a, b)
    }
}
