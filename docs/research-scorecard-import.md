# Marker — Research: Where course cards and hole GPS actually come from

Date: 2026-08-26 · Status: measured in both regions; implemented in `golfctl course import` + the
editor. **Revised the same day**, when the user said the target is mainly American courses — the
US measurements and the unit decision below replace an earlier Korea-only reading.

Companion to [`research-course-map.md`](research-course-map.md), which covers **geometry** (where the
tee and green *are*) and **imagery** (the photo underneath). This one covers the **card** — par,
handicap, and distance per tee, per hole — and how a course gets from "nothing" to "usable file".

Everything below is measured against real published cards — American and Korean — not surveyed
from documentation. Reproduce with the commands inline.

---

## 0. Findings

1. **A course card and course geometry come from different places and must be acquired separately.**
   A card is numbers on a web page; geometry is coordinates. **No free source gives both**, for any
   Korean course. Designing one importer for "course data" is the mistake this document prevents.
2. **OSM is not a card source in either region — and this is the one number that does not vary.**
   `dist` is on **0.3%** of 150,178 US hole ways and 1.8% of Korea's 597. `handicap` is on 38% of
   US holes and 6% of Korean ones. OSM gives geometry and par (and in the US it gives them for
   ~half of all courses — see research-course-map.md §2.1); yardage and stroke index come from a
   card, everywhere.
3. **Course websites are the card source, and they are excellent where they exist** — complete
   HTML tables with hole, par, handicap, and a distance row per named tee (§2). Not images, not
   PDFs: plain text in the markup.
4. **They are not reliably crawlable, and that is true in both countries.** Sampled with the same
   crawler: **41 of 250 US sites (16.4%)** and 43 of 244 Korean sites (17.6%). The misses are
   almost never missing data — they are JS splash redirects, framesets, `/Mobile` forks and
   (in Korea) EUC-KR. The one difference is reachability: 9% of US sites failed to answer versus
   32% of Korean ones, which confirms that most of Korea's "unreachable" was geo-blocking rather
   than dead sites.
5. **Therefore: do not write site parsers.** Fetch whatever the user points at — URL, PDF, photo,
   pasted text — and have the model extract it to schema. One code path, four input types, no
   per-site maintenance and no hit-rate cliff. §4.
6. **Distance units are usually unlabeled, and no rule based on the numbers can recover them.**
   Measured across six real cards (§3.1): the metric one sits *between* two imperial ones on
   per-par length, and an ordinary American card from the middle tees sits below all of them. So
   the unit is **assumed regionally — yards — announced as assumed, and checked later** by
   `lengthDisagreement` the first time a tee and green are placed. An earlier version of this
   document tried to infer it from the totals; that refused the modal American card and still got
   Korean ones wrong.
7. **American cards print two stroke-index rows** — men's and women's, different allocations
   (§3.3). A single `handicap` field silently picks a column, and *both* rows are a valid 1…18
   permutation, so nothing downstream could detect the error.
8. **A hole number is not a key.** Named nines are common in both regions — 황룡/청룡/흑룡,
   Lakes/Woods/Meadows — each numbered 1–9 (§3.2).
9. **Cards give distance; they never give coordinates.** So the model must represent a hole with
   par and yardage and *no geometry at all* — which it originally could not (§5).
10. **HTML reduction is a correctness problem, not plumbing** (§3.4). On a real card an inline
   `<span>` inside a number splits `17` into `1 7`, which shifts a whole handicap row and still
   yields eighteen plausible stroke indexes.

---

## 1. OSM gives par, and nothing else a card needs — in either country

Measured 2026-08-26 (the geometry counts, which differ hugely by region, are in
research-course-map.md §2.1):

| Tag on `golf=hole` | US (of 150,178) | Korea (of 597) |
|---|---:|---:|
| `ref` | 97.8% | 76.6% |
| `par` | 89.3% | 71.5% |
| `handicap` | **38.2%** | **5.9%** |
| `dist` | **0.3%** | **1.8%** |

The geometry story reverses between the two countries; **the card story does not**. Yardage is
absent from OSM everywhere, and stroke index is absent or thin. That is what makes card import a
requirement rather than a regional nicety.

```sh
curl -s -X POST https://overpass-api.de/api/interpreter --data-urlencode 'data=
[out:json][timeout:120];
area["ISO3166-1"="KR"][admin_level=2]->.kr;
way["golf"="hole"](area.kr);
out tags;'
```

Where OSM has the geometry it usually has par too, which is a real bonus — those are the same
holes whose tee and green came free. But per-tee distance is the entire reason a card is worth
importing, and handicap is how strokes are allocated in a match. Neither is in OSM at a rate worth
designing around.

---

## 2. Course websites — the real source

Sample frames from OSM `website` tags: **6,879 US courses** (250 sampled at random, seed 7) and
**244 Korean courses** (all of them). Same crawler for both: fetch the homepage, follow one JS
`location.href` / meta-refresh / frameset hop, follow up to 8 links whose href or label matches
`course|score|hole|yard|코스|스코어|홀|야디지`, and score a page as a card if it contains `PAR`/`파`
and ≥18 three-digit numbers in 90–680.

| Outcome | **US (250)** | **Korea (244)** |
|---|---:|---:|
| **Card found** | **41 — 16.4%** | **43 — 17.6%** |
| No card found | 184 — 74% | 106 — 43% |
| Unreachable | 23 — 9% | 78 — 32% |
| JS app shell, no server-rendered text | 2 — 1% | 17 — 7% |

**The crawlable share is the same in both countries to within a point and a half.** The design
consequence is therefore regional-independent: the input has to be whatever the user has, because
five in six course sites will not give a card to an unattended fetch. The one thing that *does*
differ is reachability — 9% versus 32% — which is the geo-blocking result, not a data result.

### 2.1 That ~17% is a crawler score, not a data-availability score

Spot-checking the misses is what makes this number honest:

- **스카이뷰CC** looked like a dead end — the homepage is a video splash whose only content is
  `location.href = '/Mobile'` in a `<script>`. Following that one redirect found a complete card at
  `/Mobile/course/info.aspx`. Ten more sites flipped to "card" on that single rule alone.
- **가야CC** serves EUC-KR and redirects via JS to `/main.php/`.
- **파인비치골프링크스** and **아델스코트CC** are real, operating courses that simply do not answer
  from a US IP. Some fraction of the "unreachable" 78 is **geo-blocking, not death** — and it does
  not apply to the phone of a golfer standing in Korea.

So the true share of courses that publish a card is well above 17%; the share an unattended
crawler can extract is roughly that. **The gap between those two numbers is the whole argument for
§4**, and it is the same gap in both countries.

### 2.2 There is a platform tail worth knowing about

The 43 hits are not 43 bespoke sites. Recurring vendors: `/swp/course` (윈체스트, 소피아그린,
경주신라, YJC), `onetheclub.com` (신라CC, 파가니카), and an ASP.NET `Course/ScoreCard.aspx`
platform (안성, 해운대, 대영힐스, 도고). A per-platform extractor would cover more courses per unit
of work than a per-site one — **but it is still a treadmill, and §4 makes it unnecessary.** Noted
so nobody rediscovers it and mistakes it for a plan.

---

## 3. What a real card looks like, and the three traps in it

Angeles National Golf Club, `https://www.angelesnational.com/aboutus/scorecard/`, front nine, as
the importer's HTML reduction actually emits it (tabs shown as `|`):

```
Hole|1|2|3|4|5|6|7|8|9|Out||
Black 74.7/143|402|585|212|427|422|459|176|530|486|3699|3699|
Blue 72.1/136|381|562|177|396|378|416|164|494|446|3414|3414|
White 70.0/130|368|542|156|382|359|364|149|469|417|3206|3206|
Men's Hcp|15|5|7|17|9|3|13|11|1|0|0|
Par|4|5|3|4|4|4|3|5|4|36|36|
Red 68.9/116|273|493|62|338|261|306|81|390|328|2532|2532|
Women's Hcp|11|7|17|15|5|1|13|9|3|0|0|
```

Everything the model needs, in markup, for free — and three things a Korean card does not have:
**rating and slope attached to the tee name** (`Black 74.7/143`), **two stroke-index rows**, and
**no unit marker anywhere** despite being yards.

안성CC, `https://www.ansungcc.co.kr/Course/ScoreCard.aspx`, Out course, for contrast:

```
HOLE NO.   1    2    3    4    5    6    7    8    9   OUT
Back      383  404  200  423  525  548  167  395  392  3,437
Regular   358  373  174  383  500  527  149  365  370  3,199
Front     337  346  147  351  478  506  126  335  347  2,973
Ladies    318  329  117  323  428  459  104  306  317  2,701
PAR         4    4    3    4    5    5    3    4    4   36
HANDICAP    4    1    6    2    7    5    9    8    3
```

Tee names are free text and vary by course — `Back/Regular/Front/Ladies` here,
`Black/Blue/White/Red` at Angeles National and 천룡, `C.T/R.T/L.T` at 서울한양,
`Back TEE(M)/Regular TEE(M)/LADY TEE(M)` at 도고, `Championship/Middle/Forward` at plenty of
American clubs. **Never model tee name as an enum.**

### 3.1 Trap one: the unit is usually not printed, and it cannot be recovered from the numbers

| Course | Row label | 18-hole total | ÷ par 72 | Actually |
|---|---|---:|---:|---|
| Angeles National, White | `White 70.0/130` | 6,169 | 85.7 | **yards** |
| 서울한양 | `C.T` | 6,475 | 89.9 | **yards** |
| 도고칸트리구락부 | `Back TEE(M)` | 6,556 | 91.0 | **metres** (stated) |
| 천룡CC | `Black` | 6,914 | 96.0 | **yards** |
| 안성CC | `Back` | 7,067 | 98.2 | **yards** |
| Angeles National, Black | `Black 74.7/143` | 7,141 | 99.2 | **yards** |

**Sort that column and the units do not sort with it.** The one metric card sits *between* two
imperial ones, and an ordinary American middle-tee set sits below all of them. There is no
threshold anywhere in this list that separates the two units — and the middle of it, 85–92 per
par, is exactly where the modal American public course plays from the tips.

An earlier version of this document proposed inferring the unit from the total and refusing in an
"ambiguous band". Measured against the American cards, that design **refuses ordinary imports**
while still mis-reading 도고. It was wrong and has been replaced.

**What the code does instead** (`DistanceUnit`, `CourseCard.resolveUnit`):

1. `--unit` if the caller passed one.
2. The unit the card printed, if it printed one.
3. Otherwise **the regional assumption — yards**, because the target courses are mainly American
   and an American card is in yards essentially always. `--unit-default metres` flips it.

An assumed unit is **announced as assumed** at import, and it is **checked twice**:
`CourseCard.unitWarning()` flags a total that is impossible in *either* unit (a totals row read as
a hole), and — the real check — `HoleGeometry.lengthDisagreement` compares the card against the
ground the moment anyone places a tee and a green. A metric card read as yards is stored 9.4%
short, far past the editor's 25 m flag.

That is why assuming is safe and inferring is not: **the assumption is falsifiable and the
inference was not.** Do not try to make the guess smarter; the table above is the evidence that it
cannot be made to work.

### 3.2 Trap two: 1–9 is not a hole number

천룡CC publishes three nines — 황룡, 청룡, 흑룡 — each numbered 1 through 9. A round plays two of
them. This is the standard Korean layout, not an exception: 서울한양 has New and Old, 안성 has
Out and In.

`Hole.ref` alone therefore is not unique within a course, and `Hole.id { ref }` collides on import.
The fix is small if done before any file is written and annoying afterwards: an optional
`Hole.nine`, a composite id, and a lookup that takes both. American 27- and 36-hole clubs name
their nines too (Lakes / Woods / Meadows), so this is not a Korea-specific accommodation.

### 3.3 Trap three: an American card has two stroke-index rows

`Men's Hcp` and `Women's Hcp` above are **different allocations** — the men's front nine runs
15, 5, 7, 17, 9, 3, 13, 11, 1 and the women's runs 11, 7, 17, 15, 5, 1, 13, 9, 3.

A single `handicap` field means the extractor silently picks a column, and the error is
undetectable downstream: **both rows are a valid permutation of 1…18**, so the reconciliation
check passes either way. A men's fourball playing the women's stroke index gets the wrong shots on
the wrong holes and nothing anywhere says so.

`CardHole.handicap` is the men's row (or the only row); `CardHole.handicapWomen` is the second one
when the card prints it. Nil means the card had one allocation — not that the men's applies to
everyone. Both rows are permutation-checked separately.

While in there: **rating and slope are on every American card**, printed against the tee name as
`74.7/143`. Nothing uses them yet, but they are the input any real handicap calculation needs and
they are free at import and expensive to go back for, so `TeeBox` carries them. They are **not** a
unit detector — the KGA and others use USGA rating over metric cards too.

### 3.4 Trap four: reducing the HTML is a correctness problem

Angeles National's men's stroke index for hole 4 is, in the markup:

```html
<td class="style1">1<span class="style1">7</span></td>
```

A tag-stripper that replaces tags with a space — the obvious implementation, and the one this
importer originally had — turns that cell into `1 7`. The row then has one extra value, every
stroke index after it shifts by one, and the result is still eighteen plausible numbers. The
1…18 permutation check may or may not catch it depending on what falls off the end.

`CardText.strip` therefore: flattens the source's own whitespace **first** (a raw newline between
`</td>` and `<td>` would otherwise read as a row break), converts `</td>` to a tab and `</tr>` to a
newline **while those tags still exist**, and then **deletes** every remaining inline tag rather
than substituting a space. Cell and row boundaries survive into the text the model reads, so an
empty cell stays an empty column instead of vanishing and shifting the row. Numeric HTML entities
are decoded too — `&#8217;` is the apostrophe in `Men&#8217;s Hcp`, and a card whose row *labels*
are mangled is a card whose columns have to be guessed.



---

## 4. The importer: one path, four inputs

The measurement kills the "search online by course name and parse it" design — ~17% in both
countries is a bad success rate for the *primary* path, and every point of improvement is a
site-specific parser that rots. It equally kills "photograph the card" as the *only* path, because
for a large minority of courses the numbers are sitting in HTML and asking a golfer to photograph
them is silly.

**So the input is whatever the user has, and the extraction is uniform:**

| Input | How it arrives | Notes |
|---|---|---|
| **URL** | `--url https://…/ScoreCard.aspx` | Fetch, follow one JS/meta redirect, strip to text. The stripping is the only site-aware code, and it is generic |
| **PDF** | `--card card.pdf` | Many clubs publish a course guide PDF |
| **Image** | `--card card.jpg` | Photograph of the card at the first tee, or a screenshot. The universal fallback — always works |
| **Text** | `--card card.txt`, or stdin | Paste. The escape hatch when everything else fails |

All four converge on one prompt and one JSON schema. Extraction is the model's job, not a parser's:
tee-name rows, half-width/full-width digits, `3,437` totals to discard, 나인 names, and a HANDICAP
row that is missing on some cards are exactly what an LLM absorbs without a rule per case.

Consistent with CLAUDE.md: the prompt and schema resolve from `--prompt` / `--schema` paths, never
`Bundle.module`; the raw fetched text and the model's response cache next to the output so
re-tuning the prompt never re-fetches.

**Checkable output, and this matters.** A card is self-validating in a way most model output is
not — per-nine totals and the grand total are printed on the card, and par plus each tee row must
sum to them. The importer adds the extracted holes and compares. A card that does not reconcile is
flagged for review, not silently written. This is nearly free and catches the failure mode that
matters (a transposed or hallucinated digit).

### 4.1 Legal footing

Extracting par, handicap and yardage from a course's own published page is extracting **facts about
a physical place**, which is not what copyright protects, for one course at a time at the request of
a golfer who is about to play it. That is the use case, and it is fine.

What is not fine, and is not being built: crawling all 928 sites into a database, or lifting a card
database out of 스마트스코어 / 골프존 / 카카오골프예약 and redistributing it. Those are compilations
behind terms of service. **Import is per-course, user-initiated, and stores to the user's own
`Courses/` folder.** Keep the `source` and `attribution` fields honest per research-course-map.md.

---

## 5. What this forces on the model, before any importer is written

A card-imported course has **par, handicap, yardage, and not one coordinate**. Today that is
unrepresentable: `Hole.green` is non-optional and `Green.center` is non-optional, so a `Hole` cannot
be constructed from a card at all. The changes, smallest set that works:

| Change | Why |
|---|---|
| `Green.center: Coordinate?` | A card has no coordinates |
| `TeeBox.at: Coordinate?` | Same |
| `TeeBox.distance: Double?` — metres | The number the card *does* give. Normalised at import (§3.1) |
| `Hole.nine: String?` + composite `id` | §3.2 |
| `Hole.hasGeometry` | The predicate the hole view branches on — a card-only hole shows its numbers with the map suppressed, never a degenerate plane at (0,0) |
| `Hole.source: Source?` | A card-from-web + geometry-from-track hole is now the **normal** case. research-course-map.md already requires per-hole provenance for mixed sources |

`HolePlane` is pure arithmetic with no guard, so a nil-coalesced coordinate renders a hole at the
equator rather than failing. `hasGeometry` must be checked before a plane is ever built.

This ordering is deliberate: **the model change lands before the importer**, because the importer's
output type is the thing being changed.

---

## 6. Getting geometry onto a card-only course

Import gives par and yardage. It never gives coordinates. The three paths from
research-course-map.md §2 stand unchanged — track-derived (primary), OSM where it exists (~3%),
walk-and-MARK — and this document adds the fourth, which the user chose on 2026-08-26:

**Hand-place tee and green centre on the satellite layer.** A tap per point, ~40 taps for 18 holes,
minutes per course, no visit needed. The card supplies par and the *distance*, which is a real
check on the placement: if the card says 383 and the placed tee-to-green measures 340, one of the
two is wrong, and the app can say so before the user walks onto the tee.

> **Standing invariant, deliberately narrowed 2026-08-26 by the user.** CLAUDE.md said "Never trace
> a course from Google or Apple imagery", on the grounds that both agreements forbid using their
> data to build a competing mapping service. The user's judgment is that hand-placing a few dozen
> points for a personal course file is not that. **The consequence is real and must be recorded:
> a course file built this way carries `source: traced` and cannot be published or shipped as
> data.** Files built from a track or a survey are unaffected and remain ours outright. Do not
> quietly merge the two into one distributable file.

Card distance also gives geometry a **bootstrap** it did not have: with a tee placed and a known
383 m to the green along a known bearing, the green centre has a starting position before anyone
has walked the hole.

---

## 6a. What is built, as of 2026-08-26

| Piece | Where |
|---|---|
| `CourseCard` — the extraction DTO, unit resolution, and reconciliation against the printed totals | `Sources/GolfCourse/CourseCard.swift` |
| `CardText.strip` — HTML → text with the table's shape intact (§3.4) | `Sources/GolfCourse/CardText.swift` |
| Optional geometry, `HoleGeometry`, `Hole.nine` + composite id, `Course.merging(card:)` | `Sources/GolfCourse/Course.swift` |
| `POST /v1/messages` over raw HTTPS — text, image and PDF blocks, JSON-schema output | `Sources/AnthropicClient/AnthropicClient.swift` |
| Fetch + one redirect hop + tag strip; the four-input importer; `--fetch-only` | `Sources/golfctl/CourseImport.swift`, `main.swift` |
| Prompt and schema, resolved from `--prompt` / `--schema` paths | `Prompts/course-card.{md,schema.json}` |
| Tap-to-place editor with the card-versus-ground check | `Sources/GolfMap/CourseEditorView.swift` |

**Unproven:** the `/v1/messages` leg has never run — the machine this was built on has no
`ANTHROPIC_API_KEY`. Everything on the near side of it is tested (64 tests) or verified by hand;
`--fetch-only` is verified end-to-end against Angeles National (US), 안성CC and 스카이뷰CC, with
the reduced text checked cell by cell against the source markup. The editor is verified in the
simulator, but the tap gesture itself was not exercised, only pre-placed state.

---

## 7. Open questions

- **Q1.** Does the card reconciliation check (§4) actually catch model transcription errors in
  practice, or do the totals get hallucinated consistently with the holes? Measure on ~10 real
  cards before trusting the flag.
- **Q2.** Is there a bulk US card source worth asking about — the USGA/GHIN course-rating
  database publishes rating and slope per tee for essentially every rated American course, and a
  rated tee implies a yardage. Licensing unknown, and it would not replace §4 (it has no per-hole
  yardage) but it would cover rating, slope and tee names at scale.
- **Q2a.** What fraction of the 78 "unreachable" Korean sites answer from a Korean IP? The US
  figure of 9% suggests most of the 32% is geo-blocking. Only matters if Korea becomes primary.
- **Q3.** Does the assumed-yards default ever silently survive to a placed course? It should be
  impossible — `lengthDisagreement` fires at 25 m and a mis-read unit is ~9% — but nobody has run
  a metric card through the US default and watched the flag fire. One end-to-end test with a real
  key would settle it.
- **Q4.** How close is a hand-placed green centre to a track-derived one, on a course where both
  exist? This is the honest accuracy number for §6 and nobody has it yet.
- **Q5.** 스마트스코어 and 골프존 both hold surveyed geometry for most Korean courses. Is there any
  licensed route to it, or is it strictly off-limits? Worth one email before assuming. Lower
  priority now that the primary market is the US, where OSM covers about half the courses free.

---

## Sources

- Overpass API, queried 2026-08-25 (KR) and 2026-08-26 (US and KR) — `golf=hole`,
  `golf=green` and `leisure=golf_course`
- Angeles National Golf Club scorecard — https://www.angelesnational.com/aboutus/scorecard/
- Crawl of 250 randomly sampled US course websites (of 6,879 OSM-listed), 2026-08-26
- 안성CC scorecard — https://www.ansungcc.co.kr/Course/ScoreCard.aspx
- 도고칸트리구락부 scorecard — https://www.dogocc.co.kr/Course/ScoreCard
- 천룡CC course guide — https://www.crcc.co.kr/course/course02.asp
- 서울한양컨트리클럽 scoreboard — https://www.hanyangcc.com/course/score.asp
- 스카이뷰CC (mobile fork found via JS redirect) — https://www.skyviewcc.co.kr/Mobile/course/info.aspx
- Crawl of 244 OSM-listed Korean course websites, 2026-08-26
