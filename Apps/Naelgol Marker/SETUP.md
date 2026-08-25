# Naelgol Marker — iOS app

The project exists and builds. Sources are in `Naelgol Marker/`, which is an Xcode 16+
**synchronized root group**: dropping a `.swift` file in that folder adds it to the target,
no project edit required.

## Already done

- Local Swift package dependency on `../..` → `GolfSessionFormat`, `GolfCaptureCore`,
  `GolfCaptureMotion`
- iOS 26.5 deployment target, bundle id `com.naelgol.Naelgol-Marker`, automatic signing
- Every privacy usage string, as real text — placeholders are an automatic App Review rejection
- `UIBackgroundModes` (`audio`, `location`) and `UIFileSharingEnabled` in `Info.plist`

Two of those needed care, and both fail *silently* if you undo them:

- **`NSMotionUsageDescription`** — without it `CMMotionActivityManager` and `CMPedometer`
  return nothing at all, with no error. Elevation and activity just never arrive.
- **`UIBackgroundModes` / `UIFileSharingEnabled`** — Xcode's Info.plist *generator* drops
  these two even when the matching `INFOPLIST_KEY_*` build settings are set, so they live in
  `Info.plist` instead. That file sits beside the `.xcodeproj`, deliberately outside the
  synchronized folder: inside it, Xcode also copies it as a resource and the build dies with
  "Multiple commands produce Info.plist".

## Compile check (no device, no signing)

```sh
cd "Apps/Naelgol Marker"
xcodebuild -scheme "Naelgol Marker" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

The simulator has no barometer and no motion coprocessor, so it is a compile check only —
elevation and activity will read empty there. Both need a real phone.

## Running it on the phone

**Plug the phone in first.** `xcrun xctrace list devices` shows it as *offline*, and a device
build fails until it is connected:

> Your team has no devices from which to generate a provisioning profile.

Xcode registers the device the first time it sees it. Then pick it as the run destination and
hit Run. Trust the Mac on the device if prompted.

Permissions are granted from the **This device** section — tap a row, or use
**Allow microphone and location**. Nothing is requested on launch. A row already denied opens
Settings instead.

Location is a two-step prompt: iOS offers "While Using" first and only offers "Always"
afterwards, so expect to be asked twice — take Always, or the track stops when the screen
locks. Deny motion and elevation silently disappears.

## Getting a round off the phone

Finder > your iPhone > Files > Marker → drag the `Sessions` folder out. Then:

```sh
swift run golfctl inspect ~/Downloads/Sessions/session-2026-08-24-1430
```

That round-trip is the Phase 1 gate.

## What to expect on the first real round

Nothing reconstructs yet — Phase 1 records, and that is all. What you get is a session
folder with audio, a GPS track, motion, barometric elevation, and whatever you tapped MARK
for. That is the input Phase 2 (transcription) and Phase 3 (reconstruction) consume, and
collecting it is the schedule driver: start recording rounds now, because the reconstruction
work needs real audio of a real foursome to tune against.

Unmeasured, and worth watching on the first round: battery over 4.5 hours (GPS runs
continuously — duty cycling is deliberately not implemented yet), whether the recording
survives the screen locking in a pocket, and how much of the other three players you can
actually hear.
