// golfctl — macOS CLI. The iteration surface for everything off-device.
//
// Every stage caches into the session folder, so stages are independently
// re-runnable: re-tuning a prompt never re-runs a 30-minute transcription.
//
//   golfctl transcribe <session> --asr apple|whisperkit
//   golfctl bundle     <session>
//   golfctl reconstruct <session> --model claude-haiku-4-5 \
//                                 --prompt Resources/prompt.md \
//                                 --schema Resources/round.schema.json
//   golfctl eval       <session>
//   golfctl sweep      <session>...      # all three models via the Batch API
//
// --prompt/--schema take PATHS, defaulting to the bundled resources. That is what
// keeps prompt tuning to an edit-and-rerun loop instead of a rebuild.

import Foundation

// TODO(phase-2): adopt swift-argument-parser and implement the subcommands.
print("golfctl: not implemented yet — see docs/PLAN.md")
