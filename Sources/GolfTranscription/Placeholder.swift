// GolfTranscription — ASR + diarization behind one protocol, so the Phase 2 A/B
// is a runtime flag (golfctl --asr apple|whisperkit), not a code branch.
//
//   protocol Transcriber { func transcribe(audio: URL) async throws -> [Utterance] }
//
// A: AppleTranscriber      SpeechAnalyzer + SpeechTranscriber   @available(iOS 26, macOS 26, *)
// B: WhisperKitTranscriber WhisperKit large-v3 + SpeakerKit     (Pyannote v4 on the ANE)
//
// The `speaker` field carries an ACOUSTIC CLUSTER id, never a name. Mapping
// clusters to players is the LLM step — see docs/PLAN.md §4.
//
// TODO(phase-2): both impls + the diarization-quality metrics.

import Foundation
import GolfSessionFormat
