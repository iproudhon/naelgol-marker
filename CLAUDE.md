# Marker — working notes for Claude

Golf round tracking and replay from **audio + GPS**, for the whole group. Pre-alpha.
**Phase 1 (capture) is implemented and verified on macOS**; Phases 2–7 are still placeholders.

Read [`docs/PLAN.md`](docs/PLAN.md) before proposing work. It is the product and architecture
layer; [`docs/research-game-tracking.md`](docs/research-game-tracking.md) is the feasibility
research behind it and [`docs/poc-plan-round-reconstruction.md`](docs/poc-plan-round-reconstruction.md)
is the PoC that gates P1.

## Commands

```sh
swift build
swift test                                    # 14 tests, all green

# Record a round from the Mac — the Phase 1 gate, no phone needed.
swift run golfctl record --out Sessions --players steve,dave --course "Naelgol CC"
swift run golfctl record --out Sessions --seconds 60 --no-gps   # headless
swift run golfctl inspect Sessions/session-2026-08-24-1430

# Compile the package for iOS (the #if os(iOS) branches only build this way):
xcodebuild -scheme GolfCaptureMotion -destination 'generic/platform=iOS' build
```

**CoreLocation needs a bundle identifier**, so `golfctl record` on a Mac captures audio
and marks but no GPS track — `RoundSession.locationAvailable` reports this rather than
hanging, which is what the unbundled CLI used to do. The GPS track comes from the phone.

The iOS app is `Apps/Naelgol Marker/` (bundle id `com.naelgol.Naelgol-Marker`, iOS 26.5,
team NXSNHHAUQN). It builds:

```sh
cd "Apps/Naelgol Marker"
xcodebuild -scheme "Naelgol Marker" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build          # compile check, no device or profile needed
```

Device builds need the phone plugged in — the team has no registered devices, so provisioning
fails without one.

**`UIBackgroundModes` and `UIFileSharingEnabled` live in `Apps/Naelgol Marker/Info.plist`, not in
`INFOPLIST_KEY_*` build settings.** Xcode's Info.plist generator silently drops those two: the
settings resolve, and the keys never reach the built app. Everything else is an `INFOPLIST_KEY_*`.
That file also sits *outside* the `Naelgol Marker/` synchronized folder — inside it, Xcode copies
it as a resource too and the build fails with "Multiple commands produce Info.plist".

**Permission state is three-valued in the UI, not two,** and it must be `@Published`, not a
computed property. A bool renders a red ✗ next to Microphone before anyone has been *asked*;
a computed property never refreshes after the user answers a prompt, so the row stays on "?"
forever and the app looks like it never asked. Keep `RoundViewModel.Capability.Status`
(`ready` / `willAsk` / `denied` / `unavailable`), keep `capabilities` published, and call
`refreshCapabilities()` on appear, on `scenePhase == .active`, and after every request.
`canStart` gates on `.denied` only — "not asked yet" must never block a round.

**Permission is requested from the capability row, not only from Start.** Gating the prompt
behind "fill in the roster first, then tap Start" is what made it look like the app never
asked. Rows are tappable; denied rows open Settings.

**`LocationPermissionMonitor.escalate()` must return early unless `wantsAlways`.** Assigning
the `CLLocationManager` delegate fires `locationManagerDidChangeAuthorization` immediately, so
without that guard the app throws a location dialog on launch before the user has typed a name.

**Players are `Player`, not `String`** — `name` plus `aliases`, because a player is "steve" on
the card, "스티브" to one friend and "형" to another, often inside one hole. Attribution matches
spoken names against `allNames`, never a roster position. `Mark.player` / `Correction.player`
store `Player.id` (defaults to `name`). CLI syntax: `--players 'steve=스티브|형,dave'`.

**The setup screen is a `Form`, not a hand-rolled `VStack`.** The VStack version squeezed its
content when the keyboard appeared and the large navigation title landed on top of the players
field. `Form` + `.navigationBarTitleDisplayMode(.inline)` + `.scrollDismissesKeyboard` is what
fixes it; verified on device and in the simulator with the keyboard up.

The target uses an Xcode 16+ **synchronized root group**, so a `.swift` file dropped into
`Naelgol Marker/` joins the target automatically — no pbxproj edit needed.

## Invariants — violate these and the design stops working

- **Capture everything; the user corrects the rest.** *(Decision 2026-08-24 — Phase 0 is no longer
  a gate; the earlier "no capture code until the far-field test runs" rule is void. PLAN §3.)*
  Reconstruction output is a **draft the user amends**, never a final answer. Propose low-confidence
  shots rather than omit them — a wrong shot costs one tap to delete, a missing one is invisible.
  Every shot carries a confidence and the evidence behind it.
- **`Correction` is ground truth.** Same firewall as `Mark`/`Scorecard`: never in an evidence
  bundle, never in a prompt. Corrections are also the eval set — every one is a free labeled error
  for `GolfEval`, which is why the firewall matters more here than it did for `Mark`.
- **The app targets iOS 26; the package floor stays iOS 16 / macOS 13.** Deployment target and
  package platform floor are independent — do not raise `Package.swift` to match the app. iOS 26
  means `SpeechAnalyzer`/`SpeechTranscriber` with no `SFSpeechRecognizer` fallback; that fork is
  dead, don't reintroduce it.
- **Prompt and schema resolve from `--prompt` / `--schema` file paths**, never `Bundle.module`.
  Bundle resources force a rebuild per prompt edit; paths keep tuning to edit-and-rerun.
- **Ground truth must never reach the model input.** `Mark` / `Scorecard` / `Correction`
  (`Sources/GolfSessionFormat/Mark.swift`) are the answer key for eval only. Nothing in
  `GolfReconstruction` may import or reference them. *Currently a convention, not a structural
  guarantee — `GolfReconstruction` depends on `GolfSessionFormat`, so the compiler will not stop
  you. Splitting them into their own target was raised and deliberately deferred; see "Known gaps".*
- **One platform floor, in `Package.swift`.** SPM declares platforms per package, not per target,
  so the floor is the lowest any target needs (iOS 16 / macOS 13). Higher-floor APIs are gated with
  `@available` in source, never by raising the package floor. Per-target floors: PLAN §4.
- **`GolfCaptureCore` stays cross-platform** so the recorder runs on a Mac. iOS-only motion and
  barometer APIs live in `GolfCaptureMotion` — that split is the entire reason it exists.
- **`Transcriber` is a protocol.** The Apple-vs-WhisperKit ASR comparison is
  `golfctl --asr apple|whisperkit`, not a branch.
- **`AnthropicClient` knows nothing about golf.** Messages, model config, JSON schema. No golf
  types cross into it.
- **Every stage caches into the session folder.** Re-tuning a prompt must never re-run a 30-minute
  transcription.
- **One clock: milliseconds since epoch**, across every stream. See
  `Sources/GolfSessionFormat/SessionFolder.swift`.

## Never commit

Recorded rounds or credentials — `Sessions/`, `*.m4a`, `*.wav`, `.env`, `secrets.json`. Already in
`.gitignore`; keep it that way. Real audio of a foursome is other people's voices.

## LLM usage

Reconstruction calls Claude over raw HTTPS to `/v1/messages` — **Swift has no official Anthropic
SDK**. Before writing or changing any of that, load the `claude-api` skill; do not write model IDs
or pricing from memory.

## Relationship to `vipl`

`~/src/vipl` is the swing-analysis app this research started inside. Swing capture and pose
analysis are **out of scope here** (PLAN §8). The swing research doc stays there:
`~/src/vipl/docs/research-2026-08-body-club-3d.md`. If both ship, a swing video recorded during a
round joins a reconstructed shot by timestamp + coordinate — an integration, not a dependency.
`docs/research-game-tracking.md` §1 describes vipl's codebase, not this one, and says so.

## What exists

| Target | State |
|---|---|
| `GolfSessionFormat` | **Done.** Types, `JSONLWriter`/`JSONLReader`, `SessionFolder` I/O, `SessionClock` |
| `GolfCaptureCore` | **Done.** `AudioRecorder` (segmented), `LocationRecorder`, `RoundSession` |
| `GolfCaptureMotion` | **Done.** `MotionRecorder` — activity, pedometer, barometer. iOS-only |
| `golfctl` | `record` + `inspect` implemented; the rest print "not implemented" |
| Everything else | Placeholder files with TODOs |

Tests: 22 (1 skipped when the mic is already authorized). The iOS app launches in the
simulator; the simulator has no barometer or motion coprocessor, so those read empty there.

**No `.allowBluetooth` in the audio session, ever.** Connected AirPods would become the input
over HFP — narrowband and beamformed at the wearer's own mouth, recording the phone's owner
nicely while suppressing the other three players. That is the exact capture the product depends
on. `configureSession()` uses `.record` with no options and pins `.builtInMic`, and the resolved
route is written to `meta.audioRoute` so a bad round is distinguishable from a bad premise.

**`AVAudioSession` category is what grants background recording**, not `UIBackgroundModes:
audio`. `AudioRecorder.configureSession()` sets `.playAndRecord` + `setActive(true)` before
every segment opens. Remove it and the app records fine with the screen on and stops the
moment the phone goes in a pocket — i.e. the whole round, and macOS tests cannot catch it.

Audio is **segmented** (`audio-000.m4a`, `audio-001.m4a`, …) with an `audio.jsonl` index of
`AudioSegment` rows. A 4.5-hour recording will be interrupted by a call or Siri; each
interruption closes a segment and the resume opens the next, so no sample drifts behind a
single whole-file offset. Do not collapse this back to one file.

`golfctl` parses arguments by hand — swift-argument-parser arrives in Phase 3 with the
subcommands that need it.

## Known gaps

- `Mark`/`Scorecard`/`Correction` are in `GolfSessionFormat`, which `GolfReconstruction` depends
  on, so the firewall is convention, not structure. Moving them into their own target that only
  `GolfEval` depends on would make it real. **Raised 2026-08-24 and deliberately deferred** — do
  not restructure without asking. Until then: grep `GolfReconstruction` for `Mark`/`Correction`
  before shipping any bundle change.
- WhisperKit's iOS floor is still unverified (PLAN §4).
- **GPS duty cycling is not implemented.** Phase 1 records location continuously so there is an
  honest baseline to measure the 3–7× saving against (PLAN §5). Don't add it without a before/after.
- **The iOS app has never been run on a device.** Audio, session folder, and marks are verified on
  macOS; motion, barometer, background survival over a real 4.5-hour round, and battery cost are
  all unmeasured.
