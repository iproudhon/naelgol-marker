# Marker — Research: Imagery before the round

Date: 2026-08-29 · Status: research. **Nothing implemented, and the headline answer is "not the
way it was asked".**

The question, as put: *cache satellite images before a round, for all zoom levels.* Extends
[`research-course-map.md`](research-course-map.md) §3, which decided the two-layer hole view but
stopped at "imagery is decoration".

---

## 0. The answer in four lines

1. **Pre-caching Apple's imagery is the one thing the licence names.** It is not a grey area and
   it is not a question of how the bytes are stored — a deliberate persistence step is the
   excluded act, and "warm every zoom level of eighteen holes before the round" is that act
   described precisely. This is already an invariant in CLAUDE.md; §1 is why.
2. **Google is stricter, not looser.** Their Tile API policy prohibits pre-fetching, indexing,
   storing and caching outright, and names offline use as prohibited.
3. **The providers that *do* license offline storage are paid ones** — Mapbox offline tile packs,
   Esri tile services with export enabled. Both are a subscription, an API key on a course with no
   signal, and a second attribution surface. §2.
4. **The free-and-storable answer exists and it is not a map provider: US federal orthoimagery.**
   **NAIP is 60 cm, public domain, and downloadable as files** — no tile licence, no key, no
   expiry, ours to store per course exactly like `Courses/<id>.json`. §3. It is the only option
   that survives the constraint the request was made under. Korea has no equivalent settled here
   (§4) and stays an open question, as it already is for VWorld.

**So the shape of a real answer is: keep MapKit as the live decoration it already is, and if the
photograph must survive a round with no signal, store a NAIP crop per course as our own asset.**
That is a different feature from "cache the map", and it is the one that can be built.

---

## 1. Why the obvious version is excluded

Apple's Maps Services terms restrict caching, prefetching and storing map data to what is
temporary and necessary, and require cached data to be deleted after use. Two consequences
this codebase already encodes:

- **`MKMapSnapshotter` writing a PNG per hole is the excluded act**, and it is exactly what
  someone reaches for after reading "cache the imagery". So is panning the camera over all
  eighteen holes on load to warm MapKit's own cache — the mechanism is different, the intent is
  the store.
- **MapKit's own cache is fine and is not ours.** `Map(.mapStyle(.imagery))` fetching at display
  time and caching however it likes is the supported use. What it is *not* is dependable: the
  cache is opaque, unguaranteed, and sized by the OS. **Nothing may come to depend on the
  photograph being there** — and, as CLAUDE.md says, that rule is about coverage first and
  licensing second. A course has poor cell service whatever the terms say.

"All zoom levels" makes it worse rather than better: the tile count for a hole grows fourfold per
zoom step, so the request as written is the largest possible version of the excluded act.

Google is not an alternative here. Their Map Tiles API policy prohibits pre-fetching, indexing,
storing or caching content except under narrow stated conditions, and calls out offline use.

---

## 2. Providers that do license offline storage

| Provider | Offline imagery? | What it costs |
|---|---|---|
| Apple MapKit | **No** — temporary caching only | — |
| Google Maps / Tile API | **No** — prefetch, store and cache prohibited | — |
| Mapbox | **Yes**, via offline tile packs in the Maps SDK | Subscription; satellite has its own commercial licence for derivative use; a second SDK in the app |
| Esri / ArcGIS | **Yes**, for tile services with export enabled | ArcGIS subscription |

Both real options are a paid dependency, an API key that must be present at download time, and
another attribution surface to keep clear of the HUD — the same class of obligation
`SatelliteHoleView.bottomReserve` already exists to discharge for Apple. Neither is obviously
worth it for a private group's app when §3 is free.

---

## 3. NAIP — the option that fits the constraint

The **National Agriculture Imagery Program** (USDA FSA, distributed through USGS):

- **60 cm ground sample distance** for 2018 and later, ±4 m horizontal positional accuracy.
- **Public domain.** Freely distributable and storable; a credit is requested, not required as a
  licence condition. This is the whole point: it is *data we hold*, not a *service we are
  permitted to display*.
- **Delivered as files**, JPEG 2000 quarter-quad tiles (3.75′ × 3.75′ with a 300 m buffer),
  through The National Map downloader and the TNMAccess API, plus ArcGIS image services at
  `imagery.nationalmap.gov` and `gis.apfo.usda.gov`.
- Refreshed on a multi-year cycle per state, so it is **older than Apple's imagery** and a course
  re-bunkered last season may look wrong. That is a real cost and it argues for NAIP as the
  *fallback* layer rather than the primary.

The shape that fits this codebase: a `golfctl course imagery` step that crops the course's
bounding box out of NAIP once, at one resolution, and writes it beside `Courses/<id>.json` — the
same acquisition model as the card and the geometry, and subject to the same rule that a course
file is committable and a session is not. 60 cm over a 400 m hole is about 670 px across, which
is roughly the resolution `HolePlane` already draws at (§ CLAUDE.md's 0.6 m/px note on outline
simplification), so **one level is enough and "all zoom levels" is answering a question the
vector layer already answers better**: past the photograph's detail the overlays stay sharp and
the numbers keep working, which is the two-layer design's own argument.

---

## 4. Korea

Unresolved, and it joins the open questions already standing in
[`research-course-map.md`](research-course-map.md) §4:

- There is no NAIP equivalent settled here. **VWorld** is the candidate and its storage terms are
  already open question C1 — the same question, asked of imagery instead of geometry.
- MapKit `.imagery` over Korea is good (verified in the simulator at 37.40/127.20, buildings
  legible at hole scale) — but "good" is about the live layer, and says nothing about storage.

Korean courses are the supported secondary case, so a US-only imagery asset is an acceptable
asymmetry as long as **nothing depends on the layer existing**, which is already the rule.

---

## 5. What not to build

- No `MKMapSnapshotter` pass, per hole or per round.
- No camera sweep over eighteen holes on load.
- No tile scraper against any provider's tile endpoint, Apple's or otherwise.
- No feature whose fallback is "the photograph should be here by now". The vector layer carries
  every number the golfer acts on; that is why it exists.

---

## Sources

- [Apple Developer Forums — Maps Server API caching questions](https://origin-devforums.apple.com/forums/thread/807656)
- [Google Map Tiles API policies](https://developers.google.com/maps/documentation/tile/policies)
- [Mapbox offline concepts and constraints](https://docs.mapbox.com/android/maps/guides/offline/concepts/)
- [Mapbox imagery tilesets](https://docs.mapbox.com/data/tilesets/guides/imagery/)
- [USGS NAIPPlus image service](https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer)
- [NAIP on data.gov](https://catalog.data.gov/dataset/national-agriculture-imagery-program-naip-imagery)
- [UGRC — NAIP resolution and accuracy](https://gis.utah.gov/products/sgid/aerial-photography/naip/)
