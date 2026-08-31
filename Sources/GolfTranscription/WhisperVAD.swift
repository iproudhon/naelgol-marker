import Foundation
import GolfSessionFormat

/// Where the speech is in a window — and, more often, whether there is any.
///
/// **This is the single most effective thing in the Whisper path.** Measured over
/// 301,317 inferences on non-speech audio, Whisper hallucinates **40.3%** of the
/// time; with a VAD in front of it, **0.2%** — and the word error rate *improves*,
/// because the model stops spending frames on noise (arXiv:2501.11378). The same
/// paper measured Whisper's own knobs — silence threshold, beam size — as barely
/// helping, which is exactly what happened here: `noSpeechProb` and `avgLogprob`
/// caught the pure-noise cases and let every realistic one through.
///
/// It also fixes a bug that looked unrelated. **Whisper decides the language from
/// the first 30-second frame**, so leading non-speech decides it. Measured
/// 2026-08-27 on one English sample: clean speech with 4 s of digital silence
/// either side → `en`; quiet, noisy speech with no padding → `en`; quiet, noisy
/// speech *with* noisy padding → **`nn`** (Norwegian) plus a looping glyph
/// hallucination. Neither low SNR nor padding alone breaks it — **noisy non-speech
/// does**, and a golf course is never digitally silent.
///
/// ## Why the threshold is relative and not a number
///
/// `EnergyVAD`'s fixed 0.02 was tried first and **it ate a whole spoken phrase** on
/// a quiet far-field sample: the speech sat at 0.031 peak over a 0.009 noise floor,
/// so a third of the speech frames fell below the line. An absolute threshold
/// cannot be right in a wind gust and in a clubhouse car park at the same time, and
/// there is no real far-field golf audio to fit one to. So the floor is estimated
/// from the window's **own** quietest frames and speech has to stand above it.
///
/// ## The asymmetry is deliberate
///
/// A frame wrongly called speech costs one hallucinated line, which the filters
/// downstream are there to catch. A frame wrongly called silence costs **what
/// somebody said**, permanently, and the product's first invariant is to capture
/// everything and let the user delete. So a window is declared speechless only when
/// *nothing anywhere in it* stands out from its own floor.
public struct WhisperVAD: Sendable {

    /// 100 ms, the usual frame for energy VAD: long enough to average out a glottal
    /// pulse, short enough to place the start of a word.
    public var frameSeconds: Double = 0.1

    /// How far above the window's noise floor a frame has to sit to be speech.
    /// 1.6× is about 4 dB.
    public var floorRatio: Float = 1.6

    /// A hard floor, for a window that is genuinely near-silent — a pocket indoors.
    /// Without it the ratio test on digital silence multiplies zero by 1.6.
    public var absoluteFloor: Float = 0.0035

    /// Kept before the first speech frame when trimming, so a soft word onset is
    /// not clipped off the front of the phrase.
    public var preRollSeconds: Double = 0.3

    public init() {}

    /// Root-mean-square energy per frame.
    public func frameEnergies(_ samples: [Float], sampleRate: Double) -> [Float] {
        let step = max(1, Int(frameSeconds * sampleRate))
        guard samples.count >= step else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / step)
        var i = 0
        while i + step <= samples.count {
            var sum: Float = 0
            for j in i..<(i + step) { sum += samples[j] * samples[j] }
            out.append((sum / Float(step)).squareRoot())
            i += step
        }
        return out
    }

    /// The energy a frame must exceed to count as speech in *this* window.
    public func threshold(for energies: [Float]) -> Float {
        guard !energies.isEmpty else { return absoluteFloor }
        let sorted = energies.sorted()
        // Tenth percentile, not the minimum: one artificially quiet frame should
        // not define the floor for the whole window.
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        return max(absoluteFloor, floor * floorRatio)
    }

    /// Frame indices of the first and last speech in this window, or nil when there
    /// is none.
    public func speechFrames(_ samples: [Float], sampleRate: Double) -> (first: Int, last: Int)? {
        let energies = frameEnergies(samples, sampleRate: sampleRate)
        guard !energies.isEmpty else { return nil }
        let t = threshold(for: energies)
        guard let first = energies.firstIndex(where: { $0 > t }),
              let last = energies.lastIndex(where: { $0 > t })
        else { return nil }
        return (first, last)
    }

    /// Sample index the window should start at, so the decoder is not handed the
    /// noise that would otherwise choose the language for it. Nil when there is no
    /// speech at all.
    ///
    /// Includes `preRollSeconds` of lead-in, and never returns a negative index.
    public func speechStart(_ samples: [Float], sampleRate: Double) -> Int? {
        guard let frames = speechFrames(samples, sampleRate: sampleRate) else { return nil }
        let step = max(1, Int(frameSeconds * sampleRate))
        let preRoll = Int(preRollSeconds * sampleRate)
        return max(0, frames.first * step - preRoll)
    }

    /// Seconds of non-speech at the end of the window — what says a phrase is over.
    public func trailingSilence(_ samples: [Float], sampleRate: Double) -> Double {
        guard let frames = speechFrames(samples, sampleRate: sampleRate) else {
            return Double(samples.count) / sampleRate
        }
        let step = max(1, Int(frameSeconds * sampleRate))
        let lastSample = min(samples.count, (frames.last + 1) * step)
        return Double(samples.count - lastSample) / sampleRate
    }
}

// MARK: - What language a line is actually in

public enum ScriptLocale {

    /// The language of a transcript line, from **the script it is written in**.
    ///
    /// **More reliable than asking Whisper, and free.** Whisper reports a language
    /// per 30-second frame and gets it wrong on short or noisy windows — measured
    /// here as correct English text tagged `ko`, and elsewhere as `nn`. The text it
    /// produced, meanwhile, says what language it is without ambiguity: Hangul is
    /// Korean, Latin is not.
    ///
    /// Returns nil when the line carries no letters at all — "240", "3" — because a
    /// number is not evidence of a language and guessing one puts a wrong tag on a
    /// row that could have stayed honest. The caller falls back to what the model
    /// reported.
    public static func detect(_ text: String) -> String? {
        var hangul = 0, latin = 0, other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F:
                hangul += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            case 0x3040...0x30FF, 0x4E00...0x9FFF:
                other += 1                      // Japanese / Chinese — neither of ours
            default:
                break
            }
        }
        guard hangul + latin + other > 0 else { return nil }
        if hangul >= latin && hangul >= other { return "ko" }
        if latin >= other { return "en" }
        return nil
    }

    /// The tag to store: the script when it is unambiguous, otherwise whatever the
    /// model said.
    public static func resolve(text: String, modelSaid: String?) -> String? {
        detect(text) ?? modelSaid
    }
}
