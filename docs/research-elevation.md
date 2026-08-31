# Marker — Research: Elevation, and the "plays like" number

Date: 2026-08-29 · Updated 2026-08-30 · Status: **§7 steps 1–3 are built.** The
`Elevation` grid, the GeoTIFF reader, `golfctl course elevation` against the live 3DEP
service, and the plays-like number on the hole view all exist and both real course files
have terrain. Steps 4 (the profile) and 5 (Korea) are not built. §0's findings survive
the build with **two corrections measured on the way**, marked ⚠ below.

Covers the elevation half of **P3** — the profile that
[`research-course-map.md`](research-course-map.md) lists as unbuilt, and the plays-like distance
that is the only reason a golfer cares about elevation at all. Read
[`research-course-map.md`](research-course-map.md) first: this document assumes its
geometry-versus-imagery split and extends it with a third acquisition, **terrain**, which behaves
like geometry (ours, storable, offline) and not like imagery.

---

## 0. Findings and the decisions they imply

1. **The phone's GPS altitude is the worst of the three sources available and must not be the
   basis of a number.** Vertical accuracy is substantially worse than horizontal — CoreLocation
   reports it separately as `verticalAccuracy` precisely because it is a different and weaker
   quantity, and developer reports put the error over 5 m routinely. A 5 m vertical error is
   about five yards of plays-like on a shot the golfer is choosing a club for. §1.
2. **The barometer is already being recorded and is the precise one — but only for
   *differences*, and only over minutes.** `GolfCaptureMotion.MotionRecorder` already writes
   barometric data. `CMAltimeter` relative altitude is quiet and fine-grained (centimetres of
   resolution); it drifts with weather over the hours of a round, and `CMAbsoluteAltitudeData`
   (iOS 15+) has a poor reliability record. §2.
2a. ⚠ **The elevation request must be made in EPSG:4326, not Web Mercator, and the
   georeferencing must be read out of the returned raster rather than out of the request.**
   Both were measured on 2026-08-30 and both produce a file that looks entirely correct.
   Asking for `imageSR=3857` returns a pixel scale in *Mercator* units, which at Coyote
   Creek's latitude is 1/cos(37.2°) = **1.26× the ground metre** — stored as metres it
   displaces a sample by ~270 m at the far corner of the course. And the service **snaps a
   requested bounding box outward to whole posts**: measured, by 146 m in one call, so a
   grid georeferenced from the bbox that was asked for is offset by up to that. §3.1.
3. **A stored DEM is the right primary source, and in the US it is very good.** USGS **3DEP
   1-metre** DEMs are lidar-derived, **public domain**, and specified at **10 cm (1σ) vertical in
   non-vegetated ground, 15 cm vegetated**; the seamless dynamic service is quoted at **0.53 m
   RMSE** nationally. That is an order of magnitude better than the phone can do for itself, and
   it needs no network on the course. §3.
4. **Korea gets a coarser answer and one real trap.** No 3DEP equivalent is settled here.
   **Copernicus GLO-30** is free, global, and covers Korea — but it is 30 m and it is a **surface**
   model, so it carries tree canopy and clubhouse roofs as though they were ground. That is the
   opposite of what a golf number needs. §3.2.
5. **Never mix a DEM height with a GPS height in one subtraction.** DEMs are orthometric
   (3DEP is NAVD88); CoreLocation's `altitude` is above mean sea level while
   `ellipsoidalAltitude` is not, and the two differ by tens of metres in California. Over a
   *difference* the datum cancels **only if both ends come from the same source**. One end from
   the DEM and one from the phone produces a plays-like number that is thirty yards wrong and
   looks entirely plausible. §4. **This is the invariant to write first.**
6. **The plays-like model is a model, and no manufacturer publishes theirs.** The defensible
   baseline is `playsLike = D + Δh`, and it should be labelled as an estimate the way an assumed
   distance unit already is. §5.
7. **It fits the existing shape with no new concepts**: a small elevation grid per course, stored
   in metres, beside `Courses/<id>.json` — the same acquisition model as the card and the OSM
   geometry, and the thing that finally lets `HolePlane.unproject` stop refusing to invent an
   altitude. §6.
8. ⚠ **Corica Park cannot verify a plays-like number and Coyote Creek can.** §7 step 2
   names Corica because it was the only course file that existed when this was written.
   Measured 2026-08-30: **10 m of relief across the entire Corica property** — every
   tee-to-green delta there is a yard or two, which no error would show against — against
   **177 m at Coyote Creek**, where hole 8 drops 14 m on a 308 m par 4. Verify against
   Coyote.

---

## 0a. What was measured on 2026-08-30, and what it settled

Every number below is from the live services, not from the documentation.

| | Corica Park South | Coyote Creek Tournament |
|---|---|---|
| 3DEP native resolution reported | **1 m** | **1 m** |
| grid vs the USGS point service | 1.375 vs **1.345** m | 107.31 vs **107.21** m |
| four points cross-checked after storage | — | **3–34 cm**, tee→green deltas within **0.37 m** |
| relief across the site | 10 m | **177 m** |
| grid at 3 m posts | 282 × 668, 368 KB | 570 × 507, 564 KB |
| one `exportImage` request | 6.5 s | 15.5 s |
| file on disk (`<id>.dem`) | 491 KB | 753 KB |

- **E1 is answered: yes.** 3DEP 1 m covers both courses this group has files for.
- **A whole course is one request.** Both fit far inside the service's 8000-pixel cap at
  any spacing worth using, so there is no tiler and no need for one.
- **`exportImage` will not tell you the native resolution**, and it resamples 10 m data to
  a 3 m grid without comment. The **point service** (`epqs.nationalmap.gov`) reports it,
  so the fetcher asks it once at the centre of the course and writes the answer into the
  file. A metre of vertical error against ten centimetres is the difference, and a grid
  built over the coarse product is byte-identical in shape to one built over lidar.
- **The vertical datum is not in the file.** A 3DEP GeoTIFF's geokeys describe the
  *horizontal* CRS (`WGS 84 / Pseudo-Mercator` or 4326) and its GDAL metadata says
  `DataType: Generic`. So `.navd88` is asserted by the fetcher from the product it
  requested, and stored — nothing reads it back out of the raster.
- **`format=bsq` is not usable and `format=tiff` is.** The headerless raw dump came back
  with **990,000 bytes for a 300 × 800 request** — 247,500 floats, not 240,000 — while the
  `f=json` metadata for the same call said 300 × 800. A raster whose dimensions have to be
  inferred from a byte count is one transposed grid from a course file that is silently a
  hole out of place. TIFF states its own width, height, tiling and georeferencing.
- **3DEP returns *tiled* TIFFs** (128 × 128, uncompressed, F32, one band) on every request
  measured. `GeoTIFF` reads stripped files too, because which layout the service emits is
  its choice and a stripped one would otherwise decode as an empty grid rather than as an
  error.

---

## 1. Why not the phone's own altitude

`CLLocation` exposes `verticalAccuracy` separately from `horizontalAccuracy` because vertical is
the weaker axis of a GNSS fix — satellite geometry constrains the horizontal plane far better
than it constrains height. The practical consequence for this app:

- A ±3–5 m horizontal fix, which is what the rest of this codebase is written around, comes with
  a vertical error commonly **two to three times larger**.
- The error is not white noise from shot to shot: it is correlated over minutes, so averaging
  across a stop does not help nearly as much as it does for position.
- `verticalAccuracy` is *reportable*, so a bad sample is at least rejectable — which is the one
  genuinely useful thing about it, and the same shape as `LogEntry.isPlaced` reading `hAcc`.

**So the phone can veto, and it cannot be the source.** The same conclusion as the position work
one axis up: the sensor decides where you are, the stored course file decides what is there.

## 2. The barometer we already have

`MotionRecorder` records barometric data on iOS today (it reads empty in the simulator, which has
no barometer). What that buys, precisely:

- **`CMAltimeter` relative altitude is the most precise elevation signal on the device** —
  fine-grained and quiet, because it measures pressure rather than trilaterating.
- It is **relative to when the update started**, and it drifts with the weather over a 4.5-hour
  round. Tee-to-green over ten minutes is well inside its stable window; hole 1 to hole 18 is not.
- **`CMAbsoluteAltitudeData` (iOS 15+) is not a substitute for a DEM.** It has a documented
  history of slow and inaccurate delivery, and it is calibrated against a model this app cannot
  inspect.

The useful role is therefore **not** as a source of absolute height but as a *check on the DEM
and a bridge between two points measured minutes apart* — the same relationship
`TrackingState`'s lock has with a raw fix. It is also free: the data is already being written.

## 3. Terrain sources

### 3.1 United States — USGS 3DEP

| Product | Post spacing | Vertical accuracy | Licence |
|---|---|---|---|
| 3DEP 1 m DEM | 1 m | 10 cm (1σ) non-vegetated, 15 cm vegetated (spec) | Public domain |
| 3DEP seamless dynamic service | mixed, 1 m where available | 0.53 m RMSE (quoted) | Public domain |
| 3DEP 1/3 arc-second | ~10 m | metre-scale | Public domain |

3DEP 1 m is produced exclusively from lidar at 1 m or better and is a **bare-earth** model, which
is what a golf course needs: a green under overhanging trees must read as the green. It is
downloadable through The National Map (TNMAccess API, the Download Client, or the ArcGIS image
services), it is **public domain with attribution requested rather than required**, and it is
therefore storable indefinitely — the same property that makes NAIP the answer for imagery in
[`research-imagery-offline.md`](research-imagery-offline.md) §3.

Coverage is not universal: 1 m exists where lidar has been flown. Where it has not, 1/3
arc-second (~10 m) is the fallback, and the fallback must be **recorded in the file**, not
inferred — the same reason `Course.Source` and `Hole.source` exist, and the same trap as a
guessed par being indistinguishable from a surveyed one.

### 3.2 Korea, and the trap in the global answer

- **No 3DEP equivalent is settled here.** NGII publishes national elevation data; its terms and
  its accessibility from a native app are unresolved, exactly as VWorld's are (open question C1).
- **Copernicus DEM GLO-30** is the global fallback: 30 m, free worldwide under a licence
  requiring an attribution notice, with a short excluded-country list that does not include
  Korea.
- **GLO-30 is a *surface* model (DSM), not bare earth.** It includes canopy and buildings. Over a
  tree-lined Korean course that is a systematic error in the direction that matters — the ground
  beside a green reads several metres high — and it is not noise that averages away.
- 30 m posts also smooth a golf hole flat. A green sitting 4 m above the fairway approach is a
  feature about 30 m across; at 30 m spacing it may not appear at all.

**So the honest Korean answer today is: a gross tee-to-green elevation difference, marked as
coarse, and no green contour.** Better than nothing and much worse than the US case. SRTM and
ASTER are both 30 m and both older; there is no reason to prefer them to GLO-30.

## 4. Datums — the failure that looks correct

Three heights, three references:

| Source | Reference |
|---|---|
| 3DEP | NAVD88 orthometric (approximately mean sea level) |
| `CLLocation.altitude` | Above mean sea level |
| `CLLocation.ellipsoidalAltitude` (iOS 15+) | WGS84 ellipsoid |

Ellipsoid and geoid differ by roughly **−30 m in California** and by a comparable amount in
Korea. A plays-like number is a *difference*, so the datum cancels — **but only when both ends
come from the same source**. The moment one end is the DEM and the other is the phone, the offset
does not cancel and the number is out by the geoid separation, which is far larger than the
elevation change it is trying to express, and it will look like an ordinary large number rather
than like an error.

**Rule, to be written as an invariant when this is built: an elevation difference is computed
from two samples of the *same* source, or it is not computed.** The barometer's relative altitude
is safe by construction here — it is already a difference and has no datum at all.

## 5. What "plays like" actually is

**Researched again on 2026-08-30, against the question "what is the most popular
formula", and the answer is unchanged and now sourced: add the elevation change to the
horizontal distance, one for one.**

```
playsLike = D + k · Δh          (Δh positive uphill, same unit as D, k = 1)
```

Every general-audience source says the same thing in the same words — *"about one yard of
distance adjustment per yard of elevation change"* — and the variants that put numbers on
it land within about 15% of it:

| Source | What it says | Implied k |
|---|---|---|
| ShotPattern, "How to Calculate Plays Like Distance" | one yard per yard of elevation | **1.0** |
| Common range/teaching rule | one yard per 3 ft of elevation | 1.0 |
| Uphill/downhill rule of thumb | +8 yd per 25 ft up; drop ÷ 3.5 down | 0.96 up, 0.86 down |
| Probable Golf Instruction (ballistics simulation, 6-iron) | 20 yd uphill costs **21**; 20 yd downhill gains **18** | 1.05 up, 0.90 down |

Two things worth keeping from that table:

- **There is a real, consistent asymmetry** — uphill costs slightly more than downhill
  gives, in both the rule of thumb and the trajectory model, at roughly 1.0 up against
  0.86–0.90 down. It is smaller than a GPS fix's own error over the distances involved
  and it is **not** what anybody teaches, so `k = 1` stays the default. It is the first
  thing to try if E3 ever gets data.
- **It also depends on club**, and in the direction that makes a single constant a
  compromise rather than an error: a driver's flatter descent is affected more per foot
  than a wedge's. That is the same first-order argument §5 has always made, now with a
  simulation behind it rather than an appeal to 45°.

`Geodesy.playsLike(distance:elevationDelta:factor:)` is that formula with `factor`
defaulting to 1, in one named function so a measured model can replace it without being
dug out of a view.

Rangefinder manufacturers all compute the same underlying quantity — horizontal distance
from the laser's slope distance and incline angle, then an in-house elevation
adjustment — and **none of them publish the adjustment**. So there is no standard to
match and no ground truth to check against, which is exactly why the number is marked as
an estimate wherever it appears.

Three constraints this codebase already implies:

- **`D` is the straight-line horizontal distance to the target, not the walked one.** A
  leg is a shot; the dogleg belongs to `measuredLength`. This is also what a rangefinder
  reports: its "plays like" is built on horizontal distance, never on line-of-sight.
  `Geodesy.distance` is haversine and therefore already horizontal — nothing has to strip
  a slope component out.
- **The adjustment is announced as an estimate.** It carries `~`, the same mark
  `CardYardage` puts on a measured length standing in for a card number: a different
  quantity, not a substitute. The *rise* is measured — 3DEP lidar — and is printed bare.
- **It is never the only number shown.** The measured yardage stays and the plays-like
  figure sits beside it.

### 5.1 How it is shown *(user, 2026-08-30)*

**`<distance>.<plays like><arrow><rise>`** — `333.~334▲1` — inline, in **four** places:
the big distance at the top, the first and second target legs, and the leg between two
shot markers. The two distances sit together because they are the same quantity twice —
what it measures and what it plays — and the rise trails as the *reason*.

- **No capsule.** The orange pill that carried this until 2026-08-30 was a second object
  saying something about a number three lines above it, which the eye had to join up.
- **No unit on any number.** It is stated once, in the caption: `YARDS TO GREEN`.
- **`~` marks the modelled half only.** The rise is measured — lidar, 10 cm spec — and is
  printed bare. It also stops `333.334` reading as a decimal.
- **The big number stays centred and the suffix hangs off its right edge.** Centring the
  pair moved the one yardage a golfer reads at a glance every time the ground stopped
  being flat.

**The arithmetic is done in the units the numbers are printed in.** Doing it in metres and
rounding afterwards puts three numbers on screen that do not add up: a 0.49 m rise over
164 m rendered `180 ▲1 · ~180`, because the rise rounds *up* to a yard while the
plays-like distance rounds *down* to the same 180. Found by screenshot on Corica hole 1,
and it reads as an arithmetic error in the app rather than as rounding. Since the model is
1:1, rounding first makes `distance + rise = plays like` exact on screen, always.

The suffix disappears when the rise rounds to nothing, which is most of Corica: `.~353▲0`
beside `353` is three claims that all say the same thing.

## 6. How it would fit

Nothing here needs a new concept:

- **Acquisition is a `golfctl` step**, like the card and like OSM: crop the course's bounding box
  out of the DEM once, resample to a fixed grid, write it beside `Courses/<id>.json`. A course
  file is committable and holds no voices, so this is the right side of the "never commit" line.
- **Storage is metres**, like every other distance in `GolfCourse`. `DistanceDisplay` is where
  feet or metres appear, if elevation is ever displayed as a number at all.
- **Size is not a problem.** A 1.5 km × 1.5 km course at 2 m posts is 750 × 750 = 562,500
  samples; as `Int16` decimetres that is about **1.1 MB**, against the 240 KB the Corica geometry
  file already takes. At 1 m posts it is 4.5 MB. Either is small next to half a gigabyte of
  CoreML.
- **It is the thing `HolePlane.unproject` is waiting for.** That function deliberately returns a
  coordinate with **no** altitude, because `Geodesy.coordinate(from:east:north:alt:)` would
  otherwise stamp the tee's elevation onto a point up the fairway and feed a plays-like number
  nothing measured. A DEM is the source that can answer honestly, and it is the only thing that
  should ever fill that field.
- **A `HoleGeometry` cross-check falls out for free**, in the same spirit as
  `lengthDisagreement`: if the DEM says the green is 12 m above the tee and the barometer says
  4 m over the same walk, something is wrong — a mis-assigned green, the wrong course file, or a
  DSM being used as a DTM. Report, never correct.

## 7. Order of work — 1–3 are done

1. ✅ **The datum rule and the `Elevation` type in `GolfCourse`.** `Elevation` is a grid
   georeferenced in **degrees** (which keeps every projection out of `GolfCourse`), stored
   as `Int16` decimetres with a void sentinel, sampled bilinearly, carrying its source,
   datum and native resolution. `Elevation.Sample.delta` returns **nil across two datums**,
   which is §4's invariant made structural. `Hole.elevationDelta(from:)` stopped reading
   the point's own altitude for the same reason. Tested against a synthetic grid, no
   network.
2. ✅ **`golfctl course elevation <course.json>`.** Fetches, verifies out loud (native
   resolution, relief, voids, coverage over the course's own points, per-hole tee-to-green
   rise) and writes `Courses/<id>.dem`. **Verified against Coyote Creek, not Corica** —
   see finding 8. The stored file agrees with the independent USGS point service to
   **3–34 cm** at four points and its tee→green deltas to **0.37 m**.
3. ✅ **`playsLike` on `HoleReadout`, marked as an estimate, and inline** *(revised by the
   user on 2026-08-30: no separate box, and on every distance rather than one)*. The
   format is `333.~334▲1` and it appears on the big distance, both target legs and the
   leg between two shot markers. `HoleReadout.Leg` carries a **per-leg** rise, so a layup
   over a ridge and the approach down off it read as the two different shots they are.
   §5.1.
4. ⬜ The elevation profile in the hole view — the P3 item this document was opened for and
   the *least* valuable of the four, because a golfer clubs off a number rather than a curve.
   `Elevation.profile(from:to:count:)` exists and nothing draws it.
5. ⬜ Korea: GLO-30 as a coarse fallback, marked coarse. `Elevation.Source.copernicusGLO30`
   and `.egm2008` are modelled and no fetcher writes them.

## 8. Open questions

- ~~**E1.**~~ **Answered 2026-08-30: yes, 1 m at both.** Corica Park South and Coyote Creek
  Tournament both report `resolution: 1` from the point service. This says nothing about the
  *next* course, and `golfctl course elevation` prints the answer per import for that reason.
- **E2.** How far does the barometer drift over a real 4.5-hour round? Answerable from a round
  already recorded — `MotionRecorder` has been writing this data and nothing has ever read it.
- ~~**E6.**~~ **Answered 2026-08-30 by the user: a separate button, on demand.**
  `CourseFinder` stays geometry-only and `TerrainSheet` is its own step in the course menu.
  The consequence, stated on the sheet: terrain has to be fetched *before* the round.
- **E3.** Is `k = 1` acceptable to the user, or should it be per-club? Needs a real round with
  known outcomes; not answerable from a desk.
- **E4.** NGII's terms and whether its DEM is reachable from a native app — the elevation half of
  the still-open C1.
- **E5.** Does the green's own contour matter, or only tee-to-green? 1 m 3DEP could carry a putting
  surface's slope; nothing in the product asks for it yet, and adding it would put a number on a
  putt, which is a different feature.

---

## Sources

- [USGS — vertical accuracy of 3DEP DEMs](https://www.usgs.gov/faqs/what-vertical-accuracy-3d-elevation-program-3dep-dems)
- [USGS — About 3DEP products and services](https://www.usgs.gov/3d-elevation-program/about-3dep-products-services)
- [USGS — terms of use for National Map services and data](https://usgs.gov/faqs/what-are-terms-uselicensing-map-services-and-data-national-map)
- [USGS — does the USGS have APIs?](https://www.usgs.gov/faqs/does-usgs-have-apis)
- [Copernicus DEM collection description](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM)
- [Copernicus GLO-30 licence](https://docs.sentinel-hub.com/api/latest/static/files/data/dem/resources/license/License-COPDEM-30.pdf)
- [Apple Developer Forums — CMAltimeter absolute altitude delivery](https://developer.apple.com/forums/thread/751610)
- [Apple Developer Forums — does CoreLocation fuse GPS altitude and barometer?](https://developer.apple.com/forums/thread/659367)
- [Today's Golfer — what the slope function in a rangefinder is](https://www.todays-golfer.com/news-and-events/equipment-news/what-is-slope-function-in-a-rangefinder/)
- [ShotPattern — how to calculate plays-like distance](https://shotpattern.app/blog/plays-like-distance)
- [Probable Golf Instruction — uphill/downhill club selection (trajectory model)](https://probablegolfinstruction.com/elevation_club_selection.htm)
- [WOSports — how to calculate uphill and downhill distances](https://wosports.com/blogs/news/how-to-calculate-uphill-downhill-distances-in-golf-slope-explained)
