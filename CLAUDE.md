# Marker — working notes for Claude

Golf round tracking and replay from **spoken logs + GPS**, for the whole group. Pre-alpha.
**Siri and Apple Intelligence were tried for one day and scrapped** *(user decision,
2026-08-27)*. All of that code is deleted — `LogShotIntent`, `MarkerShortcuts`,
`GolfIntelligence`, `CardImport`, `CardImportView`, `DarwinBridge`. Do not reintroduce either:
Siri is two turns per sentence and single-language (which fails the bilingual requirement
outright), and `FoundationModels` has ~4k of context including output, takes no image input, and
generated garbage on real input. TODO.md holds the defects in full.
**The app listens again as of 2026-08-27, recording is off by default, and the engine is
WhisperKit** *(both user decisions)*. A round starts silent; a **record button** opens a
microphone burst that writes an `.m4a` segment and runs Whisper live off the same tap. Tapping
again closes the segment and hands the audio session back. **There is still no model step** — a
committed phrase becomes a `LogEntry`, and extraction is the unbuilt cloud pass.

**The engine changed on 2026-08-27, and `docs/research-live-transcription.md` §7 — which
recommended keeping Apple's — is now history, not guidance.** The user chose WhisperKit with a
multilingual model, **never told a language** and **never asked to translate**. Those three
settings are the whole reason it works here and they live in one place,
`WhisperDecoding.options`. Apple's path is still built and still reachable
(`golfctl transcribe --asr apple`), because Phase 2 is a measurement and `Transcriber` is a
protocol for exactly that.
**Courses are mainly American** *(2026-08-26)* — that decides the OSM and distance-unit defaults
below, and Korean courses stay a supported secondary case rather than the design centre.
**Phase 1 (capture) is implemented and verified on macOS.** So is **Phase 2**
(`GolfTranscription`, both engines, file and live) — its *gate* is unpassed, not its code.
**Phase 6** (`GolfMap`) is built bar replay and the elevation profile, and Phase 3 is half
built: `AnthropicClient` is done and the reconstructor is not. Phases 4, 5 and 7 are
placeholders. The table under "What exists" is the authority.

Read [`docs/PLAN.md`](docs/PLAN.md) before proposing work. It is the product and architecture
layer; [`docs/research-game-tracking.md`](docs/research-game-tracking.md) is the feasibility
research behind it and [`docs/poc-plan-round-reconstruction.md`](docs/poc-plan-round-reconstruction.md)
is the PoC that gates P1.
[`docs/research-course-map.md`](docs/research-course-map.md) covers course geometry and the hole
view (P3) — read it before touching maps, course data, or imagery.
[`docs/research-live-transcription.md`](docs/research-live-transcription.md) covers live ASR and
the **English + Korean** requirement — read it before touching `GolfTranscription`, `AudioRecorder`,
or proposing a different speech engine. **It describes `golfctl`, not the app**, as of 2026-08-27
— and closing that gap is the current task. **§7 is the live one**: it re-ranks the engines for
the phone after Siri was scrapped and after the user relaxed multi-language to "good, not must",
and it reaches the same answer (keep the Apple two-locale path) for a different reason. §0 and §4
were written under the old premises; §7 says so at the top of §0.
[`docs/research-elevation.md`](docs/research-elevation.md) covers terrain, the plays-like number
and the datum trap behind it — read it before touching altitude, `HolePlane.unproject`'s missing
`alt`, or the elevation profile. **§7 steps 1–3 are built as of 2026-08-30** — the `Elevation`
grid, `golfctl course elevation` against USGS 3DEP, and the plays-like chip on the hole view.
Steps 4 (the profile) and 5 (Korea/GLO-30) are not. §0a is the measurement log and §0's findings
2a and 8 are the two things the build corrected.
[`docs/research-imagery-offline.md`](docs/research-imagery-offline.md) answers "cache the
satellite imagery before a round": **not from Apple or Google — the licence names that act** —
and points at public-domain NAIP orthoimagery as the storable alternative for US courses.
[`docs/research-scorecard-import.md`](docs/research-scorecard-import.md) covers where a course's
**card** (par / handicap / yardage) comes from and the two traps in it — read it before touching
`CourseCard`, `golfctl course import`, or the editor.

## Commands

```sh
swift build
swift test                                    # 473 tests (1 skipped), all green

# Record a round from the Mac — the Phase 1 gate, no phone needed.
swift run golfctl record --out Sessions --players steve,dave --course "Naelgol CC"
swift run golfctl record --out Sessions --seconds 60 --no-gps   # headless
# --live transcribes while it records, off the same tap that writes the .m4a.
swift run golfctl record --out Sessions --live [--live-volatile] [--locale en-US,ko-KR]
# --mic-off starts silent, the way the app does; `r ENTER` then starts and stops
# recording during the round. **This is the only machine the burst path can be
# watched on** — each r opens a segment, closes it with a true t1, and starts a
# fresh recognizer, which is the sequence the record button rides on.
swift run golfctl record --out Sessions --mic-off --live
swift run golfctl inspect Sessions/session-2026-08-24-1430

# Transcribe a recorded round on device or Mac — on-device ASR, macOS/iOS 26.
# Caches per audio segment, so re-running does only what is missing.
swift run golfctl transcribe Sessions/session-2026-08-24-1430
swift run golfctl transcribe <session> --asr whisperkit --model openai_whisper-small
swift run golfctl transcribe <session> --asr apple --force --locale en-US,ko-KR

# Which Whisper models can be run. English-only builds are deliberately absent.
swift run golfctl models
# Replay a file through the **live** path in real time — the only way to watch the
# rolling-window wrapper work without a microphone. Without --realtime the whole
# file arrives at once and only the committed lines appear.
swift run golfctl live recording.m4a --realtime [--model VARIANT]
# Re-read one stretch of a recording with a chosen model — the CLI half of the
# app's "Transcribe again" button, and the only place that path can be watched here.
swift run golfctl relisten recording.m4a --from 4.5 --to 7 --model openai_whisper-small
swift run golfctl relisten recording.m4a --players 'steve,dave'   # +roster prompt
swift run golfctl transcribe <session> --show-vocab      # what the recognizer is told
swift run golfctl transcribe <session> --no-vocab        # the A/B; see the invariant

# Course geometry — what the hole view draws from.
swift run golfctl course sample --out Courses      # writes the built-in sample
swift run golfctl course show Courses/naelgol-cc.json [--hole 7]

# Course geometry from OpenStreetMap — holes, greens, tee boxes, bunkers, water.
# Never yardage. Covers about half of US courses; ~3% of Korean ones.
swift run golfctl course osm --name "Corica Park" --dry-run          # list the courses at a site
swift run golfctl course osm --name "Corica Park" --id corica-park-south \
    --name-as "Corica Park South" --out Courses
# --at <lat,lon> [--radius m] and --bbox <s,w,n,e> when the name does not resolve.
# --course <n> picks one of several at a site (default: the largest).

# Terrain — USGS 3DEP, US only. Writes Courses/<id>.dem beside the course file.
# Prints native resolution, relief, voids, coverage and per-hole tee-to-green rise.
swift run golfctl course elevation Courses/coyote-creek-golf-club-tournament-course.json
# --spacing metres between posts (default 3), --pad margin round the course (default 150).

# Scorecard import — par, handicap, per-tee yardage. Never coordinates.
swift run golfctl course import --url https://www.angelesnational.com/aboutus/scorecard/ --fetch-only
swift run golfctl course import --url <page> --name "Angeles National" --out Courses [--merge]
swift run golfctl course import --card card.jpg --name "Pebble Beach"   # photograph at the tee
# --unit metres|yards overrides; --unit-default flips the assumption (default: yards, US cards).
# needs ANTHROPIC_API_KEY; --fetch-only stops before the model and needs nothing.

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
computed property. A bool renders a red ✗ next to Location before anyone has been *asked*;
a computed property never refreshes after the user answers a prompt, so the row stays on "?"
forever and the app looks like it never asked. Keep `RoundViewModel.Capability.Status`
(`ready` / `willAsk` / `denied` / `unavailable`), keep `capabilities` published, and call
`refreshCapabilities()` on appear, on `scenePhase == .active`, and after every request.
**`canStart` no longer gates on permission at all** *(2026-08-27)*: a round with no fixes still
records logs, marks and motion, and `LogEntry.hasPosition` makes a coordinate-less log a real
row rather than an error. Refusing to start would throw the sentences away too.

**Permission is requested from the capability row, not only from Start.** Gating the prompt
behind "fill in the roster first, then tap Start" is what made it look like the app never
asked. Rows are tappable; denied rows open Settings.

**`LocationPermissionMonitor.escalate()` must return early unless `wantsAlways`.** Assigning
the `CLLocationManager` delegate fires `locationManagerDidChangeAuthorization` immediately, so
without that guard the app throws a location dialog on launch before the user has typed a name.

**Players are `Player`, not `String`** — an id and **one** display name. `Player.aliases` and
`allNames` existed until **2026-08-31 and were removed by the user** ("no nick name part for
player names"); the removal is decode-safe (an `aliases` key in an old `meta.json`, journal row
or export is an unknown key `JSONDecoder` ignores) and it is total — the field, the journal
act's parameter, `RoundExport`, `TranscriptionContext.names` and the CLI's `name=alias|alias`
syntax all went, because a syntax still accepted and no longer doing anything is worse than one
that is gone (`--players` now *refuses* an `=`). What survives is the reason the type exists:
attribution matches on the **name**, never on a roster position — a removal slides every later
slot down one, so an index would go on answering under somebody else's name.
`Mark.player` / `Correction.player` / `LogEntry.player` store `Player.id` (defaults to `name`).
CLI syntax: `--players 'steve,dave'`. **The cost is real and is now a known gap**: diarization
was cut, so a spoken name is the only attribution signal there is, and a card or a sentence in
the other script than the roster now matches nobody — `CardReading` *reports* that as an
unmatched row rather than guessing.

**A new round starts with one player and an empty name** *(user, 2026-08-31)*. `RoundViewModel`
no longer restores the previous roster from `UserDefaults` (`playerDrafts.v1` is neither read
nor written, and nothing migrates it). The old behaviour made Start live the instant the screen
appeared, over names nobody had looked at, so a round played with a different group recorded the
old one. An empty row cannot be started by accident: `canStart` is `!players.isEmpty` and a
draft with a blank name is not a player. **The free-text course name went too** (`marker`'s
`"course"` key): it is the other branch of the same screen, and on a phone with no course files
it came up pre-filled with a name nobody had looked at. What *is* still carried over is
`CourseLibrary.selectedID` — a picker showing the course by name, so what was remembered is
legible on screen rather than sitting in a box that looks freshly typed.

**A round is imported from the clipboard *or* a file, and the file half is not optional**
*(user, 2026-08-31)*. Export offers a `ShareLink`, so a round arrives by AirDrop, Mail or iCloud
Drive — as a **document**, which a clipboard cannot reach; without `.fileImporter` the only way
in was to open it elsewhere and hand-copy 400 KB of base64. Three things this depends on:
`startAccessingSecurityScopedResource()` (a URL from the picker is outside the container, and
reading without the scope fails with a permission error that reads exactly like a corrupt
export — balanced by `defer`, or it leaks a sandbox extension); the read being **off the main
actor**, since a file in iCloud Drive may still need downloading; and both roads ending in one
`decode(_:from:)` that sets `sourceName` itself, so a paste always clears it and "From
<file>" can never stand over a round that arrived another way. The old `TextEditor` is **gone**
— it grew to fit a 400 KB paste and pushed the Import button off screen, and once a file could
be chosen it was a blank void under two working buttons; what it really guarded, a paste
failing in silence, is now an **empty clipboard reported out loud**.

**`RoundBundle.currentVersion` is 2, and the rule for moving it is which direction breaks.**
An *added* key (`CourseData.terrainOmitted`) is invisible to an older reader, so bumping for one
would make that reader refuse — "update the app" — a document it reads perfectly. A *removed
non-optional* property (`Player.aliases`) is a hard break the other way: the older reader hits
`keyNotFound` and reports a missing field of **ours**, which is the confusion `BundleText`'s
`Envelope` probe exists to prevent, arriving from the far side. `isSupported` is
`version <= currentVersion`, so every v1 document still reads.

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
- **A card and geometry are two separate acquisitions, and no free source gives both.** A card
  (par / handicap / per-tee yardage) comes off a course's own web page or a photograph; coordinates
  come from a track, a survey, or the editor. `Hole` therefore represents *either* half alone:
  `Green.center` and `TeeBox.at` are optional, and **`Hole.hasGeometry` is checked before anything
  geometric**. Renderers take `HoleGeometry` (from `Hole.geometry(tee:)`), never a raw `Hole` —
  `HolePlane` is unguarded arithmetic, so a nil-coalesced coordinate would draw the hole at the
  equator instead of failing. research-scorecard-import.md §5.
- **A card's distance unit is usually not printed, and it cannot be recovered from the numbers.**
  Six real cards, sorted by length per par (research-scorecard-import.md §3.1): the one metric card
  sits *between* two imperial ones, and an ordinary American middle-tee set sits below all of them.
  **No threshold separates them**, and an earlier "infer it from the total, refuse in the ambiguous
  band" design refused the modal American card while still mis-reading the metric one. So:
  `TeeBox.distance` is **always metres**, normalised once at import; the unit is resolved
  `--unit` → printed on the card → **`DistanceUnit.assumedWhenUnstated` = `.yards`**; an assumed
  unit is announced as assumed and then *falsified* by `HoleGeometry.lengthDisagreement` the moment
  a tee and green are placed (a metric card read as yards is 9.4% short, far past the 25 m flag).
  Do not try to make the inference smarter — that was measured and it does not work.
- **An American card has two stroke-index rows.** Men's and women's are different allocations, and
  **both are valid 1…18 permutations**, so a single `handicap` field picks a column and nothing
  downstream can tell. `Hole.handicap` is the men's row (or the only row), `Hole.handicapWomen` the
  second; both are permutation-checked separately. `TeeBox.rating`/`.slope` capture the USGA
  numbers every American card prints — not a unit detector, since metric cards carry them too.
- **`CardText.strip` is correctness code, not plumbing.** A real card
  (angelesnational.com) writes hole 4's stroke index as `1<span class="style1">7</span>`; replacing
  inline tags with a space splits it into `1 7`, shifts the whole row, and still yields eighteen
  plausible numbers. Inline tags are **deleted**, source whitespace is flattened **first**, and
  `</td>`/`</tr>` become tabs and newlines **before** the tags are gone, so an empty cell stays an
  empty column. research-scorecard-import.md §3.4.
- **`Hole.ref` is not a key — `Hole.id` is.** Korean 18s are two of three named nines, each
  numbered 1–9 (천룡: 황룡/청룡/흑룡). `Hole.nine` plus `ref` makes the composite id. Look holes up
  with `course.hole("황룡/3")` or `hole(nine:ref:)`.
- **Re-importing a card must never destroy placed coordinates.** `Course.merging(card:)` takes par
  and yardage from the new card, keeps every `at` and `green.center` already placed, keeps tees that
  exist only in the old file, and keeps holes the new card does not mention — importing one nine of
  a 27 must not delete the other two.
- **Where course geometry comes from is regional, and the two answers are opposite.** Measured
  (research-course-map.md §2.1): the US has **150,178 `golf=hole` ways covering ~7,900 courses —
  about half of all US facilities**, with `ref` on 98% and `par` on 89%. Korea has 597 ways
  covering 28 courses, ~3%. *So in the US, check OSM first; in Korea, expect nothing and derive
  from the recorded track.* **An earlier version of this file said "not from OSM … do not re-plan
  around OSM" as an absolute — that was measured on Korea only and is wrong for the primary
  market.** The track path stays primary wherever OSM is thin and is the only one that improves
  per round.
- **OSM-derived geometry is ODbL, and in the US that will be most files.** Share-alike is now the
  normal case rather than an edge case — a stronger constraint than the `traced` marking and one
  that applies to the majority. `Course.Source.osm` and per-hole `Hole.source` model it; nothing
  enforces it yet.
- **Nothing in OSM links a green to a hole, so every association is geometric and exclusive.**
  There is no relation and no shared `ref` — at Corica Park 32 greens and 100 tee polygons carry no
  hole number at all. `OSMCourse` matches by distance, assigns nearest-pair-first so two holes can
  never claim one green, and **reports everything that failed to associate** instead of leaving a
  nil. A mis-assigned green produces a file that passes every structural check and reads a club and
  a half wrong; only `Candidate.measuredTotal` sees it.
- **A `golf=hole` way's direction is a convention, not a guarantee.** Orientation is decided from
  the data — whichever end sits nearer a green *is* the green end — because a reversed way renders
  the hole backwards with the camera pointing at the tee.
- **Splitting a site into courses is a per-ref matching, never a greedy chain.** Refs repeat: a 27
  has three holes called "1". The greedy "nearest next tee" chain was written first and it walked
  out of Corica's par-3 nine into the South Course's back nine, reporting a confident *18 holes,
  par 63*. Courses at a site are geographically interleaved, so a per-hole decision cannot see it
  has crossed. `OSMCourse.split` decides a whole hole *number* at once, matching all candidates to
  all routings by minimum total green-to-next-tee walk.
- **Verify an OSM import, never trust it.** Three independent checks, all run by `golfctl course
  osm`: a stroke index that is a complete 1…n permutation (where OSM tags `handicap` — 38% of US
  holes — it is a free labelled partition of the site); total measured length per par through
  `DistanceUnit.plausibility`; and `OSMCourse.teeAnomalies`. A wrong partition and a crossed green
  both look exactly like success.
- **A tee is checked against the course's own colour order, because length checks cannot see it.**
  `teeAnomalies` compares colours **pairwise** — is black longer than yellow — which is the same
  answer on every hole of a course and is exactly what a misassigned tee breaks. It caught three
  real faults on the first real import (Corica holes 3, 8, 17; on 8 and 17 a yellow polygon 64 m
  *behind* the black tee was the nearest yellow to that hole's tee end). The black-tee length still
  matched the raw OSM way to the metre, so only someone playing yellows would ever have found out.
  Rank position and share-of-back-tee were both tried first and both fail: rank is not comparable
  between a five-tee hole and a three-tee one, and a share cascades — once a stray tee is the
  longest on a hole, every other tee there looks short and four false alarms follow the one fault.
  **It reports and never corrects**: geometry cannot tell a real back tee from a neighbour's, and
  silently deleting a tee that turned out to be real is the worse error.
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
- **An adopted tee's name comes from the length order, against one ramp chosen for the whole
  course.** `TeeBox.ramp(of:)` degrades by dropping the middles — five tees give
  black/blue/white/gold/red, four give black/blue/white/red, which is what American cards print —
  and `TeeBox.standardRamp` is the single source `TeePalette.standard` reads its *names* from, so
  the two cannot drift into a course whose "blue" tee is painted green. **The ramp is per course, sized to *every* tee on
  the widest hole that has an adopted one — never per hole, never from a modal count, and never
  from the adopted count alone**: a per-hole ramp makes the third-longest tee "white"
  on a five-tee hole and "red" on a three-tee one, and `marker.tee.<courseID>` remembers a *name* —
  so the hole view would lose its yardages on exactly the holes where that name did not exist.
  Two narrower sizings were tried and both produced a `tee N` on a real file: the *modal total*
  gave `tee 5` on Coyote Creek's one five-tee hole, and the *adopted count alone* gave Corica a
  one-entry ramp whose single entry a tagged black tee had already taken — a ramp entry a tagged
  tee holds is skipped, so a hole with one tagged and one adopted tee needs two entries to name
  one. `TeePalette` reads `tee 2` as a non-colour name and blends its neighbours, and
  `marker.tee.<courseID>` persists the string. A name a tagged tee on the hole
  already uses is skipped rather than duplicated.
- **`inferredName` survives `Course.merging(card:)`, and that is deliberate.** A card confirms the
  course *has* a white tee; it says nothing about which polygon that is, and our name came from a
  rank in the length order. Dropping the mark on merge would put a printed yardage under an
  invented name with nothing on screen saying so — "no tee may answer with another tee's numbers"
  arriving by the one road nobody watches. `HoleGeometry.lengthDisagreement` is then the check.
- **`holesWithoutGreen` / `holesWithoutTee` are per candidate, not per site.** They were computed
  over every draft before the split, so a course with all its tees still listed *"no tee found for
  hole(s) 1, 2, 2, 3 …"* — the duplicates being the **other** course at the site, whose refs
  repeat. In `golfctl` that is a confusing line; in `CourseFinder` `report.lines` **is** the row a
  golfer reads in front of Save, which is the one place an import that reads a club and a half
  wrong is meant to be caught, and a check that cries wolf about holes that are fine is a check
  nobody reads.
- **A tee whose own label names a hole goes to that hole, and only that hole.** Coyote Creek tags
  five tees "Hole 1 Black" … "Hole 1 Red"; proximity put four on hole 1 and **the red one on hole
  13** — an ordinary-looking file, a hole out for anyone playing the reds. A surveyor writing the
  number down beats a centroid being nearest, so a stated hole narrows the candidates to one and an
  out-of-reach tee is dropped and counted rather than falling back to the guess this exists to
  overrule. `Reach.namedTee` (300 m) is wider than `Reach.tee` because distance is then only a
  sanity bound — hole 1's red sits 113 m out — and anything past `Reach.tee` is reported.
  `OSMCourse.holeNumber(in:)` reads **the first standalone number, not the word "hole"**: the white
  tee there is tagged `Holw 1 White`, and a surveyor's typo must not cost the number beside it.
- **`Report.teeAnomalies` is appended to, never assigned.** `assignTees` writes into it and
  `Candidate` used to overwrite it one line later — a report that exists to be read, deleted
  immediately after it was written.
- **Traced outlines are simplified to 1 m at import, and the centroid is taken before that.** A hole
  draws ~400 m in ~700 points (0.6 m/px) and a GPS fix is ±3–5 m, so 1 m is below anything
  downstream can resolve — Corica's 132 bunkers arrive as 4,610 vertices and 197 KB of a 240 KB
  file. Douglas–Peucker on a *ring* must split at the far vertex first: first and last are the same
  point, so the naive baseline is degenerate and the whole outline collapses to a triangle.
- **Tee names are matched case-insensitively when merging.** OSM tags `black`, an American card
  prints `BLACK`, the editor writes `Black`. `TeeBox.sameTee` also strips a trailing "Tee"/"Tees".
  An exact match silently drops every card tee's coordinate and leaves duplicates beside them — a
  merge that reports success and throws away the geometry it exists to preserve.
- **OSM never supplies yardage, in any region.** `dist` is on 0.3% of US hole ways and 1.8% of
  Korean ones; `handicap` on 38% and 6%. Geometry and par come from OSM where it exists; per-tee
  distance and stroke index always come from a card.
- **A course file is committable; a session is not.** `Courses/<id>.json` lives outside
  `Sessions/` and holds no voices and no credentials — a course does not change between rounds.
  The "never commit" rule below is about recordings and secrets.
- **A MARK-button survey must be *exported* before reconstruction sees it.** Course geometry is a
  legitimate model input — you cannot place a shot on a hole without knowing where the hole is —
  but `marks.jsonl` is still ground truth. `golfctl survey export` writes `Courses/<id>.json`;
  `GolfReconstruction` reads that file and never a session's marks. This is the one thing that
  crosses the firewall, and only in that direction.
- **This is private use — the user and their friends.** *(Stated 2026-08-26.)* Course files are not
  distributed, so **ODbL share-alike has nothing to discharge** and the "a traced file cannot be
  published" bar has no one to bind. Keep `Course.Source` anyway: one enum, zero cost, and it is the
  only thing that keeps publishing possible later — the moment a file leaves the group, both
  constraints come back exactly as written below. **What private use does *not* excuse is
  attribution** (next bullet). Read this as the terms, not as legal advice.
- **Imagery is MapKit `.imagery`, and it is decoration.** *(Decision 2026-08-24.)* No provider
  licenses persistent storage of map imagery — Google's terms bar offline use outright, Apple's licence
  agreement allows only temporary caching. So the hole view is **two layers**: vector
  rendered from the course file, which always works with no network and carries every number the
  golfer acts on, and MapKit imagery under it when there is signal. Nothing may depend on the
  imagery layer being present — **not for licensing reasons but for coverage**: courses have poor
  cell service and MapKit's cache is opaque and unguaranteed. Private use does not make imagery
  dependable.
- **Terrain is the third acquisition, and it behaves like geometry rather than like
  imagery.** *(Built 2026-08-30; research-elevation.md.)* A card gives par and yardage,
  OSM gives coordinates, and neither gives elevation — but a DEM is ours to store, does
  not change between rounds, and is public domain, so it goes in a file beside the course
  and works with no signal. `Elevation` (in `GolfCourse`, network-free) is the grid;
  `GolfTerrain` (`Elevation3DEP` + `GeoTIFF`) is the socket, split out for exactly the
  reason `GolfCourseOSM` was. The imagery rules above are unaffected and still apply to
  imagery.
- **An elevation difference comes from two samples of the *same* source, or it is not
  computed — and the type enforces it.** 3DEP is NAVD88 orthometric;
  `CLLocation.altitude` is above mean sea level and `ellipsoidalAltitude` is above the
  WGS84 ellipsoid, and those differ by roughly **−30 m in California**. Over a difference
  the datum cancels *only* if both ends share it, so one end from the DEM and one from the
  phone is a plays-like number thirty metres wrong that reads like an ordinary large
  number. So there is **no public `Double` height**: `Elevation.sample(at:)` returns a
  `Sample` carrying its `datum` and `source`, and `Sample.delta` **returns nil when the
  two disagree**. `Hole.elevationDelta(from:)` also **stopped reading the point's own
  `alt`** — it used to prefer it, which was correct only for a coordinate that came out of
  the course file and silently wrong for a fix. `RoundViewModel.here` already nils the
  altitude for this reason; relying on every future caller to remember is what the type
  removes. research-elevation.md §4.
- **The 3DEP request is made in EPSG:4326, and the grid is georeferenced from the returned
  raster, never from the bbox that was asked for.** Both measured 2026-08-30 and both
  produce a file that looks entirely correct. `imageSR=3857` hands back a pixel scale in
  *Mercator* units — 1/cos(37.2°) = **1.26× the ground metre** at Coyote Creek, which
  stored as metres displaces a sample by ~270 m at the far corner. And the service **snaps
  a requested box outward to whole posts**, by **146 m** in one measured call. Degrees also
  keep every projection out of `GolfCourse`: `Elevation` stores `lat0/lon0/dLat/dLon` and
  sampling is two divisions. The consequence is that posts are **not square on the
  ground** — 2.2 m east against 2.8 m north at that latitude — which a bilinear sample does
  not care about and `nativePosts` reports for anything that does.
- **`format=tiff`, never `format=bsq`.** The headerless raw dump returned **990,000 bytes
  for a 300 × 800 request** — 247,500 floats, not 240,000 — while `f=json` for the same
  call said 300 × 800. A raster whose dimensions have to be inferred from a byte count is
  one transposed grid away from a course file that is silently a hole out of place. TIFF
  states its own width, height, tiling and georeferencing, and `GeoTIFF` reads all of it
  from the file. 3DEP returns **tiled** 128 × 128 F32; the stripped path exists because the
  layout is the service's choice and a stripped file would otherwise decode as an empty
  grid rather than as an error.
- **The native resolution is asked for separately, because `exportImage` will not say.**
  It resamples 1/3 arc-second data onto a 3 m grid without comment, and the result is
  byte-identical in shape to one built over lidar — a metre of vertical error against ten
  centimetres. `Elevation3DEP.resolution(atLat:lon:)` hits the point service once at the
  centre of the course and the answer is stored on the grid. Same rule as a guessed par
  being indistinguishable from a surveyed one. **The vertical datum is not in the raster
  either** — the geokeys describe the *horizontal* CRS — so `.navd88` is asserted by the
  fetcher from the product it requested and written into the file.
- **A void poisons its interpolation, and a zero-weight corner is not consulted.** A
  bilinear average of a known height with an unknown one is a number nothing measured, so
  any void with weight makes the whole sample nil. But a corner with *zero* weight cannot
  affect the answer, and requiring it made a point sitting exactly on a known post return
  nil whenever the post diagonally next to it was a void — a hole beside water losing its
  number for no visible reason. `sample(at:)` also clamps within a millionth of a post:
  a point derived from the grid's own corner lands a few ulps outside it (measured, the
  last row of an 8 × 6 grid came out at 5.0000000001).
- **`playsLike = distance + rise`, one for one, and that is the *researched* answer
  rather than a guess** *(user, 2026-08-30: "research and use whatever most popular")*.
  Every general-audience source says it in the same words — one yard per yard of
  elevation — and the variants that put numbers on it land within 15%: a ballistics
  simulation gives 20 yd uphill costing 21 and 20 yd downhill gaining 18, and a common
  rule of thumb gives +8 yd per 25 ft up against drop ÷ 3.5 down. **The asymmetry is
  real** (≈1.0 up, ≈0.86–0.90 down) and is smaller than a GPS fix's own error over these
  distances, so `Geodesy.playsLike`'s `factor` stays 1 and the asymmetry is the first
  thing to try when E3 gets data. No rangefinder maker publishes their adjustment, so
  there is nothing to match and nothing to check against. research-elevation.md §5.
- **Plays-like carries a `~`; the rise does not.** The rise is *measured* — 3DEP lidar,
  10 cm spec — and the plays-like number is a model, so it takes the same mark
  `CardYardage` puts on a measured length standing in for a card number: a different
  quantity, not a substitute. One formatter, `DistanceDisplay.plays`, because the same
  expression is drawn in four places and four hand-built strings is four chances for one
  to round differently or point the arrow the wrong way.
- **No number on the hole carries its unit** *(user, 2026-08-30: "No YD")*. It is stated
  once, in the caption under the big distance — `YARDS TO GREEN`. The vector layer's leg
  labels already followed this and said so in a comment; the **satellite** leg box, the
  rulers on both layers and the tee tray did not. Repeating `YD` on a number drawn over a
  hole is three more characters of box for something the screen has already said.
- **The plays-like arithmetic is done in the units the numbers are printed in.** Doing it
  in metres and rounding afterwards puts three numbers on screen that **do not add up**: a
  0.49 m rise over 164 m rendered `180 ▲1 · ~180`, because the rise rounds *up* to a yard
  while the plays-like distance rounds *down* to the same 180. Found by screenshot on
  Corica hole 1 — it reads as an arithmetic error in the app, not as rounding. Since the
  model is 1:1, rounding first makes `distance + rise = plays like` exact on screen,
  always. The suffix is **nil when the rise rounds to nothing**, which is most of Corica:
  `▲0 · ~353` beside `353` is three claims that all say the same thing.
- **The elevation suffix is inline on the distance, in four places, and there is no
  capsule** *(user, 2026-08-30: "no separate orange box"; format restated the same day as
  `"<dist>.<plays like dist><up/down arrow><elevation>"`)*. **`333.~334▲1`** — the two
  distances sit together because they are the same quantity twice, what it measures and
  what it plays, and the rise trails as the *reason*. The `.` is the user's separator,
  given twice; `~` is what keeps `333.334` from reading as a decimal as well as marking
  the modelled half. On the
  big distance at the top, on **both** target legs, and on the leg between two shot
  markers. The orange pill it replaced was a second object saying something about a number
  three lines above it, which the eye had to join up. On the plan legs the box **grows
  with the text**, which is required rather than tolerated: the rectangle drawn is the
  rectangle the drag gesture tests, so it roughly triples and stays the handle for its
  target. `PlanLayout.advance` went from an estimated **0.6 to a measured 0.618** at the
  same time — `NSFont.monospacedSystemFont` reports 0.618 em for every glyph these labels
  use, `▲ ▼ · ~` included (so none of them falls back to a proportional face), and at 0.6
  the box ran 3% narrow: absorbed by `padX` at three characters, not at thirty.
- **The big distance stays centred whatever the suffix does, and the suffix is placed by
  arithmetic** *(user, 2026-08-30: "main number stays in the center regardless of plays
  like dist, and plays like dist shows on the right")*. An `HStack` centres the *pair*, so
  the one yardage a golfer reads at a glance slid sideways the moment a hole stopped being
  flat and slid back on the next level lie. `HoleScreen.bigDistance` draws the number
  alone and hangs the suffix in an `.overlay` offset by a **measured monospaced advance**
  (`PlanLayout.advance`), the same technique `PlanLayout` and `measureLabelRects` already
  rely on. The obvious `.overlay(alignment: .bottomTrailing)` with the child's `trailing`
  guide resolved at its own `leading` — which should sit it just outside — landed it *on*
  the number instead: screenshotted, `.~97▼4` written across the `1` of `101`. The gap is
  **zero**, because a 20-point `.` beside a 68-point digit already has that glyph's right
  sidebearing between them and anything more orphaned the dot. **Verified by measurement,
  not by eye**: the same hole rendered with the `.dem` removed and with it puts the big
  number's left edge at 35.24% and 35.27% of screen width — identical inside a third of a
  pixel, against 21.98% on the `HStack` build. `PlanLayout.advance` is load-bearing in
  three places now, and a test pins it against `NSFont.monospacedSystemFont` at 14, 20 and
  68 points.
- **`HoleReadout.Leg.rise` is per leg, not one number for the hole.** A layup over a ridge
  and the approach down off it are two different shots, and one hole-wide rise would
  describe neither; the legs partition the tee-to-green climb exactly.
  `HoleReadout.rise` is then the **approach leg's**, read back rather than derived a
  second time — two derivations of one number is two numbers that can differ. It is
  measured from the **last waypoint** to the flag, matching `green.center`, because a rise
  from where the golfer stands and a distance from their layup target are two halves of
  two different shots. `riseSource` is nil when the number came from the course file's own
  altitudes rather than from a stored grid.
- **A shot-marker leg's rise is sampled in the renderer, and it is the only one that is.**
  Every other elevation number on the hole arrives already resolved on `readout`; a track
  leg is not part of the plan, so nothing upstream computed it. `VectorHoleView.terrain`
  and `SatelliteHoleView.terrain` exist for that one lookup. It is also the only place the
  plays-like figure can ever be checked against a shot somebody actually hit.
- **Terrain is downloaded by a button, not by the importer** *(user decision,
  2026-08-30)*. `CourseFinder` stays geometry-only: a DEM is another request, three
  quarters of a megabyte, 6–15 s, and it finds **nothing at all outside the United
  States** — a golfer searching for a course is answering a different question.
  `TerrainSheet` is its own step in the course menu, and the cost of that split is the one
  thing the sheet says out loud: **do it before the round**, because a course has no
  signal. **The three checks are the sheet, not a detail behind it** — same rule
  `CourseFinder` follows and a sharper reason here, since a grid built over 1/3
  arc-second data instead of lidar, or one clipping a corner of the course, is
  byte-identical in shape to a good one.
- **`Text` parses markdown only from a `LocalizedStringKey`, so `"a" + "b"` does not.**
  `TerrainSheet`'s footer concatenated its strings and rendered `**United States only**`
  as literal asterisks. One literal fixes it. Caught by screenshot, which is the only way
  it could have been.
- **The terrain sidecar is `Courses/<id>.dem`, and the extension is load-bearing.**
  `CourseStore.loadAll()` decodes **every `.json`** in the directory as a `Course`, so a
  sidecar named `<id>.elevation.json` would be a file that fails to parse on every scan.
  Separate from the course file because a grid is hundreds of kilobytes of base64 and a
  course file is read and edited by hand. Missing is the ordinary case — no course
  imported before 2026-08-30 has terrain and Korea has no source at all — and missing
  simply means the plays-like chip does not appear.
- **Store coordinates, never tiles — and the line is deliberate persistence, not disk.** A course
  file holds `Coordinate`s; imagery is fetched at display time by `Map(.mapStyle(.imagery))` and
  cached by MapKit however it likes. That is the *supported* use and needs no change. What crosses
  the line is a deliberate persistence step: **`MKMapSnapshotter` writing a PNG per hole**, or
  panning the camera over all eighteen on load to warm the cache. That is the offline store the
  terms exclude, and `MKMapSnapshotter` is exactly what someone reaches for after reading "cache
  the imagery". Don't. **Asked again on 2026-08-29 ("cache satellite images before round for all
  zoom levels") and answered the same way**, with the alternative written up:
  [`docs/research-imagery-offline.md`](docs/research-imagery-offline.md). If a photograph has to
  survive a round with no signal, it comes from **public-domain NAIP orthoimagery stored as our
  own asset**, not from a provider's tiles — a different feature, and the only one that survives
  the constraint.
- **Apple's logo and Legal link are not optional, private use included.** They bind any app that
  displays MapKit, and `.mapControlVisibility(.hidden)` suppresses the compass and scale, *not*
  attribution. `SatelliteHoleView`'s `.safeAreaPadding(.bottom, bottomReserve)` — 110 by
  default, plus whatever `HoleScreen`'s bottom bar measures — and `CourseEditorView`'s
  measured `panelHeight`/`bottomInset` exist to keep them uncovered — and so do the comments saying
  so, or the padding reads as dead weight and gets deleted.
- **Hand-placing points on Apple imagery is allowed; bulk tracing and redistribution are not.**
  *(The earlier flat rule "never trace a course from Google or Apple imagery" was **narrowed by the
  user on 2026-08-26**.)* `CourseEditorView` places a tee and a green centre by tap on MapKit
  imagery, because that is what makes a card-only course usable. The consequence is enforced in
  code and must stay enforced: a hole placed **by tap** is marked `source: .traced` and **a traced
  file cannot be published or shipped as data**, while a hole placed from the live GPS fix
  ("Standing here") is `.survey` — that path never touches imagery and stays ours outright. The
  file marking only ever gets more restrictive. Track-derived and survey-derived files are ours
  outright and are unaffected. Do not merge the two into one distributable file. Building a course
  *database* by tracing either provider's imagery remains out of the question.
- **Pan and zoom live inside `HolePlane.View`, never in a SwiftUI modifier.** A
  `.scaleEffect`/`.offset` on the `Canvas` moves the pixels while `project` and
  `unproject` keep describing the *unfitted* layout, so every tap lands somewhere
  other than the finger — and it looks perfectly correct until someone places a
  target while zoomed. `HolePlaneTests` asserts the round trip under pan and zoom.
- **`HolePlane.unproject` returns a coordinate with no altitude, deliberately —
  and that is now the right answer rather than a placeholder.**
  `Geodesy.coordinate(from:east:north:alt:)` defaults a nil altitude to the
  *origin's*, which would stamp the tee's elevation onto a point up the fairway and
  feed a plays-like number nothing measured. research-elevation.md §6 expected a DEM
  to be the thing that finally filled that field; it is not. A tapped point's height
  is looked up in `Elevation` **at the moment it is needed**, by whoever needs it,
  rather than baked onto a coordinate that then travels — because a `Coordinate`
  carrying an `alt` has no datum on it, which is the whole failure the grid exists to
  prevent.
- **Display units are formatting; storage is always metres.** `DistanceDisplay`
  applies yards or metres where a number becomes text. Nothing in `GolfCourse` knows
  about yards — same firewall `DistanceUnit` enforces at import. Default is yards.
- **A tee's colour comes from its place in the length order, not from its name.**
  `TeePalette` resolves longest-first: a colour name wins, a set with no colour names
  gets the standard ramp (black → blue → white → green → gold → red), and a
  non-colour tee among colours blends its neighbours — `Members` between blue and
  white is blue-white, which never collides and reads as "between those two". Outline
  colour is picked from fill luminance or `white` vanishes on a light green.
- **MARK is disabled while simulation mode is on.** *(Decided 2026-08-26.)* A dragged
  position is not a fix, and `marks.jsonl` is ground truth **and** `GolfEval`'s answer
  key. Disabling by construction beats a `simulated` flag every consumer must
  remember to filter — one that forgets corrupts an accuracy number silently. The
  simulated marker is also visually unmistakable (orange, dashed, a golfer glyph):
  a hand-placed position that renders like a fix makes every number a plausible lie.
  **That styling is now the *only* on-screen signal, so it is not decoration.**
  *(X11, user 2026-08-28: "'SIMULATED POSITION — drag it. MARK is off.' is
  unnecessary".)* The banner that used to say so out loud is gone — half of it was
  stale the moment MARK left the hole view, and the other half described the marker
  standing next to it. Do not tidy the orange dashes away as leftovers.
- **The hole view needs a position outside a round, and for a long time had none.**
  `LocationRecorder` is created by `RoundSession` and started by
  `RoundViewModel.startRound()`, so `here` was nil unless a round was recording and
  every distance silently fell back to the tee. `LiveLocation` (app target) is the
  round-independent feed for the view: it writes nothing, runs **fast** while a hole
  is on screen and **slow** otherwise, and **stands down while a round records** —
  the recorder owns the radio then, and two managers asking for Best is twice the
  power for one position.
- **`TrackingState` separates mode from phase, because they are different claims.**
  Mode (Off / Slow / Fast) is what the radio is doing; phase (Searching /
  Stabilising / Locked) is whether the number is worth clubbing off. A first fix
  arrives fast and can be hundreds of metres out — showing a yardage off it looks
  like the app working and is wrong by a hole. A lock takes three consecutive fixes
  inside 15 m, breaks on one bad fix, and **decays after 20 s** because under trees
  the last fix can be minutes old and was being presented as current. It lives in
  `GolfSessionFormat`, the zero-dependency contract, so `GolfMap` does not have to
  depend on the capture stack to draw a status dot.
- **~~The live feed is duty-cycled; the recorded track is not.~~ Voided by the user
  on 2026-08-26** — the recorded track is duty-cycled too, from the start (TODO item
  16, plan D3). PLAN §5's full-rate baseline round will not be collected, so **the
  3–7× saving is permanently unmeasurable against a real before-number**: state it as
  an estimate wherever it is claimed, never as a measurement. `LocationRecorder` runs
  slow by default during a round and fast while a hole view is open; `LiveLocation`
  is unchanged.
- **`PlanLayout` places the leg distance boxes, and drawing and hit-testing both go
  through it.** The box *is* the drag handle for its target — a 28-point ring is a
  poor thing to catch with a gloved thumb — so the rectangle filled and the
  rectangle tested must be the same rectangle. It measures text arithmetically
  rather than through `GraphicsContext.resolve` because the gesture has no context;
  a monospaced advance is fixed, so the estimate is exact enough to *be* the
  definition. The approach leg's box anchors at the **target** end of its line, not
  the flag end, or it reads as a label on the green rather than on the shot.
- **`HoleReadout.origin` and `HoleReadout.playerAt` answer different questions.**
  `origin` is what a distance is measured *from* and falls back to the tee when the
  fix is off this hole; `playerAt` is where the golfer actually is. Drawing the map
  marker from `origin` meant a fix off the hole drew no marker at all — so "go to my
  location" panned to an empty patch of rough, in precisely the case the button
  exists for. Draw from `playerAt`, dim it when `origin.isPlayer` is false.
- **A drag holds the gap between the finger and the object — `DragAnchor`.** Setting
  the object's centre to the fingertip on the first gesture event is placing, not
  dragging: picking a target up moves it before the drag starts, and nudging
  something by less than the grab offset becomes impossible. Measure once on finger
  down, derive every later position from it. Both layers do this; the satellite one
  works in degrees because `MapProxy` is what projects there.
- **The grab handle lives on `HoleStyle`, so both layers get the same one.** It was
  a `VectorHoleView` constant for a while and satellite kept a 34-point annotation,
  which made the target feel ungrabbable on that layer only. Draw it as **area with
  no edge**: an outline reads as an object in its own right and competes with the
  ring it sits behind.
- **A control that is invisible is indistinguishable from one that does not work.**
  The target drag handle was three times the ring and completely undrawn, and was
  reported as broken. It is now drawn at 5% fill — enough to find with a thumb, not
  enough to compete with the numbers.
- **The hole's framing is fitted to the hole, its tees and the round's shots — never
  to the player or the targets.** Both of those are placed *by looking at the
  screen*, so they are already on it. Feeding them to the fit caused three separate
  reported bugs at once: dragging a target re-fitted the plane so the hole slid the
  opposite way to the finger, dragging the simulated player did the same, and a fix
  off the hole shrank the hole toward a dot to keep a point in another county in
  frame.
- **Zoom is clamped; pan is not.** Holding pan to half a screen made "go to my
  location" impossible whenever the golfer was not standing on the hole they were
  looking at — which is most of the time, and exactly when they want to see where
  they are relative to it. *Fit hole to screen* in the pin menu is the recovery.
- **A target's drag handle is an invisible circle three times the drawn ring**,
  concentric with it. The distance box was tried as the handle and is worse than the
  ring: the box is repositioned as its number changes, so the handle crawls out from
  under the thumb mid-drag. Anything that moves while being dragged cannot be the
  thing you drag.
- **Simulation re-seeds on every switch-on**, from `HoleReadout.origin` — the same
  rule the numbers use. Carrying the previous point over meant switching it on
  anywhere but the hole on screen left the marker on another hole, so the readout
  fell back to the tee while the banner still claimed SIMULATED.
- **The top inset for the hole view comes from `statusBarManager`, not
  `safeAreaInsets.top`.** The view ignores the top safe area so the distance can run
  through the navigation bar's band to the edge of the display — which is exactly
  what makes the proxy report an inset of zero. The nav bar is made *transparent*,
  never hidden: hiding it takes the back button and the course switcher with it.
- **`HolePlane.View.panY` is screen-oriented** — positive moves the hole *down*, the
  way `y` grows. The drag gesture negated it and the vector layer scrolled against
  the finger; the convention belongs on the type, not in whichever gesture sets it.
- **The `HoleScreen` call in `CourseView` is written in declaration order with
  pre-typed locals.** It has enough defaulted parameters that letting the
  type-checker reorder them fails outright with "unable to type-check this
  expression in reasonable time".
- **The hole view has exactly one drag gesture, and it classifies itself.** Four
  competing gestures (drag, magnify, double-tap, tap) is what shipped first, and
  SwiftUI resolved the arbitration in the tap gestures' favour — **a drag starting on
  a target never reached the handler, so nothing on the hole could be moved at all.**
  `VectorHoleView.touch` is now a single `DragGesture(minimumDistance: 0)` deciding
  tap / hold / move-marker / pan from where the finger went down and how long it
  stayed, with only a two-finger `MagnifyGesture` alongside it. Do not add a fifth —
  "Fit hole to screen" lives in the pin menu for exactly this reason. **The two that
  are left still overlap**: a pinch drives the drag as well, which is what broke the
  zoom outright until `pinchBlockedDrag` — see the zoom invariant below.
- **Tap owns target 1, press-and-hold owns target 2.** Fixed slots, not "next free":
  a tap must never surprise anyone with a second target, and the first must stay
  adjustable with the cheapest gesture. On the satellite layer a marker is moved by
  a drag on the *annotation itself*, because a drag on the map surface is MapKit's
  pan and taking it over would cost the map the gesture it exists for.
- **A leg's distance is drawn on its own line, near the target end** — a number
  floating in a strip at the top has to be matched to its line by eye every time it
  is read. Labels de-collide against each other *and* against the target rings: the
  first attempt drew the 83-yard label straight through the 109-yard one.
- **Targets: tap places, tap-on-a-target removes, nothing is ever auto-placed.**
  research-course-display.md §9. Tap won the category and removal is undocumented in
  all of it; GolfLink auto-placed its crosshair into a grove of trees, which is why
  there is no default target. Two is the cap, and `HoleReadout` measures
  front/centre/back **from the last target**, not from the player — otherwise the
  target is decorative.
- **A leg is a shot, so it is straight-line; `measuredLength` walks the dogleg.**
  Different numbers on purpose — Corica hole 1 is 469 yd on the card and 426 to the
  green from the same tee. Nobody carries the corner of a dogleg.
- **`HoleScreen` takes its target and simulation state as init parameters** so it can
  be *rendered* in any state. That is the only review available for a gesture-driven
  screen here: **scripted taps do not exist in this environment**, so every touch
  interaction in the hole view is unverified by a finger.
- **`ImageRenderer` cannot draw a SwiftUI `Menu`** — it comes out as a yellow
  prohibition box. Proven, not assumed: the same SF Symbol renders correctly outside
  a `Menu`. Do not chase it as a bug when reviewing screenshots.
- **`nil` means exactly one tee: `Hole.defaultTee`.** *(Fixed 2026-08-27.)* `defaultTee`
  preferred a tee *named* white while `geometry(tee:)` independently preferred the first tee
  with *coordinates* — two answers to "which tee does nil mean?". On Corica hole 1, where black,
  blue and white are all placed, `cardLength(from: nil)` meant white and `geometry(tee: nil)`
  meant black, so **`length(from: nil)` returned black's 483 m under white's name: 59 yards,
  four clubs, on hole 1 of the only real course file there is.** `defaultTee` now filters to
  placed tees first (so a card-only hole keeps its white and a placed-black hole keeps its hole
  view) and `geometry(tee:)` defers to it. Found by probing the real file after a screenshot
  disagreed with `golfctl course show`, not by reading either.
- **No tee may answer with another tee's numbers.** `cardLength(from:)` and `geometry(tee:)` both
  return nil for a tee that lacks the value asked for, rather than falling back to the longest or
  the first-placed tee. The fallback looked harmless and rendered another tee's distance under this
  tee's name, and framed the camera on a tee the screen was not labelled with.
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
- **The rounds list reads session folders; there is no database.** `SessionIndex`
  scans `Sessions/`, parses each `meta.json` and classifies it. A store in front of
  that would be a schema, a migration policy and a translation layer to draw a list
  out of data that is already durable. `GolfStore` (SwiftData) stays a Phase 5 /
  replay concern.
- **A round can be reopened, and Record is offered on a finished one.**
  *(User decision, 2026-08-27.)* A round does not end when the golfer stops
  talking — the scores get said on the way to the car park — and the alternative is
  a second folder holding half a hole. `RoundSession.resume()` clears `meta.end`,
  reopens the marks and corrections writers in append mode, restarts the sensors
  and leaves `start` alone. The round therefore reads **unfinished** while it runs
  again and `duration` is nil until it stops, which is the existing rule about
  inventing "now minus start", not a bug to fix later.
- **A resumed round must adopt the segments already on disk.** `segmentIndex`
  starts at -1 so a fresh round opens `audio-000.m4a`; a reopened one would
  otherwise open it *again* and overwrite the audio of the round being added to.
  `SessionFolder.lastAudioIndex` takes the maximum of the index rows **and** the
  `.m4a` files — a crash mid-segment deliberately leaves a file with no row, so
  reading the rows alone destroys an orphaned recording.
- **Reopening rewires the sensors, not just the writers.** `location.onFix` is what
  fills `here`, and `here` is what gives a log its coordinate; a reopen that only
  reopened the files would record and place nothing, which looks like working.
  Reopening also **refuses while another round is recording** — one microphone, and
  `SessionIndex.summaries(recordingID:)` assumes exactly one.
- **"Active rounds" is plural because of crash recovery, not concurrency.** One
  microphone and one `AVAudioSession` mean exactly one round can be *recording*, and
  only the running process knows which — hence `SessionIndex.summaries(recordingID:)`.
  What piles up is **`unfinished`**: `SessionMeta.end == nil`, i.e. the app was killed
  mid-round. Before the rounds list existed those folders were orphaned in silence.
- **`SessionIndex.closeOut` stamps the last evidence in the folder, never `now`.**
  The app died at some point and the clock ran on; stamping the present invents hours
  of round that were never recorded, and that number lands in every duration and
  every rate derived from it. `SessionSummary.duration` is `nil` for an unfinished
  round for the same reason — "now minus start" on a round killed three days ago
  reads as a three-day round, which looks exactly like a bug.
- **`Event.provenance` is a firewall, not a label.** `.model` is a proposal that may
  be fed back to the model as context; `.user` is what a person typed or corrected
  and is **GROUND TRUTH**, in the same sense `Mark` and `Correction` are. Incremental
  extraction naturally feeds prior events back as context, and one unfiltered pass
  puts the answer key in the prompt. **Every bundle builder reading `events.jsonl`
  goes through `Event.modelVisible(_:)`.** `Event.init` also drops `confidence` on a
  `.user` event: a person who typed a score is not expressing a probability, and
  storing one invites code that averages the two.
- **`events.jsonl` is the first mixed-provenance file, so `isGroundTruth == false` is
  the wrong question about it** — and wrong in the direction that leaks.
  `SessionFolder.File.mixedProvenance` names it explicitly; the check is per row, not
  per file. Events are append-only and a correction **supersedes** rather than
  rewrites (`Event.current(_:)` collapses for display) — the sequence is the labelled
  error set, same reasoning as `Correction`.
- **A round's course lives in its own `meta.json`; `CourseLibrary.selectedID` is a
  global preference.** Reading the round screen's title and the scorecard's pars from
  the library put *another* course's name and pars on this round — twice, in one
  screen. `RoundScreen.roundCourse` matches the library by the round's own course
  name and is nil when there is no file, which is the honest answer.
- **`RoundViewModel` owns the hardware; `RoundDocument` owns a folder.** There is one
  view model for the life of the app (one mic, one round recording) and any number of
  documents. Conflating them is what left the old single-screen shell unable to open a
  round that had already ended.
- **`ImageRenderer` cannot draw a `List` either** — not just a `Menu`. Both screens
  come back as the yellow prohibition box, so the rounds and round screens are
  reviewed by **screenshotting the real app in the simulator**: `DemoSeed` (DEBUG
  only) reads `marker.seed`, `marker.wipe`, `marker.open`, `marker.hole`,
  `marker.sheet` (`history` / `card` / `detail` / `marker` — a sheet only reachable
  through a menu is a sheet nobody can review before it ships), `marker.map`
  (push straight to the hole view, the only way to see `MarkerBar` there),
  `marker.course` (open the whole-course view on top of it — two menu taps deep, and
  `ImageRenderer` draws neither a `Menu` nor a MapKit `Map`, so there is no other way
  in), `marker.targets` (place targets as fractions along the hole,
  `-marker.targets 0.35,0.7` — a target is placed by *tapping*, and scripted taps do not
  exist here, so without it the two leg boxes and the plays-like suffix on each could only
  be reasoned about),
  `marker.terrain` + the value `fetch` (open the terrain sheet and **run the
  download** — same argument as the finder's query: it is behind the same `Menu`, and
  without the fetch only the empty sheet is reviewable, so the three checks in front of
  Save would ship unlooked-at),
  `marker.find` + `marker.find.query` (open the OSM course finder and **run the
  search** — it lives behind a `Menu`, and without the query only the empty sheet can
  be looked at, so the facility list, the candidate rows and the three checks in front
  of Save would ship unreviewed), `marker.simulate` (open the hole view with the
  simulated position **on** — it is
  switched on by a tool-column button and then dragged, so its layering, its z-order
  against the marker pills and its grab handle had all been changed twice on the
  user's report without anyone here ever seeing one on screen), and
  — since the record button — `marker.start` (start a round on launch and open it), `marker.record`
  (open the microphone burst too) and `marker.speech <path>` (feed that file to the
  recognizer **instead of the microphone**, looped: there is no way to speak into
  this simulator, so it is the only way the live pane can be looked at, and it
  drives the real `LiveTranscript` and the real `LogStore` rather than a mock), then
  `xcrun simctl io <device> screenshot`. That is closer to the truth than a render
  anyway; it is the actual app. **They are `UserDefaults` keys, so every one needs a
  value**: `-marker.seed YES -marker.open <session> -marker.hole 4`. A bare
  `-marker.seed` parses as nothing, the seed silently does not run, and the screen
  comes up on whatever was left in the container from a previous launch — which
  looks exactly like the change under review having no effect. Cost three rebuilds
  on 2026-08-27 before the argument, rather than the code, turned out to be wrong.
- **Diarization is not needed** *(user, 2026-08-26)*. Attribution is content-only —
  the model resolves who did what from what was said. Q12 is closed by decision, not
  measurement: no `SpeechTranscriber` diarization probe, no SpeakerKit, and
  `Utterance.speaker` simply stays nil. The bet is that corrections carry the load;
  **attribution accuracy is still the metric that decides the feature**, so watch it
  in `GolfEval`.
- **An ASR result is timed from the start of its own file; `AudioTimeline` puts it
  back on the session clock, per segment and never cumulatively.** "Segment 1 is
  600 s long so segment 2 starts at 600 s" is wrong, because **a segment boundary is
  a real gap in time** — segments close on an interruption, and the mic was shut for
  the length of that call. An accumulated offset silently compresses the round and
  every timestamp after the first interruption drifts by the total of all previous
  interruptions, with nothing downstream able to detect it. There is deliberately no
  API taking a list of segments. Verified on a two-segment fixture with a five-minute
  gap: the second segment lands at 305.32 s, not 5.32 s.
- **A window is clamped to its segment's end only when that end is known.** A decoder
  reports ranges a few ms past the last sample; an utterance ending after the
  recording did is a claim nothing supports. A segment with `t1 == nil` never closed
  (the crashed round) — nothing to clamp against, and substituting "now" would invent
  recording that never happened.
- **Transcription coverage is recorded explicitly, because a silent segment produces
  no utterances.** "Does any utterance fall in this segment's window" would mark a
  quiet stretch undone and re-transcribe it forever. `TranscriptCoverage`
  (`transcript.coverage.json`) also records **which transcriber and locale** produced
  it — Phase 2 is a comparison, and a cache that could not tell Apple from WhisperKit
  would serve one path's output for the other's run.
- **`AnalysisContext.contextualStrings` does nothing for `SpeechTranscriber`** —
  measured 2026-08-27 (identical output with the strings and without, over words the
  recognizer demonstrably fails on: "Chungmin" → "Chungman", "Naelgol" → "Nielgal"),
  and the cause is now known: **contextual strings are honoured by
  `DictationTranscriber` and ignored by `SpeechTranscriber`.** Not our bug. The code
  stays because it costs nothing and would apply to a `DictationTranscriber` module,
  but **nothing may depend on it**. Consequence: diarization was cut, so a spoken
  name is the *only* attribution signal, and this was the knob protecting it.
  **Name matching in the model step must be phonetic/fuzzy against the roster,
  never exact** — and since aliases were removed on 2026-08-31 there is exactly one
  name per player to match against, which makes it matter more, not less.
  research-live-transcription.md §2.5.
- **The round is bilingual, and one locale cannot cover it.** *(Requirement stated
  2026-08-27: English and Korean, automatically. Everything below is the **Apple**
  path, which is now the comparison arm rather than the app's engine — Whisper
  handles the same requirement by detecting per phrase instead. The measurement is
  what makes the bullet worth keeping: it is why an English-only model is never
  offered anywhere in this codebase.)* Measured: **`en_US` silently drops
  every Korean utterance** — not garbage, absence — and `ko_KR` transcribes both but
  turns `보기`(bogey) into `고기`(meat) and mangles English names. **Two
  `SpeechTranscriber`s, `en_US` and `ko_KR`, run simultaneously as two modules of one
  `SpeechAnalyzer` and both produce output.** That is the design, and it is built —
  `TranscriptionContext.locales` is plural and defaults to the pair. Tag each
  `Utterance` with the locale that produced it (`Utterance.locale`, canonical
  `en_US`) and **keep both transcripts — do not merge them in code**: their errors
  are uncorrelated (the Korean model recovered "you're away" where the English one
  produced "your way"), and the model step is the reconciler. Verified end to end
  2026-08-27 on a real recording: one pass, both locales, 43× realtime.
  research-live-transcription.md §0, §2.
- **`TranscriptCoverage.locales` is what actually *ran*, never what was asked for.**
  A bilingual round asks for `en_US` and `ko_KR`; on a device with no Korean model
  only English resolves. Recording the *request* would mark every segment done and
  the Korean half would never transcribe, on any later pass, with nothing to show it
  was missing — the same trap as the silent segment, one level up. So
  `Transcriber.effectiveLocales(for:)` resolves before a sample is read, the cache is
  keyed on the resolved *set*, and `Report.unavailableLocales` is printed out loud.
  An English-only pass over a bilingual round looks exactly like a round in which
  nobody spoke Korean.
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
- **Live transcription was an audio-plumbing problem, not a model problem, and the
  plumbing is now built** *(2026-08-27)*. `AudioRecorder` runs on `AVAudioEngine`:
  **one `installTap`, one converter per consumer.** The old `AVAudioRecorder`
  exposed no buffers at all, which is the only reason a round could not be
  transcribed until a segment closed; every engine, Apple's or otherwise, needs the
  same tap, so swapping the recognizer would not have avoided this. **The `.m4a`
  keeps being written whatever happens** — poc-plan Phase 2 compares two ASR paths
  over the same audio, and a discarded recording makes that unrunnable forever.
  Live transcription is additive to the file, never a replacement.
- **`AudioRecorder.listen(_:)` takes an `AudioTap` carrying its own format,
  because the file's format is not the analyzer's.** `SpeechAnalyzer
  .bestAvailableAudioFormat` names what it wants and it is not the 16 kHz mono the
  `.m4a` is written in. Ask for it; never assume. One converter per consumer off the
  one tap, each reused across buffers — a converter rebuilt per buffer re-primes its
  resampler and clicks at every tap boundary, twelve times a second, in a file
  nobody plays back until after the round.
- **Releasing the `AVAudioFile` is what finalises an `.m4a`, and it must happen
  before `closeSegment` returns.** `AVAudioRecorder.stop()` gave that for free; an
  `AVAudioFile` does not. Measured 2026-08-27: a file whose `AVAudioFile` is still
  alive **fails to open at all** (`ExtAudioFileOpenURL`), and even one that opens is
  missing the encoder's last frames — `length` read 45,056 before release and 45,880
  after. "Transcription only ever sees closed segments" assumes closed means
  *readable*, and the Transcribe button runs immediately after `stop()`.
- **Never pass `bufferStartTime` on live input.** Measured 2026-08-27: stamping each
  buffer with its wall-clock position produced one volatile word ("I"), repeated,
  and **no finalized results at all** over speech the same analyzer transcribes
  cleanly with the times left off. `SpeechAnalyzer` keeps its own clock by counting
  the samples it is handed; a second, jittering clock makes its input look
  overlapped. The mapping is done on the way *out* instead.
- **`LiveAudioClock` maps the live analyzer back onto the session clock, and it
  absorbs gaps rather than averaging them.** The analyzer's clock is "delivered
  samples", not elapsed time — the same number only while buffers keep arriving. A
  four-minute phone call stops delivery, the analyzer's clock does not advance, and
  every word afterwards lands four minutes early with nothing downstream able to
  tell. Each buffer is stamped on arrival and a drift past `gapTolerance` (1 s)
  moves the anchor. Same rule as `AudioTimeline`, one layer up: stamp, never
  accumulate.
- **The live transcript never writes `transcript.jsonl`, and that is the whole of
  the rule.** *(Sharpened 2026-08-27, when `LiveTranscript` was actually built —
  this bullet used to say it "writes nothing to the session folder", which is no
  longer true and was the wrong statement of the constraint.)* The authoritative
  transcript stays `SessionTranscriber` over the closed `.m4a`s: a file pass sees
  each segment whole, which is a better recognition problem than a stream, and
  Phase 2's ASR comparison is run over those files — a live pass standing in for
  them makes the comparison unrepeatable. What `LiveTranscript` **does** write is
  `log.jsonl`: a finalised sentence becomes a `LogEntry` with `source: .spoken`,
  which is what that case has always meant and the same stream the typed box
  writes to. A log is an observation, not ground truth, so it is model-visible by
  design and no firewall is crossed.
- **`task = .transcribe` is inert without `usePrefillPrompt = true`, and that is
  how Whisper translated anyway.** The task is not a switch the decoder reads — it
  is expressed *as* the `<|transcribe|>` token in the prefill, so turning the
  prefill off makes `.transcribe` a value nothing acts on. **Measured 2026-08-27:**
  Korean came back detected as `ko` and rendered in fluent English — "스티브가
  버디를 했어요" as "Steve did a Buddy". Translation, produced by the setting meant
  to forbid it, reported under the right language tag. `detectLanguage = true` is
  required for the same reason in the other direction: it defaults to
  `!usePrefillPrompt`, so with the prefill on it is `false`, which prefills
  `<|en|>` and drops Korean in silence. **The three options only work as a set**,
  they live in `WhisperDecoding.options`, and `WhisperOptionsTests` pins them.
- **One pass, one language, decided per 30-second frame.** This is the cost of the
  engine and no setting removes it: a sentence that switches language halfway is
  decided by whichever language most of it is in. It replaces the Apple path's
  two-recognizers-over-one-audio arrangement, so the "both locales write a log"
  rule is gone — there is now **one log per phrase**, tagged with the language
  Whisper detected. Nothing reconciles the logs against the later batch
  `transcript.jsonl` over the same audio; extraction reads the logs.
- **Do not ask Whisper what was said when nothing was said — gate on VAD.**
  Measured over 301,317 inferences on non-speech audio, Whisper hallucinates
  **40.3%** of the time and **"thank you" alone is 24.76%** of those; a VAD in front
  of it takes that to **0.2%** and *improves* WER (arXiv:2501.11378). The same paper
  measured Whisper's own knobs as barely helping — which is exactly what happened
  here: `noSpeechProb`/`avgLogprob` caught pure noise and let every realistic case
  through, and the user came back from a real round with "so many phantom thank
  you's". `WhisperVAD` gates the live path; `chunkingStrategy = .vad` does the file
  path. The output filters in `WhisperSilence` stay as the residue-catcher the same
  paper describes (VAD 0.2% → bag-of-hallucinations 0%), **not** as the fix.
- **The VAD threshold is relative to the window's own noise floor, and that is
  load-bearing.** `EnergyVAD`'s fixed 0.02 was tried first and **ate a whole spoken
  phrase**: quiet far-field speech at 0.031 peak over a 0.009 floor lost a third of
  its frames, and "Steve is away." vanished from a transcript. No absolute number is
  right in a wind gust and a car park at once. **The asymmetry is deliberate**: a
  frame wrongly called speech costs one hallucinated line the filters catch; a frame
  wrongly called silence costs what somebody said, permanently. So a window is
  declared speechless only when *nothing anywhere in it* stands out from its floor.
- **Whisper decides the language from the first 30-second frame, so leading
  non-speech decides it.** Measured 2026-08-27 on one English sample: clean speech
  with 4 s of digital silence either side → `en`; quiet noisy speech with no padding
  → `en`; quiet noisy speech *with* noisy padding → **`nn`** (Norwegian) plus a
  looping glyph hallucination. **Neither low SNR nor padding alone breaks it —
  noisy non-speech does**, and a golf course is never digitally silent. That was the
  user's "I spoke English and it came out Korean". The fix is the same VAD: leading
  non-speech is dropped **by advancing the window itself**, never by trimming a copy
  — a trimmed copy shifts every timestamp silently, which is the accumulation bug
  `AudioTimeline` exists to prevent, one level down.
- **`Utterance.locale` comes from the script the line is written in, not from what
  the model reported.** `ScriptLocale`: Hangul is Korean, Latin is not, and the text
  Whisper produced answers the question without ambiguity where its own per-frame
  language claim does not. A line with no letters ("240") keeps the model's answer,
  because a number is not evidence of a language.
- **Each segment carries the language of the result it came from, never
  `results.first`'s.** A pass over a long window returns several results, one per
  30-second frame, each with its own detected language. This still matters as the
  fallback for a line `ScriptLocale` cannot read.
- **English-only Whisper builds are never offered, and that is a correctness rule.**
  `.en` and `distil-*` cannot produce Korean at all and the failure is *silence* —
  indistinguishable from nobody having spoken, which is the same shape as `en_US`
  dropping Korean on the Apple path. `WhisperModels.isMultilingual` filters them
  out of the picker and out of `golfctl models`.
- **A model must be on the phone before the round, and the picker downloads it.**
  A course has no signal; leaving the download to the first tap loses exactly the
  words the button was pressed for. `WhisperEngine.download` is called when a model
  is selected, and `isDownloaded` decides whether the pane says *Downloading* or
  *Loading* — two very different waits that look identical if it just says
  "loading".
- **`downloadBase` must carry the `huggingface` component — WhisperKit only adds it
  to its own default.** `HubApi` reads `if let downloadBase { use it } else {
  documents.appending("huggingface") }`, then resolves a repo to
  `<downloadBase>/models/<repo>`. Passing a bare Application Support directory
  therefore wrote to `<base>/models/…` while this code looked in
  `<base>/huggingface/models/…`, **so the cache was never found and every launch
  re-downloaded half a gigabyte** *(reported twice, 2026-08-27)*. It survived one
  round of "fixing" because the simulator copy had been placed **by hand** at the
  path the wrong assumption expected — a real download with an explicit base had
  never once been made. The lesson is the general one: a path convention read off
  the library's source is fine, a path convention *inferred from where files
  happened to be* is not, and the check for it must exercise a real download.
  Pinned by `testDownloadBaseCarriesTheHuggingfaceComponent`.
- **Where the model is, is answered by looking, not by computing.**
  `WhisperEngine.modelFolder` prefers the folder `WhisperKit.download` actually
  *returned* (persisted per variant), then anywhere the weights really are —
  including the broken layout, so a phone that already downloaded under it adopts
  the model instead of fetching it again — and only then the canonical path.
  `bytesOnDisk` is surfaced in the picker for the same reason: "is it cached?" got
  the wrong answer twice from reasoning about paths, and a size on screen is a fact.
- **Pass `modelFolder` the moment the *weights* exist, not once everything does.**
  `setupModels` reads `if let modelFolder { use it } else if download { … }`, so
  supplying it short-circuits the weights download entirely and `download` then only
  governs the tokenizer. Gating on "weights **and** tokenizer" is what made the app
  **download the model twice** *(reported 2026-08-27)*: `download(model:)` fetches
  the weights and then loads, and at that instant the tokenizer is not there yet, so
  the check said "not downloaded", took the online path with no `modelFolder`, and
  pulled half a gigabyte again. The user watched it download, finish, and start
  over. `hasWeights` and `isDownloaded` are now separate questions.
- **Load offline-first, or a phone holding the model still fails on the course.**
  `WhisperKit` resolves a variant name against the model index **over the network**
  before it looks at disk, so `WhisperEngine.kit` passes `modelFolder` +
  `tokenizerFolder` and `download: false` whenever the files are already there.
  Seen exactly that way in the simulator with the network blocked: the weights were
  present and the error was a TLS failure. **The tokenizer is a separate download
  from a different repo** and is just as required — it is the half you do not
  notice until the first tee.
- **Models live in Application Support, not Documents.** `UIFileSharingEnabled`
  exposes Documents to Finder and the Files app — that is the whole device→Mac
  transfer story for session folders — and half a gigabyte of CoreML sitting next
  to them is clutter and an invitation to delete it. A model is a cache.
- **A coordinate without an accuracy is not a placed log.** `LogEntry.isPlaced`
  reads `hAcc ?? .infinity`, so handing `LogStore.append` a `Coordinate` and no
  `accuracy` leaves the log unplaced however good the fix was — and it then joins
  the convergence backlog to ask the radio, for fifteen seconds, for the position
  it was already given. Harmless while the typed box appended a row every few
  minutes; a bilingual burst appends one every few seconds. `RoundViewModel.fix`
  returns the pair, and **both** the typed box and `LiveTranscript` pass it.
- **The placement task is keyed on the *unplaced* logs, not on every log.**
  `.task(id:)` cancels and restarts on every change of its id, so keying it on all
  log ids meant an arriving log that needed no placement at all tore down a
  convergence fifteen seconds into its radio wait. Still keyed on **ids, not a
  count**: a delete and an arrival in the same reload leave the count identical,
  and convergence itself appends a superseding row that `current` collapses.
- **`LogPlacement.attempted` is given back when the attempt never ran.** The
  reservation is taken up front so two passes cannot converge one log at once, but
  a burst restarts that task often — and a log torn down before the radio ever ran
  would otherwise be marked attempted and **never placed at all**, silently and
  permanently. Returned only when nothing was tried: a convergence that ran and
  found nothing has had its turn, which is the whole reason `attempted` exists.
- **`AudioRecorder.onStateChange` is consumed, because the record button can
  otherwise lie.** An interruption closes the segment and sets `.interrupted`, and
  the resume is best-effort — if the OS declines, the round continues with a gap.
  Rendering only `isListening` leaves a red button counting up over nothing being
  written, the same class of error as drawing a simulated position like a fix.
  `RoundViewModel.audioState` publishes it and the button turns orange.
- **`NSSpeechRecognitionUsageDescription` is set even though `SpeechAnalyzer` may
  not need it.** `SFSpeechRecognizer` did; the on-device-only successor may not,
  and **the simulator cannot tell you** — with no speech model, a missing usage
  string and a missing model both surface as "unavailable". One line here against
  a TCC abort on the first burst of a real round, four holes from the car.
- **One log entry per recording, not per phrase** *(user decision, 2026-08-27)*.
  A burst is one thing the golfer did — pressed record, said what happened,
  stopped — so it reads as one row rather than as however many times they paused
  for breath. Grown by **superseding** rather than buffered until Stop: the row
  appears with the first phrase and a round that dies mid-burst keeps what was
  already said. Two consequences: a phantom line inside a three-minute entry costs
  a text edit rather than a swipe, which raises the stakes on the VAD work; and
  every supersede is a new id, so **extraction must read a burst entry when the
  burst ends, not while it grows**, or `ExtractionCoverage` re-reads the whole
  accumulated text on every phrase — the runaway shape that file exists to prevent.
- **Never extend a log from a cached copy — re-read the chain head from disk.**
  Two writers grow the same chain: `LiveTranscript` extends a burst's entry, and
  `LogPlacement.converge` appends a placed row when a fix arrives. Editing a stale
  copy forks the chain — two rows superseding one parent — and `LogEntry.current`
  keeps one head, so the coordinate convergence just spent fifteen seconds of radio
  acquiring is silently dropped. `LogStore.head(ofChainFrom:in:)`.
- **A live-derived log is written with no hole and no time of its own choosing.**
  Stamped with the *utterance's* start on the session clock (`LiveAudioClock` has
  already mapped it), not `now` — a sentence finalises after it was said. And no
  `hole`: that field means "nearest hole to a measured fix", and stamping the hole
  the card happens to be showing puts a second, unmeasured meaning in one field.
  `LogPlacement` fills in position and hole afterwards, the same path the typed
  box takes — written first, placed second.
- **Never compare two session-folder `URL`s with `==` — use `SessionFolder.isSame`.**
  `URL.appendingPathComponent(_:)` consults the filesystem and appends a trailing
  slash when the component names an **existing** directory. `RoundSession.create`
  builds its URL before `create()`; the round screen builds the same path
  afterwards; the two compare unequal. Measured 2026-08-27: the round screen's
  `LogStore.didAppend` guard dropped **every** refresh during a burst, so twenty-nine
  logs were on disk and the screen said "Nothing on this hole". It had never shown
  up before because the typed box appends to `doc.logs` in memory as well — the
  notification path was load-bearing for the first time only once the recognizer
  started writing.
- **`AudioRecorder.listen(nil)` clears the pending listener too, or it detaches
  nothing.** `stopEngine` deliberately parks the listener's *request* in
  `pendingListener` so a restart re-attaches it across an interruption — but a
  recording **burst** ends with the engine stopped and the listener already moved
  there, so clearing only `listener` left the finished burst's tap armed. The next
  `start()` then fed live buffers into a `LiveTranscriber` whose analyzer had
  already been finalised: no output, and nothing anywhere saying why. Found while
  wiring the toggle, fixed, and verified by two consecutive `golfctl` bursts each
  producing their own output.
- **A burst is torn down audio-first, then analyzer, then tap.** Stopping the audio
  first closes the segment with a real `t1` and stops the buffers; draining the
  analyzer second lets the last phrase finalise instead of being thrown away —
  which is the end of a hole, which is when scores get said; detaching the tap
  third is what keeps the next burst clean. Any other order loses something.
- **A fresh `LiveTranscriber` per burst, never one reused across a pause.**
  Reusing one means feeding a finalised analyzer, and `LiveAudioClock` would have
  to absorb a gap it saw no buffers for. A fresh analyzer seeds its clock from the
  first buffer of its own burst, so a ten-minute pause between bursts costs
  nothing to get right.
- **A hypothesis is shown and a commit is stored, and the split survived the engine
  change.** On the Apple path that was `.volatileResults` on live and off for files.
  Whisper has no such distinction of its own, so `WhisperLiveTranscriber` *makes*
  one: a rolling window is re-decoded every pass and published as a hypothesis, and
  a phrase is committed at a silence. The reason is unchanged — a caption that only
  appears when a phrase finalises looks like an app that is not listening, and a
  file full of rewritten hypotheses is not a transcript. A non-final line is drawn
  dimmed and italic and **is never stored**; a hypothesis that renders like a fact
  is the same failure as the simulated position marker.
- **A phrase commits at a silence, not on a timer.** Trailing quiet is what a
  sentence boundary sounds like, so committing there yields one log per utterance
  instead of one per arbitrary window. `maxWindowSeconds` (14 s) is only the
  backstop for a golfer who does not pause — and it must stay well under Whisper's
  **30-second frame**, past which the model silently drops the oldest audio.
- **A tap that stops delivering buffers fails silently, and this app is the case that
  triggers it.** A developer-forum report has `installTap` ceasing to fire after a
  phone-call interruption — engine running, no error, no buffers. Segmentation exists
  here *because* a 4.5-hour round gets interrupted. **`AudioRecorder`'s stall
  watchdog treats "no buffer for `Config.stallTimeout` (10 s)" as a fault** and
  restarts the engine into a *new* segment — not the same one, because the audio
  between the last buffer and the restart does not exist and writing what comes next
  into the same file puts a hidden gap inside a stretch the clock says is
  continuous. It is disarmed while `state == .interrupted`: the tap is *supposed* to
  be silent during a call, and restarting under the interruption fights the OS for
  the microphone every two seconds. **Verified against a faked dead tap 2026-08-27**:
  the segment closed `(stall)`, a new one opened, and the live recognizer resumed —
  the listener survives an engine restart because `stopEngine` keeps the `AudioTap`
  and drops only its converter.
- **A segment ends when its last sample arrived, not when the code noticed.**
  `AudioRecorder.endTime(lastBuffer:notBefore:)`, floored at the segment's own `t0`.
  The watchdog waits ten seconds before declaring a stall, so stamping `now` gave a
  segment claiming **18.0 s while holding 6 s of audio** — the dead stretch landed
  *inside* a window the session clock says is continuous recording, and everything
  derived from `t1 - t0` lied with it. Stamped properly, the twelve silent seconds
  appear where they belong: as the gap *between* two segments, which is exactly what
  this format exists to express. Same rule as `SessionIndex.closeOut`.
- **The *file* transcriber only ever sees closed segments; that is what live
  transcription exists to route around.** An `.m4a` still being written is not a
  readable file, so a round in progress has nothing transcribable in its current
  segment — which for an uninterrupted round means nothing until the eighteenth
  hole. The Transcribe button therefore stays manual and the live feed carries the
  round. `AudioRecorder.rotateSegment()` is the other half of the answer and is
  built but unused: on `AVAudioEngine` a rotation is one file close and one file
  open with the tap still running, so a timed rotation is now cheap. Nothing calls
  it yet.
- **The simulator has no on-device speech model and cannot download one.** Verified
  2026-08-27: the whole path runs — locale resolution, transcriber construction, the
  `AssetInventory` check — and stops there with a message about `en_US` that reads
  like an app bug. `RoundTranscription.explain` says so explicitly under
  `targetEnvironment(simulator)`. **Transcription is testable only on a real iPhone.**
- **`golfctl transcribe` reports missing segments out loud.** An `audio.jsonl` row
  whose file is gone would otherwise yield a short transcript that looks complete.
- **A log names its own audio, and `tEnd` is the only thing that makes that true.**
  *(2026-08-28.)* `LogEntry.tEnd` is the session-clock end of what was said; `[t, tEnd]`
  resolves against `audio.jsonl` through `AudioSpans.resolve`, which is what lets one
  entry be re-read by a bigger model. **Session times, never a file name and an
  offset** — one clock, and `AudioTimeline` already owns the segment↔session mapping,
  so a second copy on the row would be a second authority that can disagree. A burst
  grows by superseding: `t` stays where the golfer started talking, `tEnd` advances.
  Nil is a real answer (a typed log, or any spoken log recorded before the field
  existed) and `hasAudioSpan` is what the UI checks.
- **A span is a list, because a burst can cross a segment boundary.** The stall
  watchdog rotates mid-burst and an interruption closes a segment, and the audio
  between two segments **does not exist** — it is a phone call. `AudioSpans.resolve`
  returns each piece separately, each is decoded on its own, and only the **text** is
  joined. Concatenating the samples hands the decoder a join that never happened,
  inside a 30-second frame. This is `AudioTimeline`'s "never accumulate" rule seen
  from the other side; it takes a list of segments where `AudioTimeline` refuses to,
  and it *selects* rather than accumulating.
- **A segment with `t1 == nil` is skipped, and usually it is not the crashed round.**
  It is the burst recording *right now*, and an `.m4a` still being written cannot be
  opened at all. So a log spoken into the open burst resolves to no spans, and the
  menu says so instead of offering a button that cannot work.
- **The on-demand re-transcribe writes no coverage and no transcript.** A sub-range
  pass is not a whole-segment pass; marking `transcript.coverage.json` would record
  segments transcribed when only part of them was read, and a segment marked done is
  never read again. The authoritative transcript stays `SessionTranscriber` over whole
  closed segments. What it *does* write is a **superseding row in `log.jsonl`** — same
  mechanism as an edit, so nothing is overwritten, a citation still renders its
  evidence, and the new id makes `ExtractionCoverage` re-read it, which is correct
  because the text changed.
- **`WhisperEngine` holds more than one model, and a single slot was a bug.**
  *(2026-08-28.)* It cached `(id, kit)` — one entry — so the live and final models
  evicted each other: re-transcribe an entry and the next Record tap reloaded the
  listening model, which is exactly what the "loading is seconds, reloading per burst
  misses the first sentence" comment forbids. It only appeared once the two models
  *differed*, which is the entire configuration the feature exists for. Now an
  LRU of `WhisperEngine.capacity` (2) — the two configured models fit, and a third
  request evicts the one nobody has asked for. Proven with
  `golfctl relisten <file> --model small,tiny,small`: 17.5 s, then 3.9 s, then
  **0.66 s marked "already resident"**.
- **Loads are deduplicated in flight, and that is correctness rather than tidiness.**
  An actor suspends at every `await`, so two callers that both miss the cache before
  either finishes `WhisperKit(config)` would both load the same model. Survivable
  while one thing loaded models; not survivable once a round start preloads in the
  background and a Record tap can land in the middle of it. `loading` is
  `Task<Void, Never>` and never `Task<WhisperKit, Error>` — `WhisperKit` is not
  `Sendable`, so it must not cross a task boundary; the task writes into the actor
  and callers re-read the cache.
- **Both models are preloaded at round start, live model first, and never
  downloaded.** *(User decision, 2026-08-28: "both at round start", "keep both
  resident".)* At round start rather than app launch, because most launches are not
  rounds — recording is off by default — so a gigabyte of CoreML at launch is paid by
  people who never press Record. Live model **first** because `preload` is
  sequential: by the time the bigger one is loading, the one Record needs is already
  cached. `preload` skips a variant that is not on the phone in silence — a course
  has no signal, and a fetch belongs in the picker where it has a progress bar.
  `stopRound` cancels the *warming*, never the models: a finished round can be
  reopened and its entries re-transcribed.
- **Two Whisper models, because the two jobs have opposite constraints**
  *(user request, 2026-08-28)*. `marker.whisper.model` decodes continuously for 4.5
  hours on a phone, so it is small and mishears names; `marker.whisper.model.final`
  runs on one entry, once, when somebody is looking at a line that came out wrong, so
  it can be the biggest thing that fits. §8.4's measurement is the argument: `small`
  is 1.5–2.7× realtime, so a big model over a whole round is hours and over one entry
  is seconds. Both download from the picker — a course has no signal.
- **The re-transcribe reads the whole entry's span, never one phrase.** Measured
  2026-08-28: the 4.5–7.0 s excerpt of a real file read 포기했어요 as 고기 했어요 where
  the whole-file pass got it right. Less context is worse context, and the burst —
  pauses included — is the context.
- **`promptTokens` is wired for the on-demand pass only, and it carries names and
  nothing else.** *(2026-08-28; this replaces the "deliberately not wired" note.)*
  Whisper reads the prompt as *previous text*, so it is evidence about the language:
  a couple of hundred English golf words in front of a Korean phrase argues for the
  failure the user reported twice. `TranscriptionContext.names` (the roster — one
  name per player since 2026-08-31) is the only thing that reaches a decoder; `contextualStrings` keeps
  the whole vocabulary for engines where the knob is not a language signal. **The live
  path stays unwired** — least context, most to lose. Measured on four fixtures with
  and without a bilingual roster: no language flipped, nothing looped; but the
  fixtures are `say` output, so the half it exists for is still unmeasured and **L5
  decides it**. research-live-transcription.md §8.5.1.
- **`GolfVocabulary.synonyms` is a glossary the model reads, never a rewrite of a
  log.** *(2026-08-28.)* Half the Korean list is not a recognition problem at all:
  Whisper transcribes 고구마 perfectly and it means *sweet potato*. 따블, 트, 유틸,
  오비 are the same shape. Several keys are ordinary Korean syllables, so a mechanical
  substitution would corrupt sentences about lunch — it goes to the model as context
  and the log stays exactly as it was heard. **Injected, never imported**:
  `LogExtraction.instructions(players:glossary:)` takes it as a parameter, because
  importing `GolfTranscription` into `GolfReconstruction` would drag WhisperKit into
  the one target whose point is being framework-agnostic.
- **A copied transcript is built from the logs, not from the timeline.**
  `LogTranscript` lives in the package for exactly this reason. The round screen's
  timeline *hides* a log an event already cites — the event quotes it underneath — so
  copying that list would drop precisely the sentences extraction succeeded on, and
  the result would look complete. `onHole` also keeps a nil-hole row on every hole,
  the same rule the screen follows.
- **The recorded track is duty-cycled: slow by default, fast for a burst and the
  placement window after it.** *(TODO 16, implemented 2026-08-28.)* `LocationRecorder`
  has a `mode`; `RoundViewModel.trackFast` drives it. **State the saving as an
  estimate** — the full-rate baseline round was voided and is not coming, so there is
  no before-number. The visible cost: `gps.jsonl` is now too coarse between bursts to
  derive geometry from.
- **The radio handback needs a belt as well as braces.** `RoundScreen`'s placement
  task is `.task(id:)` over the **unplaced** logs, so it re-runs only when that set
  changes — a burst that placed everything as it went, or produced no logs, leaves the
  signature unchanged when Stop is tapped and the task never fires again. Without
  `RoundViewModel.handBackRadio`'s timer the radio would sit at Best for the remaining
  four hours, reached through the feature meant to save power. Both paths are safe to
  run; `setMode` ignores a mode it is already in.
- **The hole view remembers the tee per course; it does not remember the hole.**
  *(User request, 2026-08-28.)* Layer and units were already `@AppStorage`; the tee is
  now `marker.tee.<courseID>` and is **validated against `course.teeNames` on load**,
  because a single global tee name applies "Black" to a course that has none — and
  `cardLength(from:)`/`geometry(tee:)` then correctly return nil rather than another
  tee's numbers, so the screen loses its yardages with nothing saying why. The hole is
  deliberately *not* remembered: the map button opens the hole the card is on.
- **`HoleScreen` needs `.id(course.id)` at its call site.** It seeds `holeIndex` and the
  remembered tee in `init`, and a `@State` initial value applies once per view
  *identity* — so switching course from `CourseView`'s menu keeps the same identity,
  `init` never re-runs, and the previous course's tee carries over **unvalidated**,
  which is the exact failure `rememberedTee` exists to prevent arriving by the one path
  it cannot see. The hole index does the same: hole 14 of an 18 renders "no holes in
  this course" on a nine.
- **"Transcribe again" is disabled while the microphone is open** — but for
  *attention*, not for memory. **Both models stay resident through a burst**
  *(user decision, 2026-08-28)*, so a re-transcribe straight after one is instant;
  that is a deliberate memory bet on a 4.5-hour round and the thing to look at first
  if the app is ever jetsammed mid-round. The button is off during a burst because a
  decode competing with the live recognizer for the ANE slows the thing the golfer is
  actually doing, and the audio is not going anywhere.
- **`HoleScreen.focus` marks where a log was said and is kept out of the fit.** It is
  panned to (`centerOn`), never fitted to — feeding it to `VectorHoleView.extraPoints`
  would shrink the hole to a dot to keep a fix in another county on screen, which is
  the bug that rule already exists for. Drawn as a hollow cross-haired ring, unlike
  anything else on the hole: it is a claim about the past, it does not respond to
  touch, and it must not look draggable.
- **Marker · Round · Location is one view, drawn on two screens.** *(X1/X2, user,
  2026-08-28.)* `MarkerBar` lives in the **app target** and reaches the hole view
  through `HoleScreen.bottomBar`, a `@ViewBuilder` slot — because `HoleScreen` is in
  `GolfMap` and Marker needs `RoundViewModel`, `LiveTranscript` and `LogStore`. A
  package that draws a hole must not import the capture stack, the same rule that
  keeps `GolfReconstruction` off WhisperKit. `HoleScreen` is generic over the bar and
  an `extension … where Bar == EmptyView` carries the no-bar initialiser, because a
  **default argument does not take part in generic inference** and every other call
  site omits it.
- **The bar's height is measured, and it is Apple's attribution reserve.**
  `HoleScreen` passes `110 + barHeight` as `SatelliteHoleView.bottomReserve`. A
  constant would go stale the first time the bar gains a row, and the symptom is a
  covered logo and Legal link — a licence problem, not a visual one. Verified by
  screenshot: both are clear of the bar.
- **The Marker sheet is Speak *or* Type, never both** *(user, 2026-08-28: "it's
  either our own recording or iphone input text view. Not both" — correcting a first
  version that put them on one surface)*. They are two modes because they are two
  **recognizers**: Speak runs `WhisperLiveTranscriber` off our tap, Type hands the
  sentence to the iOS keyboard and its own dictation. Both at once is two things
  listening to one voice and two log rows for one sentence, so switching to Type
  **closes the burst**. Speak is the default — it is what the product is for.
  Closing the sheet — Done, or a swipe — ends the burst, because a live microphone
  with nothing on screen saying so is exactly the failure the record button's own
  rule was written against. It also carries the **reopen a finished round** path
  that the record button used to own. **The choice is remembered**
  (`marker.input.mode`): which way a golfer records is a habit, not a per-sentence
  decision, and someone who types would otherwise switch eighteen times a round.
  **Speak is the default** when nothing is stored. **Type is the text box and nothing
  else** — full height, focused on arrival so the keyboard comes up with the sheet,
  and `.large` forced, because the medium detent plus a keyboard leaves about two
  lines of what is being written visible.
- **The fast window ends at a stable fix, not at dismissal** *(user, 2026-08-28:
  "keep updating location until it's stabilized, once stabilized, it's final, and
  change it back to slow")*. `MarkerSheet.settle` runs `StableLocation.best`, which
  returns the moment `TrackingState` locks — three consecutive fixes inside 15 m — or
  at the deadline; both feeds drop to slow immediately afterwards and the fix it
  found is `settled`, used by every log the sheet writes from then on. Holding fast
  for the life of the sheet meant a golfer describing a hole for two minutes paid
  Best for all of it, plus a twenty-second timer afterwards, and **the reported
  symptom was that fast tracking was still on when the sheet was done**. What the
  dense rate is *for* is one good position for this stop; once that lands there is
  nothing left to spend power on.
  `MarkerSheet.leave` and `CourseView.appear` are belts — the first drops to slow
  unconditionally, the second schedules a hand-back — because `startListening` sets
  fast and **cancels any pending hand-back before** starting the recognizer, then
  returns early if it will not start (no speech model is the ordinary case), so
  `stopListening` had nothing to stop and nothing ever asked for slow again.
- **`MarkerSheet` names three managers and runs at most two.** `trackFast` is the
  recorded track and exists only during a round; `LiveLocation` stands down for
  exactly that period, so one of the two does anything at any moment.
  `StableLocation` is the third and always runs at Best whatever the others are set
  to — which is what keeps the log path independent of duty cycling, and why
  dropping back to slow costs a log nothing.
- **The Marker sheet says what the entry is *about*: hole, player, shot** *(X15,
  user 2026-08-28)*. Above both modes, because they describe the entry and not the
  way it was captured — a golfer who speaks the sentence and one who types it are
  filing the same thing. The **hole is pre-assigned from the one on screen** and
  written `.user`; the **shot auto-fills** to one more than that player's last on
  that hole the moment a player is picked, from `LogEntry.nextShot`, which reads the
  **current** rows and never the raw file (a burst grows by superseding, so counting
  raw rows would jump the number every time somebody fixed a typo); and the stepper
  is disabled with nobody selected, because a shot number with no player cannot be
  ordered against anything.
  **The hole and shot lead the sentence** — `"7: 2 drive into the left bunker"`
  *(user decision, 2026-08-28)* — **and are also stored as fields**. Not a
  duplication to tidy away: the prefix is what a person reads in the timeline and
  what the extraction pass reads in `log.jsonl`, the fields are what the hole view
  draws from. Written in one place so the two cannot drift.
- **OK and Cancel, and Cancel deletes what the burst wrote** *(X15; the deletion is a
  user decision of 2026-08-28)*. "Done" said the sheet was finished and nothing about
  what happened to what was in it, which is not good enough once there are fields to
  fill in. Cancel cannot un-write a spoken phrase — one is committed to `log.jsonl`
  the instant it finalises, deliberately, so a round that dies mid-burst keeps what
  was said — so it **tombstones**, the way a log is deleted everywhere else.
  `LiveTranscript.markerSessionEntries` is what makes that reachable: `burstLogID`
  alone is not enough, because it clears when a burst ends and one visit to the sheet
  can open and close several.
- **Create and edit are the same three fields; only the keyboard differs** *(X15,
  "give me good arrangement on this")*. Creating, the sentence does not exist yet, so
  the text field is focused on arrival and the keyboard comes up with the sheet.
  Editing, the sentence already exists and is usually *right* — the common edit is a
  field, not the words — so the text is shown as text and one tap turns it into a
  field. Raising the keyboard there would hide the fields underneath it for a golfer
  who only wanted to file the entry under a different player.
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
- **OK on an empty box still files a marker, provided the entry is *about* something**
  *(user, 2026-08-28)*. `"7: 2"` with nothing after it is a real entry — it is where a
  shot was played from, which is the whole of what the hole view draws — and demanding
  a sentence made a golfer marking a position invent one. Two guards, both against
  writing an empty *nothing*: there must be a hole or a player, or the pill renders as
  a content-free capsule that is still tappable and still in the extraction pass's
  input; and nothing is written when the visit already produced a phrase or a line, or
  OK files a blank entry beside the real one.
- **OK and Cancel are at the bottom of both dialogs** *(user, 2026-08-28)*. They were
  toolbar items — where iOS puts them, and the furthest thing on the screen from a
  gloved thumb, for the two buttons that decide what happens to the entry.
  `.safeAreaInset(edge: .bottom)` rather than `.bottomBar`, so they ride above the
  keyboard in Type mode instead of behind it. Both dialogs, because create and edit
  are one arrangement — that is X15's whole point.
- **The entry's fields are two rows: hole and shot, then the roster across**
  *(user, 2026-08-28)*. The players were a `Menu`, so the field filled in most often
  cost a tap to open, a read and a tap to pick. They were then a **column** for one
  afternoon, which was a misread: *"player names are vertically arranged"* was about
  **the legend on the hole view**, a different control doing a different job — "in
  gps hole main view. not in marker dialog". Horizontal here costs one row for a
  four-player roster instead of four, which is what keeps the transcript pane its
  height at the medium detent. **A player toggles** — tapping the selected one
  clears it, which is the only way back to "about nobody in particular". The roster
  is on this sheet twice, so the MARK row is labelled: the chips are who the entry is
  *about*, the pills are the survey button writing `marks.jsonl`.
- **Player and shot are both optional, and either can be put back to blank**
  *(user, 2026-08-28: "both player name and shot # are optional")*. The stepper runs
  **0…20 with 0 rendering as `—`**, so the number X15 auto-fills can be taken back;
  bottoming out at 1 made an auto-filled value compulsory. **A number still needs a
  player** *(user's answer when asked, 2026-08-28)*: the stepper stays disabled with
  nobody selected and clearing the player clears the number, because a shot with
  nobody attached cannot be ordered against anything — `LogEntry.isShot` requiring
  both is unchanged. Both dialogs, create and edit.
- **The legend is always drawn, bottom left, a third of the width, hard against the
  edge** *(user, 2026-08-28)*. Always, because it is the round's **roster** and not
  a key to what happens to be on this hole — so `CourseView` emits a `PlayerTrack`
  per player even with no shots, which draws no line and contributes no framing
  points. A third of the screen because the names sit over rough that carries no
  numbers. The plate behind a switched-off row **does not dim**: dimming made the
  row look disabled when what is off is the player's markers, not the button.
  **The number on the right is that player's next shot, and tapping it files one**
  where the golfer is standing — simulated position first, then the round's fix,
  then the view's feed. **The button is dead without one, visibly**: its whole
  meaning is "where I am standing", so with no position it would write a marker that
  cannot be drawn, on a screen whose only feedback is the marker appearing. The
  number still shows; it stops being a button. It **converges afterwards** like
  every other written log, because `RoundScreen`'s task is a stack frame away
  holding a different document. It comes from `LogEntry.nextShot`, the same
  function the Marker sheet's stepper uses, because two ways of working it out is
  two numbers that disagree the first time somebody edits a log.
- **There is no tracking chip on the hole view** *(user, 2026-08-28: "remove
  location tracking state at the bottom left side")*. The mode and the lock live on
  the Marker bar, which is on screen anyway, and two places saying it is how they
  come to disagree — `LiveLocation.adopt` hardcoding `.fast` was exactly that.
  `trackingChip`, `trackingText` **and `HoleScreen.tracking` itself** went with it:
  a retired control is not retired while the code that draws it is still there.
- **The position marker's outer ring is the fix's accuracy, in metres** *(user,
  2026-08-30: "current gps location marker's outside circle should show current
  estimated radius")*. `LiveLocation.accuracy` is published beside `here` and
  `HoleScreen.accuracy` carries it to both layers — `MapCircle(center:radius:)` on
  satellite, a projected circle on vector, because a fixed-point ring is honest at one
  zoom and a lie at the other thirty-nine. **Nil while simulating, in three places at
  once**: `HoleScreen` passes nil and both renderers refuse anyway. A hand-placed point
  has no accuracy, and a ring around one would draw a measurement nobody took in the
  language of one somebody did — the failure every simulated-position rule here is
  about. It is also cleared when the radio stops, never carried over from the last fix:
  the same rule that forbids substituting a last known position.
- **"Go to my location" works on satellite too, as of 2026-08-30.** `HoleScreen` has
  driven `centerOn` since the button existed and **only `VectorHoleView` ever read
  it** — so on the satellite layer the menu item did nothing at all, silently, which
  reads as the app not knowing where the phone is. `SatelliteHoleView.centerOn` moves
  the camera and **leaves the zoom alone** (`cameraDistance`, tracked from
  `onMapCameraChange`): the golfer chose that zoom, and re-framing on the way to a
  position answers a question nobody asked. The target is `HoleReadout.playerAt` and
  never `origin`, which is what makes it work in the case the button exists for —
  standing somewhere that is not this hole.
- **Shot layer order: lines and their numbers, then the dots, then the markers**
  *(user, 2026-08-30: "for shot marker drawings — lines and line numbers first, dots
  next, shot #'s last")*. This **narrows** the 2026-08-28 "markers are the lowest"
  rule rather than undoing it: a shot marker is now a numbered circle and the number
  is what *identifies* the dot beneath it, so a track line drawn across it makes the
  one unreadable thing on the hole the one thing the layer exists for. Everything a
  golfer is about to **act on** — the plan, the rulers, the player, the flag — is
  still drawn after the markers, and `VectorHoleView.hit` still tests markers last.
  Vector does it in **three passes**, not one loop, so the order holds *between*
  players; on satellite it is declaration order (`teeMarkers`, `trackOverlays`,
  `markerOverlays`), which is what fixes the leg numbers and the shot dots —
  annotations, like the pills — while the lines were always underneath anyway.
- **A hole with a centre line is drawable with no tee and no green point** *(user,
  2026-08-30: "if tees are not in the data, we're not showing anything right now. We
  should show the hole as long as any locatable data is there")*. Not hypothetical:
  `golfctl course osm` reports **"no tee found for hole(s) 1…9"** on the one real
  site there is, and those holes rendered as *"No map for this hole yet"* — which
  reads as the app being broken about a hole OSM describes perfectly well.
  `Hole.geometry(tee:)` falls back to `line.first` / `line.last`, and `hasGeometry`
  is now simply `geometry() != nil` so the two cannot disagree. **These are real
  surveyed points, not a nil coalesced to something plausible** — `line` runs tee end
  to green end and its orientation is decided from the data — which is the whole of
  the `HolePlane` rule about a nil-coalesced coordinate drawing the hole at the
  equator. **Only when nothing on the hole is placed**: once any tee has coordinates,
  an unplaced one still returns nil, because "no tee may answer with another tee's
  numbers" and answering with the centre line's start under that tee's name is the
  same error in a different hat. `HoleGeometry.teeInferred` / `.greenInferred` say
  which end was inferred, and the hole box prints `~ White Tee` — the same mark
  `CardYardage` uses for a measured length standing in for a card number, and for the
  same reason: a different quantity, not a substitute.
- **A name search is *structured*, and it climbs a three-rung ladder** *(user, 2026-08-30:
  "search is failing: I was looking for Coyote Creek Tournament Course in Morgan Hill, CA")*.
  Measured against the live geocoder, free-form `q` returned **nothing at all** for that string and
  for `"Coyote Creek Tournament Course, Morgan Hill, CA"`, and returned **eighteen rivers and no
  golf course** for `"Coyote Creek"`. Free-form has to guess which words are the name and which are
  the place, and on a course name ending in a common noun it guesses wrong. So `Nominatim.Query`
  splits on `" in "` or the commas and the rungs are: **`amenity=<name>` + `city`/`state`**
  (structured — the only rung that finds "Coyote Creek Tournament Course" at all), then
  **`q = "golf course <name> <place>"`** (Nominatim reads a leading category phrase as a filter,
  which is what turns those eighteen rivers into six courses), then plain free-form, then the
  planet-wide Overpass regex. One request a second between rungs; the policy is a condition, not
  etiquette.
- **"Found nothing" and "could not be asked" are different answers.** `sites(named:)` was
  `try? await Nominatim.sites(…)`, so any geocoder failure fell straight through to the Overpass
  regex, which then timed out and reported **"Overpass timed out. Narrow the area"** — for a fault
  in a different service, about an area that has nothing to narrow. `Failure.geocoder` names it.
- **Overpass's public instance fails transiently and often, so retry — and never advise narrowing
  the area for it.** Measured 2026-08-30: **four of seven identical requests** for one 1.4 km box
  returned **504**, and the body says `Dispatcher_Client::request_read_and_idx::timeout. The server
  is probably too busy`. That is load on a free shared service, not a query that is too big, and a
  plain retry a second later succeeded every time. `CourseOSM.run` retries `attempts` (3) times
  with a growing backoff, and `classify` reads the body: a **dispatcher** timeout is
  `.overpassBusy` ("wait a moment"), a **query** timeout is `.overpassTimeout` ("narrow the area").
  Giving the second advice for the first sends the golfer to shrink a box that was already small.
  A mirror was tried and is **not** shipped — `overpass.kumi.systems` did not answer from here at
  all, and retrying the host that was measured to recover is the fix with evidence behind it.
- **`out geom;`, never `out tags geom;`.** They look interchangeable and are not: `tags` is a print
  mode in which a relation returns tags and a bounding box with **`members` absent entirely**, so
  every multipolygon was unreadable whatever the parser did. Measured at Coyote Creek: `out tags
  geom` gave 28 relations and zero members; `out geom` gave the same 28 carrying 60 members with
  full geometry, and keeps the way tags. Pinned by `CourseOSMClientTests`.
- **A multipolygon's outline is its `outer` members, stitched — inner rings are dropped.** Coyote
  Creek's 28 fairway relations carry 28 outer members and **32 inner** ones (the bunkers and greens
  cut out of the fairway); concatenating every member draws a spike from the outer ring across to
  the inner one and back. `OSMCourse.stitch` chains several outer ways end to end and reverses as
  needed — OSM lets one ring be several ways, in any order and either direction — and returns the
  **longest piece alone** when they will not chain, because a partial outline is visibly partial
  where a ring with a jump in it looks like a surveyed shape.
- **`golf:course:name` beats the routing walk, all or nothing.** It is on all 28 hole ways at
  Coyote Creek — Tournament 18, Valley 10 — where the minimum-walk split, handed ten clipped holes
  of the neighbouring course, produced **two spurious candidates of 7 and 3**. A surveyor's
  statement is evidence and a walk is an inference. The tag is used only when *every* hole carries
  one, because partitioning on a partial tagging puts the tagged holes in named groups and quietly
  loses the rest; and a disagreement with the walk is **reported, not silently resolved**
  (`Report.splitDisagreement`).
- **A group name is qualified by the site name — `OSMCourse.displayName`.** `golf:course:name`
  reads "Tournament Course", which slugs to `tournament-course` and would collide with the
  tournament course of every other facility on earth. When the site name already contains the group
  name it wins outright; otherwise the two are joined with the site's generic tail ("Golf
  Course"/"Club"/"Links") dropped, so Corica reads "Corica Park South Course". Both the CLI and
  `CourseFinder` go through it, because two id schemes agree right up until the day importing a
  card over an OSM file writes a second course instead of merging.
- **Cart paths are a layer, and they are the only thing on the hole that is pure orientation**
  *(user decision, 2026-08-30)*. `Hole.paths`, drawn over the fairway and under everything else,
  hairline and pale, in metres like every other width so they do not swell into roads at 40×.
  **Clipped per vertex, not assigned whole** (`OSMCourse.clip`): a path runs the length of one hole
  and carries on to the next, so "nearest hole to the midpoint" draws a neighbour's path across
  this hole and loses this hole's own. On satellite they are redundant while the photograph is up —
  and that is exactly why they are drawn: nothing on that screen may depend on the imagery having
  loaded.
- **`Hole.paths` is stored optional and read non-optional, and that pattern is the rule for any new
  `Hole` field.** A missing key for a non-optional array is a *decode failure*, so one added field
  made **every course file already on disk unreadable** — found by running `golfctl course show`
  against `Courses/corica-park-south.json`, not by reading the diff. `storedPaths` is `[[Coordinate]]?`
  behind explicit `CodingKeys`, and it is written back as nil when empty so a course with no cart
  paths encodes exactly as it did before the field existed.
- **`OSMCourse.simplify(open:tolerance:)` is a second Douglas–Peucker, and it must stay second.**
  The ring version splits at the far vertex first *because a ring has no endpoints*; doing that to
  a path moves one of its ends. A path has real ends and keeps both.
- **Name search goes to Nominatim, not Overpass** *(user, 2026-08-30: "search is very
  slow. is this expected?")*. **Measured**: the Overpass name query is a regex over
  every `leisure=golf_course` way and relation on the planet with no bounding box —
  `"Corica Park"` took **12.5 s and returned 504**, Overpass timing itself out —
  against **0.72 s** from Nominatim, which answered with the facility, its tags and
  exactly the bounding box the feature query needs. Overpass still fetches the
  geometry; that part is a spatial query and is fast once there is a box. **The old
  query stays as the fallback**, because a course the geocoder has not indexed may
  still be in OSM, and a geocoder miss must not become "this course is not in
  OpenStreetMap" — the message that sends somebody off to trace a hole by hand.
  Results are filtered to `leisure=golf_course`: a search for a course name also
  matches the road and the bus stop named after it, and a bus stop's bounding box is
  a point, which fetches nothing and looks exactly like an unmapped course.
  Nominatim's usage policy is a condition, not etiquette — one request a second, and
  a real `User-Agent`, which is `CourseOSM.userAgent`.
- **A measured length is assigned only when it actually changed.** `hudHeight`,
  `barHeight` and `legendWidth` are all measurements that feed back into the layout
  they were taken from — the first two become the map's `bottomReserve` — and a value
  settling a hundredth of a point from itself oscillates forever, which SwiftUI
  reports as `AttributeGraph: cycle detected`. `HoleScreen.setHUD`/`setBar`/
  `setLegendWidth` guard on half a point, which is below anything visible.
- **`centerOn` is cleared on the next turn, never inside its own `onChange`.**
  Writing a `@Binding` back to the parent's `@State` from within an `onChange` of
  that same binding is a self-referential update and one of the shapes SwiftUI
  reports as a cycle. Both layers hop through `Task { @MainActor in }`; the command
  is one-shot, so a frame costs nothing.
- **A shot marker is a numbered circle, and that is all it is** *(user, 2026-08-30:
  "no club icon or name. Just show shot # in circle. Color is good enough to
  distinguish")*. `HoleMarker.title` for a shot is `ShotName.of(shot)` and nothing
  else; `HoleMarker.isShot` picks the circle over the capsule on both layers, and
  `CourseView` stopped passing `figure.golf`. The pill used to read `[golfer] 1 ·
  steve` — three claims about one dot, two of which the colour and the legend already
  make. **The circle keeps `pillHeight`**, because `SatelliteHoleView.markerAnchor` is
  computed from it: change the height and the grab handle lands back on the label,
  which is a flip that has already been made and unmade once.
- **`MarkerDisplay.ghost` is 0.8** *(user, 2026-08-30: "when inactive, opacity 80%")*.
  Ghost's job is to take the layer out of every gesture while keeping what happened on
  the hole readable, and at 0.45 the second half was losing. *(`MarkerDisplay.stoodDown` was split out of it for the
  pill that yielded to the simulated marker, and went with that feature when the user
  reverted it on 2026-08-30.)*
- **The leg distance is 14pt, not 10** *(user, 2026-08-30: "make distance between
  shots font bigger")*, on both layers, with `legLabel`'s perpendicular offset grown
  to match. Ten points reads on a screenshot and not at arm's length in sunlight,
  which is where it is actually used.
- **A closed hole's score is nudged by swiping the score cell up and down** *(user,
  2026-08-30, who chose the cell over the whole row when asked)*. One cell owns the
  score, so it takes both gestures and classifies them by dominant axis — the same
  self-classifying rule `VectorHoleView.touch` follows. **Only on a closed hole**: an
  open one's number is how many markers have been filed, and a swipe must not
  contradict a count of things on disk. It goes through `onHoleOut`, so it is one
  `.setScore` journal act and undoes through `HistoryView` exactly like the swipe that
  closed the hole. Floored at 1, for the same reason the `T` state cannot hole out.
  **The change is animated in the direction it went** — the cell jumps large going up
  and small going down, and springs back — because the cell prints a score *to par*,
  so a stray nudge turns `+1` into `+2` and nothing else on screen changes. That is
  what "so that inadvertent change can be detected" is asking for.
- **Overpass lives in `GolfCourseOSM`, its own target** *(2026-08-30, when the app
  needed it: "For course OSM gps data, I want to search and download from the app")*.
  It was `Sources/golfctl/CourseOSM.swift` — an **executable** target, which nothing
  can import. The alternative was to put `URLSession` into `GolfCourse` and give up
  the one property that keeps `OSMCourse`'s assembly testable with no network. The
  client also stopped calling `print`: a library that writes to stdout cannot be used
  from a UI, so the CLI resolves the site itself and lists the other matches, and
  `CourseFinder` shows them as a list to pick from.
- **`Course.slug` is in the package, because two importers now build ids.**
  `CourseImport.slug` delegates to it. A second copy in the app would be two id
  schemes that agree until the day they do not — and the day they do not, importing a
  card over an OSM file writes a second course instead of merging.
- **The app's course finder runs the same three checks as the CLI, in front of the
  Save button.** Stroke index as a complete permutation, measured length per par
  through `DistanceUnit.plausibility`, and `report.lines` (unassociated greens and
  tees, and `teeAnomalies`). **A wrong partition and a crossed green both look exactly
  like success**, so an importer that skipped them would write a file that passes every
  structural test and reads a club and a half wrong. `golfctl` prints them; here they
  are the row itself. It deliberately **never merges** — `--merge` exists so a card can
  be laid over OSM geometry, and there is no card importer on the phone — and it says
  out loud that OSM carries no yardage rather than leaving an empty column to be found
  on the first tee.
- **The finder refuses to overwrite a course id, and that is a data-loss guard.**
  `CourseStore.save` is a *replace*, so saving over an existing id destroys every
  `at` and `green.center` placed by hand — the "re-importing a card must never destroy
  placed coordinates" rule reached by another road. The CLI has `--id` and an explicit
  `--merge`; the sheet's equivalent is to say "a course is already saved as this" and
  disable Save until the name changes. Not a rare case: **two Korean names slug to the
  same ASCII** (`Course.slug("천룡") == "course"`), and re-running the finder on a
  course already imported is the obvious thing to try.
- **"Find a course…" is on five screens now** *(user, 2026-08-30: a Courses button
  next to `+` on Rounds, and "Find a course" where "Not listed" was in New round)*.
  Rounds is the one that matters: it is the first screen, and on a fresh install it is
  the only one reachable with no round and no course. **"Not listed" was a dead end**
  that only revealed a text box; the actionable version of "my course is not here" is
  to go and get it. The free-text course name survives in the empty-library branch,
  which is where a genuinely unmapped course is typed.
- **~~"Find a course…" is on three screens, and the hole view is the one that matters
  least.~~** The hole view is reached *through* a course, so putting the finder only
  there would make it unreachable on the install that needs it — a fresh one with no
  course files. It is also in `RoundView`'s course section, which is where somebody
  starting a round discovers they have none, and in `RoundScreen`'s Round menu.
- **`HoleScreen.bump` is a render *override*, not a `@State` seed, and the difference
  is why the score bounce needed three attempts.** Two failures in a row, both of
  which look correct in a diff: setting and clearing `scoreBump` in one synchronous
  block is a single SwiftUI update that diffs nil against nil, so **no animation runs
  at all** (the clear now happens on a `Task { @MainActor }` hop); and seeding a
  debug value through `init` cannot work here, because `init` runs on the first body
  evaluation and the roster, the tracks and the current hole are all loaded
  afterwards, so the seed is always nil. Verified by screenshot with `-marker.bump up`
  only after both were fixed.
- **A network error is a sentence, not an `NSError`.** The first run of the finder
  printed forty lines of `NSURLErrorFailingURLPeerTrustErrorKey` at the user.
  `CourseFinder.message(for:)` names the three shapes that matter — no signal, Overpass
  busy, TLS being inspected — because the action is different for each.
- **The vector hole view zooms to 40×, about the fingers, and the pinch owns the
  touch** *(user, 2026-08-28: "side span is about 45 yards, I want it to be around 10
  yards, so that I can place putts better"; 2026-08-29: "zoom to 40x doesn't seem to
  work")*. The old ceiling of 8 fitted a hole and a bit of rough; a putt is read at a
  scale where the green fills the screen — measured, 5.5 yards across a 390-point
  screen at 40×, so the ten asked for lands near 20×.
  **The ceiling was never what stopped it.** The magnify gesture and the one
  self-classifying drag are `simultaneousGesture`, so a pinch drives **both**: the
  first finger travels far past the slop, the drag calls itself a pan, and the pan
  branch rebuilt the viewport from `panStart.zoom` — the zoom from *before* the
  pinch — on every callback. The two wrote alternate frames and the zoom went
  nowhere, which would have looked identical at any ceiling. So `pinchBlockedDrag`
  stands the one-finger gesture down for the rest of the touch — **cleared when the
  finger lifts, not when the pinch ends**, because a drag's translation is measured
  from where that drag began and resuming mid-touch jumps the hole by however far the
  fingers travelled — and that touch ends with no tap, no move and no confirmation.
  The pan branch keeps `viewport.zoom` rather than `panStart.zoom` as the belt.
  **`HolePlane.zooming(to:about:)` zooms about the pinch point**, not the centre of
  the fitted layout: at 40× centre-zooming puts the green being read several screens
  away, which reads as the zoom not working just as convincingly as the fight did. It
  is analytic — the projection is affine in `zoom` — and needs five values kept from
  the fit (`baseScale`, both spans, `baseX`/`baseY`), because that arithmetic is not
  invertible from a finished plane. `HolePlane` still folds zoom into `scale`, so the
  project/unproject round trip a target relies on holds at any factor.
- **The satellite layer's zoom floor is `MapCameraBounds(minimumDistance:)`, and it
  has nothing to do with `HolePlane`.** *(User, 2026-08-29: "pinch zoom level is
  still the same. are we talking about the same thing?" — we were not.)* The 40×
  ceiling is the **vector** layer's own arithmetic; MapKit has its own camera and its
  own floor, so raising one does nothing whatever to the other. It is **12 metres**
  here — about a ten-yard span, which is what the putting request asked for. Verified
  by pinning `framedCamera` to 12 m and screenshotting: the camera goes there, the
  **imagery blurs** past its tile detail and the vector overlays stay sharp. That is
  the honest limit, and it is the two-layer design's own argument — the photograph
  runs out, the numbers do not.
- **A shot is *named* on screen and *numbered* in storage, and `ShotName` is the only
  place the offset lives.** *(User, 2026-08-29: "marker shows shot # it's sitting on —
  tee off: T, #1: 1, #2: 2, #3/holeout: 3"; "player name <shot count> shows next shot
  when not holed out: T -> 1 -> 2 -> ...".)* Nobody calls the drive "shot 1" — it is
  the tee shot, and the shot after it is the first that gets a number. So stored
  1, 2, 3, 4 displays as T, 1, 2, 3, in **both** places a shot number is rendered:
  `HoleMarker.title` and the legend cell. **Storage is deliberately untouched** —
  `LogEntry.shot`, `LogEntry.nextShot`, the Marker sheet's stepper, the `"7: 2 drive…"`
  log prefix and `RoundExport` all stay 1-based, because renumbering the stored field
  to change what a pill reads would ripple into the extraction pass's input and into
  every round already on disk. **The consequence is a visible mismatch and it is
  known**: the sheet says shot 2 where the hole says `1`. See "Known gaps".
- **The legend prints shots *taken*; the button files the *next* one.** *(User,
  2026-08-29: "it should be shots taken, so it should start with 0, not 1".)*
  `PlayerTrack.shotsTaken` is `nextShot - 1` and **not** `shots.count` — a shot with
  no position is not on the track and still counts, and where the numbering has a gap
  the highest number anybody assigned is what "taken" means. The two numbers differ
  by one deliberately: the legend answers "where am I in this hole", not "what will
  this button write". *(Since the naming above, the cell renders `ShotName.of(nextShot)`
  — the same value for anything past the tee, and `T` rather than `0` at the start.)*
- **A closed-out hole runs its track into the flag.** *(User, 2026-08-29: "when holed
  out, line segment extends to the pin".)* `PlayerTrack.closingLeg(to:)`, drawn solid
  at the same weight as the rest of the track on both layers, because the shot that
  went in is a shot rather than an inference. To **`pinAt`** — the flag as dragged
  today, not the green's centre — since that is where the ball actually went and where
  the flag is drawn. Two things it must not do: its pin end is **kept out of
  `PlayerTrack.allPoints`**, which feeds the framing fit (harmless today because a pin
  sits on a green, which is exactly how a stray point gets into the fit and stays); and
  it carries a number **only when `shots.last?.number == score`**, which is the
  consecutive rule arriving by a new road — the two agreeing means exactly one shot
  spans marker to cup, and when they disagree strokes went unlogged and a number would
  state something nobody recorded. Both renderers had a `guard shots.count >= 2` in
  front of the whole track; it is gone, because a hole in one is one marker and a
  closing leg — and that guard had also been silently erasing the *dot* of any
  one-shot player, against the rule two lines below it.
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
- **A marker's label clears its dot by `HoleStyle.markerLabelGap`.** A shot's circle
  is 11 points across, so a pill starting at the coordinate covers the lower half of
  the very thing it is a claim about — which is what "under the point" was asked for
  to prevent. Both layers use the one constant; on satellite it is a second clear
  strip in the annotation's stack and `markerAnchor` is computed from all three
  heights, so changing the gap cannot move the pill off its point.
- **The markers layer has three states, and the middle one is the point.**
  *(User, 2026-08-29: "marker view toggle button: tri state — visible and
  interactive / visible half transparent not-interactive / hidden".)* `MarkerDisplay`
  is `on` / `ghost` / `off` behind a **new** `marker.markerDisplay` key, and
  **`ghost` is the default** *(user, 2026-08-29)* — the old
  `marker.showMarkers` is a `Bool` and reading it as a `String` would give every
  phone the default anyway. Ghost is not cosmetic: a hole carries a dozen entries,
  each with a handle, and every one is something a finger can pick up while reaching
  for a target. Off answers that by throwing the information away; ghost keeps what
  happened on the hole readable and takes it out of every gesture. **Half
  transparent is the only signal that the layer has stopped responding**, so the
  dimming is load-bearing in the same way the simulated marker's orange dashes are.
  The **tracks dim with it** — a full-strength line between two faded pills says the
  pills are what was switched off. Vector does it with `GraphicsContext.opacity` and
  a branch in `hit`; satellite with `.opacity` + `.allowsHitTesting(false)`, because
  each pill carries its own gesture and a hit test would never see it.
- **A marker's label sits under its point, and the handle reaches the other way.**
  *(User, 2026-08-29: "marker display label under the point".)* The rule for the
  handle was never a direction — it is **away from the label**, so a fingertip is
  never on top of the thing being dragged, which is the whole of the 2026-08-28
  request that created it. So `markerGrabDrop` became `markerGrabRise`, clash
  stacking goes downward, the leader line runs up, and the satellite annotation's
  anchor is recomputed from the pill/strip seam. Flip one without the other and the
  handle lands back on the label.
- **A simulated position seeds from what is *visible*: the tee if it is on screen,
  otherwise the middle of the map area.** *(User, 2026-08-29, and **restated the same
  day after this was reverted by mistake**: "not geo positioning: at tee when
  visible, center of the screen when tee not visible <- this is what I want".)* It
  used to seed from the phone's fix and fall back to the tee — wrong in exactly the
  case simulation exists for, where the fix is in another county and the marker lands
  where the hole on screen cannot show it, so `HoleReadout` falls back to the tee
  while the screen claims to be simulating. `GroundView` is reported **up** from
  whichever renderer is drawing (`HolePlane` on vector, MapKit's camera region on
  satellite) and is a **quad, not a lat/lon box**: the vector layer rotates the hole,
  so a box around a rotated screen calls a tee visible while it sits off the corner.
  Never re-derived in `HoleScreen` — a second copy of the transform is a second
  answer that can disagree with the one on screen, the same rule `PlanLayout` follows
  one layer down.
  **"Simulate position placing is messed up, revert it" meant the *layering*, not
  this.** Two things about the simulated marker changed on 2026-08-29 and only one of
  them was wrong; reverting both cost a round trip. Where the marker is *seeded* and
  where it sits in the *draw and hit order* are separate changes with separate
  bullets — do not collapse them again.
- **The simulated marker is an `Annotation` in the map's content, declared last —
  not a `ZStack` overlay above the map.** *(Reverted 2026-08-29: "revert it was about
  layering it — current layering it is broken".)* It was moved out of the map to make
  it win the touch outright, since MapKit decides annotation stacking for itself and
  a marker's grab strip is a large transparent rectangle carrying its own gesture.
  **The cost of being outside the map is that it stops being glued to the ground**:
  positioned through `MapProxy.convert` at body-evaluation time, it does not track
  the camera through a pan the way everything around it does. A marker that lags the
  ground it claims to be on is worse than one that is hard to pick up. Declaring it
  last is not a guarantee — that is the whole reason the overlay was tried — so if
  the pick-up problem comes back, the fix has to keep the annotation and find the
  touch some other way. The **vector** layer is unaffected: `VectorHoleView.hit`
  tests the simulated player first, which is a real ordering guarantee.
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
- **Holing out is *having a score*, and the legend's number changes meaning when it
  does.** *(User, 2026-08-29: "swiping shot # to right closes it, i.e. hole out, no
  more shot creation on the hole, i.e. click disabled. # shown is delta from par,
  e.g. -1, +0, +1".)* Not a `holedOut` flag: a local flag dies on relaunch, never
  reaches `ScorecardBand`, and makes the golfer write the same number twice, where a
  score is a journal act that undoes through `HistoryView` — "the journal is the
  record; the card is a view of it". So `PlayerTrack.score` is the state,
  `onHoleOut(id, strokes)` is the report, and **nil is reopen**, which
  `JournalReplay` already handles for `strokes == nil` — no new act type.
  **The number committed is the one already on screen** *(user, 2026-08-29: "hole out
  swipe means the last shot is in the hole, meaning, current shot # is the score")*.
  The cell shows the next shot's *name*, so a player reading `3` has played T, 1 and 2
  and scores 3 when the last of those goes in. **"Holing out is a shot" is not
  reversed by this — it has moved** *(it was the user's correction earlier the same
  day, and this supersedes it)*: the holing-out stroke is now the last marker the
  golfer **filed** rather than an increment added at swipe time, which is what
  `#3/holeout: 3` means — the shot that goes in is one you stood over and marked. So
  the swipe adds nothing. This bullet has been revised twice; do not revise it a third
  time without re-reading that sentence.
  It follows that **the `T` state cannot hole out** — nothing has been played and a
  score of zero is not a thing — so the swipe is refused there and **the chevron is
  not drawn**, because an affordance for a refused gesture is worse than none. A hole
  in one is still expressible and costs one tap first: file the tee shot, the cell
  reads `1`, swipe. Swipe-left reopen is the correction path for one nobody meant.
  `+0` prints **literally**, never `0` or `E`: the sign is the only thing telling
  "two shots so far" from "two over par" in a cell that shows both.
  `scoreCell` is one view classifying its own touch — `DragGesture(minimumDistance:
  18)` beside `onTapGesture`, not a `Button` with a drag layered on — and it is
  44×30 rather than the glyph's 26, because a gesture has to *start* inside the
  thing it is dragging out of. One faint chevron points the way the finger goes:
  a swipe with no affordance is the gesture that retired press-and-hold.
  `CourseView.holeOut` appends through a `JSONLWriter` exactly like `movePin`, never
  a `RoundDocument` — that replays and rewrites `scorecard.json` per swipe — and
  reads `prevStrokes` **before** the optimistic local write, or the history records
  that the score never changed.
- **Copy is JSON, and it is `RoundExport` that decides its shape.** *(User,
  2026-08-29: "'copy' event and 'copy whole round' should construct json with all the
  data".)* `0:12:04  steve made par` threw away every field the round turns on —
  position, player id, hole, whether that hole was measured or chosen, the language
  it was heard in — and a model cannot recover any of it from the sentence. It lives
  in the package for the same reason `LogTranscript` does: the **selection** is the
  part that goes quietly wrong, because the round screen's timeline hides a log an
  event cites and copying the list on screen would drop precisely the sentences
  extraction succeeded on. A player is exported as **id and resolved name** — the
  name is what a reader expects, the id is what joins back to the round after a
  rename. Hole labels are passed **in** (`holeRefs`), because `GolfSessionFormat` has
  no course and hole 12 of a Korean 27 is called "황룡/3". Sorted keys, so a clipboard
  can be diffed. The firewall is untouched: logs and events are model-visible;
  `Mark`, `Scorecard` and `Correction` are not here.
- **The app icon is drawn by `Tools/make-app-icon.swift`, and the head is what is
  fitted.** *(User, 2026-08-29: "give me an icon with wedge club".)* Three
  appearances, re-runnable, versioned. Fitting the **whole club** was tried first and
  is a thin diagonal scratch at 60 points; the head fills the canvas and the shaft is
  deliberately cropped, because the grooves and the leading edge are what say *wedge*
  and what survive the shrink. Hosel and shaft are **one tapered filled shape** — a
  wide stroke meeting a narrow one leaves a step, and at icon size a step in a
  silhouette reads as two objects. The fit is measured from the union of the paths
  padded by each stroke's half-width, so editing the club cannot push it off the
  canvas.
- **The simulated position is drawn last and picked up first** *(user, 2026-08-29:
  "simulate position should be the top in terms of display, drag and click order")*.
  It was drawn on top of everything and tested *second* in `VectorHoleView.hit`, after
  the targets — so a touch aimed at the thing the eye can see could be taken by the
  ring underneath it. The drawn-is-tested rule, the same one `PlanLayout` and
  `markerHandle` follow. It costs a real round nothing: the handle exists only while
  `simulating`. The satellite layer already had it, by declaration order — the player
  annotation is last.
- **`flag.fill`'s anchor is measured, not a corner.** `.bottomLeading` was the first
  attempt and it is the corner of the *box*: the glyph has padding on every side and
  the staff sits a few points in from the left, so the flag still stood short of the
  hole. Rendered at 60pt bold the symbol is 69×70 with ink from x 8…62, y 6…64 and
  the staff centred on x 11.5 ending at y 64 — `SatelliteHoleView.flagFoot`,
  (0.167, 0.929). **Nothing may pad the glyph**, because the fraction is of the
  rendered box and padding moves the foot by however much was added.
- **The hole view's legend is a column of switches, one per player** *(user,
  2026-08-28: "these buttons should be toggleable to show or hide all the markers of
  the player")*. It was a horizontal strip of read-only chips saying which colour was
  whose; vertical because the names are now *targets* rather than a caption, and a
  row of small chips is a row of small targets. Switching one off hides that player's
  markers **and** their track. **Keyed on `PlayerTrack.id`, never on `colorIndex`**:
  the colour index is a roster *position*, and a `RosterEditor` removal slides
  everyone after it down a slot, so a set of indexes would go on hiding "slot 1" and
  silently start hiding a different person — the `defaultTee` trap again, a stale
  position answering under another name. `HoleMarker` deliberately carries no
  session-format id, so the ids are resolved back to colours through `tracks` at the
  moment of use, which is always current. **A hidden player is drawn switched off, never
  removed**: hollow swatch, dimmed name, struck through. Dropping the row would take
  away the control that brings them back and would read as the app having lost their
  shots. **Not persisted** — hiding somebody is something a golfer does to read one
  hole, and a hidden player who stayed hidden into next week looks like markers that
  stopped being recorded.
- **A marker's handle reaches *below* its point** (`HoleStyle.markerGrabDrop`, 34)
  *(user, 2026-08-28: "drag handle should be extended toward down, so that I can see
  the marker itself while dragging with finger")*. The pill is drawn above its point
  on both layers, and a handle centred on the point puts a ~40-point fingertip over
  the pill, its number and the position being dragged to. On vector the tested
  rectangle is the drawn one, the same rule `PlanLayout` and `measureLabelRects`
  follow; on satellite the annotation is a pill of **fixed** height above a
  transparent strip, anchored at the seam between them (`markerAnchor`) plus
  `contentShape`, which is what makes the empty half grabbable. Padding the pill
  instead was tried first and is wrong: it lifts the pill 34 points into the air and
  strands the dot it is a claim about below it — visibly worse the moment two
  markers are a few metres apart.
- **The indicator shows the recorder's real mode, and the handover is the app's job.**
  `LiveLocation.adopt` hardcoded `.fast`, so during a round the Location button and
  the tracking chip read **Fast** on every screen whatever `LocationRecorder` was
  doing — and it is slow for all of a round except a burst. Same class of error as
  drawing a simulated position like a fix: the control looked right and described
  something that was not happening. `adopt(accuracy:mode:)` now takes
  `RoundViewModel.trackMode`. Both `adopt` and `standDown` moved to `MarkerApp`,
  because `CourseView` was driving them — so a round spent entirely on the scorecard
  never stood the second feed down and ran **two radios all afternoon**.
- **A row shows its hole, and `no hole` only when it has none** *(user,
  2026-08-28)*. Both `LogRow` and `EventRow`: the same field answered two ways,
  rather than a chip that appears only on failure — which read as "this row is
  broken" instead of "this row is on 7". It matters most under *All holes*, where
  every row comes from somewhere else. The label is **`Hole.ref`**, which is what
  the card prints and is "황룡/3" on a Korean 27, falling back to the playing index
  when the round has no course file — `RoundScreen.holeLabel`.
- **~~A typed log carries no hole either.~~ Superseded 2026-08-28 by
  `LogEntry.HoleSource`** — see the next bullet. The *reasoning* was right and is
  preserved by it rather than abandoned: `hole` meant "nearest hole to a measured
  fix", `lat`/`lon`/`hAcc` sat beside it as the evidence, and one field carrying two
  claims with nothing able to tell them apart is what made a typed entry never show
  the `no hole` chip a spoken one did. The bullet's own escape hatch — "needs a
  discriminator on `LogEntry` first" — is what was built.
- **`LogEntry.holeSource` says whether a hole was measured or chosen, and a chosen
  one is never recomputed** *(X14, user 2026-08-28: "marker's hole — it should be the
  current hole")*. `.fix` is `Course.nearestHole`'s proposal; `.user` is a person's
  answer. Nil decodes as `.fix`, so every row already on disk keeps the only meaning
  it ever had.
  **It is a bug fix, not bookkeeping.** `LogPlacement.converge` derives the hole from
  the fix and appends a superseding row, and `nearestHole` between two fairways forty
  metres apart is a coin toss — so a hole set by hand was replaced by a guess about
  fifteen seconds later, which is what *"looked like associated hole # gets flipped
  sometimes"* was. The refusal lives in **`LogEntry.placed`**, not in the convergence
  code, so it holds for every caller. The position still updates: that is measured,
  and a better fix is a better measurement. Only the claim about *which hole* is left
  alone. `edited(hole:)` marks `.user` by construction — there is no way to reach it
  except a person editing the row.
- **A shot is `player` **and** `shot`, or it is neither.** `LogEntry.player` stores a
  `Player.id` — never a display name, the same rule `Mark.player` and
  `Correction.player` follow, because a roster rename would otherwise orphan every
  marker. A number with nobody attached cannot be ordered against anything, so
  `isShot` requires both. Nil is the ordinary case: working out who did what from
  what was said is the extraction pass's whole job, and these fields are for the
  entries a person filled in by hand.
- **`LiveLocation.standDown(false)` resumes at slow, never at `wanted`.** A `.fast`
  asked for while the feed was stood down came from a screen that has since gone —
  the Marker sheet escalates *during* a round, which is exactly when this feed is
  stood down — so replaying it left the radio at Best for the rest of the app's life
  the moment a round ended.
- **A typed entry is placed exactly like a spoken one** *(user, 2026-08-28)*. It
  always *could* be — `LogPlacement.unplaced` has never filtered on `source` — but
  the convergence that appends the coordinate is driven by `RoundScreen`'s
  `.task(id:)`, and the Marker sheet also opens over the **hole view**, where that
  screen is a stack frame down holding a *different* `RoundDocument`. So
  `MarkerSheet` converges what it just wrote, and `RoundScreen`'s task is the
  backstop. Running both is safe by construction: `LogPlacement.attempted` is a
  reservation, and a converged log is no longer `unplaced`.
- **`LogStore` compares session folders with `SessionFolder.isSame`, not `==`.** Two
  `RoundDocument`s over one round is now the ordinary case — the sheet opens over the
  hole view with its own — and two URLs for one folder compare unequal when one was
  built before the directory existed. With `==` the writer was closed and reopened on
  every alternating append; `O_APPEND` made that safe rather than correct, and the
  same comparison bug one layer up cost twenty-nine invisible logs.
- **MARK lives in the Marker sheet and nowhere else** *(user, 2026-08-28: "no
  separate red MARK button on gps hole view")*. It was a red bar across the bottom of
  the hole view — a second capture control beside Marker doing nearly the same job,
  which also meant MARK's own rule (nothing simulated may reach `marks.jsonl`, which
  is ground truth *and* `GolfEval`'s answer key) had to be enforced in two places.
  Passing `onMark: nil` puts the course name back in that slot, which is what the
  slot is for. `HoleScreen` keeps the simulation guard for any caller that does pass
  one.
- **~~A log written from the hole view is filed with no hole~~ — it is filed on the
  hole being looked at** *(X14, user 2026-08-28)*. The objection was real and is
  answered rather than waived: `LogEntry.holeSource` is the discriminator the old
  rule demanded, and the hole is written `.user` so `LogPlacement` leaves it alone.
- **Round is a toggle, on and off** *(user, 2026-08-28: "when it's off, no way to
  turn it on now")*. On ends the round — **confirmed**, because a green button whose
  label is a noun must not do something irreversible-looking on one tap; off reopens
  it. It never *creates* a round: that needs a roster and a course, which is
  `NewRoundView`'s job, and a one-tap start from the hole view would produce rounds
  with neither. Every screen showing the bar was reached through a round, so there is
  always one to reopen.
- **~~Fast tracking belongs to the Marker sheet, and to nothing else.~~ Reversed by
  the user on 2026-08-30: "fast track when gps hole view is on screen, slow when
  not".** The 2026-08-28 argument — a hole view is open for most of a round and
  reading a yardage does not need a fix a second — is now history, not guidance. Both
  the hole view and the Marker sheet escalate **both** feeds, and the resting state
  is unchanged: slow everywhere else, and slow is what an empty set of reasons means.
- **Fast is asked for by *reason*, never set as a mode two callers overwrite.**
  `LiveLocation.FastReason` and `RoundViewModel.FastReason` are `{ holeView, marker }`
  and both feeds keep a set. Booleans were survivable while one thing escalated and
  are not survivable with two: `handBackRadio` schedules an **unconditional** drop to
  slow after a burst's placement window, and `MarkerSheet.leave` dropped to slow
  outright — so a burst ending, or a sheet closing, over a hole view that was still on
  screen took that screen's fast tracking away, and the hole view never re-asserts
  because its `appear` already ran. A reason is removed by the screen that added it,
  which is also what let `LiveLocation.standDown(false)` stop resuming at a hardcoded
  slow.
- **`CourseView`'s `scenePhase` handler was an unconditional `track(.slow)`, and it
  silently ate the fast request.** `scenePhase` reaches `.active` *after* `onAppear`,
  so the hole view asked for fast and one event later that handler took it away —
  found by screenshot, the Location button reading **Slow** on the screen that had
  just asked for Fast. It now drops and re-asserts this screen's own reason, which is
  also the right behaviour: fast is for a screen somebody is looking at, and a phone
  in a pocket is not that.
- **Slow keeps running in the background, and Always is what makes that true**
  *(user, 2026-08-30: "need background tracking as well in slow mode")*.
  `allowsBackgroundLocationUpdates` is set whenever `.authorizedAlways` has been
  granted and `pausesLocationUpdatesAutomatically` is off, with `UIBackgroundModes:
  location` in `Info.plist`. **Always is requested from `CourseView.appear` and
  nowhere else**: `escalateAuthorization` returns early unless something has asked,
  which is the guard that stops a launch throwing a location dialog — so the ask has
  to be hung on a moment of intent, and opening a hole view is the one this app has.
- **"Close out this round" is in the ••• menu, not the bottom band** *(user,
  2026-08-28)*. Moved, **not deleted**: it is the only crash-recovery control there
  is — the rounds list has none — so a round the app was killed during would
  otherwise stay unfinished forever with nothing able to stamp it. It is rare and it
  does not belong in the thumb zone.
- **`LiveLocation` is owned by the app, starts at slow on launch, and never prompts
  there.** *(X2.)* It used to be a `@StateObject` inside `CourseView`, so the feed was
  born when the course screen appeared and died when it left — "on means slow tracking
  even in the background" cannot be true of that, and the Location button read **Off**
  on the round screen while the preference said on. One feed, one radio, one status on
  both screens. `marker.location.enabled` defaults **on**. Off stops the radio outright
  and a log written then is simply unplaced, which `LogEntry.hasPosition` already
  treats as a real answer.
  **`escalateAuthorization()` returns early unless `wantsAlways`** — assigning
  `CLLocationManager.delegate` fires `locationManagerDidChangeAuthorization`
  immediately, so without the guard the app throws a location dialog on launch. Same
  rule as `LocationPermissionMonitor.escalate()`, and easy to reintroduce: the prompt
  looks like it came from the toggle either way.
- **`CourseView.body` and its `HoleScreen` call are both at the type-checker's
  budget.** The call already needed pre-typed locals in declaration order; adding the
  bar tipped it into "unable to type-check this expression in reasonable time", and
  adding one more `.sheet` to `body` tipped *that* over too. The fixes are structural
  — `holeScreen(_:)` is its own function and `MarkerSheetPresenter` is a
  `ViewModifier` — not a reordering of arguments.
- **The pin menu is `Equatable` and split into its own view** *(X5, user 2026-08-28:
  "something keeps updating this menu")*. `HoleScreen` is handed a `TrackingState`
  that changes on every fix and on a five-second decay ticker, and the hole is one
  view body — so each of those redrew the subtree the `Menu` lives in, SwiftUI tore
  the open menu down and put a fresh one up, and the golfer lost whatever they were
  reaching for. `HoleSettingsMenu` + `.equatable()` puts a boundary there. **Its
  closures are excluded from `==` on purpose**: they are new objects on every parent
  body evaluation and would make it always-unequal, which is safe because each only
  reads `HoleScreen`'s current `@State` when it runs.
- **Simulate position is a tool-column button, not a menu item** *(X12, user
  2026-08-28: "promote the button to gps hole view, under measurement line icon from
  menu")*. **Moved, not duplicated** — two controls for one state is how they come to
  disagree. Two consequences: the pin menu no longer rebuilds when simulation is
  toggled, which is one fewer thing that can tear an open menu down (X5); and a
  **card-only hole loses the toggle**, because the tool column is only drawn where
  there is a hole to draw. That is the right answer rather than a gap — simulation
  seeds from the tee and is measured against geometry, and a hole with no coordinates
  has neither. **The re-seed moved with it** (`HoleScreen.simulate`): the rule that a
  switch-on always re-seeds is older than the button and outlived its previous home,
  and leaving it behind would put the marker on whatever hole it was last used on.
- **Targets are placed by button as well as by tap, and press-and-hold is gone**
  *(X6)*. A hold with no affordance is a gesture nobody finds. `HoleGeometry
  .suggestedTarget` is where a button puts the first one: **two thirds of the way in
  on a par 3** (one shot, so a fraction is the only useful reference) and **250 yards
  measured along `playLine` on a par 4 or 5** — along the line, so a dogleg lands it
  on the fairway rather than in the trees the corner cuts across — clamped to 85% so
  it never lands on the green. The second is two thirds of what is left
  (`towardGreen`). Retiring the hold also returns the hole view to **one** drag
  gesture, which is the rule four competing gestures once broke.
  **The branch that read the hold outlived the gesture, and ate taps for a day**
  *(found while doing X9–X11, 2026-08-28)*. `onHoldGround` stayed on both renderers
  with nothing passing it, so `held ? onHoldGround?(c) : onTapGround?(c)` meant **a
  deliberate slow tap on open ground placed nothing at all**, and
  `SatelliteHoleView.onLongPressGesture` swallowed every long press to call a nil
  closure. A retired gesture is not retired until the branch that reads it is gone —
  a dead callback here is not dead code, it is a control that silently stops
  working.
- **A `MeasureSegment` is not a target, and must not become one.** A target is a
  point a shot is aimed at and every distance is measured *to* it; a measure is a
  ruler between two arbitrary points that has nothing to do with where the golfer
  stands. Folding it into the target chain would put a point in the shot sequence
  that is not a shot. It is laid **square to the line of play**, not east–west, or it
  would sit at a different angle on every hole. Its own label is its dismiss control
  — **and, as of X10, its drag handle**, which is the one place the "a distance box
  is a bad handle" rule below does *not* apply: that rule is about a target, whose
  number changes as it moves, so the box crawls out from under the thumb. A ruler
  dragged by its box is translated **rigidly** (`MeasureSegment.center(on:)`), so the
  length, the number and the box's width are identical at the end of the drag and at
  the start. **Each ruler carries its own `colorIndex`** from `HoleStyle
  .measureColors` — carried on the segment, never derived from its position in the
  array, or dismissing one repaints every ruler that outlives it. A set of its own
  and not `playerColors`: a ruler drawn in a player's colour reads as that player's
  track.
- **The flag is draggable, and it is an `Event`, never the course file** *(user,
  2026-08-28: "pin location should be draggable, this one doesn't get saved into db.
  but will be saved as event, so that replay should be able to use it, and copy of
  events should include this info")*. `Event.Kind.pin` carries hole + `lat`/`lon`
  with `.user` provenance: a pin is cut fresh every morning, so it is a fact about
  *this round*, and writing it to `Courses/<id>.json` would make every later round
  inherit one afternoon's flag. Replay reads it with everything else that happened
  and any events export carries it for free. Keyed by **1-based playing index**, the
  same number `Event.hole` and a scorecard column mean — never `Hole.ref`.
  **The approach is measured to it and the caption says `TO PIN`**; front and back
  stay measured against the green outline, which is geometry and does not move.
  `CourseView` appends through a `JSONLWriter` directly rather than a
  `RoundDocument`, which would replay the journal and rewrite `scorecard.json` for
  one coordinate. **The drag is drawn from `pinDrag` and written once, on release** —
  the same split as `markerDrag` and for a blunter reason: `onMovePin` *writes an
  event*, so reporting from `onChanged` appends a row per gesture callback and one
  two-second adjustment leaves a hundred `pin placed` lines in the stream the user
  was promised would carry this. No confirmation, unlike a marker: a pin is cheap to
  correct and is corrected by dragging it again, where a marker is a claim about
  where somebody stood.
- **`flag.fill` is anchored at the foot of its staff, not at the centre of the
  glyph** *(user, 2026-08-28)*. The symbol runs its staff down the left edge and
  hangs the cloth to the right, so a centred annotation stands the flag half a green
  from the hole it claims to be in — at every zoom, on both the hole view and the
  course overview. `.bottomLeading`. The vector layer draws the staff from the point
  upward and was always right.
- **A track line is slim, and only a leg between *consecutive* shots carries a
  number** *(user, 2026-08-28; the first version had this backwards and was
  corrected the same day: "Show distance when shot #'s are consecutive … and don't
  show otherwise … i.e. there's missing shots")*. The line is a trace of what
  happened, drawn behind the numbers a golfer is about to act on; at the plan's
  weight it read as a decision. A leg from 2 to 3 **is a shot** and its length is
  how far that shot went. A leg from 1 to 3 with no 2 measures nothing anybody
  played, so putting a number on it would state something nobody logged. Unnumbered
  shots label nothing. It prints with **no plate, a small face, and the number
  alone** — the unit is on the big number at the top — and it is offset to the
  **left** of the line, because a pill extends to the right of its point and the
  label was landing under the next shot's caption. This is why `PlayerTrack.shots`
  is `[Shot]` with a **number** on each rather than bare coordinates.
- **The markers switch takes the lines with it** *(user, 2026-08-28)*. A line
  joining pills that are not drawn is a line between nothing and nothing. It also
  settles the question left open the day before, when the two controls disagreed.
- **A marker is drawn only on the hole it belongs to** *(user, 2026-08-28: "markers
  from other holes should not appear")*. They were drawn wherever their coordinates
  put them, so a hole running back alongside the previous one carried the previous
  one's captions across it. `tracks(for:)` had always filtered this way and the
  pills had not. **A row with no hole is still drawn on every hole** — it could not
  be placed, so it belongs to all of them rather than to none, the same rule the
  round screen's timeline follows.
- **The legend sits under the hole box, top left** *(user, 2026-08-28: "move player
  name buttons arranged starting from just below hole #, not from bottom")*. They
  are switches for what is drawn on the hole, so they belong beside the thing that
  says which hole it is — and the bottom left is where the tracking chip, the move
  confirmation and Apple's attribution already compete.
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
- **The hole view's roster is the round's, replayed from its journal — never
  `RoundViewModel.players`** *(found 2026-08-28 by screenshotting a hole with placed
  shots on it)*. `model.players` is the *setup screen's* list and is empty whenever
  the hole view was reached on a round that is not the one recording, which is most
  of the time and every finished round. Everything X13 built matches a log's
  `player` id against that list, so with it empty a shot pill lost its name **and
  its colour** and `tracks(for:)` returned nothing at all — the connecting line the
  user asked for had never once been drawn. `CourseView.loadLogs` replays
  `JournalReplay` over `meta.players` (a player added mid-round exists only in the
  journal) and deliberately **does not** go through `RoundDocument`, which rewrites
  `scorecard.json` on every replay and would do it once per phrase during a burst.
  Same rule as `MarkerSheet.roster`, arriving one screen along.
- **`DemoSeed`'s logs are placed on the course it names.** They marched north from
  37.7402, -122.2661 — three kilometres west of Corica — so every seeded log was
  *placed*, none was on any hole, and **the marker layer could not be seen in this
  environment at all**; the fault above hid behind it. Points are interpolated along
  each hole's own white-tee-to-green line, and three of them carry a player and a
  shot, because a shot is the only entry that draws a coloured pill or joins a
  track. **One sits twenty metres off the white tee of hole 1 so that its pill lands
  *on* the simulated marker** — the simulated position seeds at the tee and a pill
  hangs below its own point, so before that row existed the two never overlapped and
  "is the simulated marker above the pills?" could not be looked at here at all. It
  is placed down the tee-to-green line rather than due north, because the camera is
  rotated to put the green at the top: *increasing* latitude moves a point **down**
  the screen.
- **On satellite a marker pill is anchored `.bottom`, so it sits above its point.**
  Centred on the coordinate it covered the very thing it is a claim about — which
  only became visible once markers moved *under* the tracks and a shot dot landed on
  the caption. The vector layer has always drawn the pill above the point.
- **A marker written on the hole view has to appear on it, and one signal is not
  enough** *(user, 2026-08-28: "just created marker is not shown in gps hole view")*.
  `CourseView` read `log.jsonl` once, on appear. Reloading when the Marker sheet is
  dismissed covers the entry that had a warm fix and **not** the one that did not: a
  log with no coordinate is not drawn at all, and `MarkerSheet.place()` converges in
  a detached task that routinely lands *after* the sheet has gone — so dismissal
  alone shows nothing in exactly the case the golfer waited for. It listens to
  `LogStore.didAppend` as well, `.receive(on: RunLoop.main)` because convergence
  appends from a background queue, and comparing with **`SessionFolder.isSame`** —
  that exact comparison cost twenty-nine invisible logs on the round screen.
- **A hole marker is a view type, not a `LogEntry`** *(X7)*. `GolfMap` must not know
  what a log is — that would drag the session format into the target that draws a
  hole. The app flattens a log into `HoleMarker`: position, SF Symbol, abbreviated
  text. **Abbreviated at a word boundary**, because a hard character cut reads as
  corrupted text rather than as a beginning.
- **What a marker *shows* is what it is, not how it was captured** *(X13, user
  2026-08-28: "no need to show keyboard or record icon")*. The waveform and the
  keyboard said which recogniser wrote the row — a fact about the app, repeated on
  every pill on the hole. An icon is now earned by being a **shot**: a golfer
  scanning a hole is looking for where somebody played from, so an entry with a
  player and a number reads `[golfer] 2 · steve` in **that player's colour**, and
  everything else is its own abbreviated sentence with no icon at all.
- **A tap on a marker opens its dialog, and this does not undo X9.** X9's complaint
  was the *discarded* tap — one that placed no target, dismissed nothing and did
  nothing, which is indistinguishable from a frozen screen. Everything that made
  markers unobtrusive stays: the handle is the size of what is drawn, they are
  checked last, and a tap that misses one still falls through to the ground. Only a
  **drag** moves a marker, and only a drag raises the move confirmation — one
  gesture decides which from how far the finger went, on both layers.
- **A marker is one object, it is drawn under everything else, and it is the last
  thing a finger picks up** *(X9, user 2026-08-28)*. Three rules with one cause: it
  is on by default (`marker.showMarkers`), so whatever it costs, it costs all the
  time. **One pill**, icon and text together — an icon chip with a caption box under
  it read as twice as many objects as the hole had. **Under everything** *(sharpened by the user
  2026-08-28: "z position for markers should be the lowest, i.e. least priority")* —
  it began as under the plan and the rulers, and is now under the pin, the tees and
  the players' tracks as well, because it is the only thing on the hole that is a
  claim about the *past*; a yardage about to be clubbed off must never be covered by
  a caption of something said an hour ago. **On the satellite layer that is
  declaration order**, where `markerOverlays` had been last — which is *top* — and
  it buys less than it looks: MapKit draws every `Annotation` above every
  `MapPolyline`/`MapPolygon` whatever the order, and the pill carries its own
  `DragGesture` on a `contentShape`, so it takes the touch outright. Order fixes what
  is *drawn* on top; only `VectorHoleView.hit` makes markers last to be picked up. And a **handle the size of what is drawn**
  (`HoleStyle.markerGrabRadius`, 17) rather than the 39-point `grabRadius` a target
  gets, checked last of everything, with **a tap on a marker falling through to the
  ground**. A dozen 39-point discs blanket a hole in invisible handles, and the tap
  they caught was *discarded* — it placed no target and dismissed nothing, which is
  indistinguishable from a frozen screen. Only a *drag* that starts on a marker moves
  it. Pills stack upward off a leader line when two land on each other.
- **The move confirmation is a strip in the layout, not an alert and not a
  `confirmationDialog`** *(user, 2026-08-28: "should not cover too much of the
  screen. Make it smaller and down to the bottom")*. The question is whether the
  entry is now in the right place, and an alert lands in the middle of the display
  over the pill, the hole and the numbers — i.e. over everything that answers it.
  `confirmationDialog` was the obvious substitute and on iOS 26 comes up as a
  centred card of much the same size: the same fault in a different shape. It sits
  directly above the hole controls, one row high, where the thumb that just did the
  drag already is.
- **A drag holds the gap between the finger and the marker, on both layers** — the
  `DragAnchor` rule, which the satellite marker was the last thing on the hole not
  to follow *(user, 2026-08-28: "currently dragged marker's center snaps to finger
  position, it should not")*. It converted the fingertip straight to a coordinate,
  so the pill jumped under the hand on the first event — which defeats the handle
  reaching below the point, since the offset that handle exists to create was thrown
  away by the next frame. In degrees there, because `MapProxy` is what projects.
- **A dragged shot carries its track with it** *(user, 2026-08-28: "when moving
  marker with shot associated, line point and line should move along")*. The pill
  and the track through it are two drawings of one row, and moving one without the
  other puts the shot in two places at once — the same class as drawing a hypothesis
  like a fact. `drawnTracks` substitutes the in-flight position, **matched by
  coordinate**, which is the only key there is: `PlayerTrack.shots` is a list of
  bare points and both it and the marker come from one `LogEntry`, so the marker's
  original position is bit-for-bit the track point to replace. Nothing is stored —
  it is thrown away on release, exactly like the pill's position.
- **While the confirmation is up, the proposed position is drawn — as a proposal.**
  `onEnded` clears `markerDrag`, so the pill and its track snap back to where they
  started the instant the finger lifts, and the question "Move this entry?" then had
  no referent on screen at all. That was invisible while the alert covered the hole;
  making the confirmation small is what exposed it. `pendingMarker` draws a **hollow
  ring on a dashed tether** from the pill — the focus ring's visual language, chosen
  for the same reason: nothing is written yet, `LogEntry` still says the old
  position, and a proposal that renders like a placed marker is the simulated-fix
  failure again.
- **The bottom HUD is measured, because Apple's attribution lives underneath it.**
  `bottomReserve` is `110 + barHeight + hudHeight`, and `hudHeight` covers the legend
  **and** the move confirmation as one block — two separate measurements would need
  two rules about which is stale, since the confirmation comes and goes. Found by
  screenshot: "Map" and "Legal" sat behind the legend on the satellite layer. It was
  a covered link while the legend was read-only; X17 made every row a button, so it
  had begun swallowing taps meant for the link as well.
- **A dragged marker is confirmed, and written as a superseding row.** A log's
  coordinate is the evidence a proposal rests on, and the hole view is full of things
  that *are* dragged — one nudged while reaching for a target would silently move
  where a shot was said to have happened. The original stays in `log.jsonl`, so a
  citation still renders, and the hole is recomputed from the new position rather
  than carried over.
  **The confirmation fires on release, and only if the finger went somewhere**
  *(X9, user 2026-08-28: "warning is after drag is done. for now it's before")*. It
  was raised from `onChanged`, so it appeared on the first pixel and asked about a
  point the finger had already left. The in-flight position is held in the renderer
  (`markerDrag`) and reported once, on `onEnded`, gated on `wandered` — a press and
  release would otherwise raise a dialog for a zero-length move. It is **cleared on
  release too**: until the row is written nothing records the marker anywhere but
  where it started, and drawing it at the new place while the alert is still asking
  is the same lie as drawing a simulated position like a fix.
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
- **A simulated position is used for a log, and that is a knowing trade** *(X3)*.
  Simulation exists to try the app somewhere other than where the phone is, so a log
  recording the desk instead would make the mode useless — it overrides the
  stabilised fix too, and `settle` does not run. The consequence: a hand-placed
  coordinate sits in `log.jsonl` looking exactly like a measured one, because
  `LogEntry` has no discriminator. `Mark` is protected from this by MARK being
  disabled while simulating; a log is not, because a log is an observation rather
  than ground truth.
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
| `GolfSessionFormat` | **Done.** Types, `LogEntry` (+supersede/tombstone), `Event`, `JournalEntry`/`JournalReplay`/`RoundState`, `JSONLWriter` (`O_APPEND` + `flock`) / `JSONLReader`, `SessionFolder` I/O, `SessionIndex`, `SessionClock` |
| `GolfCaptureCore` | **Done.** `AudioRecorder` (segmented), `LocationRecorder`, `RoundSession` |
| `GolfCaptureMotion` | **Done.** `MotionRecorder` — activity, pedometer, barometer. iOS-only |
| `GolfCourse` | **Done.** `Course`/`Hole`/`Green`/`TeeBox`/`HoleGeometry`, `Elevation` (grid, bilinear sampling, the datum rule), `Handicap`, `Course.nearestHole`, `CardLayout`/`CardYardage`, `CourseCard` + reconciliation, `CardText`, `OSMCourse` (ways **and** multipolygon relations, `golf:course:name` splitting, cart paths), `DistanceUnit`, `Geodesy`, `HolePlane`, `CourseStore`, `SampleCourse` |
| `GolfCourseOSM` | **Done.** `CourseOSM` (Overpass queries, retry, 504 classification) and `Nominatim` (structured three-rung name search). Split out of `golfctl` on 2026-08-30 so the app can import it |
| `GolfTerrain` | **Done.** `Elevation3DEP` (USGS 3DEP `exportImage` in EPSG:4326 + the point service for native resolution) and `GeoTIFF` (uncompressed F32, tiled and stripped, both byte orders). New 2026-08-30. No Korean source |
| `GolfMap` | **Hole view + editor done.** `VectorHoleView` (Canvas, offline, pans/zooms/taps), `SatelliteHoleView` (MapKit imagery), `HoleScreen`, `CourseEditorView`, `HoleReadout` (plays-like off a stored DEM), `DistanceDisplay`, `TeePalette`. Replay and the elevation *profile* are not built |
| `GolfTranscription` | **Both engines done, file and live.** `Transcriber` protocol; **WhisperKit** (`WhisperEngine`, `WhisperModels`, `WhisperDecoding`, `WhisperTranscriber`, `WhisperLiveTranscriber`) is the one the app runs; `AppleTranscriber` + `LiveTranscriber` are the comparison arm. `SessionTranscriber` (segment walk + clock mapping + per-segment cache keyed on `runID` and the *effective* locales), `GolfVocabulary` |
| `AnthropicClient` | **Done.** `POST /v1/messages` over raw HTTPS — text, image and PDF blocks, `output_config.format` JSON schema, adaptive thinking, refusal detection. Knows nothing about golf |
| `golfctl` | `record`, `inspect`, `transcribe`, `models`, `live`, `relisten`, `course sample|show|import|osm|elevation` implemented; the rest print "not implemented" |
| App target | **Logs + journal + card + live transcription + OSM course download + terrain download done.** `LogStore`, `LogPlacement`/`StableLocation`, `RoundDocument` (journal-backed), `RosterEditor`/`PlayerEditor`/`HoleDetailSheet`/`HistoryView`/`LogEditor`, `ScorecardBand`, three-band `RoundScreen`, **`LiveTranscript` + `MarkerBar` / `MarkerSheet`** (Marker · Round · Location on both screens; recording off by default, one burst per sheet) and **`WhisperModelPicker`**. **Still no model step** — nothing extracts events from the logs. Also `LogRetranscribe` (re-read one entry with the final model), copy-entry / copy-transcript, the map button opening a log's own hole, and **`CourseFinder`** — search OpenStreetMap by name or near the phone, pick a course at the site, read the three checks, save — and **`TerrainSheet`**, the on-demand USGS 3DEP download with its own three checks |
| `GolfReconstruction` | **`LogExtraction` + `CardReading` done** — instructions, per-hole prompt, `Proposal` → `.model` `Event`. Deliberately model-agnostic (no Apple-framework imports), which is why both survived the scrap intact. The cloud reconstructor is still a placeholder and is now the **only** planned extraction tier |
| Everything else | Placeholder files with TODOs |

Tests: 473 (1 skipped when the mic is already authorized). The iOS app launches in the
simulator; the simulator has no barometer or motion coprocessor, so those read empty there, and
**it has no speech model**, so nothing spoken can be tested there either.

### Audio — in the app as of 2026-08-27, and recording is a button

**`recordAudio: false` is the app's default and it is not a disabled feature.** It means "do not
open the microphone *with* the round". `RoundSession.startAudio()` / `.stopAudio()` open and close
a **burst** mid-round as often as the user taps, so a round holds several `.m4a` segments with
**real gaps between them** — which is exactly what the segment format has always expressed and
what `AudioTimeline` refuses to accumulate away. `AudioRecorder`'s `AVAudioEngine` stays `lazy`,
so a round nobody records builds none of it.

`NSMicrophoneUsageDescription` (an `INFOPLIST_KEY_*`) and `UIBackgroundModes: audio` (in
`Info.plist`) are both back. **`RoundSession.stop()` tears audio down on `audioRunning`, never on
`recordAudio`** — with a button the mic can be live on a round that started without it, and gating
the teardown on the constructor flag leaves the engine running and the last segment unclosed.

**`stop()` deactivates the audio session, and that only became necessary when recording became a
toggle.** `.record` silences every other app's playback and a session is deactivated only
explicitly, so without `setActive(false, .notifyOthersOnDeactivation)` the first burst would kill
the group's music for the whole round with the orange microphone dot lit the entire time the app
claims not to be listening. A control that looks like it is recording while it is not is the same
failure as a simulated position drawn like a fix.

**Recording and transcription fail separately, and the UI says so separately.** The simulator has
a working microphone and **no speech model at all**, so a burst there writes a perfectly good
`.m4a` while `LiveTranscript.status` reports unavailable. Collapsing the two into one flag makes
that read as the record button being broken. Verified by screenshot 2026-08-27: red button
counting up, caption pane naming the simulator, `audio-000.m4a` growing on disk, `meta.audioRoute`
= `MicrophoneBuiltIn`.

**`meta.audioFormat`/`audioRoute` are stamped on the first burst, not at round start.** `start()`
writes `"none"` when the round begins silent, which is now the default, so a round that recorded
three bursts would otherwise claim it never recorded.

*Still unverified on a phone, and only a phone can settle it:* the interruption path, the stall
watchdog against a genuinely dead tap, background audio survival, and the battery cost of two
recognizers over 4.5 hours. **Nor has a burst ever been stopped by a finger** — scripted taps do
not exist here, so the close path is verified by `golfctl record --mic-off` on macOS and by test,
not by tapping Stop.

**`AVAudioEngine.inputNode` can abort the process rather than throw.** Seen twice in the simulator
2026-08-27: `AURemoteIO::Initialize()` RPC-timed out and `AudioToolboxCore` called `abort()`,
inside `AudioRecorder.startEngine()`, with nothing catchable anywhere — a `SIGABRT` from the audio
server is not an error you can handle. A simulator reboot cleared it and it has not recurred. The
saving grace is the default: **recording is off**, so a wedged audio server costs one tap and not
a launch-crash loop. Do not add a `try?` and think you have covered it.

**No `.allowBluetooth` in the audio session, ever.** Connected AirPods would become the input
over HFP — narrowband and beamformed at the wearer's own mouth, recording the phone's owner
nicely while suppressing the other three players. That is the exact capture the product depends
on. `configureSession()` uses `.record` with no options and pins `.builtInMic`, and the resolved
route is written to `meta.audioRoute` so a bad round is distinguishable from a bad premise.

**`AVAudioSession` category is what grants background recording**, not `UIBackgroundModes:
audio`. `AudioRecorder.configureSession()` sets **`.record`** + `setActive(true)` before the
engine starts. Remove it and the app records fine with the screen on and stops the moment the
phone goes in a pocket — i.e. the whole round, and macOS tests cannot catch it. `.record` and
not `.playAndRecord`: nothing is played back during a round, and `.playAndRecord` would take
the output route as well and duck whatever the group has on. *(This paragraph said
`.playAndRecord` until 2026-08-27 and the code always said `.record` — the doc was wrong, not
the code.)*

Audio is **segmented** (`audio-000.m4a`, `audio-001.m4a`, …) with an `audio.jsonl` index of
`AudioSegment` rows. A 4.5-hour recording will be interrupted by a call or Siri; each
interruption closes a segment and the resume opens the next, so no sample drifts behind a
single whole-file offset. Do not collapse this back to one file.

`golfctl` parses arguments by hand — swift-argument-parser arrives in Phase 3 with the
subcommands that need it.

### Logs, the journal and the card — the app's input path

**A `LogEntry` is an observation, not ground truth** *(decision 2026-08-27)*, and that decision
is the whole shape of `log.jsonl`. A log is what the microphone would have heard, so it is
**model-visible** and extraction reads every row. Ground truth stays exactly as narrow as it
was: `Mark`, `Scorecard`, `Correction`, and an `Event` with `.user` provenance — which now means
specifically *a correction to a proposal*, not "anything a human typed". Reading it the other
way would put the entire product input behind the firewall and leave extraction with nothing to
read. `Event.modelVisible(_:)` needed **no edit**, `Event.Provenance` is still two-valued, and
`SessionFolder.File.log` is deliberately in neither the `groundTruth` nor the `mixedProvenance`
set. `LogEntryTests` asserts all of that.

**The input box writes a `LogEntry`, not an `Event`.** `RoundDocument.addLog` is the box;
`Event.typed` survives for the other thing — adding an event by hand *after* extraction, which
is a correction and genuinely is ground truth. Do not merge them back together.

**`JSONLWriter` opens `O_APPEND` and brackets each line in `flock`.** This was written because
a Siri App Intent wrote these files from a second process, and it **stays** now that the intent
is gone: `seekToEnd()` resolves the offset once, so a second writer overwrote the first from a
stale position and rows vanished silently; `O_APPEND` re-resolves inside every `write(2)`, and
`flock` stops a line being torn by an interleave — the one failure `JSONLReader` cannot recover
from, since it skips a bad *line* and an interleave corrupts two. It costs nothing and it is
what will make a live transcription feed appending alongside the input box safe by construction.

**A location delegate must own itself until it answers, and any deadline must live outside
CoreLocation.** *(Found on device 2026-08-27 and it cost a whole session: control reached the
app and no log appeared.)* `CLLocationManager.delegate` is a **weak** reference, so with the
timeout block capturing `[weak self]` nothing held the delegate once `start` returned — ARC may
release a local at its last use, not at end of scope. Released, it fires no callback and its own
timer no-ops, so the continuation is **never resumed**: no log, no error, nothing in any log
file. `StableLocation.Delegate.keepAlive` holds it, released a run loop turn after it answers
(dropping it inside a `CLLocationManager` callback deallocates the manager mid-call). Race the
whole location step against a deadline held *outside* CoreLocation too — the promise was
otherwise being kept by the object that had already vanished.

**Recording what was said must never wait on GPS.** `LogEntry.hasPosition` is false when no fix
arrives, and that is a real answer. The golfer has spoken a sentence and is walking away; an
input path that hangs for a fix is worse than a log with no coordinate. Never substitute the
last known position — that places a shot on the previous hole and looks exactly like a
measurement.

**`Course.nearestHole` is a proposal, not a fact, and the answer is stored on the log.**
Adjacent fairways run tens of metres apart and a GPS fix is ±3–5 m at best, so the nearest hole
to a point between two fairways is a coin toss — the same wall that makes language, not sensors,
the thing that attributes a shot. It returns the **1-based playing-order index**, because that
is what a scorecard column means and `Hole.ref` is not a key.

**There is no extraction pass in the app.** *(Scrapped 2026-08-27.)* `FoundationModels` was it,
and it is gone: ~4,096 tokens of context *including output* so a round does not fit, no image
input, on-device-only on iOS 26 (Private Cloud Compute is not exposed and a third-party app
cannot use a linked ChatGPT account), and it generated garbage on real input. The replacement is
E7 — the cloud pass through `AnthropicClient`, over `GolfReconstruction`'s existing
model-agnostic instructions. **Do not write another on-device model path** without new
measurement.

**The journal is the record; the card is a view of it.** *(User decision, 2026-08-27.)*
`journal.jsonl` holds every act a person performed on a round — score, stat, handicap index,
tee, roster edit, course, accepting or rejecting a proposal — and `scorecard.json` plus the
roster are **derived** by `JournalReplay.replay`. `setScore` used to rewrite the whole dict, so
the previous value was simply gone: nothing to undo, nothing to retrace, nobody to blame.
Consequences that are easy to undo by accident:

- **`JournalEntry` is flat with optionals, in the shape of `Correction`** — not an enum with
  associated values. These files are the user's own scores and a new act or field must not stop
  an old row decoding.
- **Undo is a row (`act: .undo`, `undoes: id`), and an undo can itself be undone — that is
  redo.** `JournalReplay.live` resolves it by walking **newest to oldest**, so every undo that
  could cancel a row is decided before that row is reached. A forward pass gets three-deep
  chains wrong and a fixpoint loop over the whole set is not guaranteed to converge.
- **`live` and `inForce` answer different questions.** `live` drops every `.undo` row, because
  replay must never apply one as an act; `inForce` keeps the ones still standing, because a
  history screen asks "is this row in force?". Using `live` for the screen struck through every
  undo and labelled it UNDONE — the opposite of what happened. Found by screenshot.
- **Replay is seeded from `scorecard.json` and `meta.json`.** A round played before the journal
  existed has no journal, and that snapshot is the only record there is.
- **`meta.json` is never rewritten from replay.** `writeJSON` is temp-file-then-replace with no
  `flock`, and two processes replaying at once would clobber it. `scorecard.json` survives that
  because it is a cache the journal rebuilds; the roster is not, so `state.players` is the
  answer on screen and `meta.json` stays as the round was started.
- **One act is one row.** Accepting a `.score` proposal writes **only** `.acceptEvent`; the
  score it claims is applied inside `JournalReplay` at that row. The first version also wrote a
  `.setScore`, so one Undo reversed half the act and left the card disagreeing with the
  proposal list, and the history showed every acceptance twice.

**Handicap is three numbers and only the ends are stored.** *Index* is the player's, journaled.
*Rating and slope* are journaled too, **frozen at round start** *(user decision, 2026-08-27)* —
re-importing a course must never rewrite a card already played, and one bad import would
otherwise silently move every round in the history. *Course handicap* is
`Handicap.course(index:rating:slope:par:)` and is **never stored**; it returns **nil** when
rating or slope is missing, because most course files here have neither and an invented number
is several shots wrong. **None of this is `Hole.handicap`**, which is the stroke-index row —
same word, unrelated quantity. They meet only in `Handicap.strokesReceived`, which allocates by
**1-based playing order**, never by `Hole.ref` (a Korean 27 has three holes called "3").

**A log is amended by appending, and that is why it is not a journal act.** `LogEntry.supersedes`
plus a `deleted` tombstone carries all four mutations — the late coordinate, an edited sentence,
a moved hole, a deletion. It lives in `log.jsonl` because a log is **model-visible** and the
journal is **ground truth**: an edit recorded there would be invisible to the extraction pass,
so the user would fix a misheard name and the model would go on reading the old one. Delete is a
tombstone rather than an absence because a proposal cites logs by id and would otherwise render
a claim resting on nothing. `LogEntry.current` collapses for display; `byID` keeps every version.

**A log is written first and placed second.** The write takes whatever fix is already warm, or
none; `LogPlacement.converge` — driven by `RoundScreen`, holding a `beginBackgroundTask` and
using `TrackingMonitor` for "locked" — appends the superseding row afterwards. Keep it driven by
the foreground app, which has a real lifecycle and is reachable in the simulator. *(This was
first attempted inside the Siri intent's `perform()`, where a detached task races the teardown
of the background-launched instance: the process is suspended and the radio stops half way with
nothing written.)*

**Reading a photographed card is OCR → text → a model, in that order.** `CardReading` (package,
model-agnostic) is built and survives the scrap; the on-device half that drove it does not. When
it is rebuilt against the cloud pass, keep the shape: OCR output arranged as a **grid** —
bucketed into rows by vertical position, tab-separated — because a card is a table and
`VNRecognizeTextRequest` returns a flat reading order, the same reason `CardText.strip`
preserves columns; and `usesLanguageCorrection` **off**, because it invents plausible readings
of smudged digits. **`CardReading` produces proposals, never writes** — a card read off a
photograph is 95% right and silently wrong in one cell, and the card is the answer key.

**A log's `hole` is never a retry condition — that was an infinite loop.**
*(Reported from the device 2026-08-27.)* `Course.nearestHole` declines beyond 250 m, so a
perfectly good fix taken anywhere but on a mapped hole resolves to nil. `LogPlacement` treated
that as "still unplaced", so it converged, appended a superseding row, saw the nil hole again,
and converged again — forever, and each lap also refired the extraction pass hanging off the
same signature, because the new row changed `RoundScreen`'s task id. `LogEntry.isPlaced(within:)` is the condition and it looks
at position and accuracy **only**; it lives in the package so the thing that caused the loop is
reachable by a test. Converging always writes a position, so a converged log can never be a
candidate again — structurally, not by a guard. `LogPlacement.attempted` is the second belt: a
convergence that finds *no* fix leaves the log unchanged, and without it the backlog is
re-walked at fifteen seconds of radio per log.

**"Has an event cited this log?" is not a coverage check, and using it as one runs the model
forever.** A log that yields **no proposal at all** — "we're on the ninth", "players are A, B,
C, D" — is cited by nothing, so a citation check reports it unread on every pass, and every pass
that hallucinates something appends another event. `ExtractionCoverage`
(`extraction.coverage.json`) records which log ids have been *shown to the model*, written **per
hole** so a killed run does not re-read what it finished, and recording **which extractor** ran
so the cloud pass is not served the on-device pass's cache. Exactly the trap
`TranscriptCoverage` exists for, one level up — a silent segment produces no utterances.
**Keyed on the row id, never the chain root**: an edited log is a new id and *must* be re-read,
since correcting a misheard name is the entire reason to edit it. Citations are still consulted
as a second source so a round extracted before the file existed is not re-read from scratch.

**The roster is editable mid-round, and its absence caused a bug report.** There was no control
anywhere to add a player after a round started, so the first person who wanted one typed
"Players are A, B, C, D" into the log input — the only free-text box on screen — which is an
observation with no shot in it and fed the loop above. `RosterEditor` adds and removes through
journal acts. It accepts several comma-separated names and strips a leading "players are" /
"playing with", which is **a fixed prefix and a separator, not a parser** — it never reaches the
model, and anything it does not recognise becomes one player with a long name, visible and one
swipe to delete. Removing a player **keeps their scores** (`JournalReplay` does not delete
them), so putting them back restores the card.

**A row with no hole is drawn on every hole, never on none.** *(Found on device 2026-08-27.)*
`LogEntry.hole` / `Event.hole` are nil whenever `Course.nearestHole` declines — no fix inside
the deadline, no course file for the round, or **more than 250 m from any hole**,
which is every test run anywhere but on the course. `RoundScreen.timeline` filtered on
`$0.hole == hole`, and `nil` equals no hole number, so a log the app had just confirmed it saved
was invisible on all eighteen and reachable only under *All holes*. Same claim as
an un-extracted log keeping its own row: a sentence that could not be **placed** still has to
be **seen**. Both row types carry a `no hole` chip so the repetition reads as an open question
rather than a duplicate, and any extraction pass must read the nil bucket alongside the selected
hole so it reads what the screen shows. **The old "do not close the gap by stamping the hole the
app last had selected" rule ended in "and needs a discriminator on `LogEntry` first" — that
discriminator is `LogEntry.holeSource`, built 2026-08-28.** A hole may now be stamped from the
screen *provided it is marked `.user`*, which is what keeps `hole` from carrying two claims at
once and what stops convergence overwriting it. Nothing else about the nil bucket changes: an
entry made with no hole chosen still has none, and is still drawn on every hole.

**A cited log is quoted under the event it produced, never given its own row.** Showing it twice
is clutter; hiding it behind a count is worse, because verifying a draft then costs a tap and
verifying drafts is the entire job of that screen. A log with **no** event beside it keeps its
own row — that is the visible signal that nothing has read it yet.

**The scorecard's columns and its yardage row are decided in the package** (`CardLayout`,
`CardYardage`), because both have a way of being quietly wrong on screen and exactly right in a
screenshot. Two things the obvious version gets wrong:

- **Out / In assumes holes numbered 1–18**, which is what `Hole.ref` is not. Named nines win
  when a course has them.
- **`cardLength(from: nil)` means "the default tee", not "no tee".** So the obvious
  `hole.tee(named: name).flatMap { … }` prints the *longest* tee's yardage under a heading
  naming a tee the hole does not have — an ordinary-looking number, a club and a half wrong.
  `CardYardage.of` returns `.none` for a tee that is absent. Caught by a test, not by reading it.
- **The yardage row is empty on an OSM course, which is every course file that exists.** OSM
  never supplies yardage in any region. A measured centre line is offered instead and is
  **marked with `~`** — it is a different quantity, not a substitute (Corica hole 1: 469 yd on
  the card, 426 measured, because nobody carries the corner of a dogleg).

## Known gaps

- `Mark`/`Scorecard`/`Correction` are in `GolfSessionFormat`, which `GolfReconstruction` depends
  on, so the firewall is convention, not structure. Moving them into their own target that only
  `GolfEval` depends on would make it real. **Raised 2026-08-24 and deliberately deferred** — do
  not restructure without asking. Until then: grep `GolfReconstruction` for `Mark`/`Correction`
  before shipping any bundle change.
- **There is no terrain outside the US, and no way to get any yet.** `Elevation.Source`
  models `.copernicusGLO30` and `Datum` models `.egm2008`; nothing writes them. A Korean
  course's plays-like chip simply does not appear, which is the honest answer — and GLO-30
  is a **surface** model that carries canopy and roofs as ground, so it is a worse answer
  than it looks. research-elevation.md §3.2.
- **The satellite layer's leg labels do not de-collide, and a short approach leg lands
  under the big distance at the top.** `PlanLayout` dodges occupied rectangles and pushes
  perpendicular for the vector layer; `SatelliteHoleView.labelPoint` just drops an
  annotation at a fraction along the leg. **Pre-existing** — it was worse before the
  approach box was moved to the target end on 2026-08-30 — and visible on Coyote hole 8,
  where the approach is 101 yd and target 2 sits at 0.7 of the hole. The elevation suffix
  made it obvious rather than causing it. The real fix is a **top** reserve on that layer,
  the way `bottomReserve` protects Apple's attribution; not done.
- **The terrain sheet has never been used by a finger.** It downloaded, checked and
  rendered in the simulator under `-marker.terrain fetch`; Save, Cancel and the
  "Download again" path over an existing file are unexercised — scripted taps do not
  exist here.
- **`k = 1` is unmeasured against a real round** (E3), and nothing records that a hole was
  played, so `GolfEval` has nothing to fit against yet. It lives in `Geodesy.playsLike` as
  a named parameter for exactly that.
- **Only two courses have terrain**, both in California, both reporting 1 m lidar. The
  coarse-product path (`native > 1.5`, printed as *NOT lidar*) and the void path have
  never been exercised against a real response.
- **A name in the other script now matches nobody.** Aliases were removed on 2026-08-31, so a
  roster that says `steve` does not resolve a card row or a spoken "스티브". `CardReading`
  returns the row with a nil `player` rather than guessing, and the extraction prompt still asks
  the *model* to allow a different script — but our own `CardReading.match` cannot cross scripts
  and nothing measures how often that costs a row. It bites hardest for a bilingual group, which
  is the group this app is for. **Attribution accuracy is still the metric that decides the
  feature**; watch it in `GolfEval` (L5).
- WhisperKit's iOS floor is still unverified (PLAN §4).
- **A guessed par is indistinguishable from a surveyed one.** `OSMCourse` writes
  `par: 4` where the tag is missing — 11% of US hole ways — and `Hole.par` is a
  non-optional `Int` with no discriminator, so the scorecard, the hole box and the
  legend's new score-to-par all state a number nobody surveyed as though somebody
  had. `PlayerTrack.toPar` guards a par of **zero** and can do nothing about a
  defaulted four. The fix is an optional or a `Hole.parSource`; not done.
- **Still open from research-course-map.md §4 (C1–C6):** VWorld's storage terms and whether its
  domain-registered API key works from a native iOS app; how accurate a track-derived green centre
  is after one round. **C3 — MapKit `.imagery` over Korea — is closed and the answer was good**;
  see the last bullet of this list. This bullet listed it as open until 2026-08-28, contradicting
  that one.
- **GPS duty cycling is done, items 16 and 17 both — and 17's answer was reversed on
  2026-08-30.** Slow is still the resting state, but **fast is now the hole view as well
  as the Marker sheet** *(user: "fast track when gps hole view is on screen, slow when
  not")*, on both feeds, each caller holding its own `FastReason`. The 2026-08-28
  answer — that the hole view should *not* speed anything up — is history. Since a hole
  view is open for most of a round, **whatever the saving was, it is now smaller**, and
  it was already an estimate: the full-rate baseline round was voided by the user, so
  there is no before-number and never will be.
- **A whole round has never been played on a phone.** *(Narrowed 2026-08-28. This bullet
  said "the iOS app has never been run on a device", which was false and contradicted three
  times in this file — the setup screen was "verified on device", and the delegate-retention
  bug and the invisible nil-hole row were both **found on device** on 2026-08-27.)* The app
  runs on a phone, the hole view has taken five rounds of hands-on feedback, and a burst has
  recorded and transcribed there. What has never happened is a **round**: motion and
  barometer over 4.5 hours, background survival with the phone in a pocket, battery cost,
  and the session folder as it comes off a phone rather than a Mac are all still unmeasured.
  The audio half of the same gap is "Still unmeasured on a phone even so", below.
- **The app has no model.** *(Narrowed 2026-08-27 — the microphone half of this gap is closed;
  the record button, `LiveTranscript` and the log-writing path are built.)* Nothing reads
  `log.jsonl` and proposes events: `GolfReconstruction`'s `LogExtraction` is written and
  model-agnostic, and the cloud pass through `AnthropicClient` that would drive it is a
  placeholder. **This is now the blocking gap.** Until it exists a round accumulates sentences
  and the card is filled in by hand.
- **The shot a pill names and the shot a stepper numbers differ by one.** `ShotName`
  offsets the *display* so the tee shot reads `T` (user, 2026-08-29) and storage is
  untouched — so the hole view says `1 · steve` for the entry whose Marker sheet
  stepper says 2 and whose log text begins `"1: 2 …"`. Deliberate for now: renumbering
  `LogEntry.shot` reaches `LogEntry.nextShot`, the log prefix the extraction pass
  reads, `RoundExport` and every round already on disk. The fix, if the mismatch is
  worth closing, is to display `ShotName` in the sheet and the prefix too — not to
  renumber storage.
- **Nothing on disk records that an entry was re-read.** `LogRetranscribe` writes an
  ordinary superseding row, so a re-transcribed burst entry and a live-grown one are
  indistinguishable in `log.jsonl` — "has the big model already seen this?" has no
  answer. Not urgent; a discriminator on `LogEntry` would be the fix if it becomes one.
- **The re-transcribe has never run on a phone**, and neither has the two-model
  picker. Verified on macOS through `golfctl relisten` against a real AAC `.m4a`
  (seek, resample, sub-range decode, model switch); the button, the row spinner and
  the download-on-select for the second slot are unexercised by a finger.
- **Only `openai_whisper-small` and `-tiny` have ever been run here.** The feature's
  premise — a bigger model hears names the small one misses — is supported by the
  tiny-vs-small comparison and by nothing larger, because no big model has been
  downloaded on this machine.
- **The name prompt's benefit is unmeasured; only its safety is.** *(This bullet used to be
  paired with one saying `promptTokens` was "deliberately not wired". It was wired on
  2026-08-28 for the on-demand pass — see the invariant above — and that stale pair is gone.)*
  `DecodingOptions.promptTokens` genuinely biases decoding, unlike the `contextualStrings`
  knob measured inert on `SpeechTranscriber`, and with diarization cut a spoken name is the
  *only* attribution signal there is. Evidence it is needed, from the first real run: "Min is
  putting" → "Mint is putting". The A/B on 2026-08-28 showed no language flips and no
  repetition loops — but the fixtures are `say` output and pronounce every name cleanly, so
  exactly that case cannot appear in them. One scoring word degraded on `ko2`. **The live path
  is still unwired**, because a Whisper prompt too long or too unlike the audio induces
  hallucination and repetition loops. L5 decides both. research-live-transcription.md §8.5.
- **Golf-vocabulary WER has still never been measured, and is now measurable again.** It was what
  replaced the cut Q12 probe as the first measurement and it was never taken; under Siri it was
  permanently *un*takeable (a black box, no `contextualStrings` equivalent, no A/B). With the
  recogniser back in our hands it is a to-do rather than a gap. Attribution accuracy still
  decides the feature.
- **First real-phone run happened 2026-08-27** *(reported by the user)*: the model **downloaded
  on the device**, a burst recorded, and Whisper transcribed — on the default
  `openai_whisper-small`. That closes three things previously listed as unverified anywhere. What
  it also produced is the two bugs above: phantom "thank you"s and English tagged Korean, both now
  traced to non-speech reaching the decoder and both fixed by `WhisperVAD`. **The fixes themselves
  have not been back on a phone.**
- **Still unmeasured on a phone even so.** *(2026-08-27.)* What ran on **macOS**: the tap,
  both converters, segment rotation, the burst toggle (`golfctl record --mic-off --live`: two
  bursts, each its own segment closed with a true `t1`, a real 3.2 s gap between them), and
  Whisper over real speech in both languages — `golfctl live --realtime`, hypotheses updating
  about twice a second, Korean staying Korean. What ran in the **simulator**: the record button,
  the burst timer, `audio-000.m4a` growing, `meta.audioRoute` = `MicrophoneBuiltIn`, and the whole
  live path end to end — caption pane, commit at a silence, log rows appearing as they were filed.
  **The speech was replayed from a file** (`marker.speech`), because there is no way to talk into
  this simulator; the microphone recorded silence alongside it.
  What has **not** run anywhere: **a real microphone with real voices at fairway distance**, the
  interruption path (`AVAudioSession` does not exist on macOS, so a real phone call is
  unexercised), the stall watchdog against a genuinely dead tap, background survival with the
  phone in a pocket, battery over 4.5 hours with Whisper decoding continuously, and
  **stopping a burst with a finger** — scripted taps do not exist here. *(Model download on a
  device was on this list and came off it: it happened on 2026-08-27, per the bullet above.
  The simulator still cannot do it — its network blocked the fetch and the model was
  side-loaded there.)*
- **The batch pass is 16× slower than it was, measured.** `golfctl transcribe` over a 68-second
  sample on this Mac: Apple's two-locale pass ran at **43× realtime**, `openai_whisper-small` runs
  at **1.5–2.7×** over two runs of the same fixture — a 4.5-hour round goes from about six minutes
  to one to three hours, and a phone will be slower. Treat it as a band, not a figure. It does not affect the live path, which decodes a short rolling window and keeps up
  easily. It is the strongest argument against moving the picker up to `large-v3`.
- **Whisper's realtime cost on a phone is unmeasured, and it is the number that decides the
  model.** Each pass decodes a padded 30-second frame whatever the window holds, so cost is per
  *pass*, not per second of speech — and the loop runs continuously while a burst is open. On this
  Mac `small` kept up comfortably; a phone with a 4.5-hour round in a pocket is a different
  question, and it is the one the picker exists to let the user answer for themselves.
- **Real geometry exists for two courses**: `Courses/corica-park-south.json` (OSM, 2026-08-26,
  verified hole by hole against the raw ways — every black tee within 45 m, most within 5; the
  outliers are doglegs) and `Courses/coyote-creek-golf-club-tournament-course.json` (OSM,
  2026-08-30, the course the user searched for). **Both were re-imported on 2026-08-30** and the
  Corica file changed materially: 1 fairway outline → 18, 0 cart paths → 51, 79 tees → 81. Still
  missing: `golfctl survey export`, any track-derived geometry, and any course placed by hand in
  the editor.
- **`golfctl course import` has never been run against the live API.** The fetch, strip, redirect
  hop, unit resolution, reconciliation and merge are all tested or verified by hand; the
  `/v1/messages` call is not, because this machine has no `ANTHROPIC_API_KEY`. `--fetch-only` is
  verified end to end against Angeles National (US), 안성CC and 스카이뷰CC. Assume the extraction
  leg is unproven until a real card round-trips.
- **OSM import is built** — `golfctl course osm`, approved by the user on 2026-08-26 after the
  question was put to them. It *does* demote the hand editor to the fallback for the ~half of US
  courses OSM does not cover, which was the reason for asking. **Two sites imported now** — Corica Park and Coyote Creek — and the second one is
  the evidence for that warning: it needed relation fairways, the `golf:course:name` split, a
  named-tee override and untagged-tee adoption, none of which Corica exercised. OSM tagging quality
  varies by mapper; the checks (`handicapIsPermutation`, `measuredTotal`, `teeAnomalies`) exist
  because the third site will be different again.
- **~~Multipolygon relations are skipped by the OSM importer.~~ Closed 2026-08-30 — and it was
  half a parser gap and half a one-word query bug.** `Element.coordinates` now answers for a
  relation as well as a way, so nothing downstream knows which drew a fairway. The bullet used to
  say "walking `members` from `out geom`" was what remained; the *actual* blocker was that the
  query said `out tags geom`, a print mode in which a relation comes back with **`members` absent
  entirely** — measured, 28 relations and zero members between them. Corica went from **1 fairway
  outline to 18**, Coyote Creek from 0 to 18.
- **The editor is verified in the simulator only**, and the tap-to-place gesture itself was never
  exercised — scripted taps are not available here, so placement was screenshotted from
  pre-placed state. `MapProxy.convert` is unproven on a real finger.
- **Nothing checks that a traced file stays out of a published one.** The `source: .traced` marking
  is written; no export path enforces it, because there is no export path yet.
- **MapKit imagery over Korea is good** — verified at 37.40/127.20 in the simulator, high enough
  resolution to read individual buildings at hole scale. That was open question C3.
