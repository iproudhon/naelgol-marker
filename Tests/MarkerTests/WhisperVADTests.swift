import XCTest
@testable import GolfTranscription

/// The gate that fixed both reported bugs at once: phantom "Thank you"s, and
/// English coming back as Korean.
final class WhisperVADTests: XCTestCase {
    private let sr = 16_000.0
    private let vad = WhisperVAD()

    /// Deterministic pseudo-noise: a test that fails one run in fifty is worse
    /// than no test.
    private func noise(_ seconds: Double, level: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        return (0..<Int(seconds * sr)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 23) - 1) * level
        }
    }

    private func tone(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * sr)).map { i in
            sinf(2 * .pi * 220 * Float(i) / Float(sr)) * level
        }
    }

    /// **The user's report.** Whisper hallucinates on 40.3% of non-speech
    /// inferences and "thank you" is a quarter of them (arXiv:2501.11378). The fix
    /// is not to filter the output, it is not to ask.
    func testANoiseOnlyWindowHasNoSpeech() {
        XCTAssertNil(vad.speechStart(noise(5, level: 0.01), sampleRate: sr))
        XCTAssertNil(vad.speechStart(noise(5, level: 0.0009), sampleRate: sr))
        XCTAssertNil(vad.speechStart([Float](repeating: 0, count: Int(sr * 5)), sampleRate: sr))
    }

    /// **A fixed threshold ate a whole spoken phrase**, which is how this came to
    /// be relative. Speech at 0.03 over a 0.009 floor is quiet far-field talk, and
    /// `EnergyVAD`'s 0.02 default cut a third of its frames — "Steve is away."
    /// vanished from a transcript.
    func testQuietSpeechOverANoisyFloorIsStillSpeech() {
        let samples = noise(4, level: 0.009) + tone(2, level: 0.03) + noise(4, level: 0.009)
        guard let start = vad.speechStart(samples, sampleRate: sr) else {
            return XCTFail("quiet speech was mistaken for noise — this is the bug")
        }
        // Trimmed to just before the speech, with the pre-roll kept.
        let seconds = Double(start) / sr
        XCTAssertGreaterThan(seconds, 3.4, "trimmed too little to fix language detection")
        XCTAssertLessThan(seconds, 4.0, "the pre-roll must survive or word onsets clip")
    }

    /// **The asymmetry, asserted.** A frame wrongly called speech costs one
    /// hallucinated line that the filters catch; a frame wrongly called silence
    /// costs what somebody said, permanently. So a window is speechless only when
    /// *nothing anywhere in it* stands out.
    func testOneLoudMomentIsEnoughToKeepAWindow() {
        var samples = noise(10, level: 0.009)
        let at = Int(sr * 5)
        for (i, v) in tone(0.4, level: 0.06).enumerated() { samples[at + i] = v }
        XCTAssertNotNil(vad.speechStart(samples, sampleRate: sr))
    }

    /// The commit signal. A phrase ends where speech stops.
    func testTrailingSilenceIsMeasuredFromTheLastSpeech() {
        let samples = tone(2, level: 0.08) + noise(3, level: 0.004)
        XCTAssertEqual(vad.trailingSilence(samples, sampleRate: sr), 3.0, accuracy: 0.25)
        XCTAssertEqual(vad.trailingSilence(noise(3, level: 0.004), sampleRate: sr), 3.0,
                       accuracy: 0.05, "a window with no speech is all trailing silence")
    }

    /// A digitally silent window multiplies a zero floor by the ratio, so the
    /// absolute floor has to carry it.
    func testDigitalSilenceDoesNotDefeatTheRelativeThreshold() {
        let energies = [Float](repeating: 0, count: 40)
        XCTAssertEqual(vad.threshold(for: energies), vad.absoluteFloor)
    }
}

/// Tagging a line by the script it is written in, rather than believing the model.
final class ScriptLocaleTests: XCTestCase {

    /// **Measured, not assumed.** Whisper reported correct English text as `ko` on
    /// a noisy sample and as `nn` on another; the text says what language it is.
    func testScriptBeatsWhatTheModelClaimed() {
        XCTAssertEqual(ScriptLocale.resolve(text: "Steve is away.", modelSaid: "ko"), "en")
        XCTAssertEqual(ScriptLocale.resolve(text: "스티브가 버디를 했어요.", modelSaid: "en"), "ko")
        XCTAssertEqual(ScriptLocale.resolve(text: "Dave found the bunker", modelSaid: "nn"), "en")
    }

    /// A number is not evidence of a language. Guessing one puts a wrong tag on a
    /// row that could have stayed honest, so the model's answer stands.
    func testALineWithNoLettersKeepsTheModelsAnswer() {
        XCTAssertNil(ScriptLocale.detect("240"))
        XCTAssertEqual(ScriptLocale.resolve(text: "240", modelSaid: "ko"), "ko")
        XCTAssertNil(ScriptLocale.resolve(text: "3 - 2", modelSaid: nil))
    }

    /// A mixed line goes to whichever script carries it — the same rule Whisper
    /// applies per frame, but applied to the text it actually produced.
    func testAMixedLineGoesToTheDominantScript() {
        XCTAssertEqual(ScriptLocale.detect("스티브가 버디를 했어요"), "ko")
        XCTAssertEqual(ScriptLocale.detect("Steve made par on 7"), "en")
    }
}
