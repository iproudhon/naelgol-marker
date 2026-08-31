# Marker — Research: Live Transcription, and Korean + English Together

Date: 2026-08-27 · Status: measured on this Mac (macOS 26.6.2) plus published sources
· **§7 added the same day, after Siri and Apple Intelligence were scrapped and the
requirement changed. Read §7 before acting on §0 or §4.**

Written after the batch transcriber landed and did not do what was wanted. Two
questions, and they are not the same question:

1. **Why is it not live?** — an audio-plumbing problem, not a model problem.
2. **What recognises the speech?** — reopened by a new requirement: **the round is
   spoken in English *and* Korean, and the app must handle both without being told
   which.**

Everything in §1–§3 was measured here. Numbers from elsewhere are marked and cited.

---

## 0. The finding that decides most of this

> **Read §7 first if you are choosing an engine.** §0–§4 were written when
> simultaneous Korean-and-English was a hard requirement and the app was going to
> record. Both premises moved on 2026-08-27: the input path went to Siri and came
> straight back (TODO.md), and the user relaxed multi-language to *"good, not
> must"*. Nothing measured below is retracted — §7 re-ranks against the new
> constraint and reaches the same recommendation for a different, weaker reason.

> **Two `SpeechTranscriber`s, one for `en_US` and one for `ko_KR`, run at the same
> time inside a single `SpeechAnalyzer`, and both produce output over the same
> audio.** Measured 2026-08-27. That is a working bilingual design using the
> framework already integrated, with no third-party model and nothing leaving the
> device.

And the corollary, which is the reason it matters:

> **Whisper is architecturally bad at exactly this case.** Its language token can
> only name one language per window, it "shows poor performance in code-switching
> speech where multiple languages are used within a single sentence", and it tends
> to **translate** the minority language rather than transcribe it. Swapping Apple
> for Whisper to gain Korean would lose the code-switching that a Korean-American
> foursome actually speaks.

---

## 1. The library was never why it is not live

`AudioRecorder` uses **`AVAudioRecorder`**, which writes an `.m4a` and exposes no
buffers. An `.m4a` still being written is not a readable file. So a round in
progress has nothing transcribable in its current segment, and that is the entire
reason the app's button is manual and only reads segments that have already closed.

`SpeechAnalyzer` **already streams.** `AnalyzerInput(buffer:bufferStartTime:)` and
`start(inputSequence:)` take an `AsyncSequence`; the file initialiser this project
uses is the convenience wrapper over that. The live path is not missing from the
framework — it is missing from our audio capture.

**WhisperKit would need the identical plumbing.** Every on-device engine consumes
PCM buffers from an `AVAudioEngine` tap. Choosing a different engine does not
avoid one line of the work below.

### The fork, which is the real decision

| | Change | Risk |
|---|---|---|
| **a. Second `AVAudioEngine` tap** alongside `AVAudioRecorder` | least code | two capture clients on one `AVAudioSession`; unverifiable from macOS |
| **b. Rebuild `AudioRecorder` on `AVAudioEngine`**, one tap feeding **both** the file and the recogniser | most code | touches route pinning, the no-`.allowBluetooth` rule, and the category that grants background recording |
| **c. Rotate segments on a timer**, transcribe each as it closes | least risk | lag of one segment; rotation is a new way to drop audio at a boundary |

**(b) is the correct shape**, and the pattern is ordinary: install one tap, write
the buffer to an `AVAudioFile` inside the tap closure *and* yield it to the
analyzer. One microphone, two consumers, one format.

Two things make (b) sharper than it looks:

- **The `.m4a` must keep being written.** poc-plan §Phase 2 is "run both paths over
  the same audio — a measurement, not a choice", and a discarded recording makes
  that comparison unrunnable forever. Live transcription is **additive** to the
  file, never a replacement for it.
- **Interruption recovery is the risky part, and it is exactly what this app hits.**
  A developer-forum report (unanswered by Apple) has `installTap` silently ceasing
  to fire after a phone-call interruption on iPhone 16e / iOS 18.4–18.7 — engine
  running, no error, no buffers. Earlier devices are unaffected. The workaround is a
  full stop / `removeTap` / re-install / restart. Segmentation exists in this
  codebase *because* a 4.5-hour round gets interrupted, so this is not an edge case
  here; it is the normal case. **A live design must treat "did a buffer arrive
  recently?" as a health check, not an assumption.**

---

## 2. Measured: what the two Apple models actually do

Fixture: `say`-synthesised golf talk, concatenated to one 7 s file —
Korean → English → Korean:

1. `형 나이스 샷. 저는 세븐 아이언 칠게요.`
2. `Nice shot Steve. What did you make?`
3. `보기 했어요. 스티브는 파.`

### 2.1 Locale support — measured, not searched

`SpeechTranscriber.supportedLocales` → **30**, including **`ko_KR`**, `ja_JP`,
`zh_*`, `yue_CN`. `installedLocales` on a fresh machine → **English variants only**;
Korean downloaded on demand through `AssetInventory` and then worked.
`DictationTranscriber.supportedLocales` → **54** (a wider, older set).

### 2.2 One locale at a time — each model fails differently

| Audio | Model | Output |
|---|---|---|
| mixed KO/EN/KO | `en_US` | `Nice shot, Steve.` · `What did you make` · `.` — **all Korean silently dropped** |
| mixed KO/EN/KO | `ko_KR` | `형 나이스샷 저는 세븐 아이언 칠이에요. Niceshot Stee. What did you make? 고기했어요. 스티브는 차.` |
| English-only golf talk | `en_US` | `Your way, Steve, I'm hitting 7 iron.` · `Nice shot.` · `That's in the bunker.` |
| the same English audio | `ko_KR` | `You'r away Steve I'm hiting 7 iron. Nice shot That's in the Bunka.` |
| more English golf talk | `en_US` | `What did you make on that hole?` · `Bogey.` · `I had a par.` · `Day 3 potted from the fringe.` |
| the same audio | `ko_KR` | `What d you make on th ale o had ar a re ad o the frind.` |

Three things fall out of that table:

- **`en_US` drops Korean entirely** — silence, not garbage. Benign as failures go,
  and catastrophic for this product: for a group that switches language mid-hole,
  the dropped half is evidence that no longer exists.
- **`ko_KR` transcribes *both* languages** but degrades English: `Steve` → `Stee`,
  and — worse — **`보기`(bogey) → `고기`(meat)** and **`파`(par) → `차`**. Scoring
  terms are what a hole's result rests on.
- **`ko_KR` alone is not a shortcut.** On pure English it went from usable on one
  segment to unreadable on the next.

### 2.3 The two models fail on *different* tokens

On the same English segment, `en_US` produced `Your way, Steve` and `ko_KR`
produced `You'r away Steve`. **The Korean model got the turn-order cue the English
model lost.** Their errors are not correlated, which is what makes running both
worth its cost — the union carries more than either transcript alone.

### 2.4 Both at once — measured working

Passing two `SpeechTranscriber`s as two modules of one `SpeechAnalyzer` produced
**both** transcripts over one pass of the audio:

```
[ko_KR]  0.00– 7.03  형 나이스샷 저는 세븐 아이언 칠이에요. Niceshot Stee. What did you make? 고기했어요. 스티브 차.
[en_US]  1.92– 4.08  Nice shot, Steve.
[en_US]  4.08– 4.86  What did you make
```

One caveat visible in that output: **the Korean model returned the whole file as a
single result**, where English segmented into utterances. Over a 4.5-hour round that
could mean very coarse Korean timestamps. Unmeasured at length; §5.

### 2.5 Contextual strings — why the earlier negative result happened

Measured 2026-08-26: `AnalysisContext.contextualStrings` changed nothing. The
reason is now known and it is not a bug in our code — **contextual strings are
honoured by `DictationTranscriber` and ignored by `SpeechTranscriber`.** Apple's
own guidance for biasing `SpeechTranscriber` toward domain terms points at
`SFSpeechLanguageModel` instead.

That reframes `DictationTranscriber`, which we had written off: it supports
contextual strings **and** carries a `ContentHint.farField` that `SpeechTranscriber`
has no equivalent for — and far-field capture (Q12a) is this product's hardest open
problem. Against it: it is the short-utterance/dictation model, the migration target
for `SFSpeechRecognizer`, not the long-form one. **Worth measuring as a third
parallel module, not as a replacement.**

---

## 3. The engines, against *this* requirement

| Engine | Korean | Code-switching | Streaming | On device | Notes |
|---|---|---|---|---|---|
| **Apple `SpeechTranscriber`** | yes (`ko_KR`, measured) | **yes, by running two locales at once (measured)** | yes, `AnalyzerInput` | yes | already integrated; ignores contextual strings |
| **Apple `DictationTranscriber`** | yes (54 locales) | untested | yes | yes | honours contextual strings; **`farField` hint**; short-form model |
| **WhisperKit / Argmax OSS SDK** | yes (large-v3) | **architecturally poor** — one language token per window; **translates** rather than transcribes across a switch | chunked 30 s windows | yes | v1.0.0 May 2026; <1 GB peak on iPhone 15 Pro; large-v3-turbo ≈1.6 GB on disk |
| **Parakeet TDT v3 (FluidAudio)** | **no** — 25 European languages | n/a | yes (Parakeet EOU, 320 ms chunks) | yes | fastest of the lot (155× realtime on M4 Pro, 2.5% WER LibriSpeech) but **Korean rules it out** |
| **whisper.cpp** | yes | same Whisper limitation | chunked | yes | no Swift package story as clean as the above |
| **SenseVoice** | yes, CJK-specialised | unclear | — | via sherpa-onnx | reported 52× realtime on CJK; would not cover English well alone |

**Parakeet is out on the requirement**, despite being the fastest and most accurate
option in the table. **Whisper is out on the requirement it was proposed to solve** —
it is the engine least suited to a sentence containing both languages.

### Performance, for scale (published, not measured here)

- WhisperKit on iPhone 15: **<5% battery per 30-minute session**, <4% extra over 60
  minutes, 0% thermal throttling over 15 minutes at 22 °C; peak memory <1 GB on
  iPhone 15 Pro, <400 MB on iPhone SE.
- Parakeet TDT v3: 1 hour of audio in **19 s** on M4 Pro; encoder cold-start
  **3.4 s** on iPhone 16 Pro Max, 20–50% slower on iPhone 13.
- **Apple `SpeechTranscriber`, measured here: ~25–30× realtime** on this Mac for
  batch files. Nothing measured on a phone, and nothing at all on battery.

---

## 4. Recommendation

**Do (b), with two Apple locales, and keep writing the file.**

1. **Rebuild `AudioRecorder` on `AVAudioEngine`.** One input tap; inside the tap
   closure, write to an `AVAudioFile` *and* yield an `AnalyzerInput` to the
   analyzer. Segment rotation stays exactly as it is; the `.m4a` output is
   unchanged, so `golfctl transcribe` and the whole Phase 2 comparison keep working
   over the same files.
2. **Two `SpeechTranscriber` modules — `en_US` and `ko_KR` — in one analyzer.** Tag
   each `Utterance` with the locale that produced it and keep both. They overlap in
   time and disagree; **do not merge them in code.** The LLM step is already the
   reconciler, and §2.3 shows the disagreement carries information — "Niceshot Stee"
   beside "Nice shot, Steve." is how *Steve* survives.
3. **Locales come from the round, not a global setting.** Default `en-US` +
   `ko-KR`, editable per round, so a group that speaks only English pays for one
   model.
4. **Treat "no buffer recently" as a fault.** The interruption bug in §1 fails
   silently, and a round that records nothing is unrecoverable. Health-check the
   tap; on a stall, tear down and re-install.
5. **Do not adopt a third-party engine yet.** It costs the plumbing anyway, it adds
   a model licence and 0.4–1.6 GB, and on the one requirement that reopened this
   question — Korean and English in one sentence — the leading candidate is worse
   than what is already integrated.

### 4.1 What building it actually cost *(implemented 2026-08-27)*

Recommendation (b) is now in the codebase, verified on macOS end to end:
`golfctl record --live` records the `.m4a` and transcribes bilingually off the same
tap. Two things that the research above did **not** predict, both of which fail
silently and both of which are now invariants in CLAUDE.md:

- **`AVAudioFile(forWriting:)` with AAC works — but only if you release it.** The
  compressed-write path was the one unverified assumption in the plan and it holds
  (spiked before anything was built on it): 3 s of tap audio wrote a 16 kHz mono
  `.m4a` that read back at 45,880 frames. But the same file, opened while its
  `AVAudioFile` was still alive, **fails `ExtAudioFileOpenURL` outright** — and
  `length` read 45,056 before release against 45,880 after, so even a file that opens
  is missing the encoder's tail. `AVAudioRecorder.stop()` gave this for free. A
  segment must be *released*, not merely stopped, before anything tries to read it.
- **`AnalyzerInput(buffer:bufferStartTime:)` is a trap for live audio.** Stamping each
  buffer with its wall-clock position — the obvious way to keep the session clock
  honest — produced **one volatile word ("I"), repeated, and no finalized results at
  all**, over speech the same analyzer transcribes cleanly with `bufferStartTime`
  omitted. The analyzer keeps its own clock by counting samples; a second, jittering
  one makes its input look overlapped. The session-clock mapping has to happen on the
  way *out* (`LiveAudioClock`), where a gap in delivery moves an anchor instead of
  quietly compressing the round.

Two supporting facts also came out of it: the input tap delivers buffers from an
**unbundled CLI** (so the whole chain is developable on a Mac, unlike CoreLocation),
and `SpeechAnalyzer.bestAvailableAudioFormat` does **not** return the 16 kHz mono the
`.m4a` is written in — the file's format and the analyzer's are different, so one tap
feeds two converters.

### What would change this

If far-field capture turns out to be the binding constraint (Q12a — still unmeasured
on real audio), `DictationTranscriber`'s `farField` hint and its contextual-strings
support may matter more than `SpeechTranscriber`'s long-form quality. It is another
module in the same analyzer, so that is a measurement, not a rewrite.

---

## 5. Open questions

| # | Question |
|---|---|
| **L1** | Does the `ko_KR` model segment a long recording, or return one enormous result? Measured only on a 7 s file, where it returned one block. |
| **L2** | Battery for two ASR models + audio encode + GPS over 4.5 hours. Nothing published covers two concurrent models; nothing here has run on a phone at all. |
| **L3** | Does `installTap` survive interruptions on the actual test device? The reported failure is silent. **A watchdog is now implemented** (10 s without a buffer ⇒ restart into a new segment) but has never been triggered by a real stall. |
| **L4** | Does `DictationTranscriber` + `farField` beat `SpeechTranscriber` on real far-field audio of a foursome? |
| **L5** | Golf-vocabulary WER on real audio, per language. Everything measured so far is synthetic close-mic TTS, which verifies plumbing and *not* accuracy. |
| **L6** | Does `SFSpeechLanguageModel` recover the term biasing that `SpeechTranscriber` ignores — and is it worth the build step? |
| **L7** | **Can this app record and recognise for 4.5 hours on a phone at all?** No engine choice answers this and only a device run does. See §7.4 — it outranks every accuracy question in this file. |
| **L8** | Apple `ko_KR` WER on real Korean conversational audio. Everything here is 7 s of synthetic TTS, and no third party publishes a Korean number for `SpeechTranscriber`. |

---

## 7. Re-ranked for the phone *(2026-08-27, after the Siri detour)*

### 7.1 What changed, and what did not

Two things moved on the day §1–§4 were implemented:

- **The app must listen again.** Siri dictation and on-device Apple Intelligence were
  built, run on a device, and scrapped in a day — two turns per sentence, one
  language, ~4k of context, and garbage on real input (TODO.md has the defects). The
  typed box is currently the *only* way into a round.
- **The user relaxed the language requirement**: *"multi language at once is good,
  not must."*

**The relaxation is smaller than it looks, and getting this wrong would reverse the
answer.** It downgrades *both languages inside one sentence*. It does **not**
downgrade *a Korean sentence must not vanish* — and that is the constraint §2.2
actually measured. `en_US` alone does not garble Korean, it **drops it in silence**,
and a dropped sentence is evidence that no longer exists: nothing downstream can tell
a quiet stretch from a sentence the recogniser declined to hear. Same failure shape as
the silent audio segment that `TranscriptCoverage` exists for.

So the relaxed requirement reads: **every utterance must produce text in some
language; the two need not be reconciled inside one recogniser.** That is a real
relaxation — it admits *parallel monolingual* recognisers, which is what Apple's
two-locale design already is — and it is not a licence to ship English-only.

**Consequences, stated so this is not misread next month:**

| Engine | Was out because | Still out? |
|---|---|---|
| **Parakeet TDT v3 / Parakeet EOU** (FluidAudio) | no Korean | **Yes — unchanged.** 25 European languages plus ja/zh; Korean is not in the set, and the streaming EOU model is English-only. Fastest thing measured anywhere and it does not matter |
| **Moonshine** | English-only | **Yes — unchanged** |
| **Whisper / WhisperKit** | code-switching | **Softened, but see §7.2** — as a *monolingual* recogniser it is viable; as the thing that hears a mixed sentence it is now measured-bad by a third party |

### 7.2 Code-switching: our synthetic result is now confirmed by a real benchmark

§0's claim was based on published architecture arguments plus a 7-second TTS fixture.
**HiKE** (EACL Findings 2026) is a non-synthetic Korean–English code-switching
benchmark, and it puts numbers on it — verified from the paper, not from a summary:

| Model | MER (overall) | PIER (overall) |
|---|---|---|
| Whisper-Small (244M) | 56.7% | 48.1% |
| Whisper-Large (1.5B) | 32.1% | 39.5% |
| SenseVoice-Small | 52.6% | 53.4% |
| GPT-4o-Transcribe (cloud, best in the paper) | 33.4% | 28.3% |

PIER is *Point of Interest Error Rate* — error measured specifically **at the
transitions**. The paper's own framing is the finding: monolingual error rates for
these models stay under 10%, and code-switching drives them past 32%.

Two things follow:

- **Whisper is confirmed bad at the mixed sentence**, at a magnitude (Small: 4.5–8.3%
  monolingual → 48.1% PIER) that a phone-sized model does not recover from. Whisper
  *large* halves it and is 1.6 GB.
- **SenseVoice is out too**, which is new. It was in §3's table as the CJK-specialised
  option and it is the *worst* PIER in the paper — worse than Whisper-Small.

Neither result forbids running a monolingual recogniser per language. Both forbid
expecting one model to do the switch.

### 7.3 The engines, against the phone

| Engine | Korean | Ships in app | On-disk | iOS floor | Streaming | Verdict |
|---|---|---|---|---|---|---|
| **Apple `SpeechTranscriber` ×2 locales** | yes (`ko_KR`, measured) | **0 MB** — in the OS | 0 | **26** | yes, `AnalyzerInput` | **Incumbent. Built, verified end to end on macOS at 43× realtime** |
| **Apple `DictationTranscriber`** | yes (54 locales) | 0 MB | 0 | 26 | yes | Third module, not a replacement. Honours contextual strings and has `ContentHint.farField` — §2.5 |
| **sherpa-onnx streaming Zipformer, one per language** | **yes** — `streaming-zipformer-korean-2024-06-16`, ~60 MB, ~160 ms reported latency | ~120 MB for the pair | ~120 MB | **low** — ONNX Runtime, no iOS 26 needed | yes, truly streaming | **The only credible non-Apple path.** New since §3 |
| **WhisperKit** | yes (large-v3) | 0.6 GB compressed / 1.6 GB turbo | 0.6–1.6 GB | low | 30 s chunked windows | Viable monolingual; chunked, not truly streaming; see §7.2 for the mixed sentence |
| **Parakeet TDT v3 / EOU** | **no** | — | — | — | yes | **Out on Korean**, still |
| **Moonshine** | **no** | — | — | — | yes | **Out on Korean** |
| **whisper.cpp** | yes | same as WhisperKit | — | low | chunked | Same model, worse Swift story, Metal/CPU rather than ANE |

**sherpa-onnx is the one genuinely new option** and it deserves the row: two streaming
Zipformers at ~60 MB each is *the same architecture as the incumbent* — parallel
monolingual recognisers, union of both transcripts — with no iOS 26 dependency and no
gigabyte. What it costs is a second audio runtime, a model licence, an ONNX build in
the app, and every one of the plumbing problems in §4.1 solved again from scratch.

### 7.4 The constraint that actually decides this, and no engine answers it

**Can this app record and recognise for four and a half hours on a phone, in a
pocket?** That question outranks every WER number in this file, and **it is identical
work for every engine in the table**:

- `AVAudioSession` `.record` + `setActive(true)` is what grants background recording —
  not `UIBackgroundModes: audio`. Verified as a rule, never on a phone.
- iOS suspends background apps aggressively; developer reports have `AVAudioEngine`
  sessions paused or killed even with the mode set.
- `installTap` can **silently** stop delivering buffers after a call interruption —
  engine running, no error, no buffers. The 10 s stall watchdog is built and has never
  fired against a real stall.
- Battery for two recognisers + audio encode + GPS over 4.5 hours is unpublished.
  WhisperKit's own figure — <5% per 30 minutes on an iPhone 15 — extrapolates to
  ~45% over a round for *one* model with nothing else running, which is the right
  order of magnitude to worry about and not a measurement of this workload.

**A third-party engine does not reduce any of that. It adds a second runtime that has
to survive all of it.** That is the argument, and it is stronger than the accuracy
argument below.

### 7.5 The accuracy evidence conflicts, and neither side measured our workload

Two 2026 benchmarks point opposite ways, and both parties have an interest:

| Source | Workload | Apple `SpeechTranscriber` | Whisper |
|---|---|---|---|
| Lyonesse/Inscribe | LibriSpeech read audiobook speech, M2 Pro | **2.12%** clean / **4.56%** other; ~3× faster | Whisper-Small 3.74% / 7.95% |
| Argmax (WhisperKit's vendor) | their own eval, unstated | **14.0%**, 70× realtime | WhisperKit-small **12.8%**; their Pro SDK 11.7% at 359× |

They are not contradictory so much as differently scoped: read audiobooks versus
something much harder. **The harder set is closer to a foursome on a fairway than
LibriSpeech is**, so Argmax's ordering deserves more weight than its provenance
suggests — and it still puts Apple within 1.2 points of WhisperKit-small.

One vendor claim is directly contradicted by our own measurement: Argmax says Apple
supports **10** languages. `SpeechTranscriber.supportedLocales` returned **30** on this
machine, Korean included (§2.1). Trust the measurement.

**Nobody has published a number for the workload that matters**: far-field,
multi-speaker, outdoors, two languages, golf vocabulary. That is L5 and it is still
open — and it is the only number that would justify carrying a gigabyte.

### 7.6 Recommendation

> **OVERRULED by the user on 2026-08-27, the same day.** The engine is **WhisperKit**, a
> multilingual model the user selects, never told a language and never asked to translate. §8
> records what that changed and, more usefully, **which of §3's objections to Whisper survived
> contact with the code**: the decisive one — "it translates the minority language" — turned out
> to be a decoding setting (`task = .transcribe` is inert unless `usePrefillPrompt` is on), not a
> property of the model. The recommendation below is kept as written because the reasoning about
> *why the deciding constraint was not accuracy* is still the right frame, and because a
> recommendation quietly edited to match what was built teaches nothing.

**Keep the Apple path. Put it back in the app. Do not adopt a third-party engine now.**

1. **Restore the microphone to the app target** — `NSMicrophoneUsageDescription`,
   `UIBackgroundModes: audio` in `Apps/Naelgol Marker/Info.plist`.
   ✅ **Done 2026-08-27.** With one change of shape the user asked for: **recording
   is off by default and driven by a record button**, so `recordAudio` stays
   `false` and `RoundSession.startAudio()` opens a *burst* instead. A round is
   therefore several segments with real gaps, not one continuous recording — which
   the segment format already expressed and which incidentally makes step 3's
   battery question a different, smaller question than it was.
2. **Run the built path unchanged.** `AudioRecorder` on `AVAudioEngine`, one tap, two
   `SpeechTranscriber` modules (`en_US` + `ko_KR`) in one `SpeechAnalyzer`, both
   transcripts kept, `.m4a` still written. It is verified end to end on macOS at 43×
   realtime and it costs **0 MB** of app download.
   ✅ **Done 2026-08-27**, plus the app half: `LiveTranscript` files each finalised
   sentence as a `LogEntry(source: .spoken)` and draws volatile lines dimmed and
   italic without storing them. Two things the toggle turned up that continuous
   recording never would have: `AudioRecorder.stop()` never deactivated the audio
   session (harmless for one long recording, fatal for a toggle — the group's music
   would have died at the first burst and stayed dead), and `listen(nil)` left
   `pendingListener` armed, so the second burst would have fed a finalised
   analyzer.
3. **The first measurement is L7, not accuracy.** One real round on a phone, in a
   pocket: does it survive interruptions, does the watchdog fire, what does the
   battery do. Everything else is unanswerable until that is.
4. **Then measure golf-vocabulary WER per language on that recording** (L5), which is
   now possible again — under Siri it was permanently unmeasurable.
5. **Keep the seam.** `Transcriber` is a protocol and `golfctl --asr apple|whisperkit`
   is the comparison rig. If L5 comes back bad on Korean, the two candidates in order
   are `DictationTranscriber` as a third module (free, `farField`, contextual strings)
   and **sherpa-onnx's paired streaming Zipformers** (~120 MB, no iOS 26 floor) —
   *not* WhisperKit, whose only advantage here is language breadth this product does
   not need.

### 7.7 What would change this

- **A device run that shows two Apple recognisers cannot survive 4.5 hours** — then
  the answer is not a different engine, it is a *duty cycle*: recognise on speech
  (VAD-gated), or transcribe closed segments on a timed rotation, which
  `AudioRecorder.rotateSegment()` already supports and nothing yet calls.
- **A Korean WER measurement that is bad** — then `DictationTranscriber` or paired
  Zipformers, in that order, per step 5.
- **The iOS 26 floor becoming a problem** — sherpa-onnx is the only option in the table
  that does not need it.
- **Apple shipping diarization or contextual-strings support in `SpeechTranscriber`** —
  would close L4 and L6 at once. Neither is a reason to wait.

---

## 6. Sources

- [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SpeechTranscriber — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
- [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Improving Speech Analyzer transcription for technical terms — Apple Developer Forums](https://developer.apple.com/forums/thread/801877) — contextual strings are `DictationTranscriber`-only
- [SpeechAnalyzer > AnalysisContext lack of documentation — Apple Developer Forums](https://developer.apple.com/forums/thread/811083)
- [AVAudioEngine installTap stops working after phone call interruption — Apple Developer Forums](https://developer.apple.com/forums/thread/805735)
- [Using AVAudioEngine to record, compress and stream audio on iOS](https://arvindhsukumar.medium.com/using-avaudioengine-to-record-compress-and-stream-audio-on-ios-48dfee09fde4)
- [WhisperKit: On-device Real-time ASR with Billion-Scale Transformers (arXiv 2507.10860)](https://arxiv.org/abs/2507.10860)
- [WhisperKit — Argmax](https://www.argmaxinc.com/blog/whisperkit)
- [iOS Speech Recognition in 2026: WhisperKit & SpeechAnalyzer — Fora Soft](https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621)
- [FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) · [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [Extending Whisper for Korean-English Code-switching Speech Recognition — IEEE](https://ieeexplore.ieee.org/document/10929894/)
- [Adapting Whisper for Code-Switching through Encoding Refining and Language-Aware Decoding (arXiv 2412.16507)](https://arxiv.org/html/2412.16507v2)
- [Multi-Language Audio and Transcription Inconsistencies — openai/whisper discussion](https://github.com/openai/whisper/discussions/2009)

Added for §7 *(2026-08-27)*:

- [HiKE: Hierarchical Evaluation Framework for Korean-English Code-Switching Speech Recognition (arXiv 2509.24613)](https://arxiv.org/html/2509.24613v1) — the MER/PIER table in §7.2
- [Apple's New Speech API vs Whisper: The First Real Benchmark — Lyonesse/Inscribe](https://lyonesse.app/blog/apple-speech-api-benchmark.html) — LibriSpeech, M2 Pro
- [Apple SpeechAnalyzer and Argmax WhisperKit — Argmax](https://www.argmaxinc.com/blog/apple-and-argmax) — the vendor's own comparison
- [sherpa-onnx pre-trained models](https://k2-fsa.github.io/sherpa/onnx/index.html) — streaming Korean Zipformer
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet TDT v3 / EOU language coverage
- [iOS Speech Recognition in 2026: The Complete Guide — Picovoice](https://picovoice.ai/blog/ios-speech-recognition/)
- [Best whisper.cpp Alternative in 2026 — Cactus](https://cactuscompute.com/compare/best-whisper-cpp-alternative) — Moonshine / Parakeet coverage


---

## 8. What WhisperKit actually did *(2026-08-27, after §7 was overruled)*

Measured on this Mac with `golfctl live <file> --realtime`, `openai_whisper-small`, over
`say`-synthesised English and Korean.

### 8.1 The translation objection was a setting

§3 rejected Whisper partly because "it *translates* the minority language instead of transcribing
it". That is real, and it is exactly what `DecodingTask.transcribe` exists to prevent — but the
task is not a flag the decoder reads. It is the `<|transcribe|>` token in the **prefill prompt**,
so with `usePrefillPrompt = false` the setting is inert:

| Setting | Korean in | Out |
|---|---|---|
| `task .transcribe`, `usePrefillPrompt false` | 스티브가 버디를 했어요 | "Steve did a Buddy" |
| `task .transcribe`, `usePrefillPrompt true` | 스티브가 버디를 했어요 | 스피브가 버디를 했어요 |

Both runs reported `language: ko`. The first is a translation delivered under the right language
tag, which is the worst possible shape for a failure — fluent, plausible, and nobody said it.

`detectLanguage` needs the same care in the other direction: it defaults to `!usePrefillPrompt`,
so with the prefill on it must be set explicitly, or `<|en|>` is prefilled and Korean vanishes in
silence. **The three settings only work as a set**, and `WhisperOptionsTests` pins all three.

### 8.2 What survives from §3

- **One language per 30-second frame.** Unchanged and unfixable by configuration. A sentence that
  switches language halfway goes to whichever language dominates it. This is the real cost of
  leaving the Apple two-recognizer arrangement.
- **Code-switching accuracy.** HiKE's 48.1% PIER for Whisper-Small is a measurement of exactly
  that failure and it still stands.
- **Parakeet** is still out: no Korean.

### 8.3 "Live" is a wrapper, and the wrapper is the interesting part

Whisper reads a fixed 30-second frame and decodes it whole; there is no partial output in the
architecture. `WhisperLiveTranscriber` keeps a rolling window since the last commit, re-decodes it
every pass, publishes the result as a hypothesis, and **commits at a trailing silence** (with a
14-second backstop, safely under the 30-second frame). Observed: hypotheses about twice a second,
each extending and revising the last —

```
~ Steve is away. He hit a beauty.
~ Steve is away. He hit a beautiful drive down the road.
~ Steve is away. He hit a beautiful drive down the middle.
```

Committing at a silence rather than a timer is what makes one log per utterance instead of one per
arbitrary window.

### 8.4 Speed, measured — and it is 16× slower than the Apple path

`golfctl transcribe` over a 68-second `say`-synthesised sample, `openai_whisper-small`, M-series
Mac, including model load:

| Engine | Realtime factor | A 4.5-hour round, batch pass |
|---|---|---|
| Apple `SpeechAnalyzer`, two locales | 43× | ~6 min |
| WhisperKit `openai_whisper-small` | **1.5–2.7×** | **~1.5–3 hours** |

Two runs of the same fixture gave 2.7× and 1.5×, so treat it as a band and not a figure. That is on a Mac; a phone will be slower. It does not affect the *live* path — that decodes a
short rolling window and keeps up easily — but it is the number to keep in mind before running the
authoritative pass over a whole round, and it is the strongest argument against moving the picker
up to `large-v3`.

### 8.5 The vocabulary lever is back, and it is not wired

`AnalysisContext.contextualStrings` was measured to do **nothing** for `SpeechTranscriber`
(§2.5) — the knob that was supposed to protect a spoken name was inert, and diarization had
already been cut, so a spoken name is the only attribution signal there is.

Whisper has a working equivalent: `DecodingOptions.promptTokens`, the initial-prompt mechanism,
which genuinely biases decoding. **It is not wired up.** Evidence it is needed, from the very
first run: "Min is putting" came back as *"Mint is putting"*.

Deliberately deferred rather than guessed at, because a Whisper prompt is not free — too long or
too unlike the audio and it induces hallucination and repetition loops.

#### 8.5.1 Wired for the on-demand pass only *(2026-08-28)*

**The prompt is a language signal, and that is the whole reason it is split.** Whisper reads
`promptTokens` as *previous text*, so a couple of hundred English golf words in front of a Korean
phrase is evidence that the audio is English — the inverse of the bug reported twice ("I said
English and it came out Korean"; a language stuck across a whole burst). Feeding the full
`GolfVocabulary` to the decoder would be arguing for the wrong answer in the one place the round
cannot afford it.

So the split is: `TranscriptionContext.names` (the roster and every alias, nothing else) is the
only thing that reaches a decoder; `contextualStrings` keeps the whole vocabulary for engines
where the knob is not a language signal. Names are short, and in a bilingual roster they are
written in **both scripts**, so they carry the attribution signal without carrying a verdict.

And it is wired for the **on-demand re-transcribe only** (`WhisperTranscriber.transcribe(samples:)`
— see §9), never for the live path. The live path decides a language per 30-second frame from a
rolling window that may open on half a sentence: least context, most to lose. The on-demand pass
runs over a whole entry that the small model has already transcribed once, so nothing about its
language decision is load-bearing.

**Measured 2026-08-28** with `golfctl relisten <file> [--players …]`, `openai_whisper-small`, on
the four synthetic fixtures (`ko1`, `ko2`, `mixed`, `en1`) with and without a four-player
bilingual roster:

| | detected language | repetition loops |
|---|---|---|
| no prompt | ko, ko, ko×3, en | none |
| roster prompt | ko, ko, ko×3, en | none |

**No language flipped and nothing looped** — which is the regression these fixtures can settle,
and the one that could make things worse than they are today. What they *cannot* settle is the
half the prompt exists for: they are `say` output, so every name is pronounced cleanly, and the
failure being fixed ("Min is putting" → "Mint is putting") only happens on real far-field speech.

One result argues the other way and is recorded rather than smoothed over: on `ko2`,
"스티브는 파" became "스티브는 다" with the prompt on. Both passes were already wrong about the
neighbouring word (보기 → 고기), it is a single synthetic sample, and it is not evidence of
anything on its own — but it is the shape a prompt regression would take, so **L5 on real audio
still decides this**, and it should look at scoring words as well as names.

### 8.6 Silence is the failure mode nobody warns you about — and VAD is the answer

*(Rewritten 2026-08-27 after a real round: "so many phantom thank-you's", and English
transcribed as Korean. Both turned out to be one bug.)*

**The measurement.** [Investigation of Whisper ASR Hallucinations Induced by Non-Speech
Audio](https://arxiv.org/html/2501.11378v1) ran 301,317 inferences over pure non-speech:

| | Hallucination rate |
|---|---|
| Whisper, unfiltered non-speech | **40.3%** |
| …of which the phrase is "thank you" | **24.76%** |
| …"thanks for watching" | 10.32% |
| Beam size = 1 | 21.3% (and WER over 100%) |
| Whisper's silence threshold = 20 s | ~14.5% |
| **SileroVAD in front of the decoder** | **0.2%** |
| **VAD + a bag of known hallucinations** | **0%**, and WER *improves* to 6.5–9.4% |

The row that matters is the last two: **Whisper's own parameters barely help, and a VAD
essentially eliminates the problem while making transcription better, not worse.** That matches
what happened here exactly — `noSpeechProb`/`avgLogprob` filtering removed the phantoms on pure
synthetic noise and left every real-world one standing.

**The same gate fixes the language bug**, which is why the two reports were one bug. Whisper
decides language from the first 30-second frame, so whatever precedes the speech chooses it:

| fixture | detected |
|---|---|
| clean speech, 4 s digital silence either side | `en` ✅ |
| quiet noisy speech, no padding | `en` ✅ |
| quiet noisy speech **with noisy padding** | **`nn`** + a looping glyph hallucination |

Neither low SNR nor padding alone breaks it. **Noisy non-speech does** — and a golf course is
never digitally silent, which is why the fixtures had not caught it and one real round did.

**The threshold has to be relative.** WhisperKit's `EnergyVAD` and its fixed 0.02 default were
tried first and **ate a whole spoken phrase**: quiet far-field speech peaking at 0.031 over a
0.009 noise floor lost a third of its frames. `WhisperVAD` estimates the floor from the window's
own tenth percentile and requires speech to stand ~4 dB above it. The asymmetry is deliberate and
follows the product's first invariant: a frame wrongly called speech costs one hallucinated line
the filters catch, a frame wrongly called silence costs what somebody said.

**And the language *tag* now comes from the script**, not from the model — `ScriptLocale`. Hangul
is Korean, Latin is not; the text Whisper produced answers the question without ambiguity where
its own per-frame claim does not.

### 8.6.1 What it looked like before and after



Whisper does not return nothing for a quiet window. It returns a short, confident, fabricated
line, because its training data is subtitles and that is what subtitles contain under quiet audio.
Observed within minutes of first running it on real gaps:

- `"Bye."` — English, on the pause between two takes.
- `"MBC 뉴스 정상빈입니다."` — a Korean television news sign-off.
- `[BLANK_AUDIO]` — the model *describing* the audio rather than transcribing it.
- A stretch of near-silence detected as **Polish**.

For a product whose input is 4.5 hours of mostly walking, this is not a curiosity — unfiltered, it
files hundreds of `LogEntry` rows that the extraction pass then reads as things a golfer said.
Two filters, in `WhisperSilence`:

1. OpenAI's own no-speech test, `noSpeechProb > 0.6 && avgLogprob < -1.0`. **Both halves are
   required**: `noSpeechProb` alone discards someone talking two fairways away, which is precisely
   the capture this product depends on, and `avgLogprob` alone discards unusual phrasing, which on
   a golf course is most of it.
2. A caption-annotation test — a line that is entirely one bracketed aside. `skipSpecialTokens`
   does not help here: these are ordinary generated text, not `<|…|>` control tokens.

Together they removed every observed case except the news sign-off, which is confidently decoded
and indistinguishable from speech by these measures. **That residue is an argument for the
existing invariant, not against the engine**: reconstruction output is a draft the user amends,
and a wrong line costs one tap to delete.

### 8.7 Open, and only a phone can settle it

- **L9 (new): realtime factor and battery on a phone.** Cost is per *pass* over a padded
  30-second frame, not per second of speech, and the loop runs continuously while a burst is open.
  This is what decides whether `small` is the right default.
- **L5** (golf-vocabulary WER per language) is unchanged and now engine-specific: it is what tells
  the user whether to move the picker up a size.
- **Model download on a device** is unexercised — the simulator's network blocked Hugging Face and
  the model was side-loaded. The picker downloads on selection precisely because a course will not.

## 9. Re-reading one entry with a bigger model *(2026-08-28)*

*(Built after the user asked for "a transcribe button on a transcribed entry to use a bigger
model … so, choose two models for live transcription and final transcription".)*

**The measurement in §8.4 is what makes this the right shape, and it is the whole argument.**
`openai_whisper-small` decodes at 1.5–2.7× realtime on this Mac and slower on a phone, so a
`large-v3` pass over a 4.5-hour round is hours of a hot phone and is never going to happen. The
same model over the twenty seconds somebody actually said "Chungmin made bogey" is seconds. The
big model is unaffordable continuously and cheap on demand — and the golfer already knows which
line came out wrong, because they are looking at it. So there are **two model settings**, not one:
`marker.whisper.model` keeps up live, `marker.whisper.model.final` is used only when asked.

### 9.1 Getting from a sentence back to its audio

`LogEntry.tEnd` (session clock, nil for a typed log and for every spoken log written before
2026-08-28) is the only thing that makes this possible. `[t, tEnd]` resolves against `audio.jsonl`
through `AudioSpans.resolve`.

**Session times, not a segment name and an offset.** One clock — milliseconds since epoch — and
`AudioTimeline` already owns the mapping between a segment's own timeline and this one; putting a
file name on the row would create a second authority for that mapping, and two authorities can
disagree. A burst's entry grows by superseding, so `t` stays where the golfer started talking and
`tEnd` advances with the last phrase.

Three things `AudioSpans` gets right that the obvious version does not:

- **A burst can cross a segment boundary**, because the stall watchdog rotates mid-burst and an
  interruption closes one. The audio between two segments *does not exist* — it is a phone call.
  So `resolve` returns the pieces **separately**, each piece is decoded on its own, and only the
  **text** is joined. Concatenating the samples would hand the decoder a join that never happened,
  inside a 30-second frame. Verified: a window spanning 320 s of wall clock across a five-minute
  gap reports 20 s of recorded audio, in two spans.
- **A segment with `t1 == nil` is skipped.** Usually that is not the crashed round — it is the
  burst that is recording *right now*, and an `.m4a` still being written cannot be opened at all
  (§8, measured). So a log spoken into the open burst has an empty span list, and the UI says "not
  until this recording stops" rather than offering a button that cannot work.
- **It writes no coverage.** A sub-range pass is not a whole-segment pass, and marking segments in
  `transcript.coverage.json` would record them transcribed when only part of them was read — the
  exact failure that file exists to prevent, since a segment marked done is never read again.
  Nothing here touches `transcript.jsonl` either; the authoritative transcript is still
  `SessionTranscriber` over whole closed segments.

The result is a **superseding row in `log.jsonl`**, the same mechanism as an edit. Nothing is
overwritten, `LogEntry.byID` keeps the original readable so a proposal citing it still renders its
evidence, and the new id makes `ExtractionCoverage` re-read it — which is correct, because the
text changed and that is the point.

### 9.2 Verified, on this Mac

`golfctl relisten <audio-file> [--from S] [--to S] [--model VARIANT] [--players …]` is the CLI
half of the button, and it is the only place the path can be watched here — scripted taps do not
exist in this environment. It makes exactly the two calls the app makes,
`AudioExcerpt.samples` then `WhisperTranscriber.transcribe(samples:)`.

Against a real AAC `.m4a` (7.03 s, bilingual, 16 kHz mono), `openai_whisper-small`:

| range | audio | result |
|---|---|---|
| whole file | 7.03 s | three phrases, all `[ko]`, 0.40× realtime *(cold: model load included)* |
| 0 → 2.8 s | 2.80 s | the first phrase only, 3.0× realtime |
| 4.5 → 7.0 s | 2.50 s | the third phrase only, 2.7× realtime |

So the seek works on compressed audio, which was the risk — AAC has no sample-accurate frame
index and a naive seek silently lands elsewhere. `openai_whisper-tiny` over the same file produced
visibly worse text ("세븐 아이언" → "세분 아이였은"), which confirms the model parameter is
honoured end to end and that the quality axis the feature rides on is real.

**One thing the numbers say that the UI has to respect:** the 4.5–7.0 s excerpt read
"포기했어요" as "고기 했어요" where the whole-file pass got it right. Less context is worse
context. That is why the button re-reads the **whole entry's span** — the burst, pauses included —
and never a single phrase inside it.

### 9.3 One slot was a bug, and only the two-model configuration showed it *(2026-08-28)*

`WhisperEngine` cached `(id: String, kit: WhisperKit)` — **one entry**. That was right
while there was one model. With two it means the live and final models evict each
other:

    burst            → small loaded
    Transcribe again → small evicted, large loaded
    next Record tap  → large evicted, small loaded again

The reload before a burst is precisely what that file's own comment forbids ("loading
is seconds … reloading per burst would mean the first sentence of every burst is
missed"). It stayed invisible because the final model **defaults to the live one**, so
nothing reloads until someone actually uses the feature as intended.

Now an LRU of `WhisperEngine.capacity` (2). Measured with
`golfctl relisten /tmp/mixed.m4a --model small,tiny,small`, one process, 7.03 s of audio:

| pass | wall | note |
|---|---|---|
| `small` | 17.53 s | cold — load dominates |
| `tiny` | 3.95 s | second model loads; `small` **not** evicted |
| `small` | **0.66 s** | reported "already resident" |

10.7× realtime warm against 0.4× cold is the whole cost of a reload, and it is what the
golfer would have paid on the first sentence of every burst.

Two smaller things fell out of it:

- **Loads are deduplicated in flight.** An actor suspends at every `await`, so two
  callers that both miss the cache before either finishes `WhisperKit(config)` would
  both load the same model. That became reachable the moment a round start began
  preloading in the background while a Record tap could land mid-preload. The in-flight
  map is `Task<Void, Never>`, not `Task<WhisperKit, Error>`: `WhisperKit` is not
  `Sendable`, so the task writes into the actor and callers re-read the cache.
- **Preload is at round start, not app launch, and never downloads.** Most launches are
  not rounds. Live model first, sequentially, so a Record tap during the preload is
  served from cache rather than queued behind half a gigabyte. A variant that is not on
  the phone is skipped in silence — the picker is where a fetch is asked for and shown
  a progress bar.
