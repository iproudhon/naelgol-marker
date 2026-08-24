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
| **P1** | **Capture & reconstruct** | Record audio + GPS + motion + altitude for a round; reconstruct a shot-by-shot round for all players | The PoC. Gated by Q12a. |
| **P2** | **Record & replay** | Past rounds and past holes, persisted; scrub a round back on a timeline | P1 |
| **P3** | **Map with elevation** | The round on a map, per-hole elevation profile, tee→green delta | Capture only — **independently useful, ships without P1** |
| **P4** | **Play suggestion** | "From here, on this hole, at this elevation delta — here's what you've done before" | P2 + several rounds of history |

### Sequencing consequence

**P3 does not depend on reconstruction.** A map with real elevation is useful the first time you
walk a hole, and it needs nothing but the capture layer. If P1 fails its kill gate (§3), P3 and a
manual-entry P2 still make a real app. Build P3 early for that reason, not last.

P4 is honest only with history. Cold start is **silence**, not generic advice — every golf app
already tells you a 7-iron goes 150 yards. Marker's claim is narrower and truer: *you* hit this
hole four times, and here is what happened.

---

## 3. The gate

Everything in P1 sits behind one unanswered question:

> **Q12a — can a pocketed phone actually hear the other three players?**
> Three players 5–20 m away, outdoors, in wind. Diarization is moot for an utterance that never
> reached the microphone.

The test costs a round of golf and zero code — Voice Memos, a paper scorecard, Whisper on a Mac.
Thresholds are committed **before** the test in
[`poc-plan-round-reconstruction.md`](./poc-plan-round-reconstruction.md) §3: below 40% non-holder
utterance capture, the foursome premise is dead and P1 pivots to phone-holder-only or per-player
devices.

**Run Phase 0 before writing capture code.** The one exception is P3, which is unaffected.

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

SPM declares platforms **once per package**, so `Package.swift` carries the *lowest* floor
(iOS 16 / macOS 13) and higher-floor APIs are gated with `@available` in source. That is what lets
a host app on iOS 16/17 import the low-floor libraries at all.

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

- **`Mark` (ground truth) is unreachable from `GolfReconstruction`.** Separate type, separate file,
  and the target does not depend on anything that exposes it. The answer key must be structurally
  incapable of leaking into the model input.
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
| **0** | Far-field capture test — **no code** | <40% non-holder capture → P1 pivots |
| **1** | `GolfSessionFormat` + `GolfCaptureCore` + `GolfCaptureMotion` + iOS shell (MARK button first) | Session folder round-trips device→Mac |
| **2** | `GolfTranscription` — Apple vs WhisperKit+SpeakerKit A/B | No usable speaker clusters → reassess P1 |
| **3** | `AnthropicClient` + `GolfReconstruction` | — |
| **4** | `GolfEval`, built alongside 3 | **Attribution accuracy decides P1 go/no-go** |
| **5** | `GolfStore` — rounds, holes, shots persisted (**P2**) | — |
| **6** | `GolfMap` — map + elevation profile + replay scrubber (**P3**) | Can start any time after Phase 1 |
| **7** | `GolfInsight` — suggestion from history (**P4**) | Needs ≥5 rounds of one player's history |

~2.5 weeks of coding for Phases 0–4; **data collection is the schedule driver**, so start
recording rounds during Phase 1.

---

## 7. Known unknowns

Carried from [`research-game-tracking.md`](./research-game-tracking.md) §10, in priority order:

1. **Q12a** far-field capture rate per non-holder player — gates P1 (§3).
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
