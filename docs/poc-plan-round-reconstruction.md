# PoC Plan — LLM Round Reconstruction (standalone app)

Date: 2026-08-24 · Companion to [`research-game-tracking.md`](./research-game-tracking.md) (§-refs below are to that doc)

**Decisions taken:**
- Build as a **separate proof-of-concept**, not inside vipl.
- Ship it as an **importable Swift package** with both halves — capture *and* reconstruction — as library products. The PoC app and the CLI are thin shells over those libraries.
- **All Swift, no Python.** See §2 for why that's now viable and what it costs.

---

## 0. What "separate PoC" buys you — it retires two of the three killers

The research doc ordered risks for a *shipping* app. A PoC reorders them:

| Constraint in the doc | Status in a PoC |
|---|---|
| **G3** — `UIBackgroundModes: audio` on a record-only app is a Guideline 2.5.4 rejection | **Out of scope.** A development / TestFlight build never faces review. Continuous 4.5-hour capture can be tested for real. |
| **§7 API key** — can't ship a key in a binary; BYO-key vs proxy backend | **Deferred entirely.** A dev-only build can embed a key it never distributes. Decide BYO-vs-proxy after the PoC proves the idea. |
| **iOS 17 floor** (vipl's constraint, from its swing research) | **Gone.** Target **iOS 26** with no fallback — `SpeechAnalyzer`, `SpeechTranscriber`, `SpeechDetector`, and native diarization all available day one. |
| **Battery** (§5 duty cycling, Q1/Q9) | **Not a PoC concern.** Carry a battery pack. Optimisation is a production problem; correctness is the PoC's problem. |
| **Q12a — far-field capture** | **Still the #1 risk. Unchanged, and now first in line.** |

Net: the PoC's job is to answer **Q12a → Q12 → Q15**, in that order, and nothing else.

### Non-goals — explicitly out of scope

Course data / OSM (§6) · SwiftData round store (§8) · vipl integration and swing-video anchors (§0) · location duty cycling (§5) · App Intents / Siri (§3) · UI polish · multi-round history · privacy/consent UX beyond verbal consent at the tee.

---

## 1. Two structural decisions

### 1a. Phase 0 needs **zero code**

The highest-risk question (Q12a: can a pocketed phone hear the other three players?) is answerable with **Voice Memos, a paper scorecard, and Whisper on a Mac**. Do not write a line of Swift until Phase 0 has a number.

### 1b. Split into a dumb recorder + an off-device pipeline

```
   ON DEVICE (thin, boring, rarely changes)      OFF DEVICE (all the iteration)
   ┌─────────────────────────────┐               ┌──────────────────────────────┐
   │  audio → .m4a               │  AirDrop /    │  ASR (A/B: Apple vs Whisper) │
   │  GPS → gps.jsonl            │  Files.app    │  evidence bundle builder     │
   │  motion → motion.jsonl      │ ────────────▶ │  Claude call (prompt tuning) │
   │  MARK taps → marks.jsonl    │   session/    │  eval harness vs ground truth│
   └─────────────────────────────┘               └──────────────────────────────┘
```

Both sides are **library targets in one Swift package**. The iOS app is a shell over `GolfCapture`; the `golfctl` macOS CLI is a shell over the rest. Nothing interesting lives in an app target.

### 1c. Record raw audio and keep it — PoC-only, and deliberately inverted from production

§9 says production must **transcribe and discard**. The PoC must do the **opposite**: you cannot re-record a round, and every session has to be replayable through the pipeline arbitrarily many times as ASR and prompts change.

This makes **verbal consent from the whole group a real prerequisite for Phase 0**, not paperwork — you are keeping 4.5 hours of their conversation on a disk. Say so at the first tee, and delete on request.

---

## 2. Module architecture

### 2a. All-Swift is viable — the Python dependency is gone

The earlier sketch assumed Phase 2's Whisper path needed Python (pyannote for diarization). It doesn't: **`argmax-oss-swift`** (the renamed WhisperKit repo, v1.0.0, MIT) ships **WhisperKit + SpeakerKit + TTSKit** in one SPM package, with SpeakerKit doing on-device diarization from **Pyannote v4** CoreML models on the ANE. `FluidAudio` is a second Swift-native option. So the entire A/B — Apple `SpeechAnalyzer` vs Whisper + pyannote diarization — runs natively, and nothing needs porting to production later.

**The cost you accepted:** prompt/schema iteration through a build cycle instead of a script re-run. §2d bounds it.

### 2b. Package layout

```
GolfRound/                       (one SPM package)
  Package.swift
  Sources/
    GolfSessionFormat/           ← the contract. Codable types + session folder I/O.
    GolfCaptureCore/             ← audio + location capture, marks
    GolfCaptureMotion/           ← CMMotionActivity + CMPedometer  (iOS-only)
    GolfTranscription/           ← Transcriber protocol + Apple / WhisperKit impls
    AnthropicClient/             ← minimal URLSession client for /v1/messages
    GolfReconstruction/          ← bundle builder, prompt+schema, self-verification
    GolfEval/                    ← metrics
    golfctl/                     ← macOS CLI executable (ArgumentParser)
  Resources/
    prompt.md                    ← default prompt (overridable at runtime, §2d)
    round.schema.json            ← default output schema
  Tests/
Apps/
  GolfPoC.xcodeproj              ← thin iOS shell over GolfCaptureCore + Motion
```

### 2c. Platform floors — the whole point of the tiering

Tiered so **vipl can import the useful halves without jumping to iOS 26**. Verify each floor against the SDK before committing it to `Package.swift`; the ones marked *(verify)* are the ones a wrong guess would bite at integration time.

| Target | Floor | Why | vipl (iOS 16.1, →17) can import? |
|---|---|---|---|
| `GolfSessionFormat` | iOS 16 / macOS 13 | Codable only, zero dependencies | **Yes, today** |
| `GolfCaptureCore` | iOS 17 / macOS 14 | `CLBackgroundActivitySession`, `CLLocationUpdate.liveUpdates()` *(verify: iOS 17)*. `AVAudioEngine` and CoreLocation are cross-platform, so this stays macOS-testable. | **Yes, at iOS 17** |
| `GolfCaptureMotion` | iOS 17, **iOS-only** | `CMMotionActivityManager` / `CMPedometer` are iOS-only — this is the *only* reason capture can't be fully cross-platform, which is why it's a separate target | Yes, at iOS 17 |
| `GolfTranscription` | iOS 16 / macOS 13 for the package; **Apple path gated `@available(iOS 26, macOS 26)`**, WhisperKit path `macOS 14+` *(verify iOS floor)*, SpeakerKit `iOS 16 / macOS 13` | Two impls behind one protocol | Package yes; **Apple path not until vipl is on 26** |
| `AnthropicClient` | iOS 16 / macOS 13 | URLSession only. Not golf-specific — reusable anywhere | **Yes, today** |
| `GolfReconstruction` | iOS 16 / macOS 13 | Pure data + HTTP | **Yes, today** |
| `GolfEval` | iOS 16 / macOS 13 | Pure data | Yes, today |

Splitting motion out means the recorder's audio+location half **runs on a Mac** — you can develop and test the pipeline without a device in the loop.

### 2d. Bounding the Swift iteration cost

Choosing Swift trades script-speed iteration for a build cycle. Three mitigations, all cheap:

1. **`golfctl` is a macOS CLI, not an app.** `swift run golfctl …` is seconds — no simulator, no device, no signing.
2. **Prompt and schema resolve from an explicit path, not `Bundle.module`.** `Bundle.module` resources still require a rebuild. `golfctl` must take `--prompt <path>` and `--schema <path>`, defaulting to the bundled resources. Two lines, and it's what actually keeps prompt tuning to an edit-and-rerun loop.
3. **Every stage caches into the session folder.** `transcribe` → `bundle` → `reconstruct` → `eval` are independently re-runnable; re-tuning a prompt never re-runs a 30-minute transcription.

### 2e. Boundaries worth enforcing in types, not discipline

- **`Mark` lives in a separate type from everything the bundle builder can see.** Ground truth must be structurally incapable of leaking into the LLM input — not merely omitted by convention.
- **`Transcriber` is a protocol**, so the Phase 2 A/B is a `golfctl --asr apple|whisperkit` flag, not a code branch.
- **`AnthropicClient` knows nothing about golf.** It takes a model config, messages, and a JSON schema.

### 2f. `AnthropicClient` — no official Swift SDK, so raw HTTPS

`POST https://api.anthropic.com/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`.

Structured output:

```json
"output_config": { "format": { "type": "json_schema", "schema": { … } } }
```

**Model config must be a per-model struct, not an `if`** — Phase 3 sweeps all three on day one, so this branch is exercised immediately:

| Model | Thinking | `output_config.effort` |
|---|---|---|
| `claude-haiku-4-5` | `{"type": "enabled", "budget_tokens": N}` | **Errors — must be omitted** |
| `claude-sonnet-5` | `{"type": "adaptive"}` | Supported |
| `claude-opus-5` | `{"type": "adaptive"}` | Supported |

Two more details: at ~14.4K output tokens you're near the non-streaming guidance ceiling (~16K) — **use streaming for the reconstruction call**. And keep a `POST /v1/messages/batches` path for model sweeps at 50% cost.

Key from environment or Keychain, never committed. Dev-only, per §0.

---

## 3. Phases and kill gates

### Phase 0 — Far-field capture test (no code) · ~1 day

**Answers Q12a. Gates everything.**

1. Play a real 9- or 18-hole round with a foursome. Verbal consent first.
2. Phone in the usual pocket/bag position, **Voice Memos recording continuously**, highest quality setting.
3. Keep a paper scorecard, and note wall-clock time at each hole's start.
4. Afterward: transcribe on a Mac with Whisper large-v3.
5. **Hand-label a 20-minute slice**: for each player, count utterances actually spoken vs utterances that survived into the transcript.

**Commit to these thresholds before running the test:**

| Non-holder utterance capture rate | Verdict |
|---|---|
| **< 40%** | Foursome premise is **dead**. Stop. Pivot to per-player devices, an external/lapel mic, or a phone-holder-only product. Do not write the capture app. |
| **40–70%** | Viable, but attribution will need heavy review UI. Proceed with reduced expectations and design the review flow early. |
| **> 70%** | Proceed as planned. |

Measure the **phone holder separately** — their rate will be high and will flatter the average. The number that matters is the other three.

Phase 0 also yields **eval round #1** for free.

> If Phase 0 fails, the remaining phases do not run. That is the point of doing it first and for free.

---

### Phase 1 — `GolfSessionFormat` + `GolfCapture*` + app shell · ~3–4 days

Build the format target first (it is the contract), then the capture libraries, then a deliberately boring one-screen iOS shell over them. The app target should contain **only** SwiftUI views and wiring.

**The MARK button is the highest-value component — design it first.**

- Big tap target, reachable one-handed, works from the lock screen ideally (Live Activity or a watchOS complication if cheap; otherwise just the app in the foreground between shots).
- Each tap writes `{t, player, lat, lon, accuracy}` — with a 4-way player selector defaulting to last-used.
- This is **ground truth inline**, instead of reconciling a paper scorecard against a 4.5-hour timeline afterwards. It also gives the evidence bundle confirmed shot anchors — the PoC analogue of §7's swing-video anchors.

Everything else is mechanical:

| Component | Spec |
|---|---|
| Audio (`GolfCaptureCore`) | `AVAudioEngine` tap → `.m4a`. **First session at high fidelity** (128 kbps or lossless) so you can measure what compression costs capture rate; settle the bitrate after. `UIBackgroundModes: audio`, session started in the foreground (G2 still applies technically, just not commercially). |
| Location (`GolfCaptureCore`) | `CLLocationUpdate.liveUpdates()` + `CLBackgroundActivitySession`, `kCLLocationAccuracyBest`, ~1 Hz, log everything. No duty cycling — that's a production concern. |
| Motion (`GolfCaptureMotion`) | `CMMotionActivityManager` + `CMPedometer` → JSONL. iOS-only; kept separate so the rest stays macOS-testable. |
| Round control (`GolfSessionFormat`) | Start / Stop. Writes a session folder. |
| Export | Session folder visible in Files.app + AirDrop. Round-trips through `GolfSessionFormat` on the Mac side. |

**Storage** (4.5 h): audio 32 MB @16 kbps → 130 MB @64 kbps → 260 MB @128 kbps; GPS @1 Hz ≈ 1.9 MB; motion ≈ 1.5 MB. Nothing here is a constraint.

**Session folder format:**

```
session-2026-09-14-1430/
  meta.json          {course, players[], start, end, device, audioFormat}
  audio.m4a
  gps.jsonl          {t, lat, lon, hAcc, vAcc, speed, course}
  motion.jsonl       {t, activity, confidence, steps, distance}
  marks.jsonl        {t, player, lat, lon, note?}      ← ground truth
  scorecard.json     {player: {hole: strokes}}          ← entered after the round
```

All timestamps: epoch milliseconds, one clock, no exceptions.

---

### Phase 2 — Transcription A/B · ~2–4 days

**Answers Q12 and refines Q12a. Run both paths over the same audio — this is a measurement, not a choice.** Both are Swift-native (§2a), behind the `Transcriber` protocol, selected with `golfctl --asr apple|whisperkit`.

| Path | What it tests |
|---|---|
| **A: Apple** `SpeechAnalyzer` + `SpeechTranscriber`, `@available(macOS 26)` | Whether the production on-device path is viable at all, and whether its diarization is real (Q12) |
| **B: `argmax-oss-swift`** — WhisperKit large-v3 + **SpeakerKit** (Pyannote v4 on the ANE) | The quality ceiling, and a fallback if A has no usable diarization. Also a Swift-native diarizer vipl could ship. |

Runtime on Apple silicon: large-v3 ≈ 8–15× realtime → ~20–35 min for a 4.5 h round; turbo/distil ≈ 30–50× → ~6–10 min. Transcripts cache into the session folder (§2d), so this cost is paid once per session, not once per prompt edit.

**Output format** (identical from both paths, so downstream doesn't care):

```jsonl
{"t0": 4512300, "t1": 4514800, "speaker": "S2", "text": "you're away", "conf": 0.81}
```

**Metrics — report separately, so a failure names its own stage:**
- **Capture rate** per player (Q12a), on a hand-labelled slice.
- **Diarization cluster purity / DER** (Q12) — do the clusters correspond to people, even without names?
- Word error rate on golf-relevant utterances specifically (club names, numbers, scoring terms), not overall WER.

**Kill gate:** if neither path yields usable speaker clusters, §7's ASR-clusters/LLM-identity division of labor collapses to content-only attribution. That is a much weaker product — decide explicitly whether to continue.

---

### Phase 3 — Evidence bundle + reconstruction · ~2–3 days

`GolfReconstruction` + `AnthropicClient`, driven by `golfctl reconstruct`.

**3a. Bundle builder.** Compress per §7: GPS → ~110 stationary segments (not 1,620 fixes), transcript with speaker clusters, motion-derived walk/stop segmentation. **`marks.jsonl` is structurally unreachable from the builder** (§2e) — it's the answer key.

**3b. Reconstruction.** Single call over the whole round (~29K input), streamed. Structured output via `output_config.format` against `round.schema.json`. Per-shot `confidence`, plus a `conflicts[]` array the model fills when constraints disagree.

**3c. Self-verification**, mechanically, after the call: shot count vs announced score; turn-order plausibility; shot distance vs named club; hole scores vs stated total.

**Model sweep — build the eval set *before* picking a model.** Run `claude-haiku-4-5` / `claude-sonnet-5` / `claude-opus-5` over the same bundles and compare. Cost per round: ~$0.10 / $0.30 / $0.51 (halved with the Batch API). At that spread, **pick on accuracy, not price.**

*API notes:* see §2f — the per-model config struct. `golfctl sweep` should drive the three models through the Batch API.

---

### Phase 4 — `GolfEval` · ~2 days (build alongside Phase 3, not after)

Score reconstruction against `marks.jsonl` + `scorecard.json`. **Split metrics by question:**

| Metric | Answers | Notes |
|---|---|---|
| Shot-count accuracy per player per hole | Q15 | Did it find the right number of shots? |
| **Player attribution accuracy** | Q15 | **The metric that decides the feature.** It's the one thing deterministic detection cannot do at all. |
| Score accuracy per hole | Q15 | The user-visible headline |
| Club accuracy (where a club was named) | Q15 | Precision on the subset, plus recall over all shots |
| Capture rate / diarization purity | Q12a / Q12 | Carried forward from Phase 2, so a bad reconstruction score can be traced to its cause |

**Target: 5–10 recorded rounds** before trusting any number. Phase 0 supplies the first.

---

## 4. Effort summary

| Phase | Work | Effort | Gate |
|---|---|---|---|
| 0 | Far-field test — no code | ~1 day + a round | **< 40% non-holder capture → stop** |
| 1 | `GolfSessionFormat` + capture libs + app shell (MARK button first) | 3–4 days | Session folder round-trips device→Mac |
| 2 | `GolfTranscription` — Apple vs WhisperKit+SpeakerKit A/B | 2–4 days | No usable speaker clusters → reassess |
| 3 | `AnthropicClient` + `GolfReconstruction` | 3–4 days | — |
| 4 | `GolfEval` (parallel with 3) | 2 days | Attribution accuracy decides go/no-go |
|   | **Total** | **~2.5 weeks + 5–10 rounds of data collection** | |

Data collection, not coding, is the schedule driver. Start recording rounds during Phase 1.

---

## 5. What would make you stop

1. **Phase 0 < 40% non-holder capture.** The foursome premise fails at the physics layer. Everything downstream is moot.
2. **No usable diarization from either ASR path.** Content-only attribution is a much weaker product; decide deliberately rather than drifting into it.
3. **Attribution accuracy below usefulness** even with good transcripts. If the review UI has to correct most shots, the user may as well have tapped them in — and the MARK button already proves tapping works.

---

## 6. If it works — what carries into production

**Nothing needs porting.** Every target is Swift and platform-tiered (§2c), so vipl imports `GolfSessionFormat`, `GolfReconstruction`, `AnthropicClient`, and `GolfEval` **at its current iOS 16.1/17 floor**, and `GolfCapture*` once it's on 17. Only `GolfTranscription`'s Apple path waits for iOS 26 — and the WhisperKit+SpeakerKit path is available before then.

What re-opens on the way to shipping:

- **G3** — continuous audio vs Guideline 2.5.4 → per-shot audio windows as the fallback (§7).
- **API key** — BYO-key vs proxy backend (§7); or **Private Cloud Compute** if Q14 lands well (32K context would just fit a round and dissolve both this and most of §9).
- **§9 consent** — explicit all-player consent at round start, and reverting to transcribe-and-discard.
- **Battery** (§5), **course data** (§6), **persistence** (§8), and **vipl integration** (§0).
