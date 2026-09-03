# naelvol — swing video browsing, capture and editing

Date: 2026-08-31 · Status: **built — N1–N4 and N6 done and verified in the simulator; N5
(capture) written and unexercised, because there is no camera here.** See §10 for what actually
happened, including four decisions this plan got wrong.
Companion: `~/src/vipl` (the app this is rewritten from), `docs/PLAN.md` §8 (swing analysis is
out of scope for Marker *the round tracker*; naelvol is the module that changes that).

**naelvol** is a clean rewrite of vipl's video half — browse, import, export, capture, edit —
as SPM targets inside this repo, written so it can be lifted into its own package later with no
edits to its own sources. Point cloud, `.moz`, depth capture and SceneKit are **out of scope**
and are not ported.

---

## 0. Decisions taken before planning *(user, 2026-08-31)*

| Question | Answer | What it forces |
|---|---|---|
| Pose in v1? | **Yes** | The overlay, freeze/ghost and the `Golfer` keypoint model are ported, not deferred |
| Pose engine | **MoveNet on TFLite** *(revised 2026-08-31 — there is no official CoreML MoveNet)* | A vendored `TensorFlowLiteC.xcframework` binary target; the inference half is iOS-only |
| Metadata home | **Embedded QuickTime metadata only** | No index file is the authority. Listing opens assets, so a *derived* cache is required |
| Foreign folders | **Bookmarked, read in place** | Security-scoped bookmarks; foreign sources are read-only. **Reaching vipl's own container is deferred** *(user, 2026-08-31)* — the mechanism is built, the vipl-specific access is the user's to arrange |
| UI stack | **SwiftUI, UIKit only inside** | `UIViewRepresentable` for preview layer, player surface, range slider |
| Capture features | **All four**: 120/240 fps, hand-pose trigger, gravity metadata track, live pose overlay | The capture path is `AVAssetWriter`, not `AVCaptureMovieFileOutput` |
| Capture vs the round's mic | **Refuse capture while a burst is recording** | naelvol never touches the shared `AVAudioSession`; the button is disabled with a reason |

---

## 1. Module layout

```
Sources/
  NaelvolCore/     model, metadata codec, sources, filters, thumbnail + listing cache
  NaelvolPose/     Golfer, keypoint geometry, smoothing, crop tracking        (cross-platform)
  NaelvolPoseTFLite/  MoveNet inference + delegates, DeepLab segmentation     (iOS only)
  NaelvolCapture/  AVCaptureSession, format picking, AVAssetWriter, gravity, triggers   (iOS only)
  NaelvolUI/       SwiftUI: browse grid, filter bar, player, edit sheet, capture screen
Vendor/            TensorFlowLiteC*.xcframework — fetched, not committed
```

**`NaelvolPose` is split in two because TFLite has no macOS slice.** The vendored xcframeworks
carry `ios-arm64` and `ios-arm64_x86_64-simulator` and nothing else, so anything that imports the
interpreter cannot build in `swift test` on this Mac. Everything that is arithmetic — `Golfer`,
the synthetic wrist, velocities, `unit`, `isValidPose`, the torso crop-region tracking that
MoveNet's sample does between frames — lives in `NaelvolPose` and **is** testable there; only the
`Interpreter` call is behind the iOS wall. That split is worth the extra target: the crop tracker
is the part with real logic in it.

Products: one `Naelvol` library re-exporting the five, plus each individually. `TensorFlowLite`
(vendored wrapper) and the `TensorFlowLiteC*` binary targets are internal — nothing outside
`NaelvolPoseTFLite` imports them.
Package floor stays **iOS 16 / macOS 13** — the existing rule. `NaelvolCapture` is
`#if os(iOS)` throughout, the same split as `GolfCaptureMotion`; `NaelvolCore` builds on macOS so
the metadata codec and the filters are testable in `swift test`.

**The extraction rule, and it is the whole point of the ask: nothing under `Sources/Naelvol*` may
import a `Golf*` target.** Same discipline as `AnthropicClient` knowing nothing about golf. A
swing's round context arrives as a plain value:

```swift
public struct SwingContext: Codable, Hashable, Sendable {
    public var courseID: String?      // Course.id — a string to naelvol
    public var courseName: String?
    public var hole: Int?             // 1-based playing index, the scorecard's meaning
    public var holeRef: String?       // "황룡/3" — display only
    public var playerID: String?
    public var playerName: String?
    public var roundID: String?       // session folder name
    public var tags: [String]
}
```

The **app target** maps `Course`/`Hole`/`Player` into it. That mapping is the only place the two
worlds meet, and it is a dozen lines.

---

## 2. The metadata format

A swing carries its own record; there is no authority file. It is written into a **custom
`mdta` key, `com.naelgol.naelvol.swing`**, as one JSON object — *not* into
`quickTimeMetadataKeyDescription`, because **that field is vipl's caption and its tag search**:
JSON in it turns every naelvol swing into a cell of raw braces in the app whose folder this
feature exists to browse. naelvol writes the description key too, as a short human sentence
(`"Corica Park South · 7 · steve · driver, fade"`), so a file reads correctly in both apps.
The structured payload:

```json
{"v":1,"course":"corica-park-south","courseName":"Corica Park South","hole":7,
 "player":"p-3","playerName":"steve","round":"session-2026-08-31-0912",
 "tags":["driver","fade"],"note":"too steep"}
```

Two rules that follow from the choice:

- **A file with no `com.naelgol.naelvol.swing` key is not an error — it is a vipl file.**
  `SwingMeta.parse` falls back to the description key, returning `tags` from whitespace/comma
  splitting and leaving every structured field nil. Every video in vipl's Documents directory
  reads correctly on day one, which is half the reason the folder is being browsed at all.
- **The custom key is the authority when both are present**, because the description is a
  rendering of it and either app may have rewritten the description by hand.
- **Writing metadata rewrites the file.** `AVAssetExportSession` passthrough to a temp file, then
  replace, preserving `creationDate`/`modificationDate` — vipl's `AVAsset.setMetadata` already
  does exactly this and its bug (`completionHandler(false)` called synchronously *after*
  `exportAsynchronously`) is fixed in the port. Consequence: **tagging is a write, so it is
  refused on a read-only source**; the edit sheet offers *Save a copy to Naelgol* instead.

Location (`quickTimeMetadataKeyLocationISO6709`) and creation date are read and written as vipl
does. A capture also writes the **gravity timed metadata track** (`AVAssetWriterInputMetadataAdaptor`,
one `x y z` string per video frame) so a tilted phone can be levelled on playback.

### The listing cache — derived, never authoritative

Opening 500 assets to draw a grid is not viable, so `SwingCache` (JSON in Application Support)
stores what a listing needs — url, size, mtime, duration, dimensions, frame rate, parsed
`SwingMeta`, thumbnail path — keyed on **(bookmark id, relative path, size, mtime)**. A key
mismatch re-reads the asset. It is a cache in the sense the Whisper model folder is: deleting it
costs a slow first scan and nothing else, and **no code path may read a field from it that it
could not have got from the file**. Thumbnails are JPEG in the cache directory (vipl's
`ThumbnailCache`, made durable).

---

## 3. Sources and bookmarks

```
Sources
 ├ Naelgol   Documents/Swings/            read-write, always present
 ├ vipl      <bookmarked folder>          read-only
 └ + Add folder…
```

- `SwingSource` = `{ id, name, kind: .app | .bookmarked, bookmark: Data? }`, persisted in
  `UserDefaults` under `naelvol.sources`.
- **`startAccessingSecurityScopedResource()` around every read, balanced with `defer`** — the
  round importer's rule, and the failure mode is identical: without the scope the read fails with
  an error that reads like a corrupt file, and an unbalanced call leaks a sandbox extension.
- **A stale bookmark is a first-class state, not an error toast.** `URL(resolvingBookmarkData:)`
  reports `bookmarkDataIsStale`; the source row says *needs permission again* and re-picking the
  folder repairs it in place, keeping the source id so cached metadata survives.
- **The app's own directory is `Documents/Swings/`** — under `Documents` deliberately, because
  `UIFileSharingEnabled` is already on and a swing should come off the phone over Finder the way
  a session folder does. (Models go in Application Support; recordings do not.)
- Foreign sources are **read-only for writes to the file** — play, scrub, export, share, and
  *save a copy into Naelgol* all work. (That copy is the import-on-demand path; it exists only as
  the escape hatch for editing a foreign file, and nothing does it automatically.)

**Reaching vipl's own container is out of scope for now** *(user, 2026-08-31)*. It is not free:
vipl's project sets `LSSupportsOpeningDocumentsInPlace` but **not** `UIFileSharingEnabled`, so its
Documents folder never appears under *On My iPhone* and no document picker can grant a bookmark to
it. The source machinery below is built generically and works against any folder the user can pick
(iCloud Drive, a synced folder, another app that does publish); wiring vipl in is a one-line
`Info.plist` change in that repo, to be made when the user chooses.

---

## 4. Capture — `NaelvolCapture`

Ported from `CaptureViewController` (2,011 lines) minus everything depth: no
`AVCaptureDepthDataOutput`, no `AVCaptureDataOutputSynchronizer`, no `PointCloudRecorder`, no
`SCNView`. What that removes is also what removes vipl's **C1** constraint — depth capture forced
the *video* down to ≤640 px and ~30 fps, so with depth gone the format picker is free to take the
fastest format the device has.

- `SwingCaptureSession` (an `ObservableObject`, not a view controller): configure, start, stop,
  camera list, format choice, torch, HDR/10-bit toggle, orientation transform.
- **Format picking is per camera, max fps per resolution**, as `CaptureHelper.listCameras()` does.
  Selection is remembered in `naelvol.camera` / `naelvol.format`.
- **Recording is `AVAssetWriter`** (`CaptureMovieFileOuptut` rewritten, name and typo both fixed),
  because a timed metadata track cannot be written by `AVCaptureMovieFileOutput`. Video + audio +
  gravity metadata, `expectsMediaDataInRealTime`, file-level metadata (creation date, location,
  the `SwingContext` JSON) written at `start`, so **a swing is tagged with its course and hole at
  the moment it is recorded** rather than by an edit afterwards.
- **Hand-pose trigger**: `VNDetectHumanHandPoseRequest` on the preview buffers, open-palm and the
  hand-shape gestures, with the torch flash as the countdown (`flashTorch(count:millis:)`).
  Behind a toggle, off by default, and **the Vision request runs on a throttled fraction of
  frames** — at 240 fps a per-frame request is not affordable and is not needed for a gesture held
  for a second.
- **Live pose overlay**: MoveNet on the same throttled preview path, drawn by the shared overlay
  renderer (§5). Off by default at ≥120 fps, and the toggle says why.
- **Capture is refused while a round burst is recording** *(user, 2026-08-31)*. One microphone —
  the rule the whole capture stack is built on — and an `AVCaptureSession` with an audio input
  starting under a live `AVAudioEngine` tap either interrupts the burst (which closes a segment)
  or fails silently. **naelvol never sets the `AVAudioSession` category, activates it, or touches
  the route**; it reads `RoundViewModel`'s recording state through an injected
  `isBlocked: () -> String?` and the button is disabled *with the reason printed*, because a
  control that does nothing and says nothing is the failure this codebase keeps rediscovering.
  A burst is open exactly when a swing is about to be played, so expect this to come back for
  revision — the video-only fallback is the thing to try, and it is one branch: drop the audio
  input, keep everything else.
- **naelvol owns no `CLLocationManager`.** vipl's capture path creates one; this app has been
  burned twice by a second radio (`LiveLocation.adopt`, and `MarkerSheet` naming three managers
  to run at most two). The location stamped on a swing arrives as an injected
  `fix: () -> (latitude: Double, longitude: Double, altitude: Double)?`, which also keeps the
  no-`Golf*`-imports rule intact.
- **A capture is filed the instant it stops.** No "captured video" holding pen: the file lands in
  `Documents/Swings/` with its context already embedded, and the browse grid is the review screen.

**Not testable anywhere but on a phone**: there is no camera in the simulator, and there are no
scripted taps here. The capture screen's *layout* is reviewable with `ImageRenderer`; nothing
about the session is.

---

## 5. Player, edit, export — `NaelvolUI`

Ported from `PlayerViewController` (1,399 lines), which is the piece with the most to keep:

- Frame-accurate stepping, play/pause, speed menu (down to 1/8), reverse, repeat, and
  **`smoothSeek`** — the serialised seek that makes scrubbing a 240 fps file usable.
- **Range slider → trim.** `RangeSlider` (216 lines, `UIViewRepresentable`) sets in/out; the loop
  plays the range; *Save* and *Save as new* export it. **The preset is `Passthrough` unless a
  `videoComposition` is actually attached**, and only then `HEVCHighestQuality`: vipl re-encodes
  unconditionally, and a re-encode of a 240 fps file is the one property the feature exists for
  put through a preset that need not preserve it. The export carries the source's **metadata,
  both keys** — trimming must not throw the course and hole away, which is a one-line mistake.
- **Pose overlay** with freeze/ghost stacking, and `PoseCollection` — whole-video pose extraction —
  **alive from the start**. It is written and commented out at both call sites in vipl; a golf app
  whose pose path is dormant is the thing being fixed.
- Zoom/pan on the video surface, sound toggle, gravity levelling from the metadata track, info
  panel, tag editor, delete, and `ShareLink` for export.
- **The player surface is UIKit** (`AVPlayerLayer` + the overlay `CALayer`) behind one
  `UIViewRepresentable`; everything around it is SwiftUI.

Import: `PHPickerViewController` (Photos), `UIDocumentPickerViewController` (Files). Both copy
into `Documents/Swings/` and stamp a `SwingContext` if one is in scope.

---

## 6. Pose — `NaelvolPose` + `NaelvolPoseTFLite`

**There is no official CoreML MoveNet.** Google publishes MoveNet as TFLite, TF.js and a TF Hub
SavedModel; Apple publishes nothing; and `coremltools` has no TFLite frontend, so a CoreML build
means converting the SavedModel yourself and then proving the result matches. The community
conversions that exist are unofficial and report friction with the model's dynamic crop logic.
So **naelvol runs the same `.tflite` files vipl runs today** — zero model risk, and
`MoveNet.swift` / `PoseEstimator` / `PoseData.swift` port with no API changes.

Packaging, which is where the cost moved to:

- **TFLite has no official SPM distribution** — CocoaPods or Bazel, and a pod cannot be consumed
  from inside a package. What it does ship is `TensorFlowLiteC.xcframework` (plus the `CoreML`
  and `Metal` delegate frameworks) inside the pod, and an xcframework is exactly what
  `.binaryTarget` wants.
- **The xcframeworks are fetched, not committed.** All three are **171 MB** unpacked
  (`TensorFlowLiteC` 65, `Metal` 56, `CoreML` 49); `Tools/fetch-tflite.sh` downloads the pod
  archive, verifies a **pinned checksum**, and extracts into `Vendor/`, which is gitignored.
  `Package.swift` declares `.binaryTarget(name:path:)` against those paths. A fresh clone runs
  the script once; a missing `Vendor/` is an SPM resolution error with the script named in it.
- **The Swift wrapper is vendored source, Apache-2.0.** `tensorflow/lite/swift/Sources` is a
  dozen files (`Interpreter`, `Tensor`, `Delegate`, `CoreMLDelegate`, `MetalDelegate`, …) and is
  what `import TensorFlowLite` resolves to. Copied under `Sources/TensorFlowLite/` with its
  licence header and `NOTICE` intact, so the package has no CocoaPods dependency and stays
  liftable into its own repo — the fetch script and the binary target go with it.
- **The version is chosen, not inherited.** vipl pins `0.0.1-nightly.20221227`, a nightly from
  December 2022. N4 picks a current stable LiteRT/TFLite release and the gate below is what says
  whether the newer runtime changed anything.
- Delegate order is vipl's: **CoreML → Metal → CPU (4 threads)**, chosen at runtime, since the
  CoreML delegate is what puts MoveNet on the ANE.

Everything else is unchanged from the earlier plan:

- `Golfer` (17 keypoints + synthetic wrist midpoint, per-point velocity/acceleration, `unit` =
  hip↔knee distance, `isValidPose`) ports **unchanged in behaviour** — it is tuned against real
  swings and re-deriving it is not in scope.
- `DeepLabV3.mlmodel` is already CoreML and ports as-is for the freeze-body segmentation. It is
  the one model that is *not* TFLite, and it needs no conversion.
- **Models are located, not bundled.** Neither pose target declares `resources:`; the host app
  ships `movenet_lightning.tflite` / `movenet_thunder.tflite` and hands over a folder URL. Same
  reasoning as the prompt/schema path rule and as `WhisperEngine.modelFolder` looking rather than
  computing: a resource declaration generates `Bundle.module`, and a library that can only find
  its model inside its own bundle cannot be handed a newer model without a rebuild. It also drops
  vipl's `Bundle.main.path` assumption, which is what makes the model unswappable there.
- `PoseCollection` — whole-video pose extraction — is **alive**, unlike in vipl where it is
  commented out at both call sites.

## 7. Host integration — the three entry points

Both actions everywhere: **Swings** (list, filtered) and **Capture** (start).

| Screen | Where it hangs | Default filter |
|---|---|---|
| `RoundsListView` | the existing toolbar `Menu` | none |
| `RoundScreen` (scorecard) | `roundMenu` | this round's course; resettable |
| `HoleScreen` (GPS hole view) | the pin menu, both items | this course **and** this hole; resettable |

Three constraints from this codebase that shape the wiring:

0. **One home per action.** Both hole-view items live in the **pin menu** and nowhere else —
   X12's rule is *moved, not duplicated*, and the hole view already has exactly one drag gesture
   by design, so neither of these earns a tool-column button or a fifth gesture. The pin menu is
   `Equatable` with its closures excluded from `==` (X5); two more closures follow that rule
   unchanged.
1. **`HoleScreen` is in `GolfMap` and must not learn what a swing is.** It takes
   `onSwings: (() -> Void)?` and `onCapture: (() -> Void)?` and draws the controls only when they
   are non-nil — the exact precedent of `onMark: nil`. The app passes them; `golfctl` and any
   render harness pass nothing and lose nothing. A second generic slot beside `Bar` is *not* the
   answer: it costs another `where Bar == EmptyView` extension.
2. **`CourseView.body` and its `HoleScreen` call are both at the type-checker's budget.** The two
   new sheets go in a `SwingSheetPresenter: ViewModifier`, mirroring `MarkerSheetPresenter`, not
   as two more `.sheet` lines in `body`.
3. **The filter is a default, not a constraint.** The filter bar shows *Corica Park South · Hole 7*
   as removable chips, because a golfer looking for "that drive on 12 last month" reaches the list
   from wherever they are standing. Chips are seeded from context; clearing them shows everything
   in every source.

---

## 8. Phases

| # | Deliverable | Gate |
|---|---|---|
| N1 | `NaelvolCore`: `Swing`, `SwingMeta` codec, `SwingSource` + bookmarks, scan, `SwingCache`, filters | `swift test`: JSON round-trip, a vipl plain-text description parses to tags, filter predicates, cache key invalidation on mtime/size |
| N2 | `NaelvolUI` browse: grid, thumbnails, filter bar, sources screen, detail/info, delete, `ShareLink` | Simulator screenshot with a seeded `Documents/Swings/` and a bookmarked folder; a stale bookmark renders as *needs permission* |
| N3 | Player + trim/export + tag editor | Trim a real `.mov` on device; **assert the exported file still carries course/hole/location** |
| N4 | `NaelvolPose` + `NaelvolPoseTFLite`: fetch script, binary targets, vendored wrapper, `Golfer`, overlay, freeze/ghost, `PoseCollection` alive | `swift test` covers the cross-platform half on macOS. On device: **same keypoints as vipl** on a fixture video, max per-joint delta reported — that is what checks the runtime version bump, not the model |
| N5 | `NaelvolCapture`: session, format picking, `AVAssetWriter`, gravity track, live overlay, hand trigger | **Device only.** 240 fps file plays back; gravity track present and levels; a triggered recording starts and stops with nobody at the phone; **the round's burst is unaffected — capture is refused while one is open, and the reason is on screen** |
| N6 | Host wiring: three entry points, `SwingContext` mapping, `SwingSheetPresenter` | Screenshot each entry point; a swing captured from the hole view lists with hole 7 pre-filtered |

N1–N4 are reviewable here. N5 is not, and N6's hole-view half needs a phone to be honest about.

---

## 9. Risks and open questions

- **TFLite packaging is the risk that replaced the conversion risk.** No official SPM
  distribution, a 171 MB fetched dependency, and a runtime version that has moved several years
  past the nightly vipl pins. Failure modes: the current release's pod layout differs from the
  script's expectation (fix the script), or the newer runtime shifts keypoints (N4's gate catches
  it; the answer is to pin the older nightly, whose xcframeworks are already on this machine
  under `~/src/vipl/Pods/`).
- **The pose stack cannot be built or tested on this Mac.** No macOS slice, so `swift test`
  exercises `Golfer` and the crop tracker and nothing that touches an `Interpreter`.
- **240 fps + live pose is a frame budget nobody has measured here.** The throttle fraction is a
  parameter, not a constant to guess once.
- **File coordination on a bookmarked folder is unsolved by design.** If vipl writes while
  naelvol reads, naelvol sees a partial file — the same rule as an `.m4a` still being written.
  A zero-byte or unopenable asset is skipped and counted, never rendered as a broken cell.
- **Two apps, one folder, no shared identity.** A swing's identity is its URL plus its embedded
  metadata; a file renamed outside naelvol is a new swing to the cache. Accepted: the metadata
  travels in the file, so nothing is lost, only re-read.
- **Refusing capture during a burst is the decision most likely to be revisited.** It is the
  safe answer and it blocks the feature at the moment it is wanted. Video-only capture is the
  fallback and the plan keeps it one branch away.
- **Hole numbering.** `SwingContext.hole` is the **1-based playing index**, matching
  `Course.nearestHole` and the scorecard column — never `Hole.ref`, which is not a key. `holeRef`
  rides along for display.


---

## 10. What was built, and where the plan was wrong

Implemented 2026-08-31. `Naelvol/` (its own package) and `Naelvol/TFLite/` (a second one),
wired into the app through `Apps/Naelgol Marker/Naelgol Marker/SwingFeature.swift`.

**Verified here**: 34 tests in `Naelvol` (`swift test`), 503 in Marker's own package still green,
the app compiles for the simulator, and the swing list, the filter chips, the metadata round trip
and the capture screen were screenshotted in it. **Not verified anywhere**: the camera, the
recorder, the gravity track, both triggers, and MoveNet — there is no camera and no ANE in this
simulator, so N5 and the pose engine are written and unexercised.

Five things the plan had wrong, all found by building it:

1. **TFLite had to be quarantined in a second package, not a second target.** The plan put
   `NaelvolPoseTFLite` in `Naelvol` beside everything else. SwiftPM builds *every* target in a
   package, so the first `swift test` after adding the binary targets failed with `no such module
   'TensorFlowLiteCCoreML'` on macOS — taking the metadata codec and the pose geometry down with
   it. `Naelvol/TFLite/` is its own package, depends on `Naelvol`, and is only ever built for iOS.
2. **The pod's frameworks have no `Info.plist`**, because CocoaPods handles static frameworks
   itself. Xcode refuses a binary target without one ("did not contain an Info.plist"), so
   `fetch-tflite.sh` writes a minimal one into every slice. The binary is a Mach-O *object*, so
   the linker still links it statically and what lands in the app is a 40 KB stub, not 65 MB. The
   xcframeworks also need `-lc++` plus Accelerate, CoreML and Metal named in `linkerSettings`;
   without them the failure is a wall of missing `std::` symbols when the **app** links.
3. **The round must not be part of the list's filter.** The first wiring seeded `roundID` from the
   scorecard and the hole view, and the list came up empty on a phone with three matching swings:
   a swing filmed on this hole last month is exactly what somebody standing on it wants. The round
   is stamped on a *capture*; the list filters on course and hole.
4. **A seeded filter cannot be applied in `init`.** Assigning `library.filter` from the browse
   view's initialiser puts it back on every body evaluation, so a cleared chip reappears. It is
   applied once, in `task`, behind a `@State` flag — the filter is a default, not a constraint.
5. **The range slider is SwiftUI, not a wrapped UIKit control.** The plan named `RangeSlider` as
   one of the three `UIViewRepresentable`s; the two handles and the draggable span are three
   gestures a `UISlider` pair does not have, and writing it in SwiftUI was shorter than wrapping
   vipl's 216-line version. The two remaining wrappers are the preview layer and the player layer.

Three more found by a review pass after the screens were up, all real:

6. **The pose toggle was dead.** `PoseCollection` extraction was written and nothing called it, so
   turning "Pose" on drew nothing on any clip — the one feature v1 was explicitly opted into. The
   toggle now runs extraction the first time and **assigns the pose immediately**, because a
   *paused* frame is how this screen is used and nothing else would set one until the next scrub.
7. **"Save trim as new" wrote a file the grid never showed.** The player told the library to
   *reload the row for that URL*, and a file that did not exist a moment ago has no row: it
   reloaded the original and the copy stayed invisible until a manual rescan. A new file triggers
   a scan (`onWroteNew`), a rewritten one a reload.
8. **The trim export moved into `NaelvolCore` as `SwingExport.trim`** so N3's own gate could
   actually run: it lived in the player, inside an iOS-only target, where no `swift test` reaches
   it. The test writes a fixture, tags it, trims it and asserts the course, the hole and the
   location survive — the failure it guards is a clip nobody can ever find again, since there is
   no index to recover them from.

9. **`NSCameraUsageDescription` was missing, and that is a crash rather than a refusal** — found
   on a device, not here: this simulator has no camera, so the capture screen reported "no camera
   naelvol can use" and never reached the input. Added as an `INFOPLIST_KEY_*`.

10. **The player was thinner than vipl's and the user asked for all of it** *(2026-08-31)*. Now
    on screen: vipl's tap zones and swipe scrub, pinch zoom with a self-classifying drag,
    reverse and fast play, speed, loop, mute, frame stepping, the trim range with vipl's
    playhead-relative presets (−0.3/+0.2, −1.75/+1.5, −2/+5, whole clip), pose and body overlays
    with freeze all/pose/body/clear, an info panel and a Maps link, and the four gravity modes.
    Two engines, not one: poses come from the precomputed `PoseCollection`, silhouettes from
    Vision's person segmentation on the live frame through an `AVPlayerItemVideoOutput` — one
    mask per frame of a 240 fps clip is hundreds of megabytes, so that one cannot be precomputed.

11. **The front camera records mirrored — and the first attempt mirrored the wrong axis**
    *(user, 2026-09-01, twice)*. Setting `isVideoMirrored` while the writer's transform did the
    rotation produced an **upside-down** clip, because the flip is about the *connection's*
    vertical axis and a horizontal flip followed by a 90° rotation is a vertical flip. Rotation
    and mirroring now both live on the connection — preview included — and the writer transform
    is identity. The cost is stated rather than hidden: a mirrored swing shows a right-hander
    swinging left-handed, which is why it follows the camera instead of being a setting.

Smaller deviations worth knowing: the payload is written to a **custom `mdta` key**
(`com.naelgol.naelvol.swing`) with a human sentence in the description beside it, so a naelvol
file still reads as a caption in vipl; `PoseCollection` is a plain array rather than vipl's ring,
and its acceleration term is *fixed* (vipl reads the previous point's velocity while dividing by
this frame's interval, and never checks that a third frame exists); and `GravityTrack` reads
vipl's `common/title` gravity items as well as naelvol's own key, so a swing filmed in vipl levels
here.

Reviewing it here: `-marker.swings YES` opens the list (add `-marker.hole 7` for the filtered
one), `-marker.swings capture` the camera, `-marker.swing swing-0001.mov` the player, and
`-marker.swings.seed YES` writes three tagged clips first. All four exist for the same reason
`marker.sheet` does: these screens sit behind a menu and a tap, and neither exists in this
environment.

**Left undone, deliberately**: the vipl container (deferred by the user), any pose overlay that
has been seen to line up with a real body, and the freeze/ghost stack beyond the code that draws
it. `MoveNetCrop`'s port keeps Google's `score < minCropKeyPointScore` filter — which reads
backwards — because the gate for this port is producing *vipl's* keypoints, not better ones.
