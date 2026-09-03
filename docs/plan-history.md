# Plan history — the implementation plans, as written before the work

**This is a record, not guidance.** Every plan below was written *before* the work it
describes and is kept for the reasoning, not the instructions: what was expected to be
hard, what turned out differently, and the arguments that are not written down anywhere
else. Three of the phases in here were built and then **deleted** (Siri, Apple
Intelligence), and one — the Apple two-locale recogniser recommendation — was
**overruled by the user** the same day it landed.

**What is still live goes in [`../TODO.md`](../TODO.md), never here.** If a statement in
this file contradicts TODO.md, CLAUDE.md or a research doc, they are right and this is
history. Moved out of TODO.md on 2026-08-28, verbatim.

*What is worth coming back for:* D1/D2/D3 (the three deliberate divergences from the
research), the two-tier extraction split and why only the authoritative tier is scored,
the `Correction`-firewall argument that put `Event.provenance` in the format on day one,
and the F1 argument for why a `LogEntry` is not an `Utterance`.
The **Retired CLAUDE.md invariants** section at the end is a separate appendix, added
2026-08-31: the rules that were reversed or superseded, kept verbatim.

---

## Implementation plan — items 31–41

### What has to be true before any of it

**`scorecard.json` stops being the source and becomes a cache.** Everything else here
is additive; this one changes a file that already exists and that `golfctl` reads. The
snapshot keeps being written on every replay so nothing downstream breaks, but the
*authority* moves to `journal.jsonl`. A round recorded before the journal existed has
no journal and its `scorecard.json` is all there is — replay therefore **seeds from the
existing snapshot** when the journal is absent, rather than presenting an empty card.

**The journal is ground truth.** `SessionFolder.File.journal` joins `.marks`,
`.corrections` and `.scorecard` in `groundTruth`. It never enters a bundle or a prompt.
This is why item 37 puts the converged coordinate in `log.jsonl` and not here.

### G1 — `journal.jsonl`

`JournalEntry` in `GolfSessionFormat`, flat with optionals in the shape of
`Correction` rather than an enum with payloads — an added field then decodes an old
file instead of failing it.

    struct JournalEntry {
        id, t, act: Act            // setScore, setStat, setIndex, setTee,
                                   // addPlayer, editPlayer, removePlayer,
                                   // setCourse, acceptEvent, rejectEvent, undo
        player, hole, strokes
        stat, statValue            // putts / gir / fairway / ob / hazard
        index                      // handicap index, the player's own number
        tee, rating, slope, par    // frozen as played — item 35
        name, aliases
        eventID
        prev, prevStrokes          // what it replaced, so one row reads on its own
        undoes                     // the journal id this reverses
    }

**No `editLog` act.** Log edits are superseding rows in `log.jsonl` (item 40) — the
journal would put a model-visible change behind the ground-truth firewall.

`prev*` is **not** redundant with replay: a history screen has to render "steve, 7:
5 → 6" without re-deriving the whole round for every row, and a row that cannot be read
alone cannot be blamed.

`JournalState.replay(_:seed:)` returns `(scorecard, players)`. Undo resolution is a
fixpoint, not one pass — an `undo` row can itself be undone, so the set of live entries
is computed before anything is applied. That is the part with a test rather than a
comment.

`RoundDocument.setScore` / `setCourse` route through it; the snapshot is rewritten
after each replay.

### G2 — Players, handicaps, and the extras

Three numbers, and only the ends are stored:

    handicap index      journaled, the player's own          14.2
    tee + rating/slope  journaled, frozen at round start     white, 71.2 / 128
    course handicap     DERIVED, never stored                16

`Handicap.course(index:rating:slope:par:)` in `GolfCourse`, returning **nil** when
rating or slope is missing — a course with no USGA numbers must produce no handicap
rather than a plausible one, the same rule as `cardLength(from:)` refusing to answer
with another tee's number. Strokes received per hole then distributes it by
`Hole.handicap`, which is the *stroke index* and not this at all; the test uses a
27-hole named-nine course, where `Hole.ref` is not the playing index and a naive
implementation quietly allocates against the wrong column.

**Per-player tee** replaces the card's single global `teeName`. The yardage row still
needs one tee to draw, so the card keeps a display tee and each player carries their
own for scoring.

The extras — putts, GIR, fairway hit, OB, hazard — are `setStat` journal acts, so they
undo and blame like everything else, but they stay **out of the grid**: the card shows
the score, and a cell opens to reveal the rest. Second rank in the UI, first-class in
the data.

### G3 — A log is placed after it is accepted, and stays editable

- `LogEntry.supersedes: String?`, `LogEntry.deleted: Bool` and `LogEntry.current(_:)`,
  mirroring `Event`. This one type then carries **all four** mutations of a log:
  the converged coordinate, an edited sentence, a changed hole, and a deletion.
- Delete is a tombstone rather than an absence, because a proposal that already cites
  a log has to keep rendering its evidence — `RoundScreen.cited(_:)` looks the row up
  by id and would otherwise show a claim resting on nothing.
- After the intent writes a log, converge: `beginBackgroundTask`, run the location
  manager to a stable fix or ~10 s, append a superseding row with the coordinate and
  the **recomputed** hole. Leaving the hole stale would keep the nil that made the row
  invisible in the first place.
- **A Darwin notification, which was deliberately skipped and should not have been.**
  `LogStore.didAppend` is in-process, and the note in the code says the foreground
  screen catches up on `scenePhase` "for a screen the user is by definition not looking
  at". That premise is wrong for Siri overlaid on the open app — which is exactly the
  case in item 37, where the log has to appear *as it is spoken*.

### G4 — Interpret on arrival, accept or reject

> **Scrapped and deleted 2026-08-27.** Kept as the record of what was tried and why it
> failed — see [`../TODO.md`](../TODO.md), Done #10.

- `GolfIntelligence` runs on a new log with the round and hole as context, writing a
  `.model` event with `logs: [id]`. The per-hole button stays; this is item 26's
  "automatic later".
- Accept and reject are journal rows referencing the event id. Replay yields the
  accepted scores and the rejected set; the card is derived from accepted `.score`
  proposals plus direct `setScore` rows.
- **Deviation from the option text, on purpose:** accepting does *not* also write a
  `.user` event. The journal row is the user's assertion and the score falls out of
  replay — two records of one act is how they drift apart.

### G5 — Reading a card

> **Scrapped and deleted 2026-08-27.** Kept as the record of what was tried and why it
> failed — see [`../TODO.md`](../TODO.md), Done #10.

Typed or pasted text first: it is the cheap half and it exercises the whole
proposal path. The photograph then adds only OCR in front of it. Both end in proposals
on the card, never a direct write.

### G6 — History

The journal rendered: what changed, when, by which act, with undo. This is the payoff
for G1 and the only way anyone sees that the journaling was worth doing.

### Still open

**Where a handicap index lives between rounds.** It is frozen per round by item 35, but
a player's index is the same next week and retyping it every round is the kind of
friction that gets a feature abandoned. `CourseLibrary` is the precedent for an
app-wide preference beside the per-round record — but a *roster* is not a course, and
"a round's course lives in its own meta.json" exists because reading a global there put
another round's data on screen. Decide it in G2, not before.

### Order, and why

G1 first: every other item writes to it, and retrofitting a journal under features
already shipping against `scorecard.json` means writing each of them twice. G3 next
because it is the live complaint. G2 is independent and can slot anywhere. G4 needs G1
(accept/reject are journal acts) and reads better after G3 (a log with a hole gets a
better proposal). G5 needs G4's proposal UI. G6 last — it can only be built once there
is a journal worth showing.

**Not planned, and worth saying:** none of this needs the phone to verify except G3's
convergence and the Siri round trip. G1, G2 and G4's replay are testable on macOS, and
the screens are reviewable by simulator screenshot.

## Implementation plan — items 23–30

### Two spikes, and one question already answered *(2026-08-27)*

**~~S1 — Can Siri capture free text in one utterance?~~ Answered from the documentation
— it cannot, and no phone is needed to find out.** `AppEnum` and `AppEntity` are the
only types permitted as parameters *inside an `AppShortcut` phrase*; an invocation
phrase cannot be open-ended. So `"Hey Siri, log in Marker, Steve made a five"` in one
breath **does not exist as an API**. The interaction is two turns and always will be:

```
"Hey Siri, log in Marker"      → phrase, no parameter
"What happened?"               → requestValueDialog
"Steve made a five on seven"   → Siri dictates; perform() gets the String
"Logged."                      → spoken confirmation
```

**The user chose this anyway *(2026-08-27)*, over a one-press push-to-talk
alternative.** The reasoning is worth recording because it is what makes the two turns
acceptable: `"Hey Siri"` works from a pocket with the phone locked, and push-to-talk
does not — it needs the phone in hand, which on a golf course is most of the cost.
Two turns from a pocket beats one press you have to dig for.

*What that decision gives up:* the microphone stays out of the app entirely (good,
that was the point), and **the bilingual path narrows to the typed box.** Siri
transcribes in the system Siri language only, so a Korean sentence spoken to an
English Siri comes back as mush and there is no second locale module to catch it —
the thing that made two `SpeechTranscriber`s worth building. Push-to-talk would have
kept it, by reusing `LiveTranscriber` unchanged. It was offered and declined; the
consequence lands on the input box.

*Still worth measuring on a phone, but as ergonomics, not as a gate:* the real
round-trip time per log, and whether Siri's dictation mangles player names and golf
vocabulary the way `SpeechTranscriber` did ("Chungmin" → "Chungman"). There is no
`contextualStrings` equivalent to reach for here — Siri is a black box — so name
matching downstream has to be fuzzy for the same reason it already did.

### The two spikes that do need a phone

**S2 — Is `FoundationModels` available on this phone, and is it good enough?**
`SystemLanguageModel.default.availability` gates it: an Apple-Intelligence-capable
device, the feature enabled, the model downloaded — the same wall the speech model
hit, and **not available in the simulator**. Then a real `@Generable` extraction over
a hole's worth of logs, checked by hand. The hard constraint: the on-device model's
context window is **~4,096 tokens, input and output together**. A whole round will not
fit. Per-hole chunking is the natural shape anyway, because a hole is a handful of
short logs rather than an hour of transcript — but it is also why D2's "single call
over the whole round" no longer applies to the live tier, and why E7 stays a cloud
call.

**S3 — Does an intent get a position?** An App Intent invoked while the app is
backgrounded may run in a background-launched instance with no location manager
running. Verify that a log made from a locked phone mid-round carries a fix. This is
the one that can still break the design: a log without a coordinate is a note, not an
event.

### F1 — The log stream

A new observation type, **beside** `transcript.jsonl` rather than inside it:

```swift
public struct LogEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var t: Millis
    public var text: String
    public var lat: Double?, lon: Double?
    public var hole: Int?
    public var source: Source     // .siri | .typed
    public var locale: String?
}
```

written to `log.jsonl`, declared **model-visible** in `SessionFolder.File`.

*Why a new type and not `Utterance`.* An utterance has a speaker, a confidence, a
locale and a `[t0, t1]` window and no coordinate; a log has a coordinate and none of
the rest. Widening `Utterance` to fit would put four always-nil fields on the ASR type
and make "does this line have a confidence" a question with two different meanings.

*Why this leaves the firewall untouched.* `Event.modelVisible(_:)` needs **no edit**,
`Event.Provenance` stays two-valued, and `isGroundTruth` stays a yes/no question. A log
is an observation — the thing the microphone would have captured — and observations
have always been model input. What stays ground truth is unchanged: `Mark`,
`Scorecard`, `Correction`, and an `Event` with `.user` provenance, which now means
specifically *a correction to a proposal*, not "anything a human typed".

**Consequence for the input box:** `Event.typed` is the wrong destination for it now.
Free text typed into the box becomes a `LogEntry(source: .typed)` — the same stream
Siri writes to, so the same extraction reads both. `Event.typed` stays for the one
case it was really about: adding an event by hand *after* extraction has run, which is
a correction. Its doc comment needs the distinction, or the next reader will merge the
two paths back together.

**Cross-process appends.** The intent may run in a background-launched instance of the
app while a foreground instance also holds a `JSONLWriter`. Two writers interleaving
mid-line corrupts the file silently. Declare the intent **in the app target** (not an
extension) so there is no App Group and `UIFileSharingEnabled` keeps working, and make
`JSONLWriter` append with a single `flock`-guarded `write()`. Cheap insurance; a torn
line is unrecoverable.

### F2 — Rip audio out of the app

Delete `LiveTranscript.swift` and `RoundTranscription.swift` from the app target, drop
`AudioRecorder` from `RoundSession`'s app-side use, remove the microphone capability
row and `NSMicrophoneUsageDescription`, and take `audio` out of `UIBackgroundModes`.
`RoundViewModel.stopRound()` can go back to being synchronous.

**`Sources/` needs no change, and this was checked rather than assumed.**
`RoundSession` already takes **`recordAudio: false`** — every audio call site inside it
is behind that flag, `meta.audioFormat` becomes `"none"`, and `AudioRecorder.currentRoute`
is never read. The app passes false; `golfctl record` keeps passing true. So
`GolfCaptureCore`, `GolfTranscription` and their 172 tests stay exactly as they are, and
`golfctl record --live` remains the ASR comparison rig — the only place that path is
exercised at all now. Rewrite the CLAUDE.md audio section to say so in the same commit.

*The one thing left to confirm:* `RoundSession.init` still **constructs** an
`AudioRecorder` even when `recordAudio` is false. Construction must not touch
`AVAudioSession` or the microphone permission — verify it, and if it does, make the
recorder lazy rather than adding a second session type.

**A GPS-only round closes out correctly** — also checked. `SessionIndex.lastEvidence`
already considers GPS, motion and altitude alongside `audio.jsonl`, so a round with no
segments still gets an honest `end` stamp instead of falling back to `now`. Nothing
downstream requires `audio.jsonl` to exist; `SessionSummary.audioSegments` simply reads
zero.

*What is lost, stated plainly:* the interruption path, the stall watchdog against a
real dead tap, and background audio survival will now **never** be verified on a
phone, because the phone will never run them. They stay verified-on-macOS forever.
That is the cost of this change and it is worth naming, because three of those were
written down as "needs a phone" yesterday.

**And one more, which is a known gap rather than a to-do: golf-vocabulary WER on the
product's real input path is now unmeasurable.** WER was what replaced E0 as the first
measurement, and it is still not measured. With the app not recording, the transcription
the product actually depends on is Siri's — a black box we neither control nor can A/B
against a second engine. Attribution accuracy is still the metric that decides the
feature, and it now rests on something we cannot instrument. Watch it in `GolfEval`
against corrections, which is the only handle left.

### F3 — The Siri intent

> **Scrapped and deleted 2026-08-27.** Kept as the record of what was tried and why it
> failed — see [`../TODO.md`](../TODO.md), Done #10.

```swift
struct LogShotIntent: AppIntent {
    static let title: LocalizedStringResource = "Log"
    static let openAppWhenRun = false        // must run with the phone locked

    @Parameter(title: "What happened", requestValueDialog: "What happened?")
    var text: String

    func perform() async throws -> some ProvidesDialog { … }
}
```

with an `AppShortcutsProvider` phrase carrying the app name — Siri requires it, there
is no bare "log a shot". No parameter in the phrase; see S1.

`perform()` resolves the active round from `SessionIndex`, takes the last fix, appends
a `LogEntry`, and **speaks a confirmation**. The confirmation is not politeness: a log
that fails silently is a shot that vanishes, and the golfer has already walked away.

No round running → say so out loud rather than writing a log with no home. That is
also the answer to "what if they forget to start the round", and an audible refusal is
a better one than a coordinate-less orphan.

### F4 — The round screen, three bands

```
+--------------------------+   scorecard, horizontally scrollable
+--------------------------+   events + logs for the chosen hole
+--------------------------+   input box, expandable
```

**The card.** Rows: hole number, yardage, par, stroke index, then one per player.
Columns 1–9, **Out**, 10–18, **In**, **Total**. Tapping a hole column is the hole
selector — no separate control. A score cell is editable in place.

Two things will not work the way the sketch assumes, and both are structural:

- **The yardage row will be empty on the only real course file there is.**
  `Courses/corica-park-south.json` came from OSM, and *OSM never supplies yardage, in
  any region* — `dist` is on 0.3% of US hole ways. Yardage needs a **card import** and
  it is **per tee**, so the row also needs a tee selector, and `cardLength(from:)`
  returns nil rather than falling back to another tee's number (invariant, deliberate).
  The honest fallback is `HoleGeometry.measuredLength`, which walks the centreline —
  but that is a *different number*, not a substitute: Corica hole 1 is 469 yd on the
  card and 426 measured, because nobody carries the corner of a dogleg. **Show it
  marked as measured, or show nothing.** Do not let a measured length render as a card
  yardage.
- **Out / In assumes holes numbered 1–18**, which is exactly what `Hole.ref` is not.
  A Korean 18 is two of three named nines each numbered 1–9. Subtotal by `Hole.nine`
  when there is one, and only fall back to 1–9 / 10–18 when there is not.

**The middle band shows both streams for the chosen hole** — extracted events and the
raw logs they came from, interleaved by time. A log with no event yet is the visible
signal that Fill the card has not been run over it.

**Hole attribution of a log** is itself a small problem: a log carries a coordinate and
a time, not a hole number. Nearest-hole-by-geometry when there is a course file and a
fix; otherwise the hole selected on screen at the time. Store it on the `LogEntry` so
it does not get recomputed differently later, and let the user move it.

### F5 — Fill the card

> **Scrapped and deleted 2026-08-27.** Kept as the record of what was tried and why it
> failed — see [`../TODO.md`](../TODO.md), Done #10.

`GolfIntelligence` (new, app-side or a target gated on `@available(iOS 26)`):
`SystemLanguageModel`, a `LanguageModelSession` per hole, `@Generable` output structs.
One hole per session, because of the 4,096-token window — and starting fresh per hole
also means one bad hole cannot poison the next.

Output is `Event`s with `.model` provenance, confidence and evidence
(`LogEntry.id`s rather than `Utterance.t0`s — `Event.evidence` needs to carry both, or
become a string id list). Scores proposed here are **drafts** and do not touch
`scorecard.json` until the user confirms them onto the card. That distinction is the
existing draft-versus-answer invariant and this is the screen where it becomes real.

Availability is a first-class state, not an error: unsupported device, feature off,
model still downloading, and language unsupported are four different messages, and
`RoundTranscription.explain`'s shape is the precedent for getting this right.

**Write it against `LanguageModelSession`, not against the on-device model**
*(decision 2026-08-27, after the question was asked)*. On iOS 26 the framework reaches
**only** the on-device model — Private Cloud Compute is never used, and a third-party
app cannot reach the user's ChatGPT-in-Siri account even when one is linked in system
settings. **iOS 27 opens the same session API to any provider** through a public
protocol (`PrivateCloudComputeLanguageModel`, plus first-party Swift packages from
Anthropic and Google). So the cloud tier becomes a **backend swap rather than a
rewrite**, provided nothing outside this file knows which model answered. Keep the
seam: the app deals in a session and a `@Generable` type, never in a provider.

*Why on-device is the right default regardless of iOS 27:* it is free, private, and
**works with no signal**, which is the normal condition on a golf course. That last
one is the same argument that made the vector hole view the base layer and MapKit
imagery decoration.

### F6 — Automatic, and everything else

Automatic Fill the card on hole change; then E6's hole-view overlay (unchanged — the
events feed it either way) and E7's authoritative cloud pass (unchanged, and now the
*only* thing that needs a key).

### Order

S2 → S3 → F1 → F2 → F3 → F4 → F5 → F6 *(S1 is answered; see above)*. **F4 can be
built before F3 and probably should be** — the input box already exists, so the card and the three bands are
testable against typed logs with no Siri involved, and that is also the fallback UI if
S1 comes back badly.

E3 (location fast/slow) is untouched by all of this and is now *more* important, not
less: the location recorder is the only sensor left running.

---

## Implementation plan — items 16–20

### Where this stands before any code

**Recording is researched *and* built.** research-game-tracking.md §3 and §5 plus
constraints G1–G6; `GolfCaptureCore` / `GolfCaptureMotion` ship it, verified on
macOS, never once over a real 4.5-hour round on a phone.

**Transcription is researched to a runnable A/B with a kill gate and has zero lines
of code.** poc-plan §Phase 2 specifies it precisely — two implementations behind one
`Transcriber` protocol, `golfctl --asr apple|whisperkit`, with capture rate,
diarization purity and golf-vocabulary WER reported separately. What exists is
`Sources/GolfTranscription/Placeholder.swift`, 15 lines of TODO. Same for
`GolfReconstruction`, `GolfStore`, `GolfEval`, `GolfInsight`.

So items 16–20 are not an extension of finished work. They are **PoC Phases 2 and 3,
re-specified as a live in-round experience** rather than an off-device batch step.

### Three places this diverges from the written plan — deliberately

**D1. Transcription moves on-device and live.** The plan had it off-device
(`golfctl --asr` on a Mac, 20–35 min per round for WhisperKit large-v3, cached in
the session folder). Item 16 wants it live on the phone during the round.

*Consequence, and the rule that follows:* **audio is never discarded.** Not for
transcript quality — because poc-plan Phase 2 says "run both paths over the same
audio — this is a measurement, not a choice", and **discarding audio makes the Q12
kill gate unrunnable forever.** The live transcript is an additional consumer of the
recording, never a replacement for it. Off-device re-transcription must always be
able to regenerate `transcript.jsonl` from the `.m4a` segments.

**D2. Extraction becomes incremental, against a measured recommendation.**
research §7 is explicit: single call over the whole round, **not** per-hole chunking
— chunking costs 66K input instead of 29K because prompt and schema repeat 18 times,
and it "strips the cross-hole context the task depends on" (turn order carries
between holes; a score announced on the next tee resolves the previous hole).

A live event list forces chunking. The resolution is **two tiers, named as such**:

| Tier | When | Model | Status of its output |
|---|---|---|---|
| **Live draft** | during the round, per hole / on demand | Haiku | A working list the user reads and corrects |
| **Authoritative** | at round end, one call over everything | swept | Supersedes the draft; **this is the only tier `GolfEval` scores** |

Scoring the live tier would measure the weaker path and report it as the product's
accuracy.

**D3. The recorded track is duty-cycled from the start.** *(User decision,
2026-08-26.)* The invariant "the live feed is duty-cycled; the recorded track is
not" is **void** — PLAN §5's honest full-rate baseline will not be collected, and the
3–7× saving is therefore permanently unmeasurable against a real before-number. Say
so where a saving is claimed rather than quoting a figure from the research.

### The thing to get right before writing any pipeline code

**Item 18's "user can correct info, or add events" lands directly on the `Correction`
firewall.** Incremental extraction naturally feeds prior events back as context on
the next call. The moment a *user-corrected* event is in that context, ground truth
has entered the model input — and `GolfReconstruction` depends on
`GolfSessionFormat`, so nothing in the compiler will stop it.

So `Event` carries **provenance from day one**:

```swift
public enum Provenance: String, Codable, Sendable {
    case model      // proposed by extraction — may be fed back as context
    case user       // typed or corrected by a human — GROUND TRUTH, never in a prompt
}
```

and the bundle builder filters on it. One undifferentiated event list built first
turns this into a migration plus an audit of every call site. This is the
known-gap-deliberately-deferred (`Mark`/`Correction` in the wrong target) becoming
load-bearing — worth revisiting the split at E1, not after.

### Phases

**~~E0 — Q12 probe.~~ Cut by the user on 2026-08-26: diarization is not needed.**
Attribution is **content-only** — the LLM resolves who did what from what was said
("nice shot, Steve"; "you're away"), and a transcript good enough for that is the
whole requirement. Consequences, stated plainly because research §7 called this
"the floor, not a plan":

- **Q12 is closed by decision, not by measurement.** No `SpeechTranscriber`
  diarization probe, no SpeakerKit, and WhisperKit path B loses its main
  justification — it stays only as a transcript-quality comparison, not a
  capability fallback.
- **`Utterance.speaker` simply stays nil** on the Apple path. The field remains,
  because the format should not have to change if diarization ever arrives free.
- **The bet this makes:** attribution accuracy drops and more events need review,
  and the thing that carries the load is corrections (PLAN §3). That is the same bet
  already made when far-field capture rate stopped being a gate, so it is consistent
  — but it is now the *only* thing standing between a noisy transcript and a wrong
  scorecard. Watch it in `GolfEval`; **attribution is still the metric that decides
  the feature.**
- What replaces E0 as the first measurement: **golf-vocabulary WER** on real audio
  — club names, numbers, scoring terms, player names — which is what "good enough
  for the LLM to analyse" actually means. **Not yet measured.** The E2 fixture is
  synthetic close-mic TTS and verifies plumbing, not WER; see the note under E2.

**~~E1 — The contract.~~ Done as part of the two screens**, because the event list and
the input box both needed it. `Event` (t, kind, player, hole, coordinate, confidence,
evidence, **provenance**), `events.jsonl`, `Event.modelVisible(_:)`,
`SessionFolder.File.mixedProvenance`. `Utterance` already matched the PoC's
`{t0,t1,speaker,text,conf}` shape and needed nothing. What is still open here: whether
the **`Mark`/`Correction`/`Event.user` split into their own target** happens before the
extraction pass — the firewall is now three types wide and still only a convention.

**E2 — Transcription. Done *(2026-08-27)*: batch, live, and bilingual.** `Transcriber` protocol, `AppleTranscriber` (`SpeechAnalyzer` +
`SpeechTranscriber`, `@available(iOS 26, macOS 26)`), `SessionTranscriber`, and
`golfctl transcribe`. Ran end to end on a real two-segment fixture: 7 utterances,
~30× realtime, cache and cache-invalidation both verified.

*What the fixture showed, and what it does not show.* The synthetic round contained
"You're away, Steve. I'm hitting seven iron… Dave three putted from the fringe." It
came back as **"Your way, Steve"** and **"Day 3 potted from the fringe"** — `bogey`,
`par`, `bunker`, `fringe` and `seven iron` all correct, but **a turn-order cue and a
player's name both destroyed**, on clean synthesised close-mic speech. Those are
precisely the two signals content-only attribution runs on. This is **not a WER
number** — TTS is not a foursome at 15 m in wind — but it says which tokens are
fragile, and it is the reason name matching downstream has to be fuzzy.

*Wired into the app 2026-08-27.* `RoundTranscription` + a **Transcribe** button in the
round screen's Transcript pane, plus a toolbar menu with *Transcribe again from
scratch*. Low-confidence lines (<60%) are flagged in orange, because with no
diarization a mangled name is a lost attribution and that is the only warning there
is. **Verified as far as the simulator allows** — the whole path runs and stops at the
missing speech model, which the simulator cannot supply. It needs a real iPhone.

**Live transcription — built and verified on macOS *(2026-08-27)*.** Researched in
[`docs/research-live-transcription.md`](docs/research-live-transcription.md);
recommendation (b) implemented as written.

- **`AudioRecorder` rebuilt on `AVAudioEngine`.** One `installTap`; one converter per
  consumer. Public surface unchanged, so the existing tests are the regression check.
  New: `AudioTap` (a consumer carries its own format, because the analyzer's is not
  the file's), `listen(_:)`, `rotateSegment()`, and a **stall watchdog** — "no buffer
  for 10 s" is a fault, and recovery is a new segment, not a retry of the same one.
- **`LiveTranscriber`** streams the same two locale modules off that tap.
  `LiveAudioClock` maps the analyzer's delivered-samples clock back onto the session
  clock and **absorbs gaps** rather than compressing the round.
- **`LiveTranscript`** (app) drives it from `RoundViewModel.startRound()`, and the
  Transcript pane shows the live feed while the round holds the microphone — finals
  plain, uncommitted hypotheses dimmed and italic, never stored.
- **`golfctl record --live`** runs the whole chain in one process. This is the only
  place the recorder and the recognizer are exercised *together*, which is the part
  that actually has to work.

*Three measurements came out of building it, all of which would have been silent bugs:*

- **An `AVAudioFile` must be released before its `.m4a` is readable.** A file still
  held fails `ExtAudioFileOpenURL` outright; even one that opens is missing the
  encoder's last frames (45,056 vs 45,880). `AVAudioRecorder.stop()` gave this for
  free and `AVAudioFile` does not, and the Transcribe button runs right after `stop()`.
- **Never pass `bufferStartTime` on live input.** Stamping buffers with wall-clock
  positions produced one volatile word repeated and *no* finalized results, over
  speech the same analyzer handles cleanly with the times left off.
- **A segment must end at its last sample, not when the stall was noticed.** Found by
  firing the watchdog against a faked dead tap: the segment claimed 18.0 s while
  holding 6 s of audio, putting twelve dead seconds inside a window the clock calls
  continuous. Fixed; the gap now appears between segments, where it belongs.

*Verified by faking a dead tap:* the watchdog closes the segment, restarts the engine,
and **the live recognizer resumes** — the listener survives an engine restart.

*Still unverified:* the interruption path (no `AVAudioSession` on macOS, so a real
phone call is unexercised), a *genuine* tap stall as opposed to a simulated one, background
survival, battery cost of two recognizers over 4.5 hours, and the live pane itself —
it only renders while a round is recording and the simulator has no speech model.
**All of it needs a phone.**

**Bilingual capture — built *(2026-08-27)*.** `TranscriptionContext.locales` is plural
and defaults to `en-US` + `ko-KR`; `Utterance.locale` tags every line;
`TranscriptCoverage.locales` keys the cache on the locales that **actually ran**, not
the ones requested — otherwise a device with no Korean model marks every segment done
and the Korean half never transcribes, with nothing to show it was missing.
`golfctl transcribe --locale en-US,ko-KR`. Verified on a real recording: one pass,
both locales, 43× realtime.

**New requirement *(2026-08-27)*: English and Korean, automatically.** Measured, and
it settles the engine question rather than reopening it:

- **`en_US` silently drops every Korean utterance.** Absence, not garbage.
- **`ko_KR` transcribes both** but turns `보기`(bogey) into `고기`(meat), `파`(par)
  into `차`, and English names to mush. Not a shortcut.
- **Two `SpeechTranscriber`s in one `SpeechAnalyzer` both produce output.** That is
  the design: tag each utterance with its locale, keep both, let the model reconcile.
  Their errors are uncorrelated — the Korean model recovered "you're away" where the
  English one gave "your way".
- **Whisper is the wrong engine for this**: one language token per window, poor
  code-switching, and it *translates* rather than transcribes across a switch.
  **Parakeet has no Korean** at all, despite being the fastest option measured.
- **`contextualStrings` ignored by `SpeechTranscriber` by design** — it is a
  `DictationTranscriber` feature. Our 2026-08-26 negative result was correct and is
  not our bug. `DictationTranscriber` also carries a **`farField`** content hint with
  no `SpeechTranscriber` equivalent, which is worth measuring against Q12a as a third
  parallel module.

**E3 — Location modes.** `TrackingMode` (off/slow/fast) already exists in
`GolfSessionFormat` and `LiveLocation` already switches on screen presence. What
changes is `LocationRecorder`: slow by default during a round, fast while a hole view
is open, motion-gated per research §5. Update the voided invariant in CLAUDE.md and
PLAN §5 in the same commit as the code, or the file will still claim the opposite.

**~~E4 — Extraction, live tier.~~ Superseded 2026-08-27 by F5.** Haiku over HTTPS with
a BYO key becomes `FoundationModels` on device — no key, no network, no cost, and a
4,096-token window instead of 200,000. The two-tier split from D2 survives intact and
is in fact sharper: the on-device pass is the draft tier, and the cloud pass (E7)
remains the only tier `GolfEval` scores.

**E5 — The event list.** Folded into F4's middle band. Rows grouped by hole, confidence visible,
swipe to delete, tap to correct, a button to add. Every user touch writes provenance
`.user` and a `Correction` row. This is where the draft-not-answer invariant becomes
a screen.

**E6 — The hole-view overlay is smaller than it sounds.** `PlayerTrack` already
exists in `HoleStyle.swift` with `shots: [Coordinate]`, `aiming`, and four colours
chosen to separate against fairway green *and* against imagery; both renderers
already draw it. The missing pieces are the events→`PlayerTrack` feed, the bubble
variant, and the toggle (pin menu, persisted in `@AppStorage`).

**E7 — The authoritative reconstruction.** poc-plan Phase 3 as written: single call
over the whole round, self-verification (shot count vs announced score, turn order,
club vs distance, hole scores vs total), then `GolfEval` alongside it. Model chosen
by sweep on accuracy, not price — the spread is $0.10 to $0.51 a round.

### Order, and why

E0 → E1 → E2 → E3 → E4 → E5 → E6 → E7. E0 first because it can shrink E4. E3 is
independent of the transcription chain and can move whenever. E7 is the phase that
decides whether P1 is a product at all, and it is last because it needs recorded
rounds — **which is the real schedule driver: start recording real rounds as soon as
E2 lands, imperfect captures included.**


---

## Retired CLAUDE.md invariants — moved 2026-08-31

CLAUDE.md was compacted on 2026-08-31. These are the bullets that carried a struck-through
(`~~…~~`) claim — a rule that was reversed, voided, superseded or closed — copied here verbatim
as they stood before the compaction. **Every one of them is history.** Where a *finding* inside
one of these still constrains the code (the three failed z-order mechanisms, the fixed-threshold
VAD, the greedy split chain, `out tags geom`), that finding was kept in CLAUDE.md and CLAUDE.md
is the authority. Nothing here is guidance.

- **~~An untagged `golf=tee` polygon is dropped, not named "tee".~~ Reversed by the user on
  2026-08-30 — untagged tees are now adopted everywhere.** The rule was written when the cost
  looked like 11 of Corica's 100 polygons; at Coyote Creek it is **107 of 112, and 16 of 18 holes
  with no tee at all**, which is the hole view falling back to a centre line on a course OSM
  describes perfectly well. What survives is everything that kept a *phantom* tee out, and it is
  still load-bearing: a practice-named polygon is refused, a polygon inside a `golf=driving_range`
  is refused (`OSMCourse.inside`), `Reach.tee` still applies, and the name is marked
  **`TeeBox.inferredName`** all the way to the screen, where the hole box prints `~ White Tee` —
  the same mark an inferred tee *position* and a measured stand-in yardage get, and for the same
  reason: a different quantity, not a substitute. A *named* green ("Practice Putting Green") is
  still never a hole's green.
- **~~The live feed is duty-cycled; the recorded track is not.~~ Voided by the user
  on 2026-08-26** — the recorded track is duty-cycled too, from the start (TODO item
  16, plan D3). PLAN §5's full-rate baseline round will not be collected, so **the
  3–7× saving is permanently unmeasurable against a real before-number**: state it as
  an estimate wherever it is claimed, never as a measurement. `LocationRecorder` runs
  slow by default during a round and fast while a hole view is open; `LiveLocation`
  is unchanged.
- **~~Whisper is the wrong engine for this product.~~ Overruled by the user on
  2026-08-27; WhisperKit is now the engine.** The objections were real and two of
  the three still stand — one language token per 30-second window, and weak
  code-switching (HiKE: Whisper-Small 48.1% PIER at Korean-English switch points).
  **The third was the decisive one and it turned out to be a setting, not the
  model**: "it translates the minority language" is what `task = .transcribe`
  forbids, and that only takes effect through `usePrefillPrompt` — see the
  invariant below. Parakeet is still out on no Korean. Verified on real audio
  2026-08-27: Korean in, Korean out; English in, English out; language detected per
  phrase and never specified. What we give up versus the Apple path is the
  two-recognizers-over-one-audio arrangement, and with it any handling of a
  sentence that switches language mid-way.
- **~~Sending in Type mode ends the marker~~ — the send button is gone**
  *(user, 2026-08-28: "no send button (up arrow)")*. There were two ways to commit
  one sentence sitting a centimetre apart and behaving differently: the arrow refused
  an empty box, OK did not. OK is the only one now, and it still ends the marker, so
  the *effect* survives — what went is the second path to it. The dismiss branch went
  with the button: `send()`'s `if mode == .type { dismiss() }` had no caller left but
  `finish()`, which dismisses anyway, and a second dismiss path is how two buttons
  come to mean subtly different things. **Return is a return** — it was
  `.submitLabel(.send)` with `.onSubmit(send)`, so the key that looks like a newline
  on a three-line box filed the entry and closed the sheet.
- **~~"Find a course…" is on three screens, and the hole view is the one that matters
  least.~~** The hole view is reached *through* a course, so putting the finder only
  there would make it unreachable on the install that needs it — a fresh one with no
  course files. It is also in `RoundView`'s course section, which is where somebody
  starting a round discovers they have none, and in `RoundScreen`'s Round menu.
- **~~The simulated position is an overlay above the map, not an annotation in it.~~
  Reverted by the user the same day — see the two bullets below.** *(It was written
  for "I still can't pick and drag it when it's overlapped with markers", 2026-08-29:
  every marker on satellite carries its own gesture on a large transparent grab strip,
  and MapKit decides annotation stacking for itself, so `SatelliteHoleView
  .simulatedOverlay` put the marker in the `ZStack` above the whole map through
  `MapProxy.convert`. `simulatedOverlay` no longer exists.)* The reason it lost is
  worth keeping and is stated below: outside the map's content the marker stops being
  glued to the ground. A **real** fix was and still is an ordinary annotation —
  nothing drags it, so nothing can take its touch.
- **~~The position and the flag are re-added whenever the marker set changes.~~
  ~~While simulating, a pill within reach stands down.~~ Both reverted by the user on
  2026-08-30: "revert simulate marker z-order changes you just made" — and the answer
  to which, when asked, was "all of it".** `stackToken`, `promotion`,
  `yieldingMarkers` and `MarkerDisplay.stoodDown` are gone; the player and the flag
  are plain annotations again, in that order, flag last. **The findings survive the
  revert and are the reason not to try a fourth time without something new:**
  `_MapKit_SwiftUI` has **no z-order API for an `Annotation`** (checked against the
  iOS 26.5 interface — `mapOverlayLevel` exists and applies to
  `MapPolygon`/`MapPolyline` only); MapKit decides annotation stacking for itself, so
  declaration order is not a guarantee; an annotation *added later* does land on top,
  which is what the token exploited; and **none of that touches the gesture** — a
  pill carries its own `DragGesture` on a `contentShape`, so under `MarkerDisplay.on`
  it takes the touch whatever is painted above it. Three mechanisms have now been
  tried and reverted: the `ZStack` overlay (lost camera tracking through a pan), the
  token re-add, and the yielding rule. The **vector** layer orders drawing and
  hit-testing explicitly and has never had the problem.
  On **vector** the same order is explicit: `drawPin` moved from just after the
  markers to the very end, after `drawPlayer`. `hit` is deliberately **not** reordered
  to match — the drawn-is-tested rule is broken for the flag and only the flag,
  because the green is where a golfer taps to place a target and a flag that took
  those taps would be worse than one needing a second attempt to pick up.
- **~~A typed log carries no hole either.~~ Superseded 2026-08-28 by
  `LogEntry.HoleSource`** — see the next bullet. The *reasoning* was right and is
  preserved by it rather than abandoned: `hole` meant "nearest hole to a measured
  fix", `lat`/`lon`/`hAcc` sat beside it as the evidence, and one field carrying two
  claims with nothing able to tell them apart is what made a typed entry never show
  the `no hole` chip a spoken one did. The bullet's own escape hatch — "needs a
  discriminator on `LogEntry` first" — is what was built.
- **~~A log written from the hole view is filed with no hole~~ — it is filed on the
  hole being looked at** *(X14, user 2026-08-28)*. The objection was real and is
  answered rather than waived: `LogEntry.holeSource` is the discriminator the old
  rule demanded, and the hole is written `.user` so `LogPlacement` leaves it alone.
- **~~Fast tracking belongs to the Marker sheet, and to nothing else.~~ Reversed by
  the user on 2026-08-30: "fast track when gps hole view is on screen, slow when
  not".** The 2026-08-28 argument — a hole view is open for most of a round and
  reading a yardage does not need a fix a second — is now history, not guidance. Both
  the hole view and the Marker sheet escalate **both** feeds, and the resting state
  is unchanged: slow everywhere else, and slow is what an empty set of reasons means.
- **A player's shots are joined into a `PlayerTrack`, filtered to the hole on
  screen** *(X13, user 2026-08-28: "connect the player's shots with line")*. Three
  things the obvious version gets wrong, all of which are already rules elsewhere:
  ~~the **tee is prepended**~~ — **voided by the user on 2026-08-28** ("why a line to
  the first shot marker of a player. it should start from shot #1"). It drew a leg
  from the tee box to wherever the drive finished: the one leg on the hole nobody
  logged, in the same weight as the legs that were. **A track now starts at shot 1**
  and a one-shot player draws no line, which is the honest answer — a line needs two
  ends. The half that outlived it and had to go with it: both renderers drew the shot
  dots as `shots.dropFirst()`, which existed *only* to skip the tee, so leaving it
  would have erased shot 1's dot on both layers. A convention's consumer outliving
  the convention, the same shape as the press-and-hold branch that ate taps for a
  day. Caught by rendering a two-shot track, not by reading the diff.
  It is **ordered by shot number, not by time**, because the numbers are
  what a person assigned; and it is **filtered to this hole**, because
  `PlayerTrack.allPoints` feeds `VectorHoleView.extraPoints` which feeds the
  **framing fit** — a shot logged on the ninth would shrink the hole on screen to a
  dot to keep a point half a mile away in frame. That is the framing rule arriving by
  a new road.
- **~~`CourseOverview` is vector-only~~ — overruled by the user on 2026-08-28
  (X8: "meant gps satellite view with normal zoom, pan, etc. action"). The number is
  still the control.** *(X4 built it as a fixed vector canvas with no gestures at
  all; the imagery-would-be-unreadable argument was mine and it was wrong.)* It is
  now a MapKit `Map` on `.imagery` with pan, zoom and rotate. **What survives the
  overrule is the coverage rule**: the centre lines, tees, pins and numbers are all
  vector overlays drawn from the course file, so a course with no signal loses the
  photograph and keeps every hole, every number and every tap target. Nothing here
  may come to depend on the imagery having loaded. **Nothing is laid over the bottom
  of it** — Apple's logo and Legal link live there and `.mapControlVisibility` does
  not touch attribution; the hole view reserves space with `bottomReserve`, here the
  answer is to put nothing there. The `MKCoordinateRegion` span is **floored**, or a
  file with one placed hole frames a zero span. The thing naming a hole is still the
  thing you tap to go there — the same decision the scorecard makes, and why neither
  screen needs a hole picker.
- **~~Multipolygon relations are skipped by the OSM importer.~~ Closed 2026-08-30 — and it was
  half a parser gap and half a one-word query bug.** `Element.coordinates` now answers for a
  relation as well as a way, so nothing downstream knows which drew a fairway. The bullet used to
  say "walking `members` from `out geom`" was what remained; the *actual* blocker was that the
  query said `out tags geom`, a print mode in which a relation comes back with **`members` absent
  entirely** — measured, 28 relations and zero members between them. Corica went from **1 fairway
  outline to 18**, Coyote Creek from 0 to 18.
