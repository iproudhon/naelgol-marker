// GolfEval — reconstruction accuracy against marks.jsonl + scorecard.json.
//
// Metrics split BY QUESTION so a bad score names its own stage:
//   capture rate per player        (Q12a — far-field, gates everything)
//   diarization cluster purity/DER (Q12)
//   shot-count accuracy            (Q15)
//   PLAYER ATTRIBUTION accuracy    (Q15 — the metric that decides the feature)
//   score accuracy per hole        (Q15)
//   club accuracy where named      (Q15)
//
// TODO(phase-4): metric implementations, per-round + aggregate reports.

import Foundation
import GolfSessionFormat
import GolfReconstruction
