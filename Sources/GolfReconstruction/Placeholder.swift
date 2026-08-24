// GolfReconstruction — evidence bundle -> Claude -> structured round.
//
// MUST NOT import or reference GolfSessionFormat.Mark. Ground truth is the answer
// key; keeping it unreachable is a type-level guarantee, not a convention.
//
// Bundle compression (docs/research-game-tracking.md §7): 1,620 raw GPS fixes
// become ~110 stationary segments; transcript carries speaker clusters; motion
// gives walk/stop segmentation; altitude gives per-hole elevation change.
// Whole round lands near 29K input tokens — one call, not per-hole chunks.
//
// Prompt and schema resolve from an explicit path with Resources/ as the default.
// Bundle.module would require a rebuild per prompt edit; a path does not.
//
// TODO(phase-3): BundleBuilder, RoundReconstructor, SelfVerifier.

import Foundation
import GolfSessionFormat
import AnthropicClient
