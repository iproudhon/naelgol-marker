# vipl — Research: Round / Game Tracking

Date: 2026-08-24 · Status: research only, no code changes
Originally written for the `vipl` swing-analysis app; its companion swing-analysis doc (`research-2026-08-body-club-3d.md`) stays in that repo. References to "the companion doc", `§A4/R2`, and vipl file paths point there.
**Build plan:** §7 is being pursued as a standalone proof-of-concept — see [`poc-plan-round-reconstruction.md`](./poc-plan-round-reconstruction.md). Cross-references below use §-numbers from that document.

---

## 0. Why this belongs in vipl rather than a separate app

The app already stamps CoreLocation into `.mov`/`.moz` metadata (`AVAsset.setMetadata(fileURL:description:location:)`, called from `onStopRecording`). So a swing video captured during a round already carries the two keys — **timestamp and coordinate** — needed to join it to a round timeline for free.

That makes the deliverable specific and differentiated: **a shot-by-shot round reconstruction in which some shots have a swing video attached, already pose-analysed.** Arccos and Shot Scope reconstruct rounds; neither hands you the swing. That join is the whole argument for building this here, and it should shape the data model from day one.

---

## 1. Baseline — what exists today

| Area | State | Where |
|---|---|---|
| Location | `CLLocationManager`, `kCLLocationAccuracyBest`, `startUpdatingLocation` + `startUpdatingHeading`, started in `viewWillAppear` / stopped in `viewWillDisappear` | `CaptureViewController.swift:222–246` |
| Location authorization | `requestWhenInUseAuthorization()` only | `CaptureViewController.swift:152–153` |
| Location persistence | Written once into asset metadata at end of recording | `AVAsset+Extension.swift:123` |
| Motion | `CMMotionManager` — device-motion/gravity for the tilt overlay only | `CaptureViewController.swift:30`, `GravityView.swift` |
| Audio | `AVCaptureAudioDataOutput` into the movie file; `AVAudioSession` set to `.playback` for playback | `CaptureViewController.swift:52`, `AppDelegate.swift:16` |
| Speech | **None** | — |
| "Tags" | One free-text string per asset, stored in AVAsset metadata, edited via an alert box | `PlayerViewController.editTags()` |
| Persistence | No database. Derived data lives in an in-memory `Cache`; files are flat in the Documents directory, named `swing-NNNN.mov`/`.moz` | `Cache.swift`, `FileSystemHelper.swift` |

**Nothing here survives backgrounding, and nothing here is a round.** There is no concept of a player, a hole, a shot, a score, or a session.

---

## 2. Hard constraints — read these first

### G1 — The app has no background execution capability whatsoever

- **No `UIBackgroundModes` key exists** — not in `Info.plist`, not as an `INFOPLIST_KEY_*` in `project.pbxproj`. The moment the screen locks or the phone goes in a pocket, everything stops.
- **`NSLocationWhenInUseUsageDescription` only.** No `NSLocationAlwaysAndWhenInUseUsageDescription`, no `allowsBackgroundLocationUpdates`.
- **No `NSSpeechRecognitionUsageDescription`** at all.
- **All four existing privacy strings are literally `"<TBD>"`** (`project.pbxproj:907–910`). That is an automatic App Review rejection today, independent of this feature. Fix regardless of what else gets built.

### G2 — iOS will not let an app *start* recording audio from the background

This is the decisive constraint on ask #1, and it is a privacy rule, not a configuration problem. Verified against current documentation: `AVAudioSession.ErrorCode.cannotStartRecording` (561145187, `!rec`) is the documented failure, and the restriction has been in force **since iOS 12.4**. An app can **continue** a recording it started in the foreground (given `UIBackgroundModes: audio`), but a background wake — geofence crossing, significant-location-change, silent push — **cannot start** one. No iOS 26 loosening found; `AVAudioApplication` and the iOS 26 session changes do not add a background-record path.

> **Consequence: "wake on event → open the mic → transcribe" is not implementable on iOS as a third-party app.** Any design that assumes it is wrong. See §3 for what replaces it.

### G3 — `UIBackgroundModes: audio` on a record-only app is an App Review rejection risk

Guideline **2.5.4** rejects apps that declare the `audio` background mode but "are unable to play any audible content when the app is running in the background." The key is documented for apps that *provide audible content* — music players, streaming. A round-tracker that only listens does not qualify on its face. This is a widely-reported rejection, not a theoretical one.

The `location` background mode, by contrast, is exactly what a round tracker is for and is straightforward to justify. **Architecture follows: `location` keeps the process alive; audio is opportunistic within a foreground-started session, never the thing keeping you alive.**

### G4 — Region monitoring is too slow to be a shot trigger

Core Location caps an app at **20 simultaneously monitored regions** — which fits 18 holes + clubhouse + parking almost exactly, and is a tempting fit. But **entry/exit notifications typically arrive 3–5 minutes late**, and regions below ~400 m radius are documented as less reliable. A golf green is ~30 m across.

> Geofences are usable for **round start/stop and coarse hole transitions**. They are **not** usable as a shot-event trigger. Do not build the audio cascade on them.

### G5 — The current location config is the most expensive one available

`kCLLocationAccuracyBest` + continuous `startUpdatingLocation` + `startUpdatingHeading`, held for the whole time the capture screen is visible. Over a 4–4.5 hour round this is very likely the **dominant** battery drain — more than the microphone, which is the intuition the ask inverts. Heading updates in particular run the magnetometer continuously for a feature (the tilt overlay) that has nothing to do with round tracking.

Do not guess at milliamps. Measure — see §9. Full location strategy is §5.

---

## 3. Ask #1 — Event-triggered audio transcription with minimal battery

> **Read §7 first if the goal is LLM round reconstruction.** This section treats audio as *user-initiated voice notes*, which is the right frame for club/score logging. §7 treats audio as a *continuous evidence stream for reconstruction*, which is a materially harder capture problem — G3 becomes the critical path there, and §3's "keep audio opportunistic under the `location` mode" escape does not apply.


### The reframe: don't do the listening yourself

Given G2 and G3, the naive design is impossible and the brute-force design (hold a foreground audio session for 4.5 hours) is both a battery disaster and a review risk. The way out is to notice that **iOS already runs an always-on, wake-word speech engine at zero marginal cost to your app.**

**Recommended primary path — App Intents + Siri.** "Hey Siri, log a seven iron." An `AppIntent` with `openAppWhenRun = false` executes in a lightweight extension **without foregrounding the app**, receives the parsed parameter, and appends to the round store. The always-on listening is the system's, already running for every user; your app pays nothing for it. An `AppShortcutsProvider` supplies the natural-language phrases; enumerated parameter types (`AppEnum` over the 14 club names, over player names) give the recognizer a closed vocabulary, which is exactly what noisy outdoor speech needs.

Caveats worth designing around: `perform()` may run in an extension where app state is not loaded, so it must bootstrap its own store access; and Siri invocation is a deliberate user action, not passive capture.

### The gating cascade, for when you *do* open the mic

**State the premise plainly, because G2 forces it:** any mic session must be *started in the foreground*, screen on, phone in hand — the state that already exists when the user records a swing. And screen-on for 4.5 hours is a worse battery story than the microphone it would be gating. So the cascade below is **not** a way to listen all round cheaply. No such way exists.

What it is: the gating for a **short, user-initiated voice-note session** — the user taps to record, speaks, the app transcribes and stops. Within that window the cheap tiers keep ASR from running longer than the speech does.

Tiers 0 and 1 do almost nothing *here* — the user is standing still holding the phone, so "stopped walking" and "crossed a geofence" gate nothing. **They are listed for completeness and because they carry real weight in §4**, where the app is backgrounded under `location` mode and the motion coprocessor genuinely is the cheap signal. Build them once, for §4; §3 gets Tiers 2–3 only.

| Tier | Mechanism | Cost | Role |
|---|---|---|---|
| **0** | `CMMotionActivityManager` — walking → stationary transition | Motion coprocessor; effectively free | **The best lever available.** On a course, "stopped walking" is a near-perfect shot proxy. `CMPedometer` also gives walked distance free, which fills GPS gaps in §5. |
| **1** | Geofence / significant-location-change | OS-handled, low power | Round start/stop, coarse hole transitions **only** (G4) |
| **2** | VAD / impact transient on an `AVAudioEngine` tap | Cheap DSP | Speech present? Ball struck? — **the same impact-transient detector as §A4/R2 in the swing doc; build it once** |
| **3** | ASR burst | Expensive | Only after a Tier 0–2 trigger, seconds at a time |

### Which speech API — and the deployment-target fork

- **iOS 26+: `SpeechAnalyzer` / `SpeechTranscriber`** (WWDC25). Purpose-built for long-form, low-latency, fully on-device transcription, and it **removes the ~1-minute session cap** that makes `SFSpeechRecognizer` painful. It also ships a **`SpeechDetector` module for voice-activity detection** — i.e. Tier 2 above is a first-party component, not something to hand-roll.
- **iOS 17–25: `SFSpeechRecognizer`** with `requiresOnDeviceRecognition = true`, plus `contextualStrings` to bias toward club names and player names. Expect to manage the ~1-minute cap with a restart loop.

> **Name the fork explicitly.** The swing doc recommends moving the deployment target to **iOS 17** (for `VNDetectHumanBodyPose3DRequest`). The best speech API wants **iOS 26**. These are different floors. Either ship `SFSpeechRecognizer` at 17 and adopt `SpeechAnalyzer` behind an availability check, or accept a much narrower device base. The availability-check route is clearly right; just don't let it be an accident.

### No *continuous* audio capture — and be honest about the audio that already exists

For the ASR path: transcribe and discard the buffers. That is simultaneously the storage answer (4.5 h of audio is large), the battery answer (no encode, no write), and part of the privacy answer.

But **the app already writes audio to disk today.** `AVCaptureAudioDataOutput` puts an audio track into every swing `.mov` (`CaptureViewController.swift:52`; `audioSettings` passed unconditionally to `movieOut?.start`), and the companion doc's §A4/R2 *wants* that audio for the impact transient. So swing clips recorded during a round already contain whatever a foursome was saying. See §8 — that file, not the ASR path, is where the consent exposure actually lives.

---

## 4. Ask #2a — Shot detection and round progress

### Calibrate against what the market achieves

Arccos — the leading phone-based tracker — reports **>98% of tee shots** captured, using phone GPS + accelerometer/gyroscope (with grip sensors in the sensor product). Its documented weak spots are **short-game shots**, cold weather, and gloves. Notably, Arccos sells a separate wearable (Link) largely to move this workload **off** the phone, which is itself the strongest available evidence about the battery cost of doing it phone-only.

So the honest expectation for a phone-only implementation: **full shots are a solved-ish problem; putts and chips are not.**

### The signal that actually works

A shot is a **stationary → displacement → stationary** transition. GPS alone is noisy (5–10 m consumer accuracy is the same order as a chip shot); IMU alone can't tell a swing from a practice swing from a bag being set down. Fuse:

1. `CMMotionActivity` gives the walk/stationary segmentation almost free (Tier 0).
2. GPS fixes at segment boundaries give shot start and end positions → **shot distance**.
3. `CMPedometer` distance bridges GPS dropouts and sanity-checks segment lengths.
4. The swing-detection work already scoped in the companion doc (or an Apple Watch IMU) disambiguates real swings from practice swings.

**Location strategy — accuracy tiers, duty cycling, background sessions, auto-pause — is entirely in §5.** It is the single source; do not duplicate it here.

### Club selection — combine two weak signals

Neither is reliable alone; together they cross-check:

- **Voice**, with a closed 14-club vocabulary (§3). High precision when the user speaks, zero recall when they don't.
- **Distance inference**: shot distance from GPS → a per-player club distribution learned over rounds. Cold-start is poor; converges within a few rounds. Works with zero user effort.

Present the inferred club as an editable default rather than a fact. The commercial answer is NFC/BLE club tags (Arccos grips, Shot Scope tags) — accurate, but it's hardware, and out of scope for a software feature.

### Score

Score is a *derived* quantity — strokes per hole = count of detected shots between hole boundaries — not a separate input. Make it correctable: a shot list the user can add to or delete from per hole. Every automatic tracker gets short-game shots wrong (above), so the edit affordance is the feature, not a fallback.

---

## 5. Ask #2c — Constant location tracking

> **This section is the single source for location strategy.** §4 and §6 defer to it.

### The reframe: golf does not need constant location

A round needs an accurate position at **~90 known moments** over 4.5 hours, plus coarse hole transitions. Continuous tracking is one way to obtain those — and it is by far the most expensive way. The parallel to §3 is exact: the answer is not "track constantly, cheaply" (there is no such thing), it is **event-gated acquisition**.

What makes this work for golf specifically is that the events are *predictable and self-announcing*: the golfer stops walking, selects a club, addresses the ball, swings. That is a 15–45 second window that the app knows about at its start.

### What the levers actually are

You do not control the GNSS chip. iOS duty-cycles it internally and exposes only intent. The real levers, in descending order of effect:

1. **Service choice** (see ladder below) — decides which subsystem runs at all.
2. **`desiredAccuracy`** — genuinely gates which radios power up. At `kCLLocationAccuracyKilometer` / `ThreeKilometers` iOS will not bring up GPS at all and answers from cell towers; `HundredMeters` leans on Wi-Fi/cell; `NearestTenMeters` and `Best` require GPS. **This is the switch that matters.**
3. **Session duration** — how long you keep the service running. The subject of the whole section.
4. **`activityType`** — hints for duty-cycling behavior; secondary, and see the pausing hazard below.

**`distanceFilter` is not a battery lever.** It filters *delivery to your app*, not *acquisition by the hardware* — the receiver keeps running. It saves wakeups and CPU, not radio power. Use it to reduce churn, never as a power strategy.

### The service ladder — and why only the top rung works for golf

| Service | Resolution / latency | Power | Status indicator | Use for golf |
|---|---|---|---|---|
| Standard (`startUpdatingLocation` / `CLLocationUpdate.liveUpdates()`) | Continuous, ~5 m at `Best` | Highest | Blue bar | **The only one that can locate a shot** |
| Significant location change | ~500 m / ~5 min; wakes a *terminated* app | Very low | Hollow/solid arrow | Detect "arrived at a course"; **500 m exceeds most hole lengths** — useless for shots |
| Visits (`startMonitoringVisits`) | Arrival/departure | Very low | Arrow | Round start/stop |
| Region monitoring / `CLMonitor` | 20-region cap, **3–5 min latency**, ~400 m radius guidance (G4) | Low | Arrow | Coarse hole transitions at best |

The low-power services cannot resolve anything smaller than a golf hole. There is no clever substitution here — shot positions require the standard service at GPS accuracy. The savings have to come from **duration**, which is what the next section is about.

### G6 — A `CLBackgroundActivitySession` can only be started from the foreground

Exactly the same shape as G2 (audio): **a new `CLBackgroundActivitySession` can only be started from the foreground; from the background, only an already-running session can be continued.** Deallocating the session object invalidates it, so it must be held for the round's duration.

Consequence: **the round must be explicitly started by the user while the app is open.** That is a fine UX for golf — a golfer taps "start round" on the first tee — but it forecloses fully automatic round detection from a cold start, and it makes mid-round session loss unrecoverable without user action (see *Resilience* below).

This is the iOS 17+ API set: `CLLocationUpdate.liveUpdates()` for the stream, `CLBackgroundActivitySession` for background entitlement, `CLMonitor` for geofences. It aligns with the iOS 17 floor the companion doc already proposes.

### Recommended architecture — motion-gated GPS duty cycling

```
[start round]  ── foreground ──▶ hold CLBackgroundActivitySession for the whole round
      │
      ├─ walking (CMMotionActivity)   → GPS down; CMPedometer carries distance
      │
      ├─ stationary detected          → GPS UP immediately  ◀── the warm-up trick
      │                                  (user is selecting a club / addressing)
      ├─ impact / departure detected  → record shot position (best fix in window)
      │
      └─ walking resumes              → GPS down
```

**The pre-shot routine is a free GPS warm-up window.** This is what makes duty cycling viable rather than a latency trap. Cold/warm TTFF is the usual objection to cycling GPS off — but the golfer stops walking 15–45 seconds *before* the ball leaves. Bring the receiver up the instant `CMMotionActivity` reports stationary, and by the moment that actually needs a position (impact, from the companion doc's §A4/R2 detector) the fix has converged. The user's own routine hides the TTFF.

`CMPedometer` distance between fixes gives a dead-reckoned path for free, which both fills the gaps on the reconstructed map and sanity-checks segment lengths.

**Order-of-magnitude duty cycle** (assumptions inline — these are *estimates to validate*, not measurements):

| Scenario | GPS-on | % of a 270 min round |
|---|---|---|
| 90 shots × 45 s + 18 hole transitions × 30 s | 76.5 min | 28% |
| 90 shots × 30 s + 18 × 30 s | 54.0 min | 20% |
| Full shots only, 54 × 45 s + 18 × 30 s | 49.5 min | 18% |
| Full shots only, 54 × 30 s + 18 × 30 s | 36.0 min | 13% |

Against 100% today. So roughly a **3–7× reduction in GPS-on time** — the actual battery ratio will be smaller, since the receiver is not the only cost, and must be measured (Q1).

### The question the whole architecture rests on

**Does lowering `desiredAccuracy` on a live subscription power the GNSS down, or does only stopping the subscription do it?** If the former, gating is trivial. If the latter, you must stop and restart `liveUpdates()` around each shot — and the follow-on question is whether that restart is permitted from the background.

*Working hypothesis to verify (Q9):* the **session** is what is foreground-gated (G6), not the subscription — so a `CLBackgroundActivitySession` held for the whole round should permit freely starting and stopping `liveUpdates()` within it, backgrounded. If that holds, the architecture works as drawn. If the subscription is also foreground-gated, motion-gating collapses and the fallback is continuous updates at a lowered accuracy tier, escalating to `Best` only around shots — strictly worse, but still better than today.

**Verify this before building anything else in §5.**

### Two hazards specific to golf

**1. Auto-pause fires exactly when you need the fix.** iOS pauses background location updates when it decides the user is stationary — and there are consistent reports that this happens **even with `pausesLocationUpdatesAutomatically = false`**. In most apps "stationary" means "nothing to record." In golf, stationary *is* the event. Whether `activityType` independently influences this is unclear and worth checking (Q10) — `.fitness` may be part of the problem rather than the fix, with `.other` / `.otherNavigation` behaving differently.

Note the convergence: **the motion-gated architecture sidesteps this hazard for free.** Because it starts a fresh subscription at each shot rather than holding one continuously, there is no long-lived stationary session for the system to pause.

**2. GPS cannot resolve the short game.** Consumer GNSS is ~5 m in the open. A full shot is 100–250 m — measurable. An approach is 20–100 m — measurable. A chip is 10–30 m — marginal. A putt is 1–10 m — **below the noise floor**. This is why §4's calibration note holds that Arccos captures >98% of tee shots but misses short-game shots: it is physics, not software. Design putts as manual entry (or a tap), never as a detection target.

Gate on `horizontalAccuracy` — reject fixes worse than a threshold rather than recording a bad position as if it were good.

### Authorization, the status indicator, and resilience

**Recommendation: `WhenInUse` + `CLBackgroundActivitySession`.** Lower permission friction than `Always`, and sufficient for a user-initiated round.

**Accept the failure mode that comes with it, and say so in the UI.** With `WhenInUse`, if the session dies mid-round — memory pressure, Low Power Mode, a reboot — **it cannot be re-established from the background**, and holes 10–18 are lost silently. `Always` would allow recovery via significant-location-change wake, at the cost of a harder permission prompt. Over 4.5 hours this is not hypothetical.

Required either way:
- A visible **"tracking stopped"** state so the user finds out *during* the round, not after it.
- **General degradation, not just for Low Power Mode:** fall back to `CMPedometer` dead reckoning plus manual shot marking whenever GPS is unavailable for any reason.
- Detect `ProcessInfo.processInfo.isLowPowerModeEnabled` and its change notification. A 4.5-hour round will very likely hit LPM — user-enabled or via the 20% prompt — and LPM pauses discretionary background activity, with reported cases of background location stopping outright.

**Status indicator:** low-power services (significant-change, visits, regions) show only the arrow glyph. The standard service in the background shows the blue bar. With `Always` authorization, `showsBackgroundLocationIndicator` controls whether it appears; **whether `WhenInUse` + background updates forces the bar unconditionally is implied by the docs but should be verified (Q11)**. For golf this is a non-issue either way — a visible indicator during a round is expected, arguably reassuring.

### What to change in the current code

`CaptureViewController.swift:222–246` runs `kCLLocationAccuracyBest` + `startUpdatingLocation` + `startUpdatingHeading` continuously for the whole time the capture screen is visible — the most expensive configuration available, for a screen that only needs one fix at the end of a recording. `startUpdatingHeading` in particular runs the magnetometer for the tilt overlay, unrelated to round tracking. Round tracking should own location as a round-scoped service; the capture screen should request a single fix, not a stream.

---

## 6. Ask #2b / #3 — Course data and round reconstruction

### Course data is the likely sinker — treat it as a data problem, not a coding problem

Mapping GPS → hole → shot sequence needs tee, green, and ideally fairway geometry. Three sources:

1. **OpenStreetMap.** Genuinely well-suited: `golf=hole` is tagged as a **line from tee to green** carrying `ref` (hole number) and `par`, with node count = par − 1, plus `golf=green`, `golf=tee`, `golf=fairway`, `golf=bunker` polygons. Free, no API key, and the schema is almost exactly the model you'd design. **Coverage is the open question** — it varies enormously by region and is the thing to measure (§9, Q6) before committing.
2. **Commercial course APIs.** Complete and maintained; licensing and per-round cost.
3. **User-walked course.** The app records tee/green as the user plays hole 1 the first time, and improves with each round. Zero dependency, poor first-round experience — but it composes well as a *fallback* behind OSM.

**Recommendation:** OSM as primary, user-walked as automatic fallback and correction layer. Cache course geometry locally; a course does not change between rounds.

### Reconstruction — and the multi-player fork

"Reconstruct games by players" has two readings, and they are very different builds:

- **One phone per player** (assumed by the recommendation below). Shot attribution is trivial — every shot on this device belongs to this player. Rounds join afterwards by course + date to produce the group view. This is what Arccos and Shot Scope do.
- **One phone tracks a foursome.** GPS cannot separate four people walking the same fairway together. Attribution then requires an explicit signal every shot: voice ("Steve, seven iron") or a tap. That is a materially heavier UX and a much weaker automatic story.

> **Resolved in favour of the foursome case — see §7.** The one-phone-per-player reading is the easy build and remains a valid fallback, but the stated goal is reconstructing the round for *all* players from one device. Deterministic detection cannot do that: GPS cannot separate four people walking the same fairway. §4's automation story does largely collapse into manual entry under that reading — **which is exactly why §7's LLM approach earns its place.** Language carries the attribution that sensors cannot.

The reconstruction itself is then a straightforward render: course geometry from §6, an ordered shot list per hole with start/end coordinates, distances, inferred or spoken clubs, and — the differentiator from §0 — **a thumbnail on the shots that have a swing video**, tapping through to the existing player with its pose overlay.

---

## 7. LLM-based round reconstruction — all players, from audio + GPS

> **This supersedes the one-phone-per-player assumption in §6.** The user's ask resolves the multi-player fork in favour of the hard reading — **one phone, whole foursome** — and that is precisely why an LLM earns its place here. Deterministic detection cannot attribute shots among four people walking the same fairway. Language can.

### Why this is the right idea

A golf group **narrates its own round continuously**, in a vocabulary that is small, structured, and unusually information-dense:

| What is said | What it encodes |
|---|---|
| "You're away" / "I'm away" | Turn order → who is playing, and relative distance to hole |
| "I'm hitting seven" / "this is a hard eight" | Club selection, attributed |
| "Nice shot, Steve" | Speaker ≠ Steve; Steve just played |
| "I'm in the bunker" / "left rough" / "that's OB" | Lie, penalty strokes |
| "What'd you make?" → "Bogey" / "Five" | **Score, announced and confirmed, per player, per hole** |
| "Long par four" / "this is the tough one" | Hole identity and par |

And golf imposes **hard structural constraints** that let a model reconstruct *and self-check*: furthest from the hole plays first; strokes accumulate monotonically; every hole ends with an announced score; hole scores sum to a round total that gets stated at the end. This is a constraint-satisfaction problem with a natural-language evidence stream — close to an ideal LLM task, and a genuinely poor fit for hand-written detection heuristics.

### Pipeline

```
audio ──▶ on-device ASR ──┐
GPS   ──▶ stationary segments ──┤
swing videos ──▶ timestamped events ──┼──▶ evidence bundle ──▶ Claude ──▶ structured round
course geometry (§6) ─────┘                                     (JSON schema)
                                                                     │
                                                              reviewable draft
                                                              + per-shot confidence
                                                              + flagged conflicts
```

Claude does not accept audio, so **on-device ASR is mandatory** — it is not an optional preprocessing step you could skip by uploading the recording.

### The question upstream of everything: can you even hear the other three?

**This gates §7 more tightly than anything else in it.** The evidence table above assumes "Nice shot, Steve" and "What'd you make?" reach the microphone. Most of it will not. One player carries the phone — pocketed, in a bag, or clipped to a cart. The other three are 5–20 m away, outdoors, in wind, on terrain with no reflective surfaces to help. That is close to the hardest far-field multi-speaker ASR case that exists.

**Diarization is moot for an utterance that was never captured.** Telling speakers apart (Q12) is the *second* question; the first is what fraction of each player's speech lands in the transcript at all (Q12a).

This also interacts badly with the G3 fallback below: per-shot audio windows capture the **phone holder's** pre-shot talk well and everyone else's poorly — **precisely inverting the attribution the feature exists to provide.** The one player you least need to identify is the one you hear best.

*Cheap, decisive test:* record 20 minutes of a real foursome with the phone pocketed, transcribe it, and count what fraction of each player's utterances survive. Run this before building anything in §7. Mitigations if the number is bad: an external mic, an Apple Watch on the wrist of each player, or accepting that only the phone holder's round reconstructs well.

### The division of labor that makes it work

**ASR produces acoustic speaker clusters; Claude maps clusters to names from content.**

Speech systems can cluster "who spoke" without knowing *who* that is. Claude resolves identity from the transcript itself — "Nice shot, Steve" spoken by cluster 2 means Steve is *not* cluster 2; a self-introduction or a scorecard reference pins one down; turn order constrains the rest. Neither half can do the job alone, and each is doing what it is actually good at.

**This makes diarization the load-bearing dependency.** Sources conflict on whether iOS 26's `SpeechTranscriber` provides it — some state it supports speaker diarization, others hedge and suggest cloud services are where diarization is reliable. **Resolve this first (Q12).** Options in descending order:

1. `SpeechTranscriber` native diarization, if it exists and is usable.
2. WhisperKit (or `whisper.cpp`) plus a separate diarization model — a real dependency, but on-device.
3. **No diarization at all** — content-only attribution. Claude can still extract a great deal ("Steve, you're away"), but accuracy drops sharply and every shot needs review. This is the floor, not a plan.

### The evidence bundle — do not send raw streams

| Source | Raw | Compressed |
|---|---|---|
| GPS @ 10 s for 4.5 h | 1,620 fixes ≈ **65K tokens** | ~110 stationary segments ≈ **3.8K tokens** |
| Transcript | — | 13–32K tokens (see below) |

Send one entry per **stationary segment** (enter time, exit time, position, `horizontalAccuracy`, pedometer distance since last), not a fix stream. Add hole boundaries derived from course geometry (§6), and swing-video events as timestamped anchors — a recorded swing is a *confirmed* shot at a known time and place, which pins the reconstruction hard wherever one exists. That is the §0 integration paying off inside the algorithm, not just in the UI.

### Size and cost — a non-issue

Transcript volume for a 4.5-hour (270 min) round, at ~150 wpm across the group:

| Talkativeness | Words | Tokens |
|---|---|---|
| Light (25% duty) | 10,125 | ~13.5K |
| Normal (40%) | 16,200 | ~21.5K |
| Chatty (60%) | 24,300 | ~32.3K |

**A whole round is ~27K tokens including compressed GPS — comfortably inside Claude Haiku 4.5's 200K context.**

Output is the same deliverable either way — 4 players × ~90 strokes ≈ **360 shot entries at ~40 tokens each ≈ 14.4K output tokens**, plus scores and flags. Input differs: 29K for a single call (bundle + prompt) vs 66K across 18 chunks (the prompt and schema repeat every time).

| Model | Context | $/1M in | $/1M out | Single call | 18 per-hole calls + reconcile |
|---|---|---|---|---|---|
| `claude-haiku-4-5` | 200K | $1 | $5 | **~$0.10** | ~$0.15 |
| `claude-sonnet-5` | 1M | $3 | $15 | ~$0.30 | ~$0.46 |
| `claude-opus-5` | 1M | $5 | $25 | ~$0.51 | ~$0.77 |

Halve any of these with the **Batch API** — reconstruction is post-round, asynchronous, and latency-insensitive, which is exactly what batching is for. Haiku with batching lands near **$0.05 a round.**

**Recommendation: single call over the whole round, not per-hole chunking.** Chunking costs *more* — same output, but 66K input instead of 29K, because the ~1.5K prompt and schema repeat 18 times — and strips the cross-hole context the task depends on — turn order carries between holes, a score announced on the next tee resolves the previous hole, running totals constrain everything. Keep per-hole as a fallback if single-call accuracy disappoints, not as the default.

**On model choice:** the ask names Haiku, and cost supports it. But be clear-eyed that this is a *hard* task — multi-entity attribution plus constraint satisfaction over a noisy, error-laden transcript. The spread between Haiku and Opus is **$0.10 vs $0.51 per round**; that difference is irrelevant next to reconstruction accuracy. Build the evaluation set first (§ below), then pick the cheapest model that actually passes. Do not pre-optimise the tier.

*Implementation notes:* Haiku 4.5 is a previous-generation model — `output_config.effort` errors on it, and thinking uses `{type: "enabled", budget_tokens: N}` rather than adaptive. Sonnet 5 and Opus 5 use `thinking: {type: "adaptive"}` and support `effort`. Constrain the output with `output_config: {format: {...}}` against a JSON schema for the round so the result is parseable by construction.

### Self-verification — ship a reviewable draft, not a fact

Golf's internal constraints make validation unusually tractable. Have the model emit **per-shot confidence** and explicitly flag conflicts, then check mechanically:

- Shot count per player per hole **vs** the score they announced.
- Turn-order plausibility against reconstructed distances-to-hole.
- Shot distance **vs** the club named (a "seven iron" that travelled 240 m is wrong somewhere).
- Sum of hole scores **vs** the round total, if stated.

Surface every disagreement in the review UI. The deliverable is a draft the group corrects in two minutes, not an oracle. This framing should be structural — in the schema, in the prompt, and in the UI — not a disclaimer.

### The three things that can kill this

**1. G3 is now the critical path, and §3's escape no longer applies.**
§3 dodged Guideline 2.5.4 by keeping audio opportunistic under the `location` background mode. **Continuous 4.5-hour capture cannot use that dodge** — it needs `UIBackgroundModes: audio` on a record-only app, which is the documented rejection. Do not paper over this with a token playback feature.

*Real fallback: per-shot audio windows.* The phone is already out at every shot (the group is filming swings). Reconstruction does not need the walking-between-shots conversation — it needs the **pre-shot club talk** and the **on-green scoring**, which is exactly when the phone is in hand. This degrades the evidence bundle without breaking the architecture, and stays inside G2/G3 as already established. Design for it from the start; treat continuous capture as the upside case pending a review-precedent check (Q13).

**2. The API key cannot live in the app — and this app has no backend.**
An Anthropic key shipped in an iOS binary is extractable. Two options, both real commitments:

| Option | Cost | Trade-off |
|---|---|---|
| **BYO key** — user pastes their own | No infrastructure | Niche-user-only; awkward onboarding; user sees per-round billing |
| **Proxy backend** — app calls your server, server holds the key | Servers, auth, ops, and now you are storing users' transcripts | Normal UX; **the app stops being fully local** |

vipl today is 100% on-device with no server. A proxy is a larger architectural commitment than the feature itself, and it changes the product's privacy posture (§8). Decide this **before** building, not after. Note also that **Swift has no official Anthropic SDK** — this is raw HTTPS to `/v1/messages` either way.

**3. On-device inference does not rescue you.**
Apple's Foundation Models on-device `SystemLanguageModel` has a **fixed 4,096-token context window**. A 27K-token round does not remotely fit — this option collapses to aggressive per-hole chunking with far weaker reasoning, on the hardest reasoning task in either document. It is not a peer alternative.

*One possible middle path, to verify (Q14):* Apple's **Private Cloud Compute** model is reported at a **32K context window** with Apple's privacy guarantees — which would just fit a round and would dissolve both the API-key problem and most of §8. Confirm whether it is developer-accessible from the Foundation Models framework, on which OS version, and whether 32K holds after the prompt and schema. If it does, it is arguably the *right* answer for this feature.

### Evaluation

Nothing here is buildable without ground truth. Record 5–10 real rounds with a manually-kept scorecard and shot log, then score reconstructions on: score accuracy per hole, shot-count accuracy, player attribution accuracy, and club accuracy. Attribution is the metric that matters — it is the one deterministic detection cannot do at all, and the one that decides whether the feature is worth its complexity.

---

## 8. Persistence — one decision that must serve both documents

There is no database today. The companion doc's §5 item 3 already asks for a per-swing sidecar (3D pose, phase indices, club track). A round store is the same ask at larger scale, and the two **must not diverge into separate mechanisms**.

New entities: `Player`, `Course`, `Hole`, `Round`, `Shot` (with optional `assetURL` linking to a `.mov`/`.moz`).

**Recommendation: SwiftData**, available at the iOS 17 floor the companion doc already proposes. It handles the relational shape (round → holes → shots), gives migration for free, and can hold the swing sidecar as a related entity rather than a parallel file format. JSON sidecars remain viable if a dependency-free file layout is preferred — but pick one mechanism for both features and record the choice in both documents.

---

## 9. Privacy and legal

Recording a foursome is materially different from recording yourself: several US states and other jurisdictions require **all-party** consent for audio capture. **§7 escalates this from a footnote to a first-order design constraint** — it proposes capturing and transcribing the group's conversation for the whole round, and (unless the Private Cloud Compute path in §7 works out) sending that transcript to a third-party API.

Three exposures now:

1. **The ASR path (new).** Mitigated by transcribing and discarding — no raw audio persists, and the session is short and user-initiated.
2. **Swing clip audio (already shipping).** Every `.mov` carries an audio track today, and §A4/R2 in the companion doc has a reason to keep it (the impact transient). This is the real exposure and "transcribe and discard" does not touch it. **Make an explicit decision:** keep the audio track and disclose it, or run impact detection at capture time and strip the track afterwards, keeping only the detected impact timestamp. The second is strictly better for privacy and storage and costs the impact detector you were building anyway.
3. **§7 reconstruction (the largest, and new).** Capturing a group's conversation for 4.5 hours is a different act from recording your own swing, and it needs **explicit consent from every player at the start of the round** — not a buried setting. This is a group product decision: the golfer who opens the app is not the only person whose voice is captured. Additionally, if reconstruction runs through a proxy backend (§7), transcripts of private conversation leave the device and are stored on your infrastructure — **the app stops being fully local, and you become a data controller.** Keep raw audio on-device and discard it after transcription regardless; consider sending the LLM a *redacted* transcript (golf-relevant utterances only, filtered on-device) rather than everything said over 4.5 hours.

Either way: a clear in-app disclosure and an off switch. One sentence in the UI; do not skip it.

---

## 10. Open questions — measure these first

1. **What does a real round actually cost?** Run each subsystem in isolation for 30 minutes and read `MXMetricPayload.locationActivityMetrics` — it reports cumulative time per accuracy tier (`cumulativeBestAccuracyTime`, `cumulativeNearestTenMetersAccuracyTime`, `cumulativeHundredMetersAccuracyTime`, …). Compare `Best` vs `NearestTenMeters` vs motion-only. **Highest priority — it decides the whole location strategy.** *Expectation to test: GPS dominates the mic.*
2. Does dropping `startUpdatingHeading` (magnetometer, currently always on with the capture screen) measurably help? It exists only for the tilt overlay.
3. How reliable is `CMMotionActivity` walking↔stationary on a golf course specifically — slow walking, cart riding, standing over a putt? Tier 0 carries the whole cascade; if it is noisy, everything downstream gets more expensive.
4. Does an `AppIntent` with `openAppWhenRun = false` reliably reach the round store from its extension context, and does Siri recognise club names in wind? *This is the load-bearing assumption of §3.*
5. Is `SpeechAnalyzer`'s `SpeechDetector` usable as a standalone VAD without a full transcription session running? If so, Tier 2 needs no custom DSP.
6. **What is OSM golf coverage for the courses that matter to actual users?** Sample 20 real courses and count how many have `golf=hole` with `ref` and `par`. *This decides §6 and is the most likely reason the feature stalls.*
7. Does a `CLBackgroundActivitySession` survive a full 4.5-hour round in practice — through Low Power Mode, memory pressure, and a pocketed phone?
8. Apple Watch: does a `HKWorkoutSession` change any of the above? It legitimately keeps a watch app alive for hours, puts an IMU on the wrist (far better swing detection than a pocketed phone), and offers a raise-to-speak affordance — **it may be a better answer to ask #1 than anything on the phone.** Scope separately.
9. **Does lowering `desiredAccuracy` on a live subscription power the GNSS down, or does only stopping the subscription do it — and can `liveUpdates()` be restarted from the background inside an already-running `CLBackgroundActivitySession`?** *The §5 architecture rests entirely on this. Verify it before building anything else there.*
10. Does `activityType` influence stationary auto-pause independently of `pausesLocationUpdatesAutomatically = false`? If `.fitness` makes pausing more likely, `.other` / `.otherNavigation` may be the safer choice for golf (§5).
11. Does `WhenInUse` + background location force the blue bar unconditionally, or does `showsBackgroundLocationIndicator` apply there too? Cosmetic for golf, but confirm before promising either behaviour.
12a. **What fraction of each player's speech is even captured** by a pocketed phone at 5–20 m outdoors in wind? *Upstream of Q12 and of all of §7 — diarization is moot for utterances that never reach the mic. Cheap test: 20 minutes of a real foursome, phone pocketed, count surviving utterances per player.* **The single highest-priority question in this document.**
12. **Does iOS 26 `SpeechTranscriber` actually provide speaker diarization?** Sources conflict. If not, what is the best on-device alternative (WhisperKit + a diarization model)? *§7's whole division of labor rests on getting acoustic speaker clusters from somewhere.* **Top priority for §7.**
13. Is there App Review precedent for `UIBackgroundModes: audio` on a record-only sports app? Search rejection reports; if the answer is no, §7 ships on per-shot audio windows and continuous capture never happens.
14. **Is Apple's Private Cloud Compute model developer-accessible from the Foundation Models framework, on which OS version, and does its reported 32K context hold after prompt and schema?** If yes, it likely dissolves both the API-key problem and most of §9 — the best possible outcome for §7. (The on-device `SystemLanguageModel` is confirmed at a fixed 4,096 tokens and does *not* fit.)
15. On 5–10 real rounds with a manually-kept scorecard: what are single-call reconstruction's score, shot-count, **player-attribution**, and club accuracies — on Haiku 4.5 vs Sonnet 5 vs Opus 5? Attribution is the metric that decides whether §7 is worth its complexity.

---

## 11. Suggested sequencing

| # | Work | Effort | Risk | Payoff |
|---|---|---|---|---|
| 0 | Replace the four `"<TBD>"` privacy strings | minutes | — | unblocks any App Store submission at all |
| 1 | Measure Q1/Q2 (MetricKit location tiers) | hours | — | decides the entire location strategy |
| 2 | Measure Q6 (OSM course coverage sample) | hours | — | decides §6; may kill or reshape the feature |
| 3 | Data model + store — `Player`/`Course`/`Hole`/`Round`/`Shot`, shared with the swing sidecar (§8) | medium | low | prerequisite for everything; unifies both docs |
| 3b | **Measure Q9** — accuracy-lowering vs stop/start, background restart inside a live session | hours | — | decides the whole §5 architecture |
| 4 | `CLBackgroundActivitySession` + motion-gated GPS duty cycling (§5) | medium | med | the app survives a round; 3–7× less GPS-on time |
| 4b | Degradation path — `isLowPowerModeEnabled`, visible "tracking stopped", pedometer dead reckoning + manual marking | small–med | low | stops silent loss of the back nine |
| 5 | Tier 0 shot detection — `CMMotionActivity` + `CMPedometer` + GPS segment boundaries | medium | medium | automatic shot list, no audio, no ML |
| 5a | **Measure Q12a — far-field capture test, 20 min of a real foursome** | hours | — | gates all of §7; run before anything else there |
| 5b | **Measure Q12 (diarization) and Q14 (PCC context)** | hours–days | — | decides §7's feasibility and its entire architecture |
| 5c | Decide the key-handling model — BYO key vs proxy backend (§7) | — | — | a product/infra commitment, not a coding task |
| 6 | Round reconstruction UI — course map, per-hole shot list, **video thumbnails on shots that have one** (§0); built as a **reviewable draft with per-shot confidence** | medium | low | the actual deliverable, and the differentiator |
| 6b | Evidence-bundle builder — compressed GPS segments + transcript + swing-video anchors (§7) | medium | low | the input format everything else feeds |
| 6c | Ground-truth eval set, 5–10 real rounds (Q15) | medium | — | must precede model choice, not follow it |
| 6d | **LLM reconstruction, single call, structured output + self-verification** (§7) | medium | med–high | the foursome ask; ~$0.05–0.10/round |
| 7 | Derived score + full manual correction affordance | small | low | makes an imperfect tracker usable |
| 7b | Decide swing-clip audio policy — keep+disclose, or detect impact then strip (§9) | small | low | closes the real consent exposure |
| 8 | **App Intents / Siri club-and-score logging** (§3 primary path) | small–med | med | ask #1, at near-zero battery cost |
| 9 | Distance-based club inference over accumulated rounds | medium | medium | zero-effort club data; needs history to converge |
| 10 | Tap-to-voice-note: foreground VAD → ASR burst (Tiers 2–3) | medium | medium | free-form notes; only if #8 proves insufficient |
| 11 | Apple Watch companion (Q8) | large | medium | likely the real answer to ask #1; scope after #8 |

---

## 12. References

- [Guideline 2.5.4 — background audio rejections](https://developer.apple.com/forums/thread/95216) · [audio_service #975](https://github.com/ryanheise/audio_service/issues/975) — record-only apps declaring `UIBackgroundModes: audio`
- [`AVAudioSession.ErrorCode.cannotStartRecording`](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartrecording) · [background-recording thread](https://developer.apple.com/forums/thread/120038) — G2, the decisive constraint; restriction in force since iOS 12.4
- [`CLBackgroundActivitySession`](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession) · [`CLLocationUpdate.liveUpdates()`](https://developer.apple.com/documentation/corelocation/cllocationupdate) · [stopping & resuming background location](https://developer.apple.com/forums/thread/810433) — G6: sessions start in the foreground only
- [Energy Efficiency Guide — Reduce Location Accuracy and Duration](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/LocationBestPractices.html) — `desiredAccuracy` gates which radios power up
- [Controlling the Location Services status bar (QA1965)](https://developer.apple.com/library/content/qa/qa1965/_index.html) — blue bar vs arrow glyph per service
- [Prevent pausing location updates when stationary](https://developer.apple.com/forums/thread/763696) — auto-pause fires even with `pausesLocationUpdatesAutomatically = false`
- [Region Monitoring and iBeacon](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/RegionMonitoring/RegionMonitoring.html) — 20-region cap, 3–5 min notification latency, ~400 m radius guidance
- [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/) · [overview](https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer) — `SpeechTranscriber`, `SpeechDetector`, no 1-minute cap
- [Getting Started With App Intents](https://useyourloaf.com/blog/getting-started-with-app-intents/) — `openAppWhenRun = false`, extension execution context
- [MetricKit `MXLocationActivityMetric`](https://developer.apple.com/documentation/metrickit/mxlocationactivitymetric) — per-accuracy-tier cumulative time
- [OSM `Tag:golf=hole`](https://wiki.openstreetmap.org/wiki/Tag:golf=hole) · [`golf=fairway`](https://wiki.openstreetmap.org/wiki/Tag:golf=fairway) · [`leisure=golf_course`](https://wiki.openstreetmap.org/wiki/Tag:leisure=golf_course)
- [Claude Haiku 4.5 / Sonnet 5 / Opus 5 pricing & context](https://docs.claude.com/en/docs/about-claude/pricing) · [Message Batches](https://docs.claude.com/en/docs/build-with-claude/batch-processing) (50% cost) · [Structured outputs](https://docs.claude.com/en/docs/build-with-claude/structured-outputs) — §7 model math
- [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) — diarization support is Q12
- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-models-context-window) — the 4,096-token ceiling that rules out on-device inference for §7
- [Arccos automatic shot tracking](https://www.arccosgolf.com/pages/automatic-shot-tracking) · [Arccos vs Shot Scope](https://www.scoringzone.net/blog/arccos-vs-shot-scope.html) — >98% tee shots, short-game weakness, phone battery as the reason for a separate wearable
