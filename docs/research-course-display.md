# Marker — Research: How existing apps display a hole, and what they all miss

Date: 2026-08-24 · Status: research, nothing implemented

Companion to [`research-course-map.md`](./research-course-map.md), which settled *where the
geometry comes from* and *what may legally sit under it*. This one is about **what to draw** —
surveyed against the apps that have been iterating on this screen for fifteen years.

Everything below is a cited feature or interaction. **No aesthetic comparisons**: the browser
extension was not connected for this session, so no screenshots were viewed, and claims like
"cleaner than X" are absent on purpose.

---

## 0. The finding in one paragraph

The hole screen is a **solved, converged design** — every serious app shows an overhead hole,
front/centre/back green numbers, a draggable target, and hazard carries, and the differences are
cosmetic. What no consumer app does is **reconstruct shot positions for every player in a group
from a single device with no per-player hardware**: Arccos and Shot Scope require a sensor per
player, Golf Genius requires a human walking scorer, and VPAR/Golf Gamebook do group *scoring*
without positions. And "replay" in this market universally means **swing-video playback**, not
spatial replay of a round. Marker should build the converged hole screen at parity, cheaply, and
spend its design budget on the three screens nobody has: **group replay, the correctable draft,
and the survey state**.

---

## 1. Comparative matrix

| App | Base layer | Distances | Green detail | Elevation | Shot positions from | Group |
|---|---|---|---|---|---|---|
| **Hole19** | Flyover (aerial) | Draggable target auto-placed at green front/dogleg; tray with F/C/B; colour-coded arcs at 100/150/200/250 | Flag button zooms into green | — | Manual / watch | Scoring |
| **Golfshot** | 3D flyover + full 3D course preview; **AR camera overlay** of yardages, hazards, landing zones | Yardages over live camera view | — | — | Auto shot tracking, post-round review | Foursome scorecard |
| **Shot Scope** | Overhead, "every hazard, bunker and tree precisely plotted" | Tap any point; front **and carry** of every hazard; F/M/B green | **Contour maps** — break, borrow, undulation, mapped in-house | Yes, in MyStrategy; manual wind entry | Sensor per club (V5/H50 hardware) | — |
| **Arccos** | Full-screen hole map | Tap for hazards and lay-up points | — | — | **Sensor per grip**; app knows fairway/green/bunker polygons and classifies drive/approach/chip/putt | — |
| **GolfLogix** | **3D hole view / flyover** | — | Colour-coded break-severity heat map; **3D putt line** | **"Plays Like"** slope-adjusted yardage (since 2022) | Manual | — |
| **18Birdies** | GPS hole view, real-time pin info | Standard | — | — | Manual + AI swing analysis | Scoring |
| **Golf Pad** | Maps + contours (incl. watch) | Standard | Contours | — | One-tap tracker, **per player** (strokes, putts, penalties, sand, fairways) | Scoring + live leaderboard |
| **Golf Genius Officials** | — | — | — | — | **A volunteer walking scorer types them in** | Per-group, tournament use |
| **스마트스코어** | 실측 실사 지도 (surveyed real-imagery) | Point-to-point **and** point-to-hole | — | — | Manual | Scoring; club-side **live cart positions** |
| **골프버디** (골프존데카) | **Dual satellite *or* graphic imagery**, ~40,000 courses (~95% worldwide) | Standard | — | **고저차** elevation-corrected distance | Manual / device | — |
| **스마트캐디** (GolfBuddy watch) | Hole map on the wrist | Per-club distance recommendation; 스마트뷰 combines numbers + map | Green undulation | — | — | — |

### Coverage, for scale

Hole19 and 18Birdies ≈43,000 courses; Golfshot ≈45,000; Shot Scope ≈36,000 mapped in-house;
골프버디 ≈40,000. Every one of these is a **staffed mapping operation**. Marker has none, which
is why `research-course-map.md` lands on deriving geometry from the track rather than competing
on a course database.

---

## 2. What everyone converged on — build this at parity, do not innovate

Fifteen years of iteration produced one screen. Copy it:

1. **Overhead hole, tee at the bottom.** Universal.
2. **Front / centre / back green numbers**, always visible. Centre alone is the average wrong
   answer — front-to-back on a 30 m green is a full club.
3. **A draggable target**, auto-placed somewhere sensible (Hole19: green front, or the dogleg),
   showing *player→target* and *target→green* simultaneously. This is the single most-copied
   interaction in the category.
4. **Hazard carry, not just hazard distance.** Shot Scope shows front *and* carry — "can I get
   over it" is the actual question.
5. **Tap anywhere for a yardage.**
6. **Zoom to the green** as a discrete mode toggle, not a pinch you have to discover.
7. **Distance arcs from the tee** as an optional overlay (Hole19: 100/150/200/250, colour-coded).

Two more that are near-universal in the premium tier and matter to Marker specifically:

8. **Slope-adjusted "plays like" distance** (GolfLogix, 골프버디's 고저차). Marker's barometer
   measures this better than any of them, and in Korea it is the *only* available source
   ([`research-course-map.md`](./research-course-map.md) §3.2).
9. **Green contour / undulation** (Shot Scope, Golf Pad, 스마트캐디, GolfLogix's 3D putt line).
   Expensive — Shot Scope surveys it with an in-house team. **Out of scope for Marker.**

---

## 3. What nobody does — this is the whole design budget

### 3.1 Group shot reconstruction from one device

The market splits cleanly, and every branch needs something Marker does not:

| Approach | Who | What it costs the user |
|---|---|---|
| Sensor per player | Arccos (grip sensors), Shot Scope (V5/H50) | Every player buys hardware |
| Human scorer | Golf Genius Officials | A volunteer walks with the group |
| Group scoring only | VPAR, Golf Gamebook, Golf Pad, Hole19, 18Birdies | Scores, never positions |

**Nobody reconstructs where all four players' shots landed from one phone in one pocket.** That is
the product (PLAN §1), and it is also why the hole view has a design problem none of these apps
has: **four shot tracks on one hole, distinguishable at a glance, in sunlight, without clutter.**

### 3.2 Spatial replay

"Replay" in this market means swing video — 18Birdies' Instant Swing Playback auto-clips a swing
and plays it back in slow motion. Useful, and a completely different feature. **Nothing replays a
round through space and time**: scrub a timeline, watch four players' shots appear in order, hear
what was said at that moment. Marker records the audio and the track already; the replay screen is
mostly a rendering problem over data it will have anyway.

### 3.3 A draft you correct

Every tracker presents its output as **fact**. Arccos classifies a shot as a chip and that is what
it is; the fix is buried in post-round editing. Marker's core invariant inverts this: the
reconstruction is a **draft with confidence and visible evidence**, and correcting it is the
primary gesture, not a repair (CLAUDE.md). No competitor screen exists to copy, because no
competitor admits uncertainty in the UI.

This is also the eval loop — every correction is a labeled error (PLAN §3) — so the correction
gesture is *load-bearing infrastructure disguised as a UI affordance*. It deserves the most care.

### 3.4 The unmapped course

All eleven apps assume the course is in a database. Marker's first visit to 내골 CC will not be —
OSM has usable geometry for ~3% of Korean courses. So Marker needs a screen the market has never
needed: **a hole view with no geometry and no imagery that is still useful**, and a survey gesture
that turns the round into geometry afterwards.

### 3.5 Where Marker is *not* novel

Say this plainly so nobody oversells it: **Shot Scope's MyStrategy already does history-grounded
strategy** — your last 30 shots per club, plotted as a dispersion cone on the actual hole, with
elevation and wind. That is PLAN's **P4**, shipping today. Marker's P4 differs in grounding, not
in kind: *this hole, your history here*, rather than your club's average anywhere. Narrower and
more honest, but the idea has a precedent and claiming otherwise is a mistake.

---

## 4. Korea

- **A graphic/vector hole view is proven in this market.** 골프버디 — Golfzon Deca, the largest
  player — ships **satellite and graphic imagery as user-selectable views**. A drawn hole is not a
  downgrade Korean golfers tolerate; it is a mode they choose.
- **고저차 (elevation-corrected distance) is table stakes here**, not a premium feature.
- **스마트스코어 owns the scorecard-and-booking layer**, with surveyed real-imagery maps and
  point-to-point measurement, plus live cart positions on the club side. Marker should not compete
  with it; the round record is a different artifact from a booking history.
- **스마트캐디's position-driven auto-zoom** — the hole map zooms itself to your situation — is the
  best interaction idea in the Korean set, and directly applicable.

---

## 5. Design principles, derived from what users complain about

| Complaint | Principle |
|---|---|
| Screens wash out in afternoon sun | **Maximum contrast; never set text over photography.** Vector base is a legibility decision before it is a licensing one |
| GPS + screen brightness drain the battery | Vector costs less to draw than streamed raster; offer a **numbers-only mode** with no map at all |
| Touchscreens fail with a glove or in rain | **Thumb-zone controls, large targets, no precision drags.** The one-handed reachable band is the bottom third |
| Cluttered screens | **One number big, everything else on demand.** Progressive disclosure over a dense HUD |
| Panning to find yourself | Auto-zoom to the player's situation (스마트캐디). The map follows you; never make someone pan mid-round |

And two Marker-specific ones:

- **MARK is the largest target on the screen.** No competitor has this button, because none is
  recording audio. It is the only thing the phone's owner can contribute that the microphone
  cannot, and it must be hittable without looking.
- **Confidence must be visible, never a number in a tooltip.** A shot the model is unsure about
  should look unsure.

---

## 6. The four screens Marker should design

Parity for #1, invention for the rest.

1. **Hole view (during round)** — vector hole from the course file, tee at bottom, one big
   distance, F/C/B tray, draggable target, plays-like adjustment from the barometer, four player
   tracks, and MARK in the thumb zone. Imagery is an optional layer under it, off by default.
2. **Group replay** — one hole, four players' shot sequences, a timeline scrubber, and the
   transcript line at the playhead. The differentiator; give it the most design.
3. **The correctable draft** — the shot list after a round, each shot with a confidence and the
   evidence behind it ("heard: *7번 아이언*"), with one-tap delete and reattribute.
4. **Survey / no-geometry** — first visit to an unmapped course: no hole drawn, MARK tee and green,
   and an honest statement that the map arrives after the round.

Mockups: see the accompanying artifact.

---

## 7. Open questions

| # | Question |
|---|---|
| D1 | Four shot tracks on one hole — colour, numbering, or sequence-on-demand? Untested and it is the hardest visual problem here |
| D2 | Does the replay scrubber belong on the phone at all, or is it a Mac/iPad screen? |
| D3 | Is a numbers-only (mapless) mode enough for a whole round, and does it actually save meaningful battery? |
| D4 | How is confidence rendered so it reads instantly in sunlight — opacity, dash, badge? |
| D5 | Green undulation is out of scope, but does that make the hole view feel incomplete against 스마트캐디? |

---

## 9. R1 — How a target is placed and removed, and whether anyone does two

*(Researched 2026-08-26, to settle TODO item 9 before building it.)*

§2 established the single draggable target as the most-copied interaction in the
category. It did not say how a target gets **placed**, how it gets **removed**, or
whether two are ever supported. All three turn out to matter.

### 9.1 Placement — tap has won, and drag is the older pattern

| Product | Placement gesture | Screen |
|---|---|---|
| **Garmin Approach S62 / S70** | **Tap** — *"Tap the map to position the target circle"* | 1.2–1.4″ watch |
| **Golfshot** | **Tap** ("TouchPoint"), plus up to 30 pre-placed course targets | phone |
| **Golf Pad** | **Tap** — "tap-for-distance" on the hole map | phone + watch |
| **Tangent** | **Tap to summon → long-press-drag to refine → or pan the map under a fixed centre target** | phone |
| **Hole19** | **Drag** the crosshair | phone |
| **18Birdies** | Movable target cursor (**drag**) | phone |

Four of six place by tap, and the one with the least room to be imprecise — a watch
face — chose tap outright. Tangent's is the most complete design in the category:
tap for coarse placement, long-press-drag to refine, and a third mode where the
target stays pinned to screen centre and the *map* moves under it.

**The argument for tap is occlusion, not gloves.** research-course-display.md §5
generalises about gloves and rain from battery and control complaints; searching
specifically for glove or wet-weather complaints about *target drag* found none, so
that generalisation should not be leaned on here. The real problem is simpler and
certain: during a drag, the point you are aiming at is underneath your fingertip.
That is exactly why Tangent's pan-under-crosshair mode exists.

### 9.2 Removal is undocumented across the whole category

Garmin's own manual describes positioning the target circle and **never says how to
dismiss it**; the same silence runs through Hole19's, Golfshot's and Golf Pad's
published help. A target you cannot remove becomes permanent clutter on the hole,
and every product appears to have shipped that. This is cheap to do better.

### 9.3 Nobody ships two targets

No product in the matrix offers a **target → target** leg. Every one is a single
target with a two-leg readout — *me → target* and *target → green*. Golfshot's "30
targets per hole" are **pre-placed course features** (green edges, bunkers, water,
doglegs, layup markers), not user waypoints, and carry no chaining.

So *lay up to 240, then what is left to the pin, and how far is the carry between* —
an ordinary two-shot plan on a par 5 — is unserved by the category. TODO item 9 is
genuinely novel rather than catch-up.

### 9.4 One documented failure worth not repeating

GolfLink auto-placed its crosshair badly enough to land it *in a grove of trees*.
The lesson is not "place it better" — it is that a target the golfer did not ask for
starts wrong and has to be corrected before it is useful. **Do not auto-place.**

### 9.5 Recommendation

1. **Tap to place.** Majority pattern, one-handed, thumb-zone, and it is what the
   smallest screen in the category chose.
2. **Long-press-drag to refine** an existing target, so precision is available
   without being required.
3. **Tap a target to remove it.** Nobody solves removal; solve it explicitly.
4. **Never auto-place.** No target until asked for (§9.4).
5. **Second target: tap again.** With one target placed, the next tap becomes T2,
   and the readout chains origin → T1 → T2 → pin.
6. **Do not adopt pan-under-fixed-crosshair.** It collides with TODO item 6, which
   gives the vector layer the same pan-and-zoom as satellite — pan cannot mean both
   "move the view" and "move the target". Pan moves the view; tap places. Revisit
   only if tap placement proves too coarse on a real finger.

---

## 8. References

- [Hole19 — Flyover View, Distances Tray and Zoom into the Green](https://help.hole19golf.com/hc/en-us/articles/202618282-Flyover-View-Distances-Tray-and-Zoom-into-the-Green) — target drag, F/C/B tray, arcs, green zoom, offline mode
- [Shot Scope — MyStrategy](https://shotscope.com/us/discover/on-the-course/build-mystrategy/) · [announcement](https://shotscope.com/blog/inside-the-ropes/press-and-announcements/mystrategy-ultimate-course-guide/) · [Apple Watch app, Aug 2026](https://www.firstcallgolf.com/industry-news/release/2026-08-05/shot-scope-releases-apple-watch-gps-app-expanding-its-golf-technology-ecosystem) — last-30-shots dispersion, hazard carry, green contours
- [Arccos Caddie 2.0 review — Golfalot](https://golfalot.com/equipment-review/arccos-caddie-2-gps-app-review) · [How does Arccos work?](https://support.arccosgolf.com/hc/en-us/articles/360036799251-How-does-Arccos-work) — full-screen hole map, tap for hazards, AI Caddie, grip sensors
- [GolfLogix — 3D flyover and "Plays Like"](https://www.firstcallgolf.com/industry-news/release/2022-08-01/golflogix-the-number-1-app-in-golf-raises-the-bar-once-again-with-new-3d-flyover-and-plays-like-features) · [3D hole view guide](https://www.golflogix.com/blog/step-into-the-future-of-golf-a-guide-to-3d-hole-view-in-the-new-golflogix-app/) — break heat map, 3D putt line, slope-adjusted yardage
- [Golfshot on Google Play](https://play.google.com/store/apps/details?id=com.shotzoom.golfshot2) · [Golfshot review](https://www.scoringzone.net/blog/golfshot-app-review.html) — AR overlay, 3D flyover, foursome scorecard
- [18Birdies — Instant Swing Playback](https://18birdies.com/clubhouse/practice/introducing-instant-swing-playback) — what "replay" means in this market
- [Golf Pad on Google Play](https://play.google.com/store/apps/details?id=com.contorra.golfpad) — per-player one-tap tracking, live leaderboards
- [Golf Genius — Shot Tracking](https://docs.golfgenius.com/en/articles/10777418-shot-tracking) — the walking-scorer model
- [Best Golf GPS Apps 2026 — Golf Monthly](https://www.golfmonthly.com/best-golf-deals/best-golf-gps-apps-213526) · [Golf GPS apps ranked 2026](https://golfpadgps.com/news/best-golf-gps-apps-2026) — coverage counts, category overview
- [스마트스코어](https://www.smartscore.kr/golf/index.html?act=club) · [App Store](https://apps.apple.com/kr/app/스마트스코어/id969887573) — 실측 실사 지도, point-to-point, cart positions
- [골프버디 (골프존데카)](https://play.google.com/store/apps/details?id=com.golfzon.fyardage) — dual satellite/graphic imagery, 고저차
- [스마트캐디 - Golf GPS](https://apps.apple.com/kr/app/스마트캐디-golf-gps/id6744308201) — 스마트뷰, position-driven auto-zoom, green undulation
- Usability complaints: [Golf Pad battery thread](https://support.golfpadgps.com/support/discussions/topics/6000062145) · [GPS phone app discussion — Golf Monthly forums](https://forums.golfmonthly.com/threads/gps-phone-app-discussion.96788/) · [5 things to know before downloading a golf GPS app](https://www.golflogix.com/blog/5-things-to-know-before-downloading-a-golf-gps-app/)
- **R1 sources (target placement, 2026-08-26):** [Garmin Approach S70 — Measuring Distance with Touch Targeting](https://www8.garmin.com/manuals/webhelp/GUID-0F89E6A5-EC1C-4382-964E-27DC4B5FC932/EN-US/GUID-2AC0AEAF-190C-43BB-9E5B-DE33A77B88A8.html) · [Approach S62, same feature](https://www8.garmin.com/manuals/webhelp/GUID-7681996C-530F-4C69-80C4-3CD20D82746C/EN-US/GUID-2AC0AEAF-190C-43BB-9E5B-DE33A77B88A8.html) · [Garmin Touch Targeting overview](https://www.garmin.com/en-US/garmin-technology/golf-science/distance-measurement/touch-targeting/) · [Tangent — Moving the Target to Measure Any Distance](https://intercom.help/tangentgolf/en/articles/12151053-moving-the-target-to-measure-any-distance) · [Hole19 GPS yardages](https://www.hole19golf.com/hole19/features/gps-yardages) · [Golf Pad](https://golfpadgps.com/) · [Golfshot review — Critical Golf](https://criticalgolf.com/reviews/archived-products/golfshot-review/) · [GolfLink review — Critical Golf](https://criticalgolf.com/reviews/archived-products/golflink-review/) (auto-placed crosshair in trees)
