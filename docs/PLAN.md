# Marker — Plan

Date: 2026-08-24 · Status: pre-alpha, nothing implemented

Golf round tracking and replay from **audio + GPS**, for the whole group.

Foundation: [`research-game-tracking.md`](./research-game-tracking.md) (feasibility) and
[`poc-plan-round-reconstruction.md`](./poc-plan-round-reconstruction.md) (the PoC that gates
everything). This document is the product and architecture layer over both.

---

## 1. The idea in one paragraph

A golf party narrates its own round continuously — *"you're away"*, *"I'm hitting seven"*,
*"I'm in the bunker"*, *"what'd you make?"*, *"bogey"*. That is a dense, self-labelling event
stream, and golf's rules make it checkable: furthest from the hole plays first, strokes
accumulate, every hole ends with an announced score. Marker records the conversation, the GPS
track, and the barometric elevation, and reconstructs the round shot-by-shot **for every player
in the group** — not just the phone's owner. Rounds accumulate into a record you can replay on a
map, and into the only honest basis for suggesting a shot: what *you* have actually done here
before.

**Why an LLM and not detection heuristics:** GPS cannot separate four people walking the same
fairway. Language can. Attribution is the one thing sensor fusion cannot do at all, and it is the
metric the whole product lives or dies on.

---

## 2. Product scope — four pillars

| # | Pillar | What it is | Depends on |
|---|---|---|---|
| **P1** | **Capture, reconstruct, correct** | Record audio + GPS + motion + altitude for a round; reconstruct a shot-by-shot draft for all players; the user amends it | Nothing — no longer gated (§3) |
| **P2** | **Record & replay** | Past rounds and past holes, persisted; scrub a round back on a timeline | P1 |
| **P3** | **Map with elevation** | The round on a map, per-hole elevation profile, tee→green delta | Capture only — **independently useful, ships without P1** |
| **P4** | **Play suggestion** | "From here, on this hole, at this elevation delta — here's what you've done before" | P2 + several rounds of history |

### Sequencing consequence

**P3 does not depend on reconstruction.** A map with real elevation is useful the first time you
walk a hole, and it needs nothing but the capture layer. If reconstruction turns out weak (§3), P3 and a correction-driven
manual-entry P2 still make a real app. Build P3 early for that reason, not last.

P4 is honest only with history. Cold start is **silence**, not generic advice — every golf app
already tells you a 7-iron goes 150 yards. Marker's claim is narrower and truer: *you* hit this
hole four times, and here is what happened.

---

## 3. Capture everything, correct the rest

**Decision, 2026-08-24: Phase 0 is no longer a gate.** Far-field capture rate (Q12a) is still worth
measuring, but not as a stop-the-world precondition. The reasoning that replaces it:

> Collect as much as the phone can hear, derive what is derivable, and let the user correct the
> rest. A reconstruction that gets 70% of the round right and is *editable* is a product. A
> reconstruction that waits for perfect audio is not.

This changes the shape of P1 rather than its existence:

- **Reconstruction must be a draft, not an answer.** Output is a proposal the user amends — add a
  missed shot, fix an attribution, delete a phantom stroke, correct a score.
- **Corrections are first-class data**, persisted in the session folder alongside the round
  (`corrections.jsonl`), not a UI-only edit applied to a view model.
- **Derivation carries the load audio drops.** A shot the microphone missed can still be inferred:
  GPS discontinuity, a stationary→walking transition after a stationary window, a stroke count that
  does not reconcile with an announced score. The reconstruction prompt should be told to propose
  low-confidence shots rather than omit them — a shot the user deletes costs one tap; a shot never
  proposed is invisible.
- **Confidence must be visible.** Every shot carries a confidence and the evidence it rests on, so
  the user knows where to look. This is now part of the output schema, not a nicety.

**Corrections are the eval set.** This is the real upside. Every correction is a free labeled error
in exactly the format `GolfEval` needs — no paper scorecards, no separate ground-truth collection
pass. The eval set grows with use instead of with dedicated effort, which is what makes the
"5–10 real rounds" of Q15 tractable. Consequence: **`Correction` is ground truth and must obey the
same firewall as `Mark`** — never in an evidence bundle, never in a prompt. See §4.

**Q12a is still worth running**, opportunistically, because the answer changes prompt design
(how much to lean on derivation) and hardware strategy (per-player devices, an Apple Watch mic).
Method and thresholds stay in [`poc-plan-round-reconstruction.md`](./poc-plan-round-reconstruction.md) §3.
It no longer blocks anything.

---

## 4. Architecture

One Swift package, thin app and CLI shells over it. Nothing interesting lives in an app target.

```
   ON DEVICE                                      OFF DEVICE (all the iteration)
   ┌──────────────────────────────┐               ┌──────────────────────────────┐
   │ GolfCaptureCore   audio, GPS │  AirDrop /    │ GolfTranscription  ASR + diar │
   │ GolfCaptureMotion motion, alt│  Files.app    │ GolfReconstruction bundle→LLM │
   │ GolfStore         history    │ ────────────▶ │ GolfEval           metrics    │
   │ GolfMap           map+relief │   session/    │ golfctl            the CLI    │
   │ GolfInsight       suggestion │               └──────────────────────────────┘
   └──────────────────────────────┘
              └── GolfSessionFormat: the contract both sides speak ──┘
```

### Platform floors

**Decision, 2026-08-24: the Marker iOS app targets iOS 26.** That is a *deployment target on the
app*, not the package floor — the two are independent knobs. `Package.swift` keeps the *lowest*
floor any target needs (iOS 16 / macOS 13), because SPM declares platforms once per package, and
higher-floor APIs are gated with `@available` in source. Keeping the package low is what preserves
the "importable module" property: another app (vipl at iOS 16.1/17) can still consume
`GolfSessionFormat`, `GolfReconstruction`, `AnthropicClient`, and `GolfEval`.

**What iOS 26 buys, and what it retires:** `SpeechAnalyzer` / `SpeechTranscriber` are available
day one — long-form, on-device, no ~1-minute session cap, with `SpeechDetector` for VAD. **The
`SFSpeechRecognizer` fallback fork is dead**; do not carry it as a live decision. `GolfTranscription`'s
Apple path stays `@available(iOS 26, macOS 26)` so the package floor can remain low.

| Target | Effective floor | Note |
|---|---|---|
| `GolfSessionFormat` | iOS 16 / macOS 13 | Codable only, zero dependencies |
| `GolfCaptureCore` | iOS 17 / macOS 14 *(verify)* | `CLBackgroundActivitySession`, `CLLocationUpdate.liveUpdates()`. Cross-platform — **the recorder runs on a Mac** |
| `GolfCaptureMotion` | iOS 17, **iOS-only** | `CMMotionActivityManager` / `CMPedometer` / `CMAltimeter` have no macOS counterpart — the only reason capture isn't fully cross-platform, hence the split |
| `GolfTranscription` | Apple path `@available(iOS 26, macOS 26)`; WhisperKit `macOS 14+` *(verify iOS)*, SpeakerKit iOS 16 / macOS 13 | Two impls, one protocol |
| `AnthropicClient` | iOS 16 / macOS 13 | URLSession only; not golf-specific |
| `GolfReconstruction` | iOS 16 / macOS 13 | Pure data + HTTP |
| `GolfStore` | iOS 17 | SwiftData |
| `GolfInsight`, `GolfMap`, `GolfEval` | iOS 16–17 | Pure data / MapKit |

### Boundaries enforced in types, not discipline

- **Ground truth must never reach `GolfReconstruction`.** That is `Mark`, `Scorecard`, **and
  `Correction`** (§3) — all in `Sources/GolfSessionFormat/Mark.swift`; nothing in
  `GolfReconstruction` may import or reference them. `Correction` makes this sharper than `Mark`
  did: marks are a one-off eval aid, corrections accumulate on every round forever, and they are
  the eval set. **As scaffolded this is a convention enforced by review, not by the compiler** —
  `GolfReconstruction` depends on `GolfSessionFormat`, which is where `Mark` lives. Making it
  structural means splitting `Mark`/`Scorecard` into their own target that only `GolfEval` depends
  on. Worth doing before the eval loop exists; the answer key leaking into the model input would
  silently invalidate every accuracy number.
- **`Transcriber` is a protocol**, so the ASR A/B is `golfctl --asr apple|whisperkit`, not a branch.
- **`AnthropicClient` knows nothing about golf** — model config, messages, JSON schema.

### Iteration cost

Swift over Python costs a build cycle. Bounded three ways: `golfctl` is a macOS CLI (`swift run`,
seconds, no simulator); **prompt and schema resolve from `--prompt`/`--schema` paths**, not
`Bundle.module`, which would need a rebuild per edit; and every stage caches into the session
folder, so re-tuning a prompt never re-runs a 30-minute transcription.

### Session folder

One clock — milliseconds since epoch — across every stream. Layout in
`Sources/GolfSessionFormat/SessionFolder.swift`.

---

## 5. Elevation is its own problem — and P3's whole justification

A hole that plays 8 m uphill plays roughly a club longer. **GNSS altitude cannot resolve that**:
vertical accuracy is ±10–20 m, worse than horizontal. The barometer can — `CMAltimeter` relative
altitude is accurate to roughly **0.3–1 m**, which is exactly the resolution the question needs.

| Source | Accuracy | Use |
|---|---|---|
| `CLLocation.altitude` (GNSS) | ±10–20 m | Fallback only, flagged as low quality |
| `CMAltimeter` **relative** | ~0.3–1 m | **Primary.** Tee→green delta, per-hole elevation profile, lie-to-pin delta |
| `CMAltimeter` **absolute** (iOS 15+) | Needs a pressure reference; can be far off | Anchor the relative track to a real elevation when available |

Consequences to design around: barometer requires iPhone 6+ — guard on
`isRelativeAltitudeAvailable` / `isAbsoluteAltitudeAvailable`; relative altitude drifts with
weather over a 4.5-hour round, so re-anchor per hole rather than trusting one session-long
baseline; and store the raw samples, since the correction strategy will change.

**Playing distance** = horizontal distance adjusted for elevation delta — that is the number a
golfer actually wants, and it is the smallest genuinely useful thing Marker can ship.

---

## 6. Roadmap

| Phase | Work | Gate |
|---|---|---|
| **0** | Far-field capture measurement — **no code, no longer a gate** (§3) | Informs prompt + hardware strategy; blocks nothing |
| **1** | `GolfSessionFormat` writers + `GolfCaptureCore` + `GolfCaptureMotion` + iOS 26 app shell (MARK button first) | **Session folder round-trips device→Mac** |
| **2** | `GolfTranscription` — Apple vs WhisperKit+SpeakerKit A/B | No usable speaker clusters → reassess P1 |
| **3** | `AnthropicClient` + `GolfReconstruction` | — |
| **4** | `GolfEval`, built alongside 3 | **Attribution accuracy decides P1 go/no-go** |
| **5** | `GolfStore` — rounds, holes, shots persisted (**P2**) | — |
| **6** | `GolfMap` — map + elevation profile + replay scrubber (**P3**) | Can start any time after Phase 1 |
| **7** | `GolfInsight` — suggestion from history (**P4**) | Needs ≥5 rounds of one player's history |

~2.5 weeks of coding for Phases 1–4; **data collection is the schedule driver**, so start
recording rounds the moment Phase 1's app installs — imperfect captures are still training data,
and every one you correct is an eval row (§3).

**Phase 1 order — the phone comes last.** `GolfCaptureCore` is cross-platform on purpose, so the
capture pipeline is developed and tested on a Mac via `golfctl record` before an app target exists:
(1) `SessionFolder` JSONL writer/reader with real tests, (2) `AudioRecorder` / `LocationRecorder` /
`RoundSession`, (3) `GolfCaptureMotion` (iOS-only), (4) the Xcode app shell over the top. The gate
— a session folder that round-trips — is reachable at step 2 without a device.

---

## 7. Known unknowns

Carried from [`research-game-tracking.md`](./research-game-tracking.md) §10, in priority order:

1. **Q12a** far-field capture rate per non-holder player — **no longer a gate** (§3); shapes how hard the prompt leans on derivation, and whether per-player devices or a Watch mic are worth it.
2. **Q12** does iOS 26 `SpeechTranscriber` actually diarize, or is SpeakerKit the only path?
3. **Q15** reconstruction accuracy on 5–10 real rounds, split by metric; attribution is decisive.
4. **Q14** is Private Cloud Compute developer-accessible, and does its 32K context hold? Would
   dissolve both the API-key problem and most of the privacy exposure.
5. **G3 / API key** — deferred while this is a dev build (PoC plan §0), both re-open at ship time.
6. Barometric drift over 4.5 hours, and the per-hole re-anchoring strategy (§5).
7. Course geometry: OSM `golf=hole` coverage for real courses, vs. user-walked fallback.

---

## 8. Deliberately not here

Swing capture and pose analysis — that is `vipl`. If both ship, a swing video recorded during a
round joins the round timeline by timestamp and location, and a reconstructed shot gains a video.
That join is the reason the two are worth having, but it is an integration, not a dependency, and
neither blocks the other.
