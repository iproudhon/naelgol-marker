# Marker — TODO

Conventions *(set 2026-08-26)*: items are rephrased for clarity when added; finished
items move to **Done** at the bottom, in the order they were executed. Anything under
**Open** is a request to execute, not a suggestion.

Two files carry what this one deliberately does not. [`CLAUDE.md`](CLAUDE.md) holds every
decision that has hardened into an invariant — if a fix below is stated in one line here,
the argument for it is there. [`docs/plan-history.md`](docs/plan-history.md) holds the
three implementation plans as written *before* the work, including the two features that
were built and then deleted.

**Current state:** 396 tests (1 skipped), `swift build` and the iOS build both clean.
**Nothing has been committed since the scaffold**, and the index is partially staged from
earlier sessions — a bare `git commit` would land a snapshot that does not build.

---

## Open

### The blocking gap — E7, the extraction pass

**Nothing reads `log.jsonl`.** A round accumulates sentences and the card is filled in by
hand. This is the one thing between the app and being a product.

The two halves either side of it are built and have been from the start:
`GolfReconstruction`'s `LogExtraction` (instructions, per-hole prompt, `Proposal` →
`.model` `Event`) is model-agnostic and survived the Apple Intelligence scrap intact, and
`AnthropicClient` is done. What is missing is the pass that joins them — one call over
the round ([`docs/poc-plan-round-reconstruction.md`](docs/poc-plan-round-reconstruction.md)
Phase 3), self-verification (shot count against announced score, turn order, club against
distance, hole scores against total), then `GolfEval` beside it. **Only this tier is
scored** — a live draft tier is the weaker path, and scoring it would report the wrong
number as the product's accuracy ([`docs/plan-history.md`](docs/plan-history.md), D2).

Three things it must respect, all of which have already caused a bug:

- **`ExtractionCoverage`, not citations.** A log that yields no proposal ("we're on the
  ninth") is cited by nothing, so a citation check reports it unread forever and every
  hallucinating pass appends another event. Keyed on the row id, so an edited log *is*
  re-read.
- **Read the nil-hole bucket alongside the selected hole**, or a row the screen shows is
  one the button provably cannot read.
- **A burst entry is read when the burst ends, not while it grows.** Every supersede is a
  new id, so reading mid-burst re-reads the whole accumulated text on every phrase.

**Needs a key.** This machine has no `ANTHROPIC_API_KEY`, which is also why
`golfctl course import`'s extraction leg has never run against the live API.

### Needs a phone

**L7 — one real round in a pocket.** The interruption path (`AVAudioSession` does not
exist on macOS, so a real phone call is unexercised), the stall watchdog against a
genuinely dead tap, background survival, and battery with Whisper decoding continuously —
cost is per *pass* over a padded 30-second frame, not per second of speech. Now also
covers the duty-cycled track and **the two-resident-model memory bet**: two CoreML graphs
held for 4.5 hours is what jetsam looks at first, it is unmeasured, and nothing larger
than `small` has ever been loaded even on this Mac. If a round is ever killed mid-way,
that is the first suspect.

Not yet back on a phone: the VAD fixes, the two-model picker, the re-transcribe button,
and **stopping a burst with a finger** — scripted taps do not exist in this environment.

**L5 — golf-vocabulary and name WER, per language, on real far-field audio.** Never
measured, and it was un*measurable* under Siri; with the recogniser back in our hands it
is a to-do. It now gates three decisions: whether `small` is enough or the picker needs to
go bigger, whether the name prompt helps at all, and whether the prompt also belongs on
the live path. Attribution accuracy is still the metric that decides the feature —
diarization was cut, so a spoken name is the only attribution signal there is.

### After that

**E6 — the hole-view event overlay** *(item 20)*. Smaller again after X7:
`PlayerTrack` already exists in `HoleStyle.swift` with `shots`, `aiming` and four colours
chosen to separate against fairway green *and* against imagery, both renderers draw it,
and `HoleMarker` is now the worked example of a point layer that lives on **both** layers
with its own toggle. Missing: the events→`PlayerTrack` feed and the bubble variant.
Blocked on E7 in practice — there are no events until something extracts them.

**A second course.** Real geometry exists for exactly one —
`Courses/corica-park-south.json`, imported from OSM and verified hole by hole against the
raw ways. The two verification checks exist because the next site will be tagged worse;
still missing are `golfctl survey export`, any track-derived geometry, and any course
placed by hand in the editor.

### Undecided

**Where a handicap index lives between rounds.** Frozen per round as played, but a
player's index is the same next week and retyping it every round is the friction that gets
a feature abandoned. `CourseLibrary` is the precedent for an app-wide preference beside
the per-round record — but a roster is not a course, and "a round's course lives in its own
`meta.json`" exists precisely because reading a global there put another round's data on
screen, twice, in one screen.

**Whether `Mark`/`Scorecard`/`Correction` move to their own target.** The firewall is three
types wide and still only a convention: `GolfReconstruction` depends on
`GolfSessionFormat`, so the compiler will not stop a leak. Raised 2026-08-24 and
deliberately deferred — **do not restructure without asking.** Worth revisiting *with* E7,
not after. Until then, grep `GolfReconstruction` for `Mark`/`Correction` before shipping
any bundle change.

**Nothing on disk records that an entry was re-read.** `LogRetranscribe` writes an ordinary
superseding row, so a re-transcribed burst and a live-grown one are indistinguishable —
"has the big model already seen this?" has no answer. A discriminator on `LogEntry` is the
fix if it ever needs one.

---

### R1 — imagery before the round *(researched 2026-08-29, nothing built)*

Asked: cache satellite images before a round, for all zoom levels. Answer in
[`docs/research-imagery-offline.md`](docs/research-imagery-offline.md): **not from Apple or
Google.** Apple's terms allow only temporary caching and require deletion after use; Google's
Tile API policy prohibits pre-fetching, storing and caching outright and names offline use. A
`MKMapSnapshotter` pass per hole, or a camera sweep to warm the cache, is the excluded act
described precisely — and "all zoom levels" is its largest form.

What is buildable instead: **NAIP**, the USDA/USGS orthoimagery programme — 60 cm, **public
domain**, delivered as files, ours to store per course exactly like `Courses/<id>.json`. One
resolution is enough; past the photograph's detail the vector overlays stay sharp, which is the
two-layer design's own argument. Mapbox and Esri do license offline tile packs and both are a
paid dependency with a key that must be present before the round. Korea has no settled answer and
joins C1.

### R2 — elevation and the plays-like number *(researched 2026-08-29, nothing built)*

[`docs/research-elevation.md`](docs/research-elevation.md). Three sources, and the ranking is not
the obvious one: the phone's GPS altitude is the **worst** (vertical is the weak axis of a fix,
which is why `verticalAccuracy` is reported separately); the barometer already being written by
`MotionRecorder` is the most precise but only for *differences* and only over minutes; and a
stored **DEM** is the right primary — USGS **3DEP 1 m** is lidar-derived, bare-earth, public
domain, and specified at 10 cm (1σ). Korea gets **Copernicus GLO-30**, which is 30 m *and a
surface model*, so it reads canopy as ground — a coarse tee-to-green number and no green contour.

**The first thing to write is the datum rule**: 3DEP is orthometric, `ellipsoidalAltitude` is
not, and the two differ by tens of metres. A difference cancels the datum **only if both ends
come from the same source**; one end from the DEM and one from the phone is thirty yards wrong
and looks like an ordinary number. Storage is a small grid per course in metres — about 1.1 MB at
2 m posts — and it is the thing `HolePlane.unproject` has been deliberately refusing to invent.
`playsLike = D + Δh` is the defensible baseline and must be labelled an estimate. Open questions
E1–E5 are in the doc; **E2 is answerable today from a round already recorded**, because the
barometer data has been written all along and nothing has ever read it.

## Not verified

**Every gesture, everywhere.** Scripted taps do not exist in this environment. Tap-to-place
a target, drag-to-move, pan, pinch, the card's tap-to-score and long-press-to-clear,
swipe-to-edit a log, the context menus, the stat pickers, the editor's tap-to-place,
stopping a burst, the whole Marker bar — the button, the sheet, the location toggle, the
end-round confirmation and swipe-to-dismiss — the hole view's tool column: placing a
target **by button**, dragging a ruler end **or its distance box**, dragging a marker
and the confirm after it, simulate, pan, zoom and tapping a hole number on the course
view — and now everything X13–X16 added: tapping a marker to open it, the hole /
player / shot pickers, shot auto-fill on a real roster, OK, Cancel deleting a burst's
rows, tap-to-edit in the edit dialog, toggling a player *off*, OK on an empty box, and
**whether a just-created marker appears on the hole view** — a bug report rather than a
preference, whose fix has two halves that fire in a different order depending on whether
a fix was already warm. All reasoned about and screenshotted from seeded state, none
touched by a finger. **The hole-flip fix is the sharpest one**:
it is argued and tested, and it was reported from a phone, where nobody has yet
watched it not happen.
`MapProxy.convert` on the satellite layer is unproven on a real finger. **The drag bug
found on device is exactly the class of fault this blind spot hides.**

**The satellite z-order re-add (X26) is the same class as X5.** MapKit's own documentation
does not promise that a later-added annotation draws on top; the `ForEach`-identity bump is
the standard workaround and it is an argument here, not an observation — it needs a marker
drag, which is a finger. If the simulated marker still cannot be picked up off a pill, the
next thing to try is not another declaration order.

**X5 is the sharp case: a fix for a symptom only a finger can see.** The menu flicker was
never reproducible here — it was diagnosed from what redraws the subtree, not observed —
so `HoleSettingsMenu.equatable()` is an argument, not a measurement. First thing to check
on a phone.

Review is by simulator screenshot from pre-seeded state (`DemoSeed`'s launch arguments) —
`ImageRenderer` cannot draw a SwiftUI `Menu` *or* a `List`, so the package render harness
is no use for any of these screens. `DemoSeed` keys are `UserDefaults` keys, so **every one
needs a value**: a bare `-marker.seed` parses as nothing and the screen comes up on
whatever the container held, which looks exactly like the change under review having no
effect.

Also unverified: WhisperKit's iOS floor; MapKit `.imagery` over *Korean* courses at hole
scale (verified good at 37.40/127.20, but not over a real course); VWorld's storage terms
and whether its domain-registered key works from a native app; how accurate a
track-derived green centre is after one round; any OSM course outside Corica Park; the
`/v1/messages` leg of `golfctl course import`.

---

## Done

*(in the order they were executed)*

### The hole view and the course file *(2026-08-26)*

1. **Target placement research** — `docs/research-course-display.md` §9. Tap won the
   category; **removal is undocumented everywhere**, Garmin's manual included; **no app
   chains two targets**; and GolfLink auto-placed its crosshair into a grove of trees,
   which is why nothing here auto-places. *Corrected on the way:* the glove-and-rain
   argument against dragging could not be corroborated — the real argument is occlusion.
2. **Phase 1 foundations** — `HolePlane.unproject`, pan/zoom folded **into the plane**,
   `DistanceDisplay`, `TeePalette`, `HoleReadout`.
3. **Items 1–10** — English hole names; yards by default (storage stays metres); the
   number block stacked at the top with its origin in a caption rather than shouted across
   the middle; tees in their own colours on both layers; vector pans, zooms and takes taps;
   the pin menu; simulation mode with **MARK disabled by construction**; two targets, tap
   places and tap-on-target removes.
4. **Device feedback, five rounds.** Each is now a CLAUDE.md invariant; the short version:
   - **Nothing was draggable** — four competing gestures and SwiftUI resolved arbitration
     in the taps' favour. One self-classifying `DragGesture` replaced them.
   - **Vertical pan scrolled against the finger** — `panY` is screen-oriented, and the
     convention now lives on the type with a test.
   - **Three bugs were one bug:** the plane was fitted to a set including the player and
     the targets, which are placed *by looking at the screen*. Dragging a target re-fitted
     the hole out from under the finger; a fix off the hole shrank it to a dot; simulation
     fought the framing the same way. Pan is no longer clamped either.
   - **"Go to my location" panned to empty rough** — the marker came from
     `HoleReadout.origin`, which falls back to the tee in exactly the case the button
     exists for. `playerAt` carries the real position independently.
   - **Dragging teleported the object to the fingertip** — `DragAnchor` measures the gap
     once, on finger down.
   - **The generous grab handle was vector-only, and invisible.** Both layers take
     `HoleStyle.grabRadius`; it is drawn at 5% fill, because a control you cannot find is
     indistinguishable from one that does not work — which is how it was reported.
5. **Location tracking was genuinely broken outside a round.** `LocationRecorder` is
   created by `RoundSession`, so the hole view had a position only while recording and
   every distance silently fell back to the tee. `LiveLocation` is the round-independent
   feed; `TrackingState` splits **mode** (what the radio is doing) from **phase** (whether
   the number is worth clubbing off).
6. **The course file.** `CourseStore`, the card layer, `OSMCourse` import with three
   independent verification checks — a stroke index that is a complete permutation, total
   length per par, and pairwise tee-colour order, which caught three real faults at Corica
   that no length check could see.

### The two screens, the journal and the card *(2026-08-26 → 27)*

7. **Items 21–22 — the rounds list and the round screen.** `SessionIndex` reads session
   folders; **there is no database**. "Active rounds" turned out to be crash recovery, and
   asking for it found a real hole: a folder with `end == nil` was orphaned in silence.
   Closing out stamps the **last evidence in the folder**, never `now`.
   `Event.provenance` was written before any pipeline code, which is what stopped it being
   a migration plus an audit of every call site later. The screenshots found the same bug
   twice: a round's course was read from the global `CourseLibrary.selectedID`, so another
   course's name and pars were on screen.
8. **Items 31–41 — six phases, all shipped.** `journal.jsonl` as the record with
   `scorecard.json` and the roster **derived** by replay; undo as a row that can itself be
   undone; handicap as three numbers with only the ends stored and ratings frozen as
   played; per-hole stats behind the cell rather than in the grid; superseding `LogEntry`
   rows for edit / move / delete / late coordinate; `HistoryView`. Four things came out
   differently from the plan and all four are invariants now — `meta.json` is never
   rewritten from replay, undo resolution is one backwards pass rather than a fixpoint,
   `live` and `inForce` are two different questions, and one act writes exactly one row.
9. **Three device rounds, three classes of bug.** A `CLLocationManager` delegate retained
   by nothing (the reference is weak, so the continuation was never resumed and *nothing*
   appeared anywhere); a log with no hole invisible on all eighteen screens because
   `nil == 1` is false; and a **runaway** with three separate causes — the hole treated as
   a retry condition, citations mistaken for coverage, and no way to add a player mid-round,
   which is why a roster went into the log box in the first place.

### Siri and Apple Intelligence — built, then scrapped *(2026-08-27)*

10. **Both were dead ends and the code is gone** *(user decision)* — `LogShotIntent`,
    `MarkerShortcuts`, `GolfIntelligence`, `CardImport`, `CardImportView`, `DarwinBridge`,
    deleted the same day they were finished. **Do not reintroduce either.** The defects,
    so nobody re-derives them:

    **Siri.** Two turns per sentence, always — `AppShortcut` phrases take only
    `AppEnum`/`AppEntity` parameters, so free text in one breath *does not exist as an
    API*. One language, the system Siri language, which fails the bilingual requirement
    outright. And a black box: no `contextualStrings` equivalent and no A/B, so WER on the
    product's real input path becomes permanently unmeasurable.

    **`FoundationModels`.** It generated garbage on real input, repeatedly — that is what
    ended it. ~4,096 tokens of context *including output*, so a round does not fit. No
    image input at all. On-device only on iOS 26: no Private Cloud Compute, and a
    third-party app cannot use a linked ChatGPT account however much it looks like it
    should.

    *What survived intact:* `log.jsonl`, the journal, the roster, the card, the round
    screen, and the model-agnostic prompt layer (`LogExtraction`, `CardReading`) — which
    was always written against no particular model, and that is the whole reason it
    survived. `AnthropicClient` came back as the extraction tier, where it was before.

### The microphone, and the engine *(2026-08-27)*

11. **The app listens again, recording is off by default, and it is a button**
    *(user decisions)*. `RoundSession.startAudio()`/`.stopAudio()` open and close a
    **burst** mid-round, so a round is several `.m4a` segments with **real gaps** between
    them — which is what the segment format has always expressed and what `AudioTimeline`
    refuses to accumulate away. `LiveTranscript` files a finalised sentence as a
    `LogEntry(source: .spoken)`; hypotheses are dimmed, italic and never stored.

    Two bugs the toggle exposed that continuous recording never would have: `stop()` never
    called `setActive(false)`, so the first burst would have silenced the group's music for
    the whole round with the orange mic dot lit; and `listen(nil)` cleared `listener` but
    not `pendingListener`, so the *second* burst fed a finalised analyzer and produced
    nothing, silently.

12. **`AudioRecorder` rebuilt on `AVAudioEngine`** — one `installTap`, one converter per
    consumer. Live transcription was an audio-plumbing problem, not a model problem: the
    old `AVAudioRecorder` exposed no buffers at all, and every engine needs the same tap.
    Three measurements came out of it that would each have been a silent bug — an
    `AVAudioFile` must be **released** before its `.m4a` is readable at all; never pass
    `bufferStartTime` on live input; and a segment ends at its **last sample**, not when
    the stall was noticed.

13. **The engine is WhisperKit** *(user decision, overruling research §7's Apple
    recommendation)*. **The objection that killed Whisper turned out to be a setting.**
    "It translates the minority language" is what `task = .transcribe` forbids — and
    `task` is not a switch the decoder reads, it is the `<|transcribe|>` token in the
    prefill, so with `usePrefillPrompt = false` it is a value nothing acts on. Measured:
    "스티브가 버디를 했어요" → "Steve did a Buddy", under the right language tag.
    `detectLanguage` needs the same care in the other direction. **The three options only
    work as a set.**

    What we give up: Whisper decides one language per 30-second frame, so a sentence that
    switches halfway goes to whichever language most of it is in. Apple's two-locale path
    stays reachable as `--asr apple`, because Phase 2 is a measurement.

14. **Bilingual capture, measured before it was designed.** `en_US` **silently drops**
    every Korean utterance — absence, not garbage. `ko_KR` transcribes both but turns
    보기 (bogey) into 고기 (meat). Hence: no English-only Whisper build is ever offered
    anywhere in this codebase, and the failure mode it prevents is *silence*.
    Also settled here: `contextualStrings` is inert on `SpeechTranscriber` by design (it
    is a `DictationTranscriber` feature) — our negative result was correct and is not our
    bug.

15. **Phantom "thank you"s and stuck language — one bug, not two** *(reported from a real
    round)*. Whisper hallucinates on 40.3% of non-speech inferences and "thank you" is
    24.76% of them (arXiv:2501.11378); it also decides the language from the first
    30-second frame, so leading non-speech chooses it. Feeding it the quiet between shots
    produced both symptoms at once — measured here as detected **Norwegian** plus a
    looping glyph hallucination, correct English once the padding was trimmed. Neither low
    SNR nor padding alone breaks it, which is why the synthetic fixtures had missed it.

    Fixed by **not asking the model when nobody spoke**: `WhisperVAD` gates the live path
    and trims leading non-speech **by advancing the window**, never by trimming a copy.
    Two things the first attempt got wrong (research-live-transcription.md §8):
    WhisperKit's `EnergyVAD` with its fixed 0.02 threshold **ate a whole spoken phrase**,
    so the threshold is now relative to the window's own noise floor; and the language
    *tag* now comes from the script the line is written in, because the text answers that
    question and a per-frame claim does not.

16. **The model re-downloaded on every launch, and the first fix missed the cause.**
    `HubApi` adds its `huggingface` path component only to its **own default** base, then
    resolves a repo to `<downloadBase>/models/<repo>` — so a bare Application Support
    directory wrote where the cache check did not look. It survived a round of review
    because the simulator's copy had been placed **by hand** at the path the wrong
    assumption expected; a real download with an explicit base had never been made.
    Verified properly: 51 s cold, 1.8 s warm, and a model in the old broken layout adopted
    rather than re-fetched. **It also downloaded twice within one fetch** — passing
    `modelFolder` short-circuits the weights download, so gating on "weights *and*
    tokenizer" took the online path at the one instant the tokenizer was not there yet.
    `hasWeights` and `isDownloaded` are now separate questions.

17. **One log entry per recording, not per phrase** *(user decision)*. A burst is one thing
    the golfer did. Grown by superseding rather than buffered to Stop, so the row appears
    with the first phrase and survives a crash mid-burst. **Record is offered on a finished
    round and reopens it** — a round does not end when the golfer stops talking; the scores
    get said on the way to the car park.

18. **A round's URL could not be compared with `==`.** `URL.appendingPathComponent`
    consults the filesystem and appends a trailing slash when the component names an
    *existing* directory, so the path built before the folder existed compared unequal to
    the identical path built after. The round screen's `didAppend` guard dropped **every**
    refresh: twenty-nine logs on disk, "Nothing on this hole" on screen. It had never shown
    up because the typed box also appends in memory — the notification path became
    load-bearing only once the recogniser started writing. `SessionFolder.isSame`.

### The entry-level tools, vocabulary and duty cycling *(2026-08-28)*

19. **Vocabulary, both languages**, and the distinction that is the larger half of it:
    `GolfVocabulary.all` biases a *recognizer*; `GolfVocabulary.synonyms` is **a glossary
    the model reads, not a rewrite of a log**. 고구마, 따블, 트, 유틸, 오비 are not
    misrecognitions — Whisper gets them right and they mean something a dictionary does
    not say. Several are ordinary syllables, so a substitution pass would corrupt sentences
    about lunch. Reaches the model **injected rather than imported**, so
    `GolfReconstruction` does not drag WhisperKit into the framework-agnostic target.
20. **Re-transcribe one entry with a bigger model**, and **two model settings** to make it
    possible — `LogEntry.tEnd`, `AudioSpans`, `AudioExcerpt`, `LogRetranscribe`,
    `golfctl relisten`; the whole argument is in research-live-transcription.md §9. The
    short version is `small` at 1.5–2.7× realtime, so a big model is hours over a round
    and seconds over one entry. A span is a **list**, because a burst can
    cross a segment boundary and the audio between two segments does not exist; only the
    **text** is joined. The pass reads the whole entry, never one phrase — measured, the
    4.5–7.0 s excerpt read 포기했어요 as 고기 했어요 where the whole-file pass got it right.
21. **Show where a log was said** — `HoleScreen.focus` marks it and pans there, **never
    fitted to**, which is the rule three separate reported bugs came from.
22. **Copy one entry, and copy the transcript on screen** (this hole / whole round). Built
    from `LogTranscript` over the logs, **not from the timeline**: the timeline hides a log
    an event cites, so copying it would drop the sentences extraction succeeded on and look
    complete doing it.
23. **Duty cycling — item 16's location half, closed.** `LocationRecorder` runs slow from
    round start, fast for a burst and the placement window after it. (Item 16's *other*
    half — "audio records continuously" — was superseded by the record button, which is a
    user decision and not a gap.) `handBackRadio` is the belt: the placement task is
    `.task(id:)` over the *unplaced* logs and does not re-run when a burst placed
    everything as it went, so without a timer the radio would sit at Best for four hours —
    reached through the feature meant to save power. **The saving is an estimate**; the
    baseline round was voided by the user and is not coming.
24. **The hole view remembers its tee, per course, validated against the file.** A single
    global tee name applies "Black" to a course that has none, and the screen then correctly
    loses its yardages with nothing saying why. Needs `.id(course.id)` at the call site, or
    a course switch keeps the view's identity, `init` never re-runs, and the previous
    course's tee carries over **unvalidated** — by the one path the validation cannot see.
    The hole is deliberately *not* remembered: the map button opens the hole the card is on.
25. **`promptTokens`, wired for one arm only.** The prompt is *previous text*, so it is a
    language signal — a couple of hundred English golf words in front of a Korean phrase
    argues for the bug the user reported twice. Only names reach a decoder, and only on the
    on-demand re-transcribe. Measured: no language flipped, nothing looped — but the
    fixtures are `say` output and pronounce every name cleanly, so **the half it exists for
    is unmeasured** and one scoring word degraded on `ko2`. L5 decides it.
26. **The model cache was one slot** *(reported: "it looks like it's loading model again
    and again")*. `WhisperEngine` cached exactly one `(id, kit)`, so the live and final
    models evicted each other on every alternation — and a reload before a burst is the
    failure that file's own comment exists to forbid. It hid because the final model
    *defaults* to the live one, so nothing reloads until the feature is used as designed.
    Fixed: LRU of two, in-flight load dedupe (an actor suspends at every `await`, so two
    callers can both miss the cache), and both models preloaded at round start — live model
    first, and **never downloading**, because a course has no signal and a fetch belongs in
    the picker where it has a progress bar. User decisions on the two judgment calls: both
    at **round start** rather than app launch, and **both resident through a burst**.
    Measured in one process, `--model small,tiny,small`: 17.53 s → 3.95 s → **0.66 s**
    ("already resident").

### X29 — revert the simulate z-order, shot draw order, entry points, tee-less holes *(2026-08-30)*

As given:

    - === AttributeGraph: cycle detected through attribute 3160824 ===
    - revert simulate marker z-order changes you just made
    - for shot marker drawings
      - lines and line numbers first
      - dots next
      - shot #'s last
    - "Find a course" menu in
      - "Rounds"
        - Add Courses button next to + button
      - "New round" -> "Course"
        - Add "Find a course" instead of "Not listed"
    - For GPS hole view
      - if tees are not in the data, we're not showing anything right now.
        We should show the hole as long as any locatable data is there.
    - For "Find a course"
      - search is very slow. is this expected?

**Reverted, all of it** (asked, and the answer was "all of it"): `stackToken`,
`promotion`, `yieldingMarkers`, `MarkerDisplay.stoodDown`. The player and the flag are
plain annotations again, flag last. What the three failed attempts established is kept in
CLAUDE.md and is the reason not to try a fourth: **there is no z-order API for an
`Annotation`** anywhere in `_MapKit_SwiftUI`, MapKit stacks them as it likes, and none of
it touches the gesture — a pill carries its own `DragGesture` and takes the touch whatever
is painted over it.

**Draw order.** Vector does it in three passes (lines + numbers, dots, markers) rather than
one loop, so one player's line cannot cross another player's dots; satellite is declaration
order. This narrows the "markers are the lowest" rule rather than undoing it — the plan,
the rulers, the player and the flag still cover the markers, and `hit` still tests markers
last.

**Tee-less holes.** `Hole.geometry(tee:)` falls back to the centre line's ends, and
`hasGeometry` is now `geometry() != nil` so the two cannot disagree. Real: `golfctl course
osm` says "no tee found for hole(s) 1…9" at Corica, and that candidate went from **"no
geometry"** to **"912 m measured over 9"** with this change. Only when *nothing* on the
hole is placed — an unplaced tee beside a placed one still returns nil, because a tee must
never answer with a position that is not its own. `HoleGeometry.teeInferred` drives a `~`
in the hole box.

**Search speed — yes, expected, and now fixed.** Measured: the Overpass name query is a
regex over every golf course on the planet with no bounding box. `"Corica Park"` took
**12.5 s and returned 504** — Overpass timing itself out. Nominatim answered the same
question in **0.72 s** with the bounding box the feature query needs. `CourseOSM.sites`
now tries Nominatim first and keeps the Overpass query as the fallback, filtered to
`leisure=golf_course` so a bus stop named after the course cannot masquerade as one.
End to end through the CLI: **4.4 s**, down from a 12.5-second failure.

**Entry points.** A Courses button beside `+` on the rounds list — the first screen, and the
only one reachable on a fresh install with no round and no course — and "Find a course"
where "Not listed" used to be in New round. The free-text course name survives in the
empty-library branch.

**AttributeGraph.** Not reproducible here — no cycle appears in this simulator, and an
attribute id is not a symbol. Two known cycle *shapes* in this code were removed anyway,
both plausible causes and both cheap: measured lengths (`hudHeight`, `barHeight`,
`legendWidth`) that feed back into the layout they were taken from are now assigned only
when they move more than half a point; and `centerOn`, which was being written back to the
parent's `@State` from inside its own `onChange`, is cleared on the next turn instead —
that write was added to the satellite layer the same day the cycle was reported. **Whether
either was the one is unproven**; if it recurs, the log with the surrounding frames is what
would settle it.

### X28 — tracking, the accuracy ring, shot circles and the OSM finder *(2026-08-30)*

As given:

    - about location tracking. Now fast track when gps hole view is on screen, slow
      when not. need background tracking as well in slow mode.
    - "Go to my location" should really go to the current location of the phone, even
      though it's not near the course.
    - current gps location marker's outside circle should show current estimated radius.
    - when holed out, on player name box, up swipe increase score, down swipe decrease.
      Shows bounce or enlarging / shrink indicator, so that inadvertent change can be
      detected.
    - for shot markers
      - no club icon or name. Just show shot # in circle. Color is good enough to
        distinguish.
      - when inactive, opacity 80%
      - make distance between shots font bigger
    - For course OSM gps data, I want to search and download from the app.

Two questions were put back and answered: fast **does** mean the hole view (reversing the
2026-08-28 decision, not merely describing it), and the up/down swipe lives on the **score
cell** rather than the whole legend row.

**Tracking.** Fast is now asked for by *reason* — `{ holeView, marker }` — on both feeds,
because two independent booleans meant the last setter won: `handBackRadio` schedules an
unconditional drop to slow, and `MarkerSheet.leave` dropped outright, so a burst ending
over a hole view took that screen's fast tracking with it and the hole view never
re-asserts. A third bug was found by screenshot: `CourseView`'s `scenePhase` handler was an
unconditional `track(.slow)`, and `scenePhase` reaches `.active` *after* `onAppear` — so the
hole view asked for fast and one event later lost it. The Location button read **Slow** on
the screen that had just asked for Fast. Background in slow was already wired
(`allowsBackgroundLocationUpdates` + `UIBackgroundModes: location`); what is now explicit is
that **Always is requested from `CourseView.appear` and nowhere else**, because
`escalateAuthorization` returns early unless something asks and that guard is what stops a
launch throwing a dialog.

**Go to my location.** `HoleScreen` has driven `centerOn` since the button existed and only
`VectorHoleView` ever read it — on satellite the menu item did nothing at all, silently.
`SatelliteHoleView.centerOn` now moves the camera and leaves the zoom alone, to
`HoleReadout.playerAt` rather than `origin`, which is what makes it work in the case the
button exists for.

**The accuracy ring.** `LiveLocation.accuracy` published beside `here`, carried through
`HoleScreen` to a `MapCircle` on satellite and a projected circle on vector — metres, not
points, or it would be honest at one zoom and a lie at the other thirty-nine. **Nil while
simulating**, refused in three places: a hand-placed point has no accuracy.

**Score nudge.** Vertical swipe on the score cell, closed holes only, through `onHoleOut`
so it is one journal act that undoes like any other. Animated in the direction it went,
because the cell prints a score to par and a stray nudge turns `+1` into `+2` with nothing
else on screen changing.

**Shot markers.** A numbered circle in the player's colour and nothing else — no glyph, no
name. `MarkerDisplay.ghost` raised to 0.8, with `stoodDown` (0.35) split out so "this pill
got out of the way for the simulated marker" stays visible. Leg distances 10pt → 14pt.

**The OSM finder.** `CourseOSM` moved out of `Sources/golfctl` — an executable target
nothing can import — into a new **`GolfCourseOSM`** target, rather than putting `URLSession`
into `GolfCourse` and losing the property that makes `OSMCourse` testable with no network.
`Course.slug` moved into the package for the same reason: two importers, one id scheme.
`CourseFinder` searches by name or near the phone, lists the facilities, lists the courses
at the chosen site, and puts **the same three checks the CLI prints** in front of the Save
button — a wrong partition and a crossed green both look exactly like success. It never
merges (no card importer on the phone) and says out loud that OSM has no yardage.

**Verified.** `golfctl course osm --name "Corica Park" --dry-run` still runs end to end
against the live API through the moved target: 379 features, South Course 18 holes par 72,
stroke index a complete permutation, the three known tee anomalies reported. Both layers
screenshotted for the ring, the circles, the bigger labels and the legend chevrons, with the
Location button reading **Fast**.

**Three follow-ups found by review, all real.** The score bounce was a **no-op**:
setting and clearing `scoreBump` in one synchronous block is a single SwiftUI update
that diffs nil against nil, so nothing animated — and a second attempt, seeding a debug
value through `HoleScreen.init`, could not work either, because `init` runs on the first
body evaluation and the roster and tracks load afterwards. It is now a `Task { @MainActor }`
hop plus a render *override* (`HoleScreen.bump`, `-marker.bump up|down`), and the enlarged
cell has been screenshotted. The finder could **silently replace a course file**, losing
hand-placed coordinates — `CourseStore.save` is a replace and two Korean names slug to the
same ASCII — so it now refuses a colliding id and says so. And "Find a course…" was only on
the hole view, which is reached *through* a course: it is now also in `RoundView`'s course
section and `RoundScreen`'s Round menu, which is where an install with no courses can
actually get at it. Plus one line in `handOver`: `trackFast` is a no-op with no session, so
a round *started* while the hole view was open began at slow on the screen asking for fast.

**Not verified.** The finder's *results* have never been seen: the simulator here sits
behind a TLS-inspecting proxy and every Overpass request fails with `-1200`. That is what
produced the one real improvement found by looking — the raw `NSError` dump has become a
sentence — but the facility list, the candidate rows and the checks in front of Save are
drawn by code nobody has watched run. A phone on cellular is the test.

### X27 — the simulated marker's promotion, keyed on moments *(2026-08-29)*

As given:

    - simulation marker above other markers still doesn't work. let's re-add
      simulation marker any time there's marker change

Done. X26 had built exactly the re-add the user is asking for, and it had a hole in it:
`stackToken` hashed the committed `markers` and nothing else, so on the path the golfer is
actually on — open the hole, tap Simulate, look — **the token had never changed and the
re-add had never fired.** All MapKit ever had was declaration order. `simulating` is now
folded into the token, and a `promotion` counter is bumped at the end of a drag of the
simulated marker. Never on the live position: `onMovePlayer` reports per gesture callback.

**There is no annotation z-order API, and that is now checked rather than assumed.**
The iOS 26.5 `_MapKit_SwiftUI` interface has `mapOverlayLevel` for
`MapPolygon`/`MapPolyline` and nothing whatever for `Annotation`. Add-order is the entire
lever; the `ZStack` overlay was the alternative and it was reverted the same week because
outside the map's content the marker stops being glued to the ground.

**A bump at first layout was written and then measured away.** `DemoSeed` gained a log
twenty metres off hole 1's white tee, placed so its pill lands *on* the simulated marker —
before it, the two had never overlapped in this environment and the question could not be
looked at at all. With the overlap in frame the screenshot is identical with the
first-layout bump and without it, so MapKit already honours declaration order there and
the bump was doing nothing.

**The paint failure is not reproducible here, and asking settled what to do about it.**
In the simulator the simulated marker paints above an overlapping pill at launch, with the
promotion and without it. Asked which half was failing, the user said **both** — seen and
grabbed — and the second half was never a z-order question at all: a pill carries its own
`DragGesture` on a `contentShape`, so under `MarkerDisplay.on` it takes a touch aimed at
the simulated marker whatever MapKit painted on top.

So `SatelliteHoleView.yieldingMarkers` stands the overlapping pills down: while simulating,
any marker whose point *or pill centre* projects inside `HoleStyle.grabRadius` of the
simulated position is drawn ghosted and is not interactive. One rule for both halves, and
it is what `VectorHoleView.hit` already does by testing the simulated player first.
Ghosted rather than hidden — a marker that vanished under the finger reads as deleted.
Verified by screenshot with the new overlapping seed: the pill under the orange ring fades
while the pills elsewhere on the hole stay at full strength.

**Untested by a unit test**, because it depends on `MapProxy` projection, which does not
exist outside a rendered `Map`. Screenshot is the only review available, as it is for every
gesture on this screen.

### X26 — shot names, the closing leg, and the flag on top *(2026-08-29)*

As given:

    - shot numbering
      - marker shows shot # it's sitting on,
        - tee off: T
        - #1: 1
        - #2: 2
        - #3/holeout: 3
      - player name <shot count> shows
        - next shot when not holed out
          T -> 1 -> 2 -> ...
        - shows score when holed out
      - when holed out, line segment extends to the pin
      - "hole out" swipe means the last shot is in the hole, meaning, current shot # is the score

    - simulated position z position
      - when marker position is updated, added, deleted, moved, etc., simulated position is
        moved in z position so that it can be above any other marker. pin flag is still
        above simulated position

**A shot is named, not numbered — `ShotName`.** Stored 1, 2, 3, 4 displays T, 1, 2, 3, in
the two places a shot number is rendered (`HoleMarker.title`, the legend cell) and nowhere
else. **Storage is untouched on purpose**: `LogEntry.shot`, `LogEntry.nextShot`, the Marker
sheet's stepper, the `"7: 2 drive…"` log prefix and `RoundExport` are all 1-based, and
renumbering them to change what a pill reads would reach the extraction pass's input and
every round already on disk. **The cost is a visible mismatch, now in "Known gaps"**: the
sheet says shot 2 where the hole says `1`. Surfaced rather than absorbed — it is the user's
call whether to carry the naming into the sheet and the prefix.

**The score committed is the number already on screen, and this is the third revision of
that rule.** Yesterday's correction ("holing out is a shot") is not reversed — it has
*moved*. The holing-out stroke is now the last marker the golfer **filed**, which is what
`#3/holeout: 3` means: the shot that goes in is one you stood over and marked. So the swipe
adds nothing and `shotsTaken` is committed. The discriminator that settles it is that
label: it only exists if the hole-out shot is a marker that has been filed.
Consequence: **the `T` state cannot hole out** (nothing played, score zero is not a thing),
so the swipe is refused there and the chevron is not drawn — an affordance for a refused
gesture is worse than none. A hole in one costs one tap first: file the tee shot, the cell
reads `1`, swipe.

**The closing leg — `PlayerTrack.closingLeg(to:)`.** Solid, same weight as the rest of the
track, on both layers, to `pinAt` (today's flag, not the green centre). Two rules it obeys
that are older than it: its pin end stays out of `allPoints`, which feeds the framing fit —
harmless today because a pin sits on a green, which is exactly how a stray point gets in and
stays; and it carries a number only when `shots.last?.number == score`, the consecutive rule
arriving by a new road.
**It also uncovered a live bug.** Both renderers opened with `guard shots.count >= 2`, so a
one-shot player drew **no dot at all** — against the "every shot gets a dot, shot 1
included" comment four lines below it, and dating from when the tee was still prepended. The
floorless hole-out made that case reachable in earnest (a hole in one is one marker and a
closing leg, and the guard threw both away). Gone; each piece decides for itself. Seeded and
screenshotted, not reasoned about: dave now has one marker and a six on hole 1.

**The z-order.** On satellite, `stackToken` hashes the markers' ids and coordinates and keys
a one-element `ForEach` for the player and for the pin — `MapContent` has no `.id()`, so
that is the only way to tell MapKit "add this again". A marker added, moved, edited or
deleted tears both down and puts them back, player first and flag second. The token is the
**committed** `markers`, never `markerDrag`: an in-flight drag fires per callback and would
flicker the thing being dragged for the whole gesture. The flag moved from *first* in the
map content to **last**. On vector the same order is explicit — `drawPin` moved to the very
end, after `drawPlayer`. **`hit` is deliberately not reordered**: the flag is checked last
because the green is where a golfer taps to place a target.

**This is a hypothesis, not a contract.** This file already records that MapKit decides
annotation stacking for itself and that declaring something last is not a guarantee — the
`ZStack` overlay was tried for exactly that reason and reverted because it stopped tracking
the camera. The add-order property is the standard workaround; nobody here has watched it
work, because it needs a marker drag and a finger.

**`-marker.simulate YES` exists now.** The simulated marker had been changed twice on the
user's report without anyone here ever having seen one on screen. Screenshotted on both
layers with it on. What the screenshots show: pills reading `T · steve` / `1 · steve` /
`3 · steve`, min's pink track running into the flag with `96` on it, dave's blue track
running into the flag with **no** number (five strokes unlogged), the legend reading
`steve 4 ›` / `dave +1 ‹` / `min -2 ‹`, and Apple's Maps/Legal links clear of the legend.

Still untouched by a finger: the swipe itself, the marker drag that triggers the re-add,
and the simulated marker's grab handle.

### X25 — a cycle, a half-revert, and holing out *(2026-08-29)*

As given:

    - === AttributeGraph: cycle detected through attribute 3415352 ===
    - simulate position placing is messed up. revert it for now.
    - player name button on gps hole view
      - swiping shot # to right closes it, i.e. hole out, no more shot creation on
        the hole, i.e. click disabled. # shown is delta from par, e.g. -1, +0, +1,
        etc.

**I reverted the wrong half, and the user corrected it.** "Simulate position placing
is messed up. revert it for now" was read as the *seeding* — the tee if visible,
otherwise the middle of the map area — so the seeding went, and `GroundView.swift`,
both renderer bindings, both write sites and its two tests went with it as dead code.
The answer came back: "revert it was about **layering** it — current layering is
broken", and "not geo positioning: at tee when visible, center of the screen when tee
not visible <- **this is what I want**". Both are now where they should be: the
seeding and `GroundView` are restored, and the *layering* is reverted.

**Two things about one marker changed on the same day and only one of them was
wrong.** Where it is seeded and where it sits in the draw and hit order are separate
changes; they have separate invariants now so they cannot be collapsed again. The
lesson is narrower than "ask": a revert request that names a symptom ("placing is
messed up") does not name a change, and there were two candidates.

**The layering, and why the overlay lost.** X24 moved the simulated marker out of the
map's content into a `ZStack` overlay above it, positioned with `MapProxy.convert`,
so that it would win the touch outright — MapKit decides annotation stacking for
itself and a marker's grab strip is a large transparent rectangle carrying its own
gesture. Outside the map it stops being glued to the ground: it is re-positioned when
the body re-evaluates, not every frame of a pan. **A marker that lags the ground it
claims to be on is worse than one that is hard to pick up.** It is an `Annotation`
again, declared last. That is not a guarantee, which was the whole reason the overlay
was tried — so if the pick-up problem returns, the fix has to keep the annotation. The
vector layer never had this problem: `VectorHoleView.hit` tests the simulated player
first, which is a real ordering guarantee.

**The AttributeGraph cycle is unresolved, and the suspect is back.** The `GroundView`
binding is a child writing a parent `@Binding` from `onChange(of: viewport)`, where
`viewport` is that same parent's `@State`, plus `.onMapCameraChange` doing the same
on the satellite side — exactly the shape a cycle takes, and it is restored because
the user wants the behaviour it carries. It **does not reproduce here** on either
layer, in any launch, before or after. Nothing has been committed since the scaffold,
so there is no "before" build to reproduce it *on*. `legendWidth`, `barHeight` and
`hudHeight` are the same measure-then-write shape; MapKit emits these from inside
itself too. If the user sees it again, the next move is to make the writes
conditional — `if ground != new { ground = new }` — rather than to remove the feature
a second time.

**Holing out is having a score.** The alternative — a `holedOut` set in `HoleScreen`
— dies on relaunch, never reaches `ScorecardBand`, and makes the golfer write the
same number twice. A score is a journal act, so it undoes through `HistoryView` and
the card stays a view of it. `PlayerTrack.score` is the state; `onHoleOut(id,
strokes)` reports; **nil is reopen**, which `JournalReplay` already handles for
`strokes == nil`, so reopening needed no new act type.

**What is committed is `nextShot`** *("hole out means the next shot is hole out, i.e.
holing out is a shot")*. **Superseded the next day by X26 above** — the rule moved
rather than reversing, and `shotsTaken` is what is committed now; this paragraph is the
history, not the rule. The putt that goes in is a stroke like any other, so a player
showing 4 taken scores 5. `shotsTaken` was the first reading and it wrote scores one
low as a matter of routine — that number is the highest shot anybody *logged*, and a
putt is the least-logged shot in this product. The correction also removes the floor:
**zero taken holes out in 1**, which is a hole in one and has to be expressible.
Swipe-left reopen is the correction path for a swipe nobody meant.

**`+0`, literally.** The same cell shows a shot count and a score to par, and the
sign is the only thing separating "two shots so far" from "two over par". `E` and a
bare `0` both lose that.

`scoreCell` is one view classifying its own touch — `DragGesture(minimumDistance: 18)`
beside `onTapGesture` rather than a `Button` with a drag layered over it — and is
44×30 rather than the glyph's 26, because a gesture has to *start* inside the thing
it drags out of. One faint chevron points the way the finger goes; a swipe with no
affordance is the gesture that retired press-and-hold.

`CourseView.holeOut` appends through a `JSONLWriter` exactly like `movePin` — a
`RoundDocument` would replay the journal and rewrite `scorecard.json` once per swipe
— and reads `prevStrokes` **before** the optimistic local write, or the history says
the score never changed.

**Verified by screenshot, both layers.** `RenderHarness` now leaves hole 1 open for
the first player, deliberately: holed out *is* having a score, so the two states can
only be looked at side by side if one player on the hole carrying the seeded shots
has none yet. Hole 1 of Corica (par 5) reads `steve 4 ›`, `dave +1 ‹`, `min +0 ‹`,
with the closed plates in each player's colour. **The swipe itself is untouched by a
finger** — scripted taps do not exist here — and so is the simulated marker's
layering, since `simulating` still has no launch-argument route in.

**Also fixed while here, both found by review rather than by the screenshot:**
`PlayerTrack.toPar` returns nil for a par of **zero** — a delta measured against
nothing is an ordinary-looking wrong number, the `cardLength(from: nil)` shape — and
the cell is gated on `onAddShot != nil || onHoleOut != nil`, since it now closes the
hole as well as filing a shot. What that guard cannot catch is in Known gaps:
`OSMCourse` writes `par: 4` where the tag is missing, and `Hole.par` has no
discriminator, so a guessed par is indistinguishable from a surveyed one.

### X24 — five corrections *(2026-08-29)*

As given:

    - for player name icon's shot #, it should be shots taken, so it should start
      with 0, not 1.
    - marker label further down. it should be under the circle / dot. it's
      overlapping right now.
    - simulate position icon. I still can't pick and drag it when it's overlapped
      with markers.
    - for marker view toggle button, visible & inactive is the default
    - pinch zoom level is still the same. are we talking about the same thing? What
      I want is in gps hole view (satellite), I want to zoom in much more with pinch

**"Are we talking about the same thing?" — no, and the answer is embarrassing.**
X22's 40× is `HolePlane.View.zoomRange`, which is the **vector** layer's own
arithmetic. The satellite layer is a MapKit `Map` with its own camera and its own
floor, and nothing in that change went anywhere near it. The knob here is
`MapCameraBounds(minimumDistance:)`, now **12 metres** — roughly a ten-yard span,
which is what X21 asked for in the first place.
Verified by temporarily pinning `framedCamera` to a 12 m distance and
screenshotting: the camera goes there, the imagery is a blur past its tile detail,
and the vector overlays stay sharp on top of it. That is the honest limit and it is
also the argument for the two-layer design — the photograph runs out, the numbers do
not.

**The legend counts shots taken.** `PlayerTrack.shotsTaken` is `nextShot - 1`, not
`shots.count` — a shot with no position is not on the track and still counts, and
with a gap in the numbering the highest number anybody assigned is what "taken"
means. The button still files `nextShot`, so the number read and the number written
differ by one on purpose: the legend answers "where am I in this hole", not "what
will this button write".

**The label was still on the dot.** It sat `8` below the point and a shot's own
circle is 11 across, so it covered the bottom of the thing it is a claim about.
`HoleStyle.markerLabelGap` (14) is now the gap on both layers — on satellite it is a
second clear strip in the annotation's stack, with `markerAnchor` recomputed from
all three heights.

**The simulated position left the annotation stack.** Making it first in
`VectorHoleView.hit` fixed the vector layer and did nothing for satellite, where
every marker carries its own gesture on a large transparent grab strip and MapKit
decides annotation stacking for itself — declaring it last is not a guarantee. It is
now drawn as an overlay in the `ZStack` **above the whole map**, positioned through
`MapProxy.convert`, with the same 39-point handle everything draggable gets and the
same faint disc so the handle is findable. That placement cannot be walked back by
anything inside the map's content, which is what "top in display, drag and click
order" actually requires. A real fix stays an ordinary annotation: nothing drags it,
so nothing can take its touch.

**Ghost is the default.** `marker.markerDisplay` now defaults to `ghost` rather than
`on`.

One test added (396 total, 1 skipped). Screenshotted: the legend reading 4 / 1 / 0,
the labels clear of their dots, and the 12 m camera.

**Not verified:** the pinch itself, and dragging the simulated marker over a
marker — both gestures, and `simulating` is view state with no launch-argument route
in, so the overlay could not even be put on screen here.

### X23 — the clipboard, the icon and the third state *(2026-08-29)*

As given:

    - "copy" event and "copy whole round" should construct json with all the data,
      including location, player name, hole #, time, etc.
    - give me an icon with wedge club
    - marker view toggle button: tri state
      - visible and interactive: current on state
      - visible half transparent not-interactive: new state
      - hidden: current off state
    - simulate position initial position
      - if tee is visible, at the given tee
      - if not, the center of screen
    - marker display label under the point

Two judgment calls put to the user: the wedge is the **app icon** (the appiconset
was empty, so the home screen showed the placeholder), and the JSON **replaces** the
plain-text copy rather than sitting beside it.

**The clipboard.** `RoundExport` (package, beside `LogTranscript` and for the same
reason — the *selection* is the part that goes quietly wrong). A row carries id,
three forms of time (session clock, ISO, and the elapsed the screen shows), text,
position with accuracy, hole + card label + `holeSource`, player **id and resolved
name**, shot, locale, and what it supersedes; an event carries its kind, provenance,
club/strokes/lie, position, confidence and **its citations**, which are what make a
proposal checkable. The whole round carries the roster, the course and the events —
so the pin X19 asked to be exported comes with it for free. Sorted keys and pretty
printing, because a clipboard is diffed and a dictionary's order is not stable.
The hole filter follows the screen's rule: **a row with no hole belongs to every
hole**. Copy is now on the event rows too; it was only ever on logs.
`LogTranscript.text` stays — nothing calls it from the app any more, and it is the
readable form if a "copy as text" is ever wanted back.

**The icon** is `Tools/make-app-icon.swift`: drawn in CoreGraphics, three
appearances (light / dark / tinted greyscale), re-runnable and versioned rather than
drafted in an editor. Three things it learned by being looked at:

- Fitting the **whole club** puts a thin diagonal line across a large empty square
  — a white scratch at 60 points. The head is fitted instead and the shaft is
  deliberately cropped: the grooves and the leading edge are what say *wedge*, and
  they are what survive the shrink.
- Hosel and shaft are **one tapered filled shape**. Drawn as a wide stroke meeting a
  narrow one they leave a visible step, and at icon size a step in a silhouette
  reads as two objects.
- The fit is **measured** — the union of every path, padded by each stroke's own
  half-width — so changing the club cannot push it off the canvas.

**The third marker state.** `MarkerDisplay` (on / ghost / off), a **new**
`marker.markerDisplay` key rather than the old `marker.showMarkers` bool. Ghost is
the interesting one and it is not cosmetic: a hole can carry a dozen entries, each
with a handle, and every one is something a finger can pick up while reaching for a
target — off solves that by throwing the information away, ghost keeps it readable
and out of the way. Half transparent is the **only** signal the layer has stopped
responding, so the dimming is load-bearing, the same argument as the simulated
marker's orange dashes. The tracks dim with the markers they join. On the vector
layer that is a `GraphicsContext.opacity` and a branch in `hit`; on satellite it is
`.opacity` + `.allowsHitTesting(false)`, because each pill carries its own gesture.

**The label moved under the point, and the handle moved with it.** The rule was
never "down" — it is *away from the label*, so the thumb is never on top of the
thing being dragged. `markerGrabDrop` is now `markerGrabRise`, stacking on a clash
goes downward, the leader line runs up, and the satellite annotation's anchor is
recomputed from the seam. Flipping one and not the other reintroduces exactly the
bug the original request was about.

**The simulated position seeds from what is visible**: the tee if it is on screen,
otherwise the middle of the map area. It used to seed from the phone's own fix and
fall back to the tee — wrong in the case simulation exists for, where the fix is in
another county and the marker lands somewhere the hole on screen cannot show.
`GroundView` reports the visible ground **up** from whichever renderer is drawing —
a **quad, not a lat/lon box**, because the vector layer rotates the hole, and a box
would call a tee visible while it sat off the corner. Never re-derived in the
screen: a second copy of the transform is a second answer that can disagree with the
one on screen.

12 tests added (395 total, 1 skipped). Screenshotted on both layers: pills under
their points, ghosted markers and tracks, and the toggle's third state legible
against both the on and off plates.

**Not verified:** tapping the toggle through its three states, the copy buttons, and
the simulate seed — `simulating` is view state with no launch-argument route in, so
the seeding rule is tested through `GroundView` and reasoned about above it.

### X22 — the pinch that fought itself *(2026-08-29)*

As given:

    - zoom to 40x doesn't seem to work.
    - simulate position should be the top in terms of display, drag and click order.

**The ceiling was never what stopped it, and raising it to 40 could not have helped.**
The hole view carries one self-classifying `DragGesture(minimumDistance: 0)` and a
`MagnifyGesture` beside it as a `simultaneousGesture` — so a pinch drives **both**. Two
fingers spreading move the first one far past the 12-point slop, the drag classifies
itself as a pan, and the pan branch rebuilt the viewport from **`panStart.zoom`** — the
zoom captured *before* the pinch — on every callback. The two gestures then wrote
alternate frames and the zoom went nowhere. That is the whole bug, and it would have
looked identical at a ceiling of 8, 40 or 400.

Three changes, only one of which is the fix:

1. **`pinchBlockedDrag`** — a pinch takes the touch and the one-finger gesture stands
   down for the rest of it. It clears when the finger *lifts*, not when the pinch ends:
   a drag's translation is measured from where that drag began, so resuming a pan
   mid-touch would jump the hole by however far the fingers travelled while zooming.
   The blocked touch also ends with no tap, no move and no confirmation — a finger
   lifting off a zoom is not a tap on the hole.
2. **The pan branch keeps the current zoom**, never `panStart.zoom`. Belt: a pan must
   not be able to reinstate a zoom the user has since left behind.
3. **`HolePlane.zooming(to:about:)`** — the pinch now zooms **about the fingers**
   rather than about the centre of the fitted layout. At 40× that is not a nicety: the
   green being read ends up several screens away, which reads as the zoom not working
   just as convincingly as the fight did. Analytic, not a search — the projection is
   affine in `zoom`, so the pan that pins one point is one line of algebra — and it
   needed five values kept from the fit (`baseScale`, the two spans, `baseX`/`baseY`),
   because the arithmetic is not invertible from a finished plane.

**Measured, so the reason survives the factor:** at 40× on a 390-point screen the sample
hole reads a **5.5-yard** side span, so the ~10 yards X21 asked for lands around 20×.
`testFullZoomReadsAPuttingScale` asserts the yards rather than the zoom number — a later
change to the fit could satisfy the factor and quietly lose what it was for.

**The simulated position is picked up first.** It is drawn last on both layers, i.e. on
top, and on the vector layer it was tested *second*, after the targets — so a touch aimed
at the thing the eye can see could be taken by the ring underneath it. Same drawn-is-tested
rule `PlanLayout` and `markerHandle` follow. It costs nothing in a real round: the handle
only exists while `simulating`. The satellite layer already had it right by declaration
order, player annotation last.

Three tests added (385 total, 1 skipped): the anchored zoom holds a point across a
compounded 2× → 8× → 25× → 40× pinch at three anchors, the clamp pins rather than drifts
past the ceiling, and the putting-scale span.

**Not verified: the pinch itself.** Scripted multi-touch does not exist here, so the
arithmetic is tested and the gesture arbitration is reasoned about.

### X20–X21 — the legend becomes a control *(2026-08-28)*

Two batches, the second correcting the first. As given:

    - pin movement, don't log all. just keep the last position
    - marker edit dialog: need delete.
    - marker list in scorecard view: show player name
    - line segment between player shot markers:
      - line thickness flip / flops: check it out
      - distance between shot markers: no YD needed. it's sometimes not shown

    - distance on line segment between shot markers. you're doing the opposite of
      what I wanted. Show distance when shot #'s are consecutive, e.g. between #2
      and #3, and don't show otherwise, e.g. between #1 and #3, i.e. there's
      missing shots.
    - gps hole view
      - always show player names on the left side
        - move them to the bottom left
        - no left margin, want to use the full space
        - make the width 1/3 of the screen
        - don't dim the background when unselected
        - make font bigger and show current shot #
          - current shot # is right aligned, and if it's clicked create shot marker
            for the user at the current location or simulated position
      - remove location tracking state at the bottom left side.
    - gps hole view zoom
      - can it zoom further in …I want it to be around 10 yards, so that I can place
        putts better
    - pin flag: its end of flag pole is not aligned well with the position. Can you
      find the offset to the end of flag pole from the icon and align it.

**I had the distance rule backwards.** A leg from 2 to 3 *is* a shot and its length
is how far it went; a leg from 1 to 3 with no 2 measures nothing anybody played.
Inverted, and the tests inverted with it.

#### Built

- **A pin drag supersedes the last one**, so a hole keeps one `pin placed` line
  however many times the flag is nudged. Same mechanism as every other correction
  here: the old rows stay on disk and `Event.current` collapses the chain.
- **Delete in the marker dialog**, confirmed, writing the ordinary tombstone.
- **The log rows show the player** — `2 · steve`, the same reading the pill on the
  hole gives, resolved from the id so a rename does not strand it.
- **One line width for both layers** (`HoleStyle.shotLineWidth`).
- **The distance label: consecutive legs only, the number alone**, offset to the
  left of the line.
- **The legend is the control it was becoming**: always drawn, bottom left, a third
  of the width, hard against the edge, bigger names, no dimmed plate, and each row
  carries that player's **next shot number as a button** that files a shot where the
  golfer is standing.
- **The tracking chip is gone**, and so are `trackingChip`, `trackingText` and
  `HoleScreen.tracking`.
- **Zoom to 40×** — about 10 yards across an iPhone, which is a putt.
- **`flag.fill` anchored at its measured staff foot.**

#### What the obvious version gets wrong

- **"Keep the last position" is not "write less".** A pin *has* to be written on
  every adjustment or the last one is lost; what must not happen is a hundred rows
  in the list. Superseding gives both, and it is the mechanism already in the file.
- **The flip-flopping width was two literals.** 1.3 on vector and 1.6 on satellite —
  the same line changing weight when the layer changed, which is the one difference
  between the layers a golfer would read as meaning something. Measured a static
  vector render first: a steady 4 device pixels, so the *drawing* was never
  unstable. One constant now, and `HoleStyle.trackWidth` — a metres value nothing
  read — was deleted rather than left next to it, since the collision of the two
  names is what the rename exists to prevent.
- **The label was there; a pill was on top of it.** "Sometimes not shown" was the
  midpoint offset going *up*, which on a hole played up the screen is exactly where
  the next shot's caption sits. Perpendicular, and always the left side.
- **"Always show the names" is a roster question, not a track question.** The legend
  is now fed a `PlayerTrack` per player whether or not they have shots here — an
  empty one draws no line and adds no framing points, so it costs nothing.
- **A retired control's code is not retired with it.** The chip took `trackingText`
  and the `tracking` property with it; leaving them is the `onHoldGround` failure,
  where a dead callback ate taps for a day.
- **`.bottomLeading` is a corner of the box, not the end of the pole.** Measured off
  the rendered glyph — and nothing may pad the image afterwards, because the anchor
  is a fraction of that box.

#### Two caught in review

- **A one-tap write with no fix writes an invisible marker.** `addShot` would have
  filed a log with no coordinate — legal everywhere else, and useless here, because
  the only feedback this control has is the marker appearing. The number is still
  shown and stops being a button when there is no position.
- **It did not converge.** Written first, placed second is the rule; `MarkerSheet`
  does the second half itself precisely because `RoundScreen`'s task holds a
  different document. This now does too — the difference between a marker at ±30 m
  and one at ±5 m.

#### Verified, and not

**382 tests**, `swift build` and the iOS build clean. New: the inverted label rule
(consecutive, gapped, unnumbered, mixed) and the pin chain (one survivor, per-hole
chains independent, not model-visible, round-trips).

Screenshotted on both layers: the legend bottom-left at a third width with steve 5 /
dave 2 / min 1 — **min having no shots on the hole at all**, which is the "always"
case; no tracking chip; `192` on the 1→2 leg and nothing on 2→4; the log row reading
`2 · steve`; and the flag standing on a mid-fairway pin with the readout at **200 ·
YARDS TO PIN**. The flag foot was checked against a temporary cyan dot drawn at the
pin coordinate — reverted after.

Not verified: **tapping the shot number**, which is the one control here that writes
without a dialog; the delete button; the pin drag; and the 40× zoom, which needs a
pinch. Scripted taps and gestures do not exist in this environment.

*(Housekeeping: the simulator's seeded round now carries two hand-injected `pin`
events, so a screenshot session there opens on hole 1 with the flag out in the
fairway and the hole reading 200 yards. That is the injection, not a bug —
`-marker.seed YES` clears it.)*


### X19 — the flag, and what the lines say *(2026-08-28)*

Six items, and the first structural one in a while: a pin position is a new kind of
`Event`. As given:

    In the gps hole view
      - move player name buttons arranged starting from just below hole #, not from
        bottom
      - line between shot markers is too thick, make it much slimmer
        - show distance as well only if shots are skipped, e.g. if #2 is missing, #1
          and #3 will have line, but no distance. no background for this distance,
          and smaller font
      - pin location should be draggable, this one doesn't get saved into db. but
        will be saved as event, so that replay should be able to use it, and copy of
        events should include this info.
        - also for pin, pin location is not the center of the icon / image. the end
          of the flag stick should be at the position.
      - markers from other holes should not appear
      - when global marker display button is off, not just markers, but lines between
        markers should be hidden as well.

One question was put back: **the big number now measures to the pin** and the caption
reads `YARDS TO PIN`. Front and back stay measured against the green outline.

#### Built

- **The legend moved under the hole box.**
- **Slim lines**, 2.6 → 1.3 on vector and 3 → 1.6 on satellite.
- **A distance only on a leg that skips a shot** — no plate, 10-point face, in the
  player's colour.
- **The flag is draggable**, and a drag appends an `Event(kind: .pin)` to
  `events.jsonl`: hole, `lat`, `lon`, `.user` provenance. Nothing touches the course
  file.
- **`flag.fill` anchored at the foot of its staff** on the satellite layer and on the
  course overview; the vector layer drew it correctly already.
- **Markers filtered to the hole on screen**, with the nil-hole row still drawn on
  every hole.
- **The markers switch hides the lines too** — which also settles the disagreement
  between those two controls flagged the day before.

#### What the obvious version gets wrong

- **A pin in the course file would outlive the round.** It is cut fresh every
  morning; `Courses/<id>.json` is a fact about the course. An event is the right
  home and it is what makes replay and any events export carry it for free.
- **Bare coordinates cannot tell a gap from a step.** `PlayerTrack.shots` had to
  become `[Shot]` with a number on each, or "only when shots are skipped" is
  unimplementable — every leg looks alike. A caller with positions and no numbering
  labels *nothing*, which is the honest answer rather than a guess.
- **A centred `flag.fill` is not on its point.** The staff runs down the left edge,
  so the glyph's centre is half a green away from the hole — at every zoom, and it
  looked plausible the whole time.
- **`TO GREEN` over a number measured to the pin is the `defaultTee` failure in a
  different field**: a real number under a label naming something else. The caption
  switches with the measurement.
- **A row with no hole must still be drawn on every hole.** Filtering markers by
  `log.hole == here` alone would hide exactly the entries that could not be placed —
  the ones the round screen deliberately shows everywhere.
- **Drawing and persisting are not the same call.** The pin drag reported from
  `onChanged`, which draws beautifully and appends an event per gesture callback —
  about a hundred `pin placed` rows per adjustment, in the very stream the feature
  exists to fill. Held in `pinDrag` and written once on release, the split
  `markerDrag` already had.
- **`RoundDocument.append` is the wrong door for one coordinate**: it replays the
  journal and rewrites `scorecard.json` behind it. `JSONLWriter` is `O_APPEND` +
  `flock`, so a second writer on `events.jsonl` is safe by construction.

#### Verified, and not

**377 tests (8 new)**, `swift build` and the iOS build clean. The new tests cover the
two things a screenshot cannot check, because both fail as an ordinary-looking
number: which legs are labelled (consecutive, skipped, unnumbered, single-shot) and
what the approach measures to with and without a pin, including that front and back
do not move and that a target still owns the start of the leg.

Screenshotted, both layers, after **injecting a pin event into the seeded round's
`events.jsonl`** — the only way to exercise the read path without a finger: the flag
drawn at the injected point, **426 → 413**, and the caption reading `YARDS TO PIN`
with FRONT 408 and BACK 444 unchanged. Also visible: the legend under the hole box,
the slim line, `64 YD` on the 2→4 leg and nothing on 1→2, and hole 2's and 3's
captions gone from hole 1. `DemoSeed` now seeds a deliberate 2-then-4 gap for that
last check.

Also checked, because indexing by playing number is where an off-by-one would hide:
**hole 2 with a pin on hole 1 only** reverts to `YARDS TO GREEN` with the flag at the
green centre, draws hole 2's captions and not hole 1's, and shows no legend, there
being no numbered shots there.

Not verified: **dragging the pin** — the write path, and whether the flag is easy to
pick up without eating the taps that place a target on the green, which is the risk
the narrow handle is there to manage. Nor the satellite flag's new anchor, which sits
under the HUD in the framing this environment can produce. The skip label also
de-collides against nothing: `64 YD` sits partly over the `2 · steve` pill in the
render, where `PlanLayout`'s labels avoid each other and the target rings.


### X18 — the drag, and what moves with it *(2026-08-28)*

Three more on the marker layer. As given:

    - "Move this entry?" dialog should not cover too much of the screen. Make it
      smaller and down to the bottom
    - when moving marker with shot associated, line point and line should move along.
    - when dragging marker, currently dragged marker's center snaps to finger
      position, it should not. The whole point is I want to see the point while
      dragging without my finger covering it.

The third is X17's handle finished: reaching the grab area below the point is worth
nothing if the first drag event throws the offset away, which is what the satellite
layer was doing.

#### Built

- **The confirmation is a strip above the hole controls**, one row high, with Cancel
  and Move on it.
- **The track follows the marker being dragged** — the point and both legs either
  side of it, live, on both layers.
- **The satellite drag holds its grab offset**, the `DragAnchor` rule the vector
  layer, the player marker and the targets already followed.

#### What the obvious version gets wrong

- **`confirmationDialog` is not a smaller alert.** It was the obvious substitute and
  on iOS 26 it comes up as a centred card of much the same size, over the pill and
  the hole the question is about — screenshotted, and it is why this ended up as a
  view in the layout instead.
- **The track point has no id to match on.** `PlayerTrack.shots` is a list of bare
  coordinates — it is a view type, like `HoleMarker` — so the substitution is by
  coordinate, which works because both come from one `LogEntry` and the marker's
  *original* position is bit-for-bit the point to replace.
- **The in-flight track is not stored.** Same rule as the pill: until the row is
  written, nothing records the shot anywhere but where it started.

#### Two more, found by looking at the screenshots

- **The strip was asking about a position nothing on screen showed.** `onEnded`
  clears `markerDrag`, so pill and track snap back the instant the finger lifts —
  and the question then has no referent. Invisible while an alert covered the hole;
  making the confirmation small is what exposed it. The proposed point is now drawn
  as a **hollow ring on a dashed tether**, the focus ring's language, because
  nothing is written yet and a proposal that renders like a placed marker is the
  simulated-fix failure again.
- **The legend was covering Apple's "Map" and "Legal" links** on the satellite
  layer — visible in every satellite screenshot taken today. `bottomReserve` only
  cleared the *bar*. It was a covered link while the legend was a read-only strip;
  X17 made every row a button, so it had begun swallowing taps meant for the link
  too. The bottom HUD is now measured as one block and added to the reserve.
  Attribution is not optional, private use included.

#### Verified, and not

369 tests, `swift build` and the iOS build clean. Screenshotted: the strip at the
bottom with the hole and every pill still visible above it; the ghost ring and its
tether with Apple's logo and Legal link clear above the strip; and a **mid-drag
state**
— reached by temporarily defaulting `markerDrag` *and* neutering the `onChange` that
clears it, since scripted taps do not exist here — showing steve's shot 1 moved with
its dot and the line running diagonally to the new position. Both hacks reverted;
`markerDrag` and `pendingMove` are back to nil and the suite is green.

Not verified: the gestures. Whether the offset really keeps the pill clear of a
thumb, whether the strip is reachable without looking, and the satellite drag at all
— its offset is the same code the player marker has always used there, which is an
argument rather than a measurement.

### X17 — the legend, the chips and the handle *(2026-08-28)*

Three corrections to X16, same day. As given:

    - by vertical player name arrangement, I meant in gps hole main view. not in
      marker dialog. these buttons should be toggleable to show or hide all the
      markers of the player
    - in marker dialog
      - player names should be horrizontally arranged.
      - both player name and shot # are optional.
    - marker in gps hole view
      - drag handle should be extended toward down, so that I can see the marker
        itself while dragging with finger.

**The first is a misread of mine, corrected.** "Vertically arranged under the hole
number" was about the **legend on the hole view** — the strip of coloured names at the
bottom left — and I put it in the marker dialog instead, where it cost four rows for a
four-player roster. Both halves are now where they belong: the dialog's chips run
across, and the legend is a column.

#### Built

- **The legend is a column of switches.** Each name hides that player's markers *and*
  their track. Keyed on the **player id**: `colorIndex` is a roster position, and
  removing a player mid-round slides everyone after them down a slot, so an index
  would go on hiding "slot 1" under a new name. The ids are resolved to colours
  through `tracks` at the moment of use — `HoleMarker` is a view type and carries no
  session-format id. A hidden player is drawn switched off (hollow swatch, dimmed,
  struck through), never removed: the row *is* the control that brings them back.
  Not persisted — it is something a golfer does to read one hole.
- **The dialog's players are a horizontal row of chips**, scrollable, on their own
  line under hole and shot.
- **Both fields are optional.** The stepper runs 0…20 with 0 as `—`, so the
  auto-filled number can be taken back. **Asked and answered**: a number still needs a
  player, so the stepper stays disabled with nobody selected and clearing the player
  clears the number. `LogEntry.isShot` is unchanged. Both dialogs.
- **The marker handle reaches 34 points below its point.** The pill is drawn above
  the point on both layers, so a handle centred on it put a fingertip over the pill,
  its number, and where it was being dragged to.

#### What the obvious version gets wrong

- **The legend must read the unfiltered list.** Filtering `tracks` once and using it
  for both the renderers and the legend removes the row you just switched off — and
  with it the only way back. `visibleTracks`/`visibleMarkers` feed the renderers;
  the legend still reads `tracks`.
- **An entry belonging to nobody is not hidden by anybody's button.** Most markers
  have no player, so the filter passes a nil `colorIndex` through rather than
  treating it as unmatched.
- **Padding the satellite pill lifts the pill, it does not lower the handle.** The
  first version did that and the dot each pill is a claim about was stranded 34
  points below it — obvious the moment two markers are a few metres apart, invisible
  in the diff. The annotation is now a fixed-height pill above a transparent strip,
  anchored at the seam.
- **The drawn handle has to be the tested handle.** It was a circle in both places;
  it is now the same rounded rectangle in both, the rule `PlanLayout` and
  `measureLabelRects` already follow. On satellite the equivalent is padding *under*
  a `.bottom`-anchored annotation, plus `contentShape` — without the shape the empty
  part is not grabbable at all.
- **A stepper that bottoms out at 1 makes an auto-filled value compulsory.** X15
  asked for the auto-fill, not for it to be permanent.

#### Verified, and not

369 tests, `swift build` and the iOS build clean. Screenshotted: the legend as a
column with steve and dave; **the switched-off state** — reached by temporarily
defaulting `hiddenPlayers`, since scripted taps do not exist here — showing steve
struck through with his pills and his track gone while dave and the unattributed
entries stay; the downward handles visible as faint tongues under each point on
vector; **the satellite layer**, where each pill sits back on its own dot after the
anchor was reworked; and the dialog with the chips across, hole and shot above them,
Cancel and OK above the keyboard.

Not verified: **the taps themselves**. Whether a legend row is comfortable to hit,
whether the extended handle actually leaves the pill visible under a real thumb, and
whether stepping the shot down to `—` reads as clearing it rather than as a bug.


### X16 — the marker layer and the dialog it is made in *(2026-08-28)*

Two clusters, both corrections to X13–X15 shipped the same day: what the hole view
draws, and what the dialog that writes it looks like. As given:

    - markers in gps hole view
      - why a line to the first shot marker of a player. it should start from shot #1.
      - z position for markers should be the lowest, i.e. least priority
      - just created marker is not shown in gps hole view
      - player button should be togglelable.
      - player names are vertically aganged under hole number on the left side

    - marker dialog
      - no send button (up arrow)
      - OK with empty string should still create a marker
      - cancel and ok should be at the bottom
      - for "Type"
        - keyboard return button should be return, not up arrow.
        - audio input should be default

Two of them were put back as questions. **The player column is the layout that was
asked for**, not a complaint about the menu — hole number on the left, the roster
stacked under it, shot on the right. And **"audio input should be default" meant the
keyboard's own dictation**, not that Speak should override the remembered mode: iOS
exposes no way to raise the dictation panel, so the answer is that the field is
already focused on arrival and the microphone key is one tap away. **Closed with no
code**, deliberately recorded rather than dropped.

#### Built

- **A track starts at shot 1.** The tee used to be element 0, drawing a leg from the
  tee box to wherever the drive finished — the one leg on the hole nobody logged, in
  the same weight as the legs that were. A one-shot player now draws no line, which
  is the honest answer: a line needs two ends.
- **Markers are the bottom layer.** Vector already drew them under the plan and the
  rulers; they now sit under the pin, the tees and the tracks as well. On satellite
  they were declared *last* in the content builder, which is *top* — the opposite of
  the other layer.
- **A marker written here appears here.** `CourseView` read the logs once, on appear.
- **The player field toggles**, and clearing it clears the shot number.
- **OK and Cancel at the bottom of both dialogs**, above the keyboard.
- **The up-arrow is gone and Return is a return.** One way to commit a sentence,
  which is also what made the empty-text rule expressible.
- **OK with an empty box files a marker** — `"7: 2"` with nothing after it is a real
  entry, and it is exactly what the hole view draws.

#### What the obvious version gets wrong

- **`dropFirst()` outlived the tee it existed to skip.** Both renderers drew the shot
  dots as `shots.dropFirst()` — element 0 was the tee and the tee draws its own
  marker. Remove the prepend without touching that and **shot 1 loses its dot on both
  layers**, with the line correctly starting nowhere visible. Same class as the
  press-and-hold branch that ate taps for a day: a convention's *consumer* outliving
  the convention. Caught by rendering a two-shot track, not by reading the diff.
- **Reload-on-dismiss is only half of "the marker is not shown".** A log with no
  coordinate is not drawn at all, and `place()` converges in a detached task that
  routinely lands *after* the sheet has gone — so dismissal alone shows nothing in
  precisely the case the golfer waited for. `CourseView` now also listens to
  `LogStore.didAppend`, on the main run loop and comparing with
  `SessionFolder.isSame`; that exact comparison cost twenty-nine invisible logs on
  the round screen.
- **Declaration order is not z-order on MapKit.** Every `Annotation` draws above
  every `MapPolyline`/`MapPolygon` whatever the order, and the marker pill carries
  its own `DragGesture` on a `contentShape`, so it takes the touch outright. Moving
  `markerOverlays` first fixes what is *drawn* on top; it does not make markers last
  to be picked up the way `VectorHoleView.hit` does. Stated rather than claimed as
  parity.
- **"Empty" has to mean empty of *everything*.** An entry with no text, no hole and
  no player renders as a content-free black capsule that is still tappable and still
  in the extraction pass's input — so OK writes one only when it is *about* something,
  and never when the visit already wrote a phrase or a line.
- **The dismiss branch had to go with the button.** `send()`'s `if mode == .type {
  dismiss() }` was the up-arrow's rule; with the arrow gone its only caller is
  `finish()`, which dismisses anyway. A second dismiss path is how two buttons come
  to mean subtly different things.
- **The roster is now on the sheet twice** — the column is who the entry is *about*,
  the MARK pills are the survey button. Two unlabelled lists of the same three names
  read as one of them being a mistake, so the MARK row is labelled. Worth watching:
  if a fourth player squeezes the transcript pane out at `.medium`, that is the thing
  to resolve, not the column.

#### Two more, found by looking

Neither was asked for; both were in the way of checking what was.

- **The seeded logs were three kilometres from the course.** `DemoSeed` marched them
  north from 37.7402, -122.2661 while the round names Corica Park South, so every one
  was *placed* and none was on any hole — **the marker layer had never been seen in
  this environment at all.** They are now interpolated along each hole's own
  white-tee-to-green line, and three carry a player and a shot.
- **…which was hiding a real one: the hole view used the wrong roster.**
  `CourseView` matched a log's `player` against `RoundViewModel.players`, the *setup
  screen's* list, which is empty whenever the hole view was reached on a round that
  is not recording — most of the time. So a shot pill lost its name **and its
  colour**, and `tracks(for:)` returned nothing: **the connecting line X13 asked for
  had never once been drawn.** It now replays the round's journal, the same rule
  `MarkerSheet.roster` follows.

#### Verified, and not

369 tests, `swift build` and the iOS build clean. **Rendered** through `ImageRenderer`:
a two-shot track running 1→2 with a dot on *both*, no leg from the tee, pills drawn
under everything. **Screenshotted on both layers** — vector and satellite, hole 1 of
Corica with steve's two shots joined 1→2 in his colour, dave's single shot drawing a
dot and no line, and the pills under the hole card and under the track dots. The
satellite pill had to be re-anchored `.bottom` for that last part: centred, it covered
the point it is a claim about, which only showed up once markers went underneath. **Screenshotted** in the simulator, Speak and Type: hole top-left,
the roster stacked under it, shot top-right, Cancel and OK at the bottom — above the
keyboard in Type, where the return key now reads `↵` and no up-arrow remains. At
`.medium` with three players everything still fits.

Not verified, and it is the same list as always: every one of these is a gesture.
Toggling a player off, the empty-OK path, dragging a marker now that it is underneath
the rest, and **whether a just-created marker actually appears** — which is the one
worth doing first, since it is a bug report rather than a preference and the fix has
two halves that fire in different orders depending on whether the fix was warm.


### X12–X15 — shots, and the hole that stopped moving *(2026-08-28)*

The first four items that are not corrections: an entry can now say **whose shot it
is and which one**, which is the first structured thing this app has ever recorded
about a round without a model. As given:

    ### X12: simulated position
      - promote the button to gps hole view, under measurement line icon from menu

    ### X13: marker on gps hole view
      - no need to show keyboard or record icon
      - if has shot #, show golf club or ball icon, shot # and player name
        - connect the player's shots with line
      - clicking on marker shows marker dialog, with text editable upon clicking
      - looked like associated hole # gets flipped sometimes. check this out.

    ### X14: marker's hole
      - it should be the current hole

    ### X15: marker dialog upon creation
      - hole #, player, shot # should be selectable
        - hole # pre-assigned by the current hole
        - instead of "Done", have "Ok" and "Cancel". "Ok" creates a marker with "Hole#: <seq>"
        - if player is selected, shot # gets auto filled based on the previous # in the same hole.
        - creation dialog and edit dialog when clicked upon is slightly different as text edit is upon clicking for edit dialog, whereis for creation it's default. Give me good arragement on this.

**Answers taken.** The created entry's text carries the hole and shot as a **prefix**
— `"7: 2 drive into the left bunker"` — as well as being stored in fields. And
**Cancel deletes what the burst wrote**, spoken rows included.

#### Built

- **X12.** Simulate position is a tool-column button under the ruler, **moved out of
  the pin menu rather than added beside it**. The re-seed-on-switch-on rule moved
  with it, which is the part that would have broken silently. A card-only hole loses
  the toggle, which is correct: simulation seeds from a tee and is measured against
  geometry, and that hole has neither.
- **X13.** No capture icon — that said which recogniser wrote the row, which is a
  fact about the app. An entry with a player and a number now reads
  `[golfer] 2 · steve` in that player's colour; everything else is its sentence, no
  icon. A player's shots are joined by a line (`PlayerTrack`, which both renderers
  already drew), **filtered to the hole on screen**. A tap opens the entry's dialog.
- **X14.** A marker is filed on the hole being looked at.
- **X15.** The sheet gained hole / player / shot above both modes, OK and Cancel
  instead of Done, and shot auto-fill from the player's last on that hole.

#### The hole flip, diagnosed

*"looked like associated hole # gets flipped sometimes"* is real and it was
`LogPlacement.converge`: it derives the hole from the fix and appends a superseding
row, and `Course.nearestHole` between two fairways forty metres apart is a coin toss.
So a hole set by hand was quietly replaced by a guess about fifteen seconds later.

X14 alone does **not** fix that — it would just have given convergence something
better to overwrite. The fix is `LogEntry.HoleSource`: `.fix` is a proposal, `.user`
is a person's answer, and **`LogEntry.placed` refuses to recompute a `.user` hole**.
It lives there rather than in the convergence code so it holds for every caller. Nil
decodes as `.fix`, so every row already on disk keeps the only meaning it ever had.

This is also the discriminator the old invariant demanded. CLAUDE.md said a log must
carry no hole from the screen "and needs a discriminator on `LogEntry` first" — that
sentence is now spent, and both bullets are struck through in place rather than
deleted, because the reasoning behind them is what the discriminator preserves.

#### Four more caught in review

- **A spoken burst was not getting the prefix.** `send()` prefixed the typed text and
  the spoken path stamped only the fields, so one entry would have been recorded two
  different ways depending on which recogniser happened to be running — and the text
  is what the extraction pass reads. The stamp prefixes too.
- **Changing the hole did not re-derive the shot number.** Pick a player on 7, then
  correct the hole to 8, and 7's number was filed on 8.
- **Clearing the player in the edit dialog left the number behind.** The stepper is
  only *disabled* without a player, so OK would have written a number with nobody
  attached — the thing `isShot` requiring both exists to prevent.
- **`written` cannot be reached by Cancel**, because `send()` dismisses in Type mode.
  That is correct rather than a bug — a typed entry is one deliberate sentence and is
  committed when sent; what Cancel takes back is what the *microphone* wrote, which
  the golfer never approved sentence by sentence. Said out loud in the code, because
  the array read as though it covered both.

#### Two traps worth naming

- **`PlayerTrack` feeds the framing fit.** `allPoints` goes into
  `VectorHoleView.extraPoints`, so an unfiltered track would put a shot logged on the
  ninth into the fit for the first and shrink the hole to a dot. Filtered to the hole
  on screen. Same rule three separate bugs have already come from.
- **Shot auto-fill counts the *current* rows.** A burst grows by superseding and an
  edit is a new row, so counting raw rows would jump the number every time somebody
  fixed a typo.

#### Verified, and not

369 tests (10 new), `swift build` and the iOS build clean. Rendered through
`ImageRenderer`: two players' shots on hole 1 of Corica with icon, number, name and a
connecting line each in the player's colour, and a plain entry beside them with no
icon. Screenshotted in the simulator: the tool column with the simulate button in it.

**Not verified: all of it is a gesture or a dialog.** Tapping a marker to open it,
the hole / player / shot pickers, shot auto-fill on a real roster, OK, Cancel deleting
a burst's rows, and tap-to-edit in the edit dialog. **The flip fix in particular is
argued and tested but has never been watched not-happening on a phone**, which is
where it was seen.

### X8–X11 — the hole view, second pass *(2026-08-28)*

Five of the six items are corrections to X3–X7, shipped the same day. As given:

    ### X8: course view
      - meant gps satellite view with normal zoom, pan, etc. action

    ### X9: marker view on gps hole view
      - move button up below "edit this hole" button
      - on by default
      - marker drag: warning is after drag is done. for now it's before.
        - click z hierarchy: should be the last to get picked up
      - marker display: showing two items now. One item with abbreviated string

    ### X10: measuring line segment
      - assign new colors, but set, to a new line segment
      - cannot drag by distance box right now

    ### X11: "SIMULATED POSION - drag it. MARK is off." is unnecessary.

#### Built

- **X8 — the course view is a map now.** `CourseOverview` was a fixed vector
  `Canvas` with no gestures at all; it is a MapKit `Map` on `.imagery` with pan,
  zoom and rotate. **The vector-only argument was mine and the user overruled it**,
  so CLAUDE.md's bullet is struck through rather than deleted — what survives is the
  coverage half: lines, tees, pins and numbers are all overlays drawn from the course
  file, so a course with no signal loses the photograph and keeps every hole, every
  number and every tap target. The number is still the control.
- **X9 — markers.** Button moved to the top of the tool column, directly under the
  pin menu; on by default and remembered (`marker.showMarkers`). Icon and text are
  **one pill** instead of a chip with a caption under it, stacked upward off a leader
  when two land on each other, and drawn **under** the plan and the rulers — a
  yardage about to be clubbed off must not be covered by a caption of something said
  an hour ago. The confirmation now fires on **release** and only if the finger
  actually moved.
- **X10 — rulers.** Each carries its own `colorIndex` into a four-colour set of its
  own (not `playerColors`, or a ruler reads as a player's track), carried on the
  segment so dismissing one does not repaint the others. The distance box is now the
  drag handle for the whole ruler as well as its dismiss control —
  `MeasureSegment.center(on:)`, a rigid translation, which is why the documented "a
  distance box is a bad handle" objection does not apply here: the length never
  changes, so neither does the number or the box's width.
- **X11 — the banner is gone.** Half of it was stale the moment MARK left the hole
  view. Recorded as a consequence, not just a deletion: the orange dashed golfer
  glyph is now the **only** on-screen signal that a position is hand-placed, so it is
  not decoration and must not be tidied away later.

#### Two things found by building it

- **"Should be the last to get picked up" was not a z-order problem.** Markers were
  already checked last in `hit()`. What made them feel greedy is that each carried a
  39-point invisible handle — a dozen of those blanket a hole — **and the tap they
  caught was discarded**: `case .player, .marker: break` placed no target and
  dismissed nothing, which is indistinguishable from a frozen screen. Fixed at both
  ends: a handle the size of what is drawn, and a tap on a marker falls through to
  the ground. Only a *drag* starting on one moves it.
- **A gesture retired in X6 was still eating taps.** `onHoldGround` outlived
  press-and-hold on both renderers with nothing passing it, so
  `held ? onHoldGround?(c) : onTapGround?(c)` meant **a deliberate slow tap on open
  ground placed nothing at all**, and `SatelliteHoleView.onLongPressGesture`
  swallowed every long press to call a nil closure. Both deleted, along with
  `metresPerPoint`, which only the long press reached. A retired gesture is not
  retired until the branch that reads it is gone.

#### Three more caught in review, before any of it was called done

- **A tap could dismiss the ruler it had just dragged.** The satellite label carried
  an `onTapGesture` *and* a `DragGesture(minimumDistance: 10)`; a slow short drag can
  activate the drag and still deliver the tap on release. One gesture now, deciding
  from the translation on release — the shape the vector layer already used, and the
  two layers must not differ in what a finger does.
- **An interrupted drag left a pill parked where no row said it was.** `onEnded` does
  not arrive if a sheet comes up or the log list refreshes mid-gesture, so the marker
  stayed at the dragged coordinate looking exactly like a move that had succeeded.
  Both layers clear the in-flight position when `markers` changes.
- **The stacking loop had no bound.** The pill's width is an estimate, and an
  underestimate on a busy green would chain rects to the top of the display with
  leader lines trailing them. Capped at four nudges.

#### Verified, and not

359 tests (5 new), `swift build` and the iOS build clean. Screenshotted in the
simulator: **all 18 holes of Corica on the imagery** with tappable numbers and
Apple's logo and Legal link clear, and — on a **freshly installed container**, which
is the only way that claim means anything — the tool column with markers at the top
and lit, confirming "on by default" is the default and not a value left in
`UserDefaults` by an earlier launch. A fresh container has no `Courses/`, so the
course file has to be copied into `Documents/Courses` before the hole view has
anything to draw.
The marker pills, the stacking, the leader line and the two ruler colours were
checked by rendering `VectorHoleView` through `ImageRenderer` — **the vector layer
renders fine**, unlike the `Menu` and `List` screens, which is worth remembering the
next time something on the hole needs looking at. Two things that changed as a
direct result: markers moved under the plan labels, and the pills gained stacking.

**Not verified: every gesture, again.** Dragging a ruler by its box, dragging a
marker and the confirm after it, the fall-through tap, pan and zoom on the course
view, tapping a hole number. `-marker.course YES` is the new `DemoSeed` key that
makes the course view reachable at all here.

### X3–X7 — the hole view *(2026-08-28)*

As given:

    ### X3: simulated position
      - when simulated position is on, use the location for marker

    ### X4: whole course view
      - provide a whole course view with tees and pins, and hole number at the center of a hole
      - should be able to go to a hole by clicking hole number
      - add "Course View" (or better or common name) to "Edit this hole" menu as the first item

    ### X5: "Edit this hole" menu flickering
      - something keeps updating this menu. when it's up, do not refresh

    ### X6: buttons below "edit this hole" button on gps view
      - 1st target: on / off
        - tap on golf course or this button creates a 1st target
        - tap again or this button dismisses
        - location when this button is clicked is
          - 250 yards from tee to 1) fairway marker if exists for 2) to the center of the green for par 4 or par 5. For par 3, it's 2/3 position from tee to the center of green
      - 2nd target: on / off
        - disabled when there's no 1st target
        - when tapped, create the second target on 2/3 distance from the first target to the center of the green
        - current tap and hold method is no more needed
      - distance measurement
        - when clicked, place two points (or line segment) horizontally with the first target as center, if no first target, where you would put the 1st target put
        - points should be draggable with draggable area extended just like targets
        - show distance between two points in the middle of the line
        - distance box: draggable, tap would dismiss
        - clicking again create a new line segment

    ### X7: markers in gps hole view
      - show markers in gps hole view with icon and abbreviated string
      - should be draggble, once dragging done, confirm if it's what user wants
      - add marker view toggle button under 2nd target button

**Answers taken:** X7's "markers" are **log entries**, not MARK survey points — so
nothing here touches `marks.jsonl` and the ground-truth question does not arise. A
dragged marker's moved value wins, which for a log is ordinary: it is written as a
superseding row and the original stays on disk.

**One assumption, stated because the text names something that does not exist.** There
is no fairway-marker concept in the course model. `Hole.line` is the centre line OSM
supplies, which is what a fairway marker approximates, so "250 yards … to fairway
marker if exists" is read as **250 yards measured along the playing line**, falling
back to a straight run at the green when a hole has no line.

#### Built

- **X3.** `HoleScreen.onPosition` reports the **simulated** point only — never the
  real one, so the caller cannot mistake a placement for a measurement. It overrides
  the stabilised fix in `MarkerSheet` and skips `settle` entirely: asking the radio
  harder is spending power to be told the wrong answer more precisely.
- **X4.** `CourseOverview` — every placed hole in one frame, north up, tees and pins
  drawn, the number at the middle of each hole's **own line** so a dogleg puts it on
  the fairway. The number is the button. First item in the pin menu. Verified by
  render against all 18 of Corica Park South.
- **X5.** `HoleSettingsMenu` split out and `.equatable()`. The cause was `TrackingState`
  changing on every fix and on a 5 s ticker, redrawing the subtree the `Menu` lives in.
- **X6.** A tool column under the pin menu: target 1, target 2 (disabled with no
  first), ruler, markers. `HoleGeometry.suggestedTarget` / `.towardGreen` /
  `.point(along:)` are the geometry, with 12 tests. **Press-and-hold is retired** —
  which also returns the hole view to one drag gesture.
- **X7.** `HoleMarker` + a marker layer on **both** renderers, draggable, with a
  confirm before the superseding row is written.

**Both layers, deliberately.** The tools were vector-only at first, which put four
buttons on the satellite layer that did nothing — the exact failure this codebase
already has a rule about.

#### Verified, and not

354 tests (12 new, all pure geometry and text), `swift build` and the iOS build clean.
Screenshotted: the tool column on the hole view with target 2 correctly disabled; the
whole-course view rendered from the real Corica file.

**Not verified: every one of these is a gesture.** Placing by button, dragging a ruler
end, dragging a marker, the confirm, tapping a hole number, and whether the menu still
flickers — all reasoned about, none touched by a finger. **X5 in particular is a fix
for a symptom that can only be seen by hand**, so it is the first thing to check.

### X1 / X2 — the Marker bar *(2026-08-28)*

Three buttons at the bottom of **both** the scorecard and the hole view. As given:

    X1  - rid of record or input text box
        - "Marker" button, at the bottom of scorecard and hole view
          - opens either current recording and live transcription mode,
            or input box with iphone's keyboard with recording turned on
          - start fast location tracking, save the location when stabilized
          - go back to slow tracking once done
        - "In Play" button in scorecard and hole view
        - "Location" button in scorecard and hole view
    X2  - location tracking: 1) off or on
          - on means slow tracking even in background

**Answers taken 2026-08-28:** *In Play* means whether the round is in progress — renamed
**Round**, so the three read as nouns (Marker · Round · Location) and "round" stays the
app's one word for it. *Location* is the tracking control **and** its status: off/on, plus
slow / fast / stabilised and the accuracy range. *X2 is only the radio* — "not about
tracing or journaling" — so it writes no new file. **X1's Location button and X2 turned
out to be one feature**, not two. X2 is truncated: it has a "1)" and no 2).

#### What was already true, and what the text did not mention

- **X1's location clause needed no work.** `StableLocation` makes its own
  `CLLocationManager` at `kCLLocationAccuracyBest` whatever mode `LocationRecorder` is in,
  so "fast, save when stabilised, back to slow" is what *every* log already did, typed as
  well as spoken. `trackFast` governs `gps.jsonl` density between logs and nothing else.
- **Deleting the bottom band took two things with it that X1 does not mention**, and both
  needed a home first: the record button also carried *reopen a finished round*
  (`RoundSession.resume()`), and MARK — whose output is `GolfEval`'s answer key — lived in
  that band. Both moved into the Marker sheet.

#### Built

- **`HoleScreen.bottomBar`, a `@ViewBuilder` slot.** The three buttons cannot live inside
  `HoleScreen`: it is in `GolfMap`, and Marker needs `RoundViewModel`, `LiveTranscript`
  and `LogStore` — a package that draws a hole must not import the capture stack. Same
  shape as `focus` and `simulating`, one step further. `MarkerBar` is **one app-target
  view drawn on both screens**, so they cannot drift; buttons only, so nothing joins
  `VectorHoleView.touch`'s arbitration.
- **The reserve is measured, not a constant.** `HoleScreen` passes `110 + barHeight` as
  `SatelliteHoleView.bottomReserve`. A number written by hand goes stale the first time
  the bar gains a row, and the symptom is a covered Apple logo and Legal link — a licence
  problem, not a visual one.
- **The Marker sheet is one surface.** X1's "either … or" reads as one sheet that opens a
  burst *and* offers the keyboard, since "recording turned on" applies to the keyboard
  branch too; the "or" is only whether the golfer reaches for the keys. Done **or** a
  swipe ends the burst — a live microphone behind a dismissed screen is the failure the
  record button's own rule was written against.
- **A log written from the hole view carries no hole**, deliberately. `LogEntry.hole`
  means "nearest hole to a measured fix"; stamping whichever hole is on screen would put a
  second, unmeasured meaning in one field — the `defaultTee` trap. `LogPlacement` fills it
  in from the fix afterwards.
- **`LiveLocation` moved to the app and starts at slow on launch.** It never prompts
  there. `marker.location.enabled` defaults on; off stops the radio outright and a log
  written then is simply unplaced, which `LogEntry.hasPosition` already treats as an
  answer.
- **`-marker.map`** pushes straight to the hole view. Same argument the seed file already
  makes for `-marker.sheet`: that screen is reachable only by tapping the map button, so
  half of what X1 asked for would otherwise ship unlooked-at. `-marker.sheet marker` opens
  the sheet.

#### Six things found by building it, not by reading

Two would have shipped, and both were mine:

- **It would have thrown a location dialog on launch.** Assigning
  `CLLocationManager.delegate` fires `locationManagerDidChangeAuthorization` immediately,
  so `escalateAuthorization()` must return early unless the user has actually asked. That
  rule is already in CLAUDE.md for `LocationPermissionMonitor` and it came back **within
  an hour of being read** — the prompt looks like it came from the toggle either way.
- **The Location button read "Off" while the preference said on.** `LiveLocation` was a
  `@StateObject` inside `CourseView`, so the feed existed only while the course screen
  did — which cannot be "slow tracking even in the background". Found by screenshot.

Two were drift between the two screens, which is the thing the shared bar exists to
prevent:

- **Marker meant two different things under one label.** `CourseView` read the *recording*
  round from `RoundViewModel`, which a finished round does not have — so on the scorecard
  Marker reopened it and on the hole view it did nothing at all, silently. The round id is
  passed in now. **Found by review, not by screenshot:** both screens render identically
  in the state that hides it.
- **The Round button read "No round" through a live round on the hole view**, because
  state and action were conflated and that screen passes no `onEndRound`. Whether a round
  is running is what the button *reports*; ending one is what it does only where that is
  offered.

Two were the compiler:

- **`HoleScreen` had to become generic over the bar**, with the no-bar initialiser in
  `extension HoleScreen where Bar == EmptyView` — a **default argument does not take part
  in generic inference**, so every existing call site would have failed to resolve `Bar`.
- **`CourseView` hit the type-checker twice.** The `HoleScreen` call already needed
  pre-typed locals in declaration order and the bar tipped it over; one more `.sheet` on
  `body` then tipped `body` over too. `holeScreen(_:)` and `MarkerSheetPresenter` are the
  fixes — structural, not a reordering of arguments.

One design change made unprompted while looking at it: **ending a round is confirmed
now.** The old control said "End round" in red; this one says "Round" in green, because
its first job is to report that a round *is* running — and a button whose label is a noun
must not do something irreversible-looking on one tap.

#### Second pass, same day — six corrections from the user

1. **Item 17, closed from the other end.** The fix was not to make the hole view
   speed the *recorded* track up as well: "in gps hole view, location tracking is
   fast always, I want it to be slow, and becomes fast when marker is up". A hole
   view is open for most of a round and reading a yardage does not need a fix a
   second; saying what just happened does. `MarkerSheet` now escalates **both** feeds
   on the way in and drops them on the way out — except after a burst, where
   `handBackRadio` already owns the release.
2. **"Close out this round" left the bottom band** — moved to the ••• menu, **not
   deleted**. It is the only crash-recovery control there is (the rounds list has
   none), so deleting it would strand any round the app was killed during.
3. **Round became a toggle.** It was a report with an action bolted to one of its two
   states, so a finished round left a dead label — "when it's off, no way to turn it
   on now". On ends, off reopens. It still never *creates* a round.
4. **No MARK on the hole view.** A red bar across the bottom, a second capture control
   beside Marker doing nearly the same job — and MARK's ground-truth rule then had to
   be enforced in two places. `onMark: nil` puts the course name back in that slot.
5. **The Marker sheet is Speak *or* Type.** This corrects the first version and my
   reading of X1: "it's either our own recording or iphone input text view. Not both."
   They are two **recognizers**, so running both is two things listening to one voice
   and two rows for one sentence; switching to Type closes the burst. Speak is the
   default.
6. **The hole view tracks slow**, per (1).

Then two more:

7. **The Speak/Type choice is remembered** (`marker.input.mode`) — a habit, not a
   per-sentence decision.
8. **A typed entry is placed like a spoken one.** It always could be —
   `LogPlacement.unplaced` never filtered on `source` — but the convergence is driven
   by `RoundScreen`'s `.task(id:)`, and the sheet also opens over the hole view, where
   that screen is a frame down holding a *different* `RoundDocument`. The sheet now
   converges what it wrote; `RoundScreen` stays the backstop, and both running is safe
   because `attempted` is a reservation. Found on the way: `LogStore` compared session
   folders with `==` — the documented trailing-slash trap, harmless under `O_APPEND`
   but newly reachable now that two documents write one round.
9. **Fast tracking did not reliably reset to slow** *(reported)*. Two leaks, both
   introduced with the bar. `startListening` cancels any pending hand-back **before**
   starting the recognizer and returns early when it will not start — the simulator's
   missing speech model is the ordinary case — so `stopListening` had nothing to stop
   and nothing ever asked for slow again. And `LiveLocation.standDown(false)` replayed
   `wanted`, which the Marker sheet had set to `.fast` *during* a round, when that feed
   is stood down — so the radio went to Best for the rest of the app's life the moment
   a round ended. Both routes now guarantee a hand-back, and standing back up resumes
   at slow.
10. **Type is the whole content area, focused.** It was a caption, a spacer, the MARK
    row and a one-line field pinned to the bottom, so raising the keyboard meant
    hitting a small target on a screen whose only purpose is typing. Speak stays the
    default when nothing is remembered.
11. **Fast tracking still ran after the sheet was done** *(reported again)*, and the
    fix was to change what ends it rather than to patch the timer. It now ends at a
    **stable fix** — `StableLocation.best` returns the moment `TrackingState` locks —
    and that fix is final for every log the sheet writes. Holding fast for the life of
    the sheet meant two minutes of Best for a golfer describing a hole, plus twenty
    seconds more.
12. **Sending in Type mode ends the marker.** One deliberate sentence, one dismissal.
    Speak has no equivalent boundary and stays open until Done.
13. **The tracking indicator was lying, not the tracker** *(reported)*.
    `LocationRecorder` starts slow and only a burst sets fast — correct all along —
    but `LiveLocation.adopt` hardcoded `.fast`, so every adopted fix stamped Fast on
    the display. It now takes the recorder's real mode. Found with it: `adopt` and
    `standDown` were driven by `CourseView`, so a round spent entirely on the
    scorecard never stood the second feed down and ran **two radios all afternoon**.
    Both moved to `MarkerApp`.
14. **A typed entry never showed `no hole`** *(reported)*, because the typed path
    stamped the hole the card was showing — since the old input box, and exactly what
    CLAUDE.md already forbade for a spoken log. Typed logs now carry no hole and
    `LogPlacement` derives it from the fix, the same as spoken.
15. **A row shows its hole number.** `no hole` was the only thing either row type
    ever said about the field, so it read as a fault rather than as one of two
    answers. Both rows now carry `Hole.ref` when there is one — the card's own
    spelling, so a Korean 27 reads "황룡/3" — and fall back to the playing index when
    the round has no course file.

#### Verified, and not

**By simulator screenshot:** the bar on the scorecard, on a live round
(Marker · **Round** · Slow), on the hole view over satellite imagery with Apple's logo
and Legal link clear of it and **no MARK bar** — the course name is back in that slot —
with the tracking chip reading `Slow · Stabilising ±5yd`; and the sheet itself, showing
the **Speak / Type** switch with Speak listening, the MARK buttons, and no text field
while Speak is selected. 342 tests green, `swift build` and the iOS build clean.

**Not verified, and it cannot be here: every tap.** Scripted taps do not exist in this
environment, so the Marker button, the Speak/Type switch, the Location toggle, the Round toggle in
both directions, the end-round confirmation and swipe-to-dismiss have all been reasoned
about and screenshotted from seeded state, and none has been touched by a finger.

---

## X30 — the OSM importer reads what OSM actually holds *(2026-08-30)*

Reported: *"search is failing: I was looking for Coyote Creek Tournament Course in Morgan
Hill, CA"* and *"it looks like very rich sets of data that we're not handling right now"*.

### The search

**Two separate failures, both measured against the live geocoder.**

| typed | golf results |
|---|---|
| `Coyote Creek Tournament Course in Morgan Hill, CA` | **0 of 0** |
| `Coyote Creek Tournament Course, Morgan Hill, CA` | **0 of 0** |
| `Coyote Creek` | **0** golf, of 18 — every one a *river* |
| `amenity=Coyote Creek Tournament Course` + `city=Morgan Hill` | **1**, the right one |
| `q=golf course Coyote Creek` | **6**, including both Coyote Creek courses |

Free-form `q` has to guess which words are the name and which are the place. `Nominatim
.Query` splits the typed string instead and the search climbs three rungs — structured,
then the `golf course` category phrase, then plain free-form — before falling back to
the planet-wide Overpass regex.

**And Overpass 504s about half the time.** Four of seven identical requests for one
1.4 km box, body `Dispatcher_Client…too busy`. That is load, not a query that is too
big, so `run` retries three times with backoff and `classify` stops advising `--radius`
for a fault that has no area to narrow. A kumi.systems mirror was tried and **not**
shipped — it did not answer from here at all.

Also fixed: `sites(named:)` swallowed every geocoder error with `try?`, so a TLS or
network failure was reported as *"Overpass timed out"* — the wrong service entirely.

### The data

`out tags geom` → `out geom`. One word, and it was half the multipolygon gap: in the
`tags` print mode a relation arrives with **no members at all** (28 relations, zero
members), so no parser could have read it.

| | before | after |
|---|---|---|
| Corica fairway outlines | 1 of 18 | **18** |
| Coyote fairway outlines | 0 of 18 | **18** |
| Corica cart paths | 0 | **51** |
| Coyote holes with a tee | 2 of 18 | **18** |
| Coyote candidates | 18 + 7 + 3 | **18 (Tournament) + 10 (Valley)** |

- **Relations are areas** — `Element.coordinates` answers for both, `outer` members
  stitched, `inner` dropped.
- **`golf:course:name`** partitions the site when every hole carries it, and a
  disagreement with the routing walk is reported rather than resolved silently.
- **A tee that names its own hole** goes to that hole. "Hole 1 Red" had been placed on
  **hole 13**.
- **Untagged tees adopted** *(user decision)* — 107 of Coyote's 112 — named from the
  length order against one course-wide ramp, marked `inferredName`, rendered `~ White
  Tee`. Practice-named and driving-range polygons are still refused.
- **Cart paths** *(user decision)* — `Hole.paths`, clipped per vertex to the hole each
  stretch serves.

Three more, found by review rather than by running it:

- **`holesWithoutTee` was per site**, so the Tournament candidate — every hole of which
  has tees — reported *"no tee found for hole(s) 1, 2, 2, 3 …"*, the duplicates being
  Valley's refs. `report.lines` **is** the row in `CourseFinder`, so that is the check
  in front of Save crying wolf. Now per candidate.
- **The ramp needs to be long enough to skip a taken name.** Two sizings were tried and
  each produced a `tee N` on a real file — the modal total gave Coyote `tee 5`, the
  adopted count alone gave Corica a one-entry ramp that a tagged black tee had already
  taken. It is now every tee on the widest hole that has an adopted one, and **neither
  real course produces a `tee N`**.
- **`inferredName` survives `Course.merging(card:)`.** It did not: `merging` builds each
  tee from the card's, so a printed yardage would have landed under an invented name
  with the `~` gone.

### Verified, and not

**Measured against the live services**, not reasoned about: every table above.
`Courses/corica-park-south.json` re-imported and `coyote-creek-…-tournament-course.json`
added. 433 tests green; `swift build`, the iOS app build and the iOS package build all
clean. Screenshotted in the simulator: Corica hole 1 on the vector layer with a real
fairway outline and a cart path where a straight band used to be, and Coyote hole 2 with
four adopted tees and `~ White Tee` in the hole box.

**Not verified:** anything past the second site. `teeAnomalies` is now judging a hundred
tees it named itself rather than eleven a surveyor tagged, and the ramp assumes the modal
tee count is the course's real set — the first course where it is not will produce a
plausible, wrong forward tee. Check the `~` marks against a card before playing off one.

---

## X31 — terrain, and the plays-like number that hangs off it *(2026-08-30)*

`docs/research-elevation.md` §7 steps 1–3, built. Steps 4 (the profile) and 5 (Korea) are
not. Everything below is measured against the live USGS services.

### What 3DEP actually answers

| | Corica Park South | Coyote Creek Tournament |
|---|---|---|
| native resolution reported | **1 m** (lidar) | **1 m** (lidar) |
| grid vs the USGS point service | 1.375 vs **1.345** m | 107.31 vs **107.21** m |
| four points re-checked *after* storage | — | **3–34 cm**; tee→green deltas within **0.37 m** |
| relief across the site | **10 m** | **177 m** |
| grid at 3 m posts | 282 × 668 | 570 × 507 |
| one `exportImage` request | 6.5 s, 1.4 MB | 15.5 s, 1.7 MB |
| `Courses/<id>.dem` | 491 KB | 753 KB |

**E1 is answered: yes, 1 m at both.** And a whole course is one request — both fit far
inside the service's 8000-pixel cap, so there is no tiler.

### Three traps, all of which produce a file that looks correct

1. **`imageSR=3857` returns a pixel scale in Mercator units.** At Coyote's latitude that
   is 1/cos(37.2°) = **1.26× the ground metre**; stored as metres it displaces a sample by
   ~270 m at the far corner of the course — several clubs, on an ordinary-looking file.
   The request is EPSG:4326 and the grid is stored in **degrees**, which also keeps every
   projection out of `GolfCourse`.
2. **The service snaps a requested bbox outward to whole posts** — measured, **146 m** in
   one call. So georeferencing comes from the TIFF's own tiepoint and pixel scale, never
   from the box that was asked for. `RasterPixelIsArea` (geokey 1025 = 1, verified against
   a live response) means the tiepoint is the pixel's **corner**, so the first sample's
   centre is half a post in.
3. **`exportImage` will not tell you the native resolution**, and it resamples 1/3
   arc-second data onto a 3 m grid without comment — byte-identical in shape to lidar, and
   a metre of vertical error against ten centimetres. The **point service** reports it; it
   is asked once per import and the answer is written into the file. The **vertical datum**
   is not in the raster either (the geokeys are the *horizontal* CRS), so `.navd88` is
   asserted by the fetcher.

### `format=bsq` was tried and is not usable

The headerless raw dump came back with **990,000 bytes for a 300 × 800 request** —
247,500 floats, not 240,000 — while `f=json` for the same call said 300 × 800. A raster
whose dimensions have to be inferred from a byte count is one transposed grid from a file
that is silently a hole out of place. `format=tiff` states its own everything, which is
why there is a `GeoTIFF` reader (uncompressed F32, one band, **tiled and stripped**, both
byte orders — 3DEP returns tiled 128 × 128 on every request measured, but the layout is
its choice).

### The datum rule, made structural

research-elevation.md §4's invariant is the one thing here that had to be a *type*.
Ellipsoid and geoid differ by roughly **−30 m in California**, so a difference across the
two is out by more than the rise it is expressing and reads like an ordinary large number.
`Elevation.sample(at:)` therefore returns a `Sample` carrying its `datum` and `source`,
and `Sample.delta` **returns nil when they disagree**. There is no public `Double` height.

**And it closed a leak that was already there**: `Hole.elevationDelta(from:)` preferred the
*point's own* `alt`, which is correct only for a coordinate out of the course file and
silently wrong for a fix. It now reads only the file. `RoundViewModel.here` had been niling
the altitude to prevent exactly this — a comment holding a rule that nothing enforced.

### On screen

`HoleReadout.rise` is measured from the **last waypoint** to the flag, matching
`green.center`, because a rise from where the golfer stands and a distance from their layup
target are two halves of two different shots. The chip reads `▼ 15 · plays ~322 YD` — the
`~` is the same mark `CardYardage` puts on a measured length standing in for a card number.
Screenshotted on Coyote hole 8, the 14 m drop.

### Verified, and not

**Verified:** the numbers above; the stored `.dem` cross-checked against an independent
service; 459 tests (was 433) with `Elevation`, `GeoTIFF` and the readout covered by
synthetic fixtures; `swift build`, the iOS app build and the iOS package build clean; the
plays-like chip screenshotted in the simulator.

### The phone can fetch it too — as a button

**Asked and answered on 2026-08-30: a separate button, on demand.** `CourseFinder` stays
geometry-only (a DEM is another request, ~750 KB, 6–15 s, and nothing at all outside the
US), and `TerrainSheet` is its own step in the course menu. The cost of that split is the
one thing the sheet says out loud: **do it before the round**. Its three checks are the
sheet rather than a detail behind it, and `-marker.terrain fetch` runs the download so
they can be looked at here — the same argument `marker.find.query` was built on.
Screenshotted downloading Coyote Creek in the simulator: 1 m lidar, 177 m of relief,
100% coverage, per-hole rises matching the CLI to the decimetre.

**Not verified:** anything but two Californian courses on 1 m lidar. The coarse-product
branch (`native > 1.5`, printed *NOT lidar*) and the void branch have never seen a real
response. `k = 1` is unmeasured against a round anybody played — E3, and it needs a round
first. The terrain sheet's **Save, Cancel and download-again paths have never been touched
by a finger**; scripted taps do not exist here.

---

## X32 — the plays-like number, inline and on every distance *(2026-08-30)*

Three asks: research the formula, drop the orange box, and put the number on every
distance rather than one.

### The formula, researched

**1:1 — `playsLike = D + Δh` — is the popular answer, and it is what the code already
did.** Every general-audience source says it in the same words ("about one yard of
distance adjustment per yard of elevation change"), and the variants that put numbers on
it land within about 15%:

| Source | What it says | Implied k |
|---|---|---|
| ShotPattern | one yard per yard | **1.0** |
| Common teaching rule | one yard per 3 ft | 1.0 |
| Uphill/downhill rule of thumb | +8 yd per 25 ft up; drop ÷ 3.5 down | 0.96 up, 0.86 down |
| Probable Golf Instruction (ballistics sim, 6-iron) | 20 yd up costs 21; 20 yd down gains 18 | 1.05 up, 0.90 down |

**The asymmetry is real and consistent** — uphill costs slightly more than downhill gives,
in both the rule of thumb and the trajectory model. It is smaller than a GPS fix's own
error over these distances and it is not what anybody teaches, so `factor` stays 1; it is
the first thing to try when E3 gets data. Rangefinder makers all compute the same
underlying quantity and none publish the adjustment, so there is nothing to match.

### On screen

`333 ▲1 · ~334`, inline, in four places: the big distance, the first target leg, the
second target leg, and the leg between two shot markers. The orange capsule is gone — it
was a second object saying something about a number three lines above it.

- **One formatter** (`DistanceDisplay.plays`), because four hand-built strings is four
  chances for one to round differently or point the arrow the wrong way.
- **`HoleReadout.Leg.rise` is per leg.** A layup over a ridge and the approach down off it
  are two different shots. Verified on Coyote hole 8: the legs read ▼9, ▼2 and ▼4, and the
  hole reads ▼15.
- **`~` still marks the modelled half and the rise is printed bare**, because the rise is
  measured (lidar, 10 cm) and the plays-like number is not.
- **The plan leg box grows with the text**, which is required rather than tolerated: the
  rectangle drawn is the rectangle the drag gesture tests, and it roughly triples.
  `PlanLayout.advance` was corrected from an estimated **0.6 to a measured 0.618** while
  checking this — every glyph in these labels, `▲ ▼ · ~` included, is 0.618 em in
  `NSFont.monospacedSystemFont`, so none falls back to a proportional face and the 0.6
  estimate had been running 3% narrow. Tested: with two targets the three boxes still do
  not intersect, each still drags the target it is about, and each holds its own text.

### The defect the screenshot caught

`180 ▲1 · ~180` — three numbers that do not add up. A 0.49 m rise over 164 m rounds *up*
to a yard while the plays-like distance rounds *down* to the same 180. It reads as an
arithmetic error in the app rather than as rounding. **The arithmetic is now done in the
units the numbers are printed in**, which for a 1:1 model makes
`distance + rise = plays like` exact on screen, always — pinned by a test that sweeps
every distance and rise in range. The suffix is also nil when the rise rounds to nothing.

### Verified, and not

471 tests (was 459); `swift build`, the iOS app build and the iOS package build clean.
Screenshotted twice: **Coyote hole 8 with two targets** — `101 ▼4 · ~98` at the top,
`118 ▼9 · ~109` and `118 ▼2 · ~116` on the legs — and **Corica hole 1 with shot tracks**,
where min's two legs read `180 ▲1 · ~181` and `91 ▼1 · ~90`, the closing leg into the flag
reads `96 ▲1 · ~97`, and steve's flat leg correctly shows `192` with no suffix at all. The
track-leg numbers were computed independently from the `.dem` first and match.

`-marker.targets 0.35,0.7` is new and is what made the target legs reviewable here at all.

**Satellite screenshotted too**, and it found a **pre-existing** defect the suffix made
obvious: that layer's leg labels do not de-collide with anything, so a short approach leg
lands under the big distance at the top. `SatelliteHoleView.labelPoint` anchored *every*
leg at 0.72 along its line; the approach leg starts at the last target, so it now anchors
at 0.28 like `PlanLayout` does — the stated rule ("anchors at the target end, not the flag
end"), which that layer had never followed. **That improves it and does not fix it**: with
a 101 yd approach and target 2 at 0.7 of the hole, the box is still under the HUD. The
real fix is a **top** reserve on the satellite layer, the way `bottomReserve` protects
Apple's attribution, and it is out of what was asked here. Logged in Known gaps.

**Not verified:** `k = 1` against a round anybody played.

### X32.1 — the format, revised *(same day)*

Three corrections from the user after the first screenshots:

- **No `YD`.** The unit is stated once, in the caption under the big distance. The vector
  layer's leg labels already followed this and said so in a comment; the **satellite** leg
  box, the rulers on both layers and the tee tray did not.
- **The big number stays centred regardless of the suffix**, which hangs off its right
  edge. An `HStack` centred the *pair*, so the one yardage read at a glance slid sideways
  the moment a hole stopped being flat. `HoleScreen.bigDistance` now draws the number
  alone and offsets the suffix by a **measured monospaced advance** — the technique
  `PlanLayout` already uses. The obvious `.overlay(alignment: .bottomTrailing)` with the
  child's `trailing` guide resolved at its own `leading` should sit it just outside and
  instead landed it **on** the number: screenshotted, `.~97▼4` across the `1` of `101`.
  The gap ended at **zero** — a 20-point `.` beside a 68-point digit already has that
  glyph's sidebearing between them, and 6 points orphaned the dot.
- **`<dist>.<plays like><arrow><elevation>`** — `333.~334▲1`, the adjusted distance
  leading and the rise trailing as the reason. The `.` is the user's separator, now given
  twice; `~` stays because it marks the modelled half and because it keeps `333.334` from
  reading as a decimal.

**The centring is measured, not eyeballed.** The same hole rendered twice — once with the
`.dem` removed so the suffix vanishes, once with it — and the big number's left edge read
**35.24%** of screen width without and **35.27%** with: identical inside a third of a
pixel. On the previous `HStack` build the same measurement was **21.98%**, so the number
had been moving 13% of the screen width whenever the ground stopped being flat. The ink
extending further right in the sloped shot is the suffix, which is where it was asked to
be. `PlanLayout.advance` is now load-bearing in three places, so a test pins the estimate
against `NSFont.monospacedSystemFont` at 14, 20 and 68 points.

Screenshotted after each change: Coyote hole 8 with two targets on **both layers**
(`101.~97▼4` centred, `118.~116▼2` and `118.~109▼9` on the legs) and Corica hole 1 with
shot tracks (`180.~181▲1`, `91.~90▼1`, closing leg `96.~97▲1`, steve's flat leg a bare
`192`). 472 tests.
