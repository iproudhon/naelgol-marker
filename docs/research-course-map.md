# Marker — Research: Course geometry and the hole view

Date: 2026-08-24 · Status: research, nothing implemented

Covers **P3** (PLAN §2): a per-hole visual — satellite/aerial imagery, tee, green, the shot line,
the elevation profile. Two separable problems, and they must not be conflated:

| | Problem | Owner | Works offline? |
|---|---|---|---|
| **A** | **Geometry** — where the tee and green *are* | Ours. A course file we produce and keep | **Yes, always** |
| **B** | **Imagery** — the photo underneath | A map provider, under their licence | **No provider licenses this for free** |

Geometry is the part that carries the product (distance, bearing, playing distance, hole
assignment). Imagery is the part that makes it legible. Getting the dependency backwards —
treating the map provider as the source of truth — is the failure mode this document exists
to prevent.

---

## 0. Decisions and findings

1. **OSM hole geometry is a regional question, and the two answers are opposite.** Measured, not
   assumed (§2.1):
   - **United States: 150,178 `golf=hole` ways, ~7,900 courses with ≥9 holes** — roughly half of
     the ~16,000 US facilities. `ref` on 98%, `par` on 89%.
   - **Korea: 597 hole ways, 28 courses with ≥9 holes** — about 3%.

   *Revised 2026-08-26, when the user said the target is mainly American courses.* The original
   version of this document said "OSM is a free head start where it exists, never the plan" and
   "do not re-plan around OSM". **That is correct for Korea and wrong for the US.**
2. **Acquisition order is therefore regional.** In the US, OSM first; in Korea, the recorded
   track first. Both fall back to the same two things — the editor and a walked survey — so this
   changes a default, not an architecture. The track path stays primary wherever OSM is thin, and
   is the only path that improves per round.
2a. **ODbL is now the normal case, not an edge case.** Where OSM is the source, the derived course
   file carries share-alike obligations — and in the US that will be most files. This is a stronger
   constraint than the `traced` marking and it applies to the majority rather than a minority.
   `Course.Source.osm` and per-hole `Hole.source` already model it; nothing yet enforces it.
3. **Imagery: Apple MapKit `.imagery`**, decided 2026-08-24. Free, no key, no quota, no new SDK,
   already the `GolfMap` plan in PLAN §4.
4. **The offline requirement is met by vector, not by stored raster.** No provider — Google,
   Apple, or otherwise — licenses persistent storage of their imagery (§3.1). So the hole view
   has two layers: MapKit imagery when there is signal, and a **vector hole rendered from our own
   course file** when there is not. The vector layer is never a degraded mode; it is the layer
   that always works.
5. **Never trace a course from Google or Apple imagery.** Both agreements forbid using their data
   to build another mapping service, and a course file is exactly that (§2.3). Trace from imagery
   that permits it (VWorld, Esri, Bing) or, better, from your own track.
6. **A survey done with the MARK button must be exported into a course file before reconstruction
   sees it.** `marks.jsonl` is ground truth and never enters a prompt; `Courses/<id>.json` is not
   ground truth and must (§2.5).

---

## 1. What a hole view actually needs

The user's premise — "assuming that we have green center and tee locations" — is close, but two
fields short of useful:

| Field | Why it is not optional |
|---|---|
| `tees[]`, **per tee box** | White and back tees differ by 30–50 m. One coordinate makes every distance wrong for whoever is not on that tee |
| `green.center` | The number a golfer wants mid-fairway |
| `green.front` / `green.back` | Front-vs-back is a full club on a 30 m green. Center alone is the *average* wrong answer |
| `green.polygon` | Needed to say "on the green" — i.e. to end a hole |
| `line[]` | Tee→(dogleg)→green. This is what makes a hole *drawn*, and what gives the camera its heading |
| `par`, `ref` | Reconciling stroke counts against announced scores (PLAN §1) |
| `hazards[]` | Optional. Lie inference — "I'm in the bunker" becomes checkable |

**Geometry is not just for the map.** With hole polygons, `GPS fix → hole number` is a solved
geometric problem, and every reconstruction prompt gets a hard constraint it currently lacks:
this shot happened on hole 7, whose green is *there*, so a claimed 300 m approach is impossible.
That is worth more to P1 than the picture is to P3.

### Proposed course file

Outside `Sessions/`, one file per course, **and committable** — the "never commit" rule in
CLAUDE.md is about voices and credentials, and course geometry is neither. A course does not
change between rounds, so this is a one-time per-course artifact.

```
Courses/
  naelgol-cc.json
```

```json
{
  "id": "naelgol-cc",
  "name": "내골 CC",
  "aliases": ["Naelgol CC", "내골컨트리클럽"],
  "source": "track",
  "attribution": null,
  "updated": 1756070400000,
  "holes": [
    {
      "ref": "1", "par": 4, "handicap": 7,
      "tees": [
        { "name": "white", "lat": 37.4001, "lon": 127.2001, "alt": 112.4 },
        { "name": "blue",  "lat": 37.3998, "lon": 127.1997, "alt": 112.9 }
      ],
      "green": {
        "center": { "lat": 37.4035, "lon": 127.2044 },
        "front":  { "lat": 37.4032, "lon": 127.2041 },
        "back":   { "lat": 37.4038, "lon": 127.2047 },
        "polygon": [[37.4032, 127.2041], "…"]
      },
      "line": [[37.4001, 127.2001], [37.4020, 127.2030], [37.4035, 127.2044]],
      "hazards": [{ "kind": "bunker", "polygon": [["…"]] }],
      "confidence": 0.8
    }
  ]
}
```

Notes that matter:

- **`source` and `attribution` are load-bearing, not metadata.** An OSM-derived file is ODbL and
  carries share-alike obligations; a track-derived file is ours outright. Mixing them silently
  is how a licence gets breached. One `source` per file; if a hole is corrected from a different
  source, record it per hole.
- **`confidence` per hole**, same invariant as reconstruction (CLAUDE.md): a survey from one
  walked round is a draft the user amends, not a fact.
- **`alt` from `CMAltimeter`, not GNSS** (PLAN §5). Tee and green elevation is the entire point
  of P3, and GNSS altitude at ±10–20 m cannot see an 8 m rise.
- **Suggested home: a new `GolfCourse` target**, depended on by both `GolfMap` and
  `GolfReconstruction`. It is *not* ground truth, so it may cross the firewall — unlike anything
  in `Mark.swift`. Not built; this is a proposal.

---

## 2. Acquiring hole GPS data

Five paths. The ranking below is what the measurement in §2.1 forces, and it is **inverted from
`research-game-tracking.md` §6**, which was written before anyone counted.

### 2.1 OpenStreetMap — measured twice, with opposite results

The schema is close to ideal. [`golf=hole`](https://wiki.openstreetmap.org/wiki/Tag:golf=hole) is
a way from tee to green carrying `ref` and `par`, alongside `golf=green`, `golf=tee`,
`golf=fairway`, `golf=bunker` polygons. Free, no key, no rate limit worth worrying about.

**"Varies by region" undersells it by two orders of magnitude.** Measured against Overpass
(Korea 2026-08-25, US 2026-08-26), clustering features into courses on a 2 km grid:

| | **United States** | **Korea** |
|---|---:|---:|
| `leisure=golf_course` features | **16,055** | 928 |
| `golf=hole` ways | **150,178** | 597 |
| `golf=green` ways | **186,931** | 1,215 |
| Course clusters with ≥9 holes | **7,874** | **28** |
| …with ≥18 holes | 2,268 | 20 |
| …with ≥9 holes *and* `par` on every one | **6,598** | — |
| `ref` present | 97.8% | 76.6% |
| `par` present | 89.3% | 71.5% |
| `handicap` present | 38.2% | 5.9% |
| `dist` present | **0.3%** | **1.8%** |

**In the US, roughly half of all golf facilities already have usable hole geometry in OSM, with a
hole number and a par attached** — 6,598 courses' worth, free, no key, no visit. In Korea it is
about 3%. Same schema, same query, opposite conclusion.

Two things are true in **both** regions and matter as much as the headline:

- **`dist` is absent everywhere** — 0.3% in the US, 1.8% in Korea. OSM gives geometry and par; it
  does not give yardage. Per-tee distance still comes from a card
  ([`research-scorecard-import.md`](research-scorecard-import.md)).
- **`handicap` is thin even in the US** (38%), so stroke allocation also still comes from the card.

Reproduce (swap `US` for `KR`) with:

```sh
curl -s -X POST https://overpass-api.de/api/interpreter --data-urlencode 'data=
[out:json][timeout:280];
area["ISO3166-1"="KR"][admin_level=2]->.kr;
way["golf"="hole"](area.kr);
out tags center;'
```

**Verdict, revised 2026-08-26: in the US, check OSM first — it will usually be there.** In Korea,
expect it not to be. Either way it supplies **geometry and par, never yardage**, and anything
derived from it is ODbL and cannot be relicensed.

> **Follow-up, 2026-08-26.** This section is about **geometry**. The *card* — par, handicap and
> per-tee yardage — is a separate acquisition with a separate answer, measured in
> [`research-scorecard-import.md`](research-scorecard-import.md): OSM carries `handicap` on 6% of
> Korean holes and `dist` on 2%, so it is not a card source; course websites are, and a fourth
> geometry path (hand-placing on imagery, §6 there) was added on the user's decision.

### 2.2 Commercial course APIs

[iGolf Connect](https://igolf.com/solutions/golf-course-data/) (tee box centres, front/centre/back
pin coordinates, custom hazard points), [golfapi.io](https://golfapi.io/) (40,000+ courses,
160+ countries, green and tee coordinates, commercial use permitted),
[Golf Intelligence](https://golfintelligence.com/api-pricing/). All complete and maintained.

Two objections, one fatal for now: none publishes pricing without a sales conversation, and
**Korean coverage is unverified** — a global course count says nothing about whether 내골 CC is
in it. Worth a single query against one provider's free tier to answer that, and not worth more
until Marker has users. Not a dependency to design around.

### 2.3 Trace from aerial imagery

Click tee and green centres on an orthophoto. Minutes per course, no visit needed; this is how
[FairwayMapper](https://fairwaymapper.com/) works, and QGIS with a WMTS basemap does the same job.

**The imagery you trace from is a legal choice, not a convenience one.** Google's and Apple's
agreements both forbid using their data to create or improve another mapping service, and a
course geometry file is precisely that. So:

| Source | Trace from it? |
|---|---|
| **VWorld** orthophoto (국토교통부 / 공간정보산업진흥원) | Highest resolution over Korea of anything available. Terms unverified — **check before relying on it** |
| Esri World Imagery, Bing Aerial | Permitted for OSM tracing under their agreements; the usual choice |
| **Google Maps / Earth** | **No.** Terms of Service |
| **Apple Maps** | **No.** Developer Program Licence Agreement |

### 2.4 Derive from a recorded track — **the primary path**

This is the one the existing architecture already pays for. A round produces a continuous GPS
track, an altitude track, and marks; from one played round:

- **Green centre** — the group stands within a few metres of the pin for 30–90 s per hole, then
  all walk off together in the same direction. That is the single strongest cluster on the hole.
- **Tee** — a stationary cluster preceding a long straight displacement, right after the previous
  green cluster. `MotionSample.activity` transitions (`stationary` → `walking`) sharpen it.
- **The hole line** — the track between those two clusters, simplified.
- **Hole order and count** — free, from the sequence.
- **Elevation** — `CMAltimeter` relative altitude at each cluster, re-anchored per hole (PLAN §5).

Accuracy improves with every round: two visits give a second estimate to average, and a green
centre estimated from four rounds is better than most commercial data. It fits the standing
invariant exactly — *capture everything, derive what is derivable, let the user correct the rest.*

**Bootstrap consequence, and it is a good one:** the first round on an unmapped course is not
degraded. It records normally, geometry is derived afterwards, and reconstruction is re-run over
the *same* session with the new course file — every stage caches into the session folder, so
nothing is re-transcribed (CLAUDE.md). The course improves retroactively.

### 2.5 Walk-and-MARK survey — the explicit fallback

Mostly built. `RoundSession.mark(player:hole:note:)` already stamps time + position + accuracy,
and already records marks with no fix rather than dropping them. A survey mode is a MARK button
with a label: `note: "tee:7:white"`, `note: "green:7:center"`.

> **Firewall.** `marks.jsonl` is ground truth — never in an evidence bundle, never in a prompt
> (CLAUDE.md). Course geometry *must* reach the prompt. Therefore a survey is **exported**:
> `golfctl survey export <session> --course Courses/naelgol-cc.json` reads `marks.jsonl` and
> writes the course file, and `GolfReconstruction` reads only the course file. It must never
> read a session's marks to find a green. Same rule for `corrections.jsonl`.

### Recommended order — regional, revised 2026-08-26

**United States (the primary market):**

1. **OSM** (§2.1) — geometry plus par for ~half of all courses, free and instant. ODbL.
2. **Hand-place in the editor** (§6) — for the other half, and as the correction layer over OSM.
   Minutes per course, no visit.
3. **Track-derived** (§2.4) — improves any course with every round played, and is the only path
   that produces geometry nobody else has.
4. **Walk-and-MARK** (§2.5) — deliberate survey.
5. **Commercial API** (§2.2) — only if the free paths leave a gap that users hit.

**Korea (and anywhere else OSM is thin):** the original order stands — track-derived first, OSM
opportunistically, then the editor and a survey.

The card is a separate acquisition in every region and is never covered by any of these; see
[`research-scorecard-import.md`](research-scorecard-import.md).

---

## 3. Displaying imagery

### 3.1 Nobody licenses offline imagery for free

The requirement is a hole view that works in a mountain dead zone. Checked against each
provider's actual terms:

| Provider | Store imagery on device? | Cost | Korea |
|---|---|---|---|
| **Google** Maps Static / Map Tiles | **No.** Prohibits pre-fetch, index, store, cache; Map Tiles API "may not be used for non-visualization use cases, **including offline uses**" | 2026 pricing is subscription — Starter $100/mo (50K calls), Essentials $275/mo | Imagery available, military sites obscured (§3.2) |
| **Apple** MapKit | **No.** The Developer Program Licence Agreement permits caching/prefetching/storing only when temporary and necessary, and requires deletion after use (Schedule 6 §2.5 as of this writing — *the conclusion is solid, verify the section number before citing it*) | **Free**, no key, no quota | Available; resolution unverified |
| **Mapbox / MapTiler** | **Yes** — SDKs ship explicit offline tile packs and style packs | Paid, plus a third-party SDK | Global imagery |
| **VWorld** WMTS | Unverified | Free with a key | **Best resolution over Korea**; Korea only |

So "offline required" and "MapKit" cannot both be satisfied by raster. **The resolution is that
they are answering different questions.**

### 3.2 Korea changes the imagery picture, as of six months ago

South Korea has restricted export of map data for two decades. On **2026-02-27** the government
conditionally approved export of 1:5000 high-precision maps to Google, with conditions that read
directly onto this project:

- Raw map data must be processed on **domestic servers run by a local partner**, with prior
  clearance before any overseas transfer.
- **Contour data is excluded entirely** — so no foreign provider will supply Korean elevation.
  Marker's barometer (PLAN §5) is not a nice-to-have in Korea; it is the only source.
- All satellite and aerial imagery, including historical archives, must **obscure military and
  sensitive facilities**. Some Korean courses sit next to exactly those.
- Exportable scope is limited to base maps and transport networks.

Two consequences: foreign-provider imagery over Korea is legally required to be degraded in
places, and **VWorld is not merely a nicer option — it is the only source of full-resolution
Korean orthophoto and elevation.** Its WMTS is
`https://api.vworld.kr/req/wmts/1.0.0/{apiKey}/{layer}/{z}/{y}/{x}.{ext}` with layers
`Base` / `Satellite` / `Hybrid` / `gray` / `midnight` in EPSG:3857, key issued free from
`vworld.kr` under 오픈API 이용약관. Caveats before anyone builds on it: **the key model is
domain-registered**, which is awkward for a native iOS client with no domain, and its terms on
storage are unread. Both are one support call to 공간정보산업진흥원 to settle.

### 3.3 Decision — two layers, and only one of them is a photo

> **Implemented 2026-08-25.** `GolfMap.HoleScreen` switches between
> `VectorHoleView` (SwiftUI `Canvas` over `HolePlane`, no network at all) and
> `SatelliteHoleView` (MapKit `.imagery(elevation: .realistic)`), both oriented to
> the tee→green bearing so switching layers does not re-orient the golfer. The
> choice persists per user. Geometry comes from `GolfCourse`.

**Layer 1 — vector, always available.** Rendered from `Courses/<id>.json`: green polygon, hole
line, tee markers, hazard polygons, the live track, the shot sequence, distances. Zero network,
zero licence, zero cost, and it is the layer that carries every number a golfer acts on.

**Layer 2 — MapKit `.imagery`, when there is signal.** `MapStyle.imagery(elevation: .realistic)`
under the vector layer. Free, keyless, no SDK. Its cache is the OS's, is not ours to manage, and
is not guaranteed — which is fine, because nothing depends on it.

This satisfies both answers honestly. What it does *not* do is put a photograph under the hole in
a dead zone; if that becomes a requirement, the escape hatch is a provider that licenses offline
packs — Mapbox or MapTiler — or VWorld if its terms permit, and that is a paid, deliberate change,
not something to slide in.

### 3.4 The rendering math

Ground resolution in Web Mercator, 256 px tiles, at latitude φ:

```
m/px = 156543.03392 · cos(φ) / 2^z
```

At φ = 37.5° (Korea):

| z | m/px | 400 m hole spans | 550 m hole spans |
|---:|---:|---:|---:|
| 16 | 1.895 | 211 px | 290 px |
| 17 | 0.948 | 422 px | 580 px |
| 18 | **0.474** | **844 px** | **1161 px** |
| 19 | 0.237 | 1688 px | 2321 px |

**z = 18 is the envelope** for a whole-hole view on a phone; z = 19 for a green close-up. Solve
directly for a hole of length `L` into a viewport of `H` px:

```
z = log2( 156543.03392 · cos(φ) · H / L )
```

**Orientation.** A hole view is tee-at-bottom, green-at-top — i.e. rotated to the tee→green
bearing:

```
θ = atan2( sin Δλ · cos φ₂,  cos φ₁ · sin φ₂ − sin φ₁ · cos φ₂ · cos Δλ )
```

MapKit does this natively: set `MKMapCamera(lookingAtCenter:fromDistance:pitch:heading:)` with
`heading = θ`, or `MapCamera(centerCoordinate:distance:heading:pitch:)` in SwiftUI. No manual
rotation, no over-fetch.

**If you fetch a north-up static image and rotate it yourself** — which is what a Google or VWorld
static request forces — the source must contain the bounding box of the rotated view rectangle.
For a view `L × W`, that box has side at most `√(L² + W²)`; for a 550 m hole at 120 m wide, 563 m,
i.e. barely more than the hole. The often-quoted `L·√2` is the worst case for a *square* view and
over-fetches by ~40% here. At z = 18 that 563 m needs 1188 px — inside a Google
`size=640x640&scale=2` (1280 px) request, but only just, and a 700 m par 5 is not.

For reference, the Google request the user asked about — legal to display, illegal to store:

```
https://maps.googleapis.com/maps/api/staticmap
  ?center=37.4018,127.2022&zoom=18&size=640x640&scale=2
  &maptype=satellite&format=png&key=API_KEY
```

`maptype` ∈ `roadmap|satellite|hybrid|terrain`; max `size` 640×640, doubled by `scale=2`;
30,000 QPM ceiling; attribution is baked into the returned image and must not be cropped.

### 3.5 Rendering, concretely

**Unverified sketch — written from recall, not compiled.** Check the SwiftUI `MapStyle` /
`MapCamera` signatures against the SDK before pasting.

```swift
Map(position: $camera) {
    MapPolygon(coordinates: hole.green.polygon).foregroundStyle(.green.opacity(0.35))
    MapPolyline(coordinates: hole.line).stroke(.white, lineWidth: 2)
    ForEach(shots) { MapPolyline(coordinates: [$0.from, $0.to]).stroke(.yellow, lineWidth: 3) }
}
.mapStyle(imageryAvailable ? .imagery(elevation: .realistic) : .standard)
```

- `MKMapSnapshotter` + `MKImageryMapConfiguration` renders a hole to a still image for a share
  card or a round summary — subject to the same temporary-caching limit (§3.1), so render on
  demand, do not build a library of them.
- Distances: `CLLocation.distance(from:)` (geodesic), never planar. Playing distance = that,
  adjusted for the barometric elevation delta — PLAN §5.
- The elevation profile is our own `altitude.jsonl` sampled along the hole line. No provider
  supplies it in Korea (§3.2), which makes it a differentiator rather than a gap.

---

## 4. Open questions

| # | Question | Why it matters |
|---|---|---|
| C1 | How accurate is a track-derived green centre after one round? After four? | Decides whether §2.4 is really primary or just cheap |
| C2 | VWorld terms — storage permitted? Does the domain-registered key work from a native iOS app? | Only path to full-resolution Korean imagery and elevation |
| ~~C3~~ | ~~MapKit `.imagery` resolution over Korean courses~~ | **Answered 2026-08-25: usable.** Verified in the simulator at 37.40/127.20 — individual buildings and vehicles are legible at hole scale, so the imagery layer is worth having |
| C4 | Is 내골 CC in any commercial course DB? | One query settles §2.2 |
| C5 | Does hole geometry measurably improve reconstruction accuracy? | The claim in §1 that geometry helps P1 more than P3 is untested |
| C6 | Tee-box separation from a track — can white vs blue be told apart, or does it need a survey? | Distances are wrong for half the group otherwise |

---

## 5. References

- [`Tag:golf=hole`](https://wiki.openstreetmap.org/wiki/Tag:golf=hole) · [`leisure=golf_course`](https://wiki.openstreetmap.org/wiki/Tag:leisure=golf_course) · [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API) — §2.1, and the query that produced the coverage table
- [Map Tiles API Policies](https://developers.google.com/maps/documentation/tile/policies) · [Google Maps Platform Terms](https://cloud.google.com/maps-platform/terms) · [Service Specific Terms](https://cloud.google.com/maps-platform/terms/maps-service-terms) — no pre-fetch/store/cache; "including offline uses"
- [Maps Static API — Get Started](https://developers.google.com/maps/documentation/maps-static/start) · [Usage and Billing](https://developers.google.com/maps/documentation/maps-static/usage-and-billing) · [Pricing](https://mapsplatform.google.com/pricing/) — 640×640, `scale=2`, `maptype=satellite`, 2026 subscription tiers
- [`MKImageryMapConfiguration`](https://developer.apple.com/documentation/mapkit/mkimagerymapconfiguration) · [`MKMapSnapshotter`](https://developer.apple.com/documentation/mapkit/mkmapsnapshotter) — §3.3, §3.5. Storage limits: Apple Developer Program Licence Agreement, Schedule 6 §2.5
- [Korea clears exporting map data for Google](https://www.koreaherald.com/article/10684189) · [JURIST — conditional approval](https://www.jurist.org/news/2026/02/south-korea-conditionally-approves-googles-high-precision-map-data-export/) · [Restrictions on geographic data in South Korea](https://en.wikipedia.org/wiki/Restrictions_on_geographic_data_in_South_Korea) — §3.2, decided 2026-02-27
- [VWorld WMTS API reference](https://vworld.kr/dev/v4dv_wmtsguide_s001.do) · [WMS/WFS 2.0](https://www.vworld.kr/dev/v4dv_wmsguide2_s001.do) · [오픈API 이용](https://www.vworld.kr/dev/v4dv_apiuse_s001.do) · [국토교통부 배경지도 API](https://www.data.go.kr/data/15101104/openapi.do) — §3.2
- [Mapbox offline concepts](https://docs.mapbox.com/android/maps/guides/offline/concepts/) · [Static Tiles API](https://docs.mapbox.com/api/maps/static-tiles/) — the licensed-offline escape hatch
- [iGolf Connect](https://igolf.com/solutions/golf-course-data/) · [golfapi.io](https://golfapi.io/) · [Golf Intelligence](https://golfintelligence.com/api-pricing/) — §2.2
- [FairwayMapper](https://fairwaymapper.com/) — browser tracing editor for golf features, §2.3
