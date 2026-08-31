# Marker — complete build specification

**This file is the whole hand-off.** It is written to be given to one person (or one
Claude Code session) with no access to the original repository, and to be sufficient to
build the same application.

It is a *specification*, not an archive. The original is ~26,000 lines of Swift across
14 package targets plus an iOS app; that does not fit here and mostly does not need to.
What is here is everything that is expensive to re-derive: the on-disk formats, the type
model, the measured constants, the algorithms whose plausible-looking versions are
silently wrong, and the reasons behind each. Where a description would let you write a
version that *looks* right and *is* wrong, the real code is inlined verbatim and marked
**VERBATIM — implement exactly**.

> Everything stated as measured was measured, on the dates given. Where something is
> unverified this file says so. Treat an unmarked claim as tested and a marked one as a
> risk you are inheriting.

**What you are not getting, and how to bootstrap it.** This file is the only artefact. There is no
repository, so four things have to be created rather than copied, and none of them blocks the
build:

- **Course files.** Run `golfctl course osm` (§13) once the CLI builds. Nothing ships with a course
  except the built-in `SampleCourse`, which is synthesised in code for previews and tests.
- **Terrain.** `golfctl course elevation` (§7.4), US courses only.
- **Prompt and schema files** (§13.1) — four files you author.
- **Whisper models.** Downloaded at runtime from Hugging Face; never checked in anywhere.

Recorded rounds are never shared, by policy (§17).

---

## 0. How to use this document

Build in this order. Each stage compiles and is testable on macOS alone; the iOS app
comes last and is the only part that needs a device.

| Stage | Targets | Gate |
|---|---|---|
| 1 | `GolfSessionFormat` | Round-trip a session folder: write every stream, read it back, timestamps comparable. |
| 2 | `GolfCourse` | Load a course file, project a hole, sample a DEM, `project`/`unproject` round-trip under pan and zoom. |
| 3 | `GolfCourseOSM`, `GolfTerrain` | `golfctl course osm` writes a course file; `golfctl course elevation` writes a `.dem` beside it. |
| 3b | `GolfExchange` | `golfctl round export` then `round import` puts a round back byte-for-byte, course and terrain included. |
| 4 | `GolfCaptureCore` | `golfctl record` on a Mac produces a session folder that `golfctl inspect` reads. |
| 5 | `GolfTranscription` | `golfctl transcribe` produces a transcript; `golfctl live --realtime` shows hypotheses. |
| 6 | `GolfMap` | Hole view renders offline from a course file. |
| 7 | iOS app | Everything above, on a phone. |

`AnthropicClient`, `GolfReconstruction`, `GolfStore`, `GolfInsight` and `GolfEval` are
small or placeholder and can be built at any point (§12).

**Two rules that hold throughout.** They are repeated in context below because each has
already been broken at least once:

- **One clock.** Every timestamp in every stream is `Millis` — `Int64` milliseconds since
  the Unix epoch. No stream has a private epoch, and no offset is ever accumulated across
  a boundary.
- **One unit.** Every stored distance is metres. Yards exist only where a number becomes
  text.

---

## 1. What the product is

Golf round tracking and replay from **spoken logs + GPS**, for the whole group — not just
the phone's owner. A party narrates its own round ("you're away", "I'm hitting seven",
"what'd you make?"). The app listens, records position, and is intended to reconstruct the
round shot by shot.

> In golf, your *marker* is the person who keeps your score.

Design commitments that shape everything else:

- **Capture everything; the user corrects the rest.** Reconstruction output is a draft the
  user amends, never a final answer. Propose a low-confidence shot rather than omit it — a
  wrong shot costs one tap to delete, a missing one is invisible.
- **The round is bilingual** (English and Korean, automatically, in the same sentence
  sometimes). This is a hard requirement and it eliminates several otherwise-obvious
  engine choices.
- **Courses are mainly American.** That decides the OSM strategy and the default distance
  unit. Korean courses are a supported secondary case.
- **It must work with no signal.** A golf course has poor cell service. Anything a golfer
  acts on is rendered from local files.
- **Private use** — the author and their friends. No distribution, which is why ODbL
  share-alike has nothing to discharge here (§7.6).

---

## 2. Prerequisites and repository layout

Verified 2026-08-30 on: macOS 26, **Xcode 26.6** (17F113), **Swift 6.3.3**, iOS SDK 26.5.

```
naelgol-marker/
├── Package.swift
├── Sources/
│   ├── GolfSessionFormat/     AudioSpan AudioTimeline Event ExtractionCoverage
│   │                          Journal JSONL LogEntry LogTranscript Mark RoundExport
│   │                          Session SessionFolder SessionIndex SessionTrash TrackingState
│   ├── GolfCaptureCore/       AudioRecorder LocationRecorder RoundSession
│   ├── GolfCaptureMotion/     MotionRecorder                    (iOS only inside)
│   ├── GolfCourse/            CardLayout CardText Coordinate Course CourseCard
│   │                          CourseStore Elevation Handicap HolePlane OSMCourse SampleCourse
│   ├── GolfCourseOSM/         Overpass Nominatim
│   ├── GolfTerrain/           Elevation3DEP GeoTIFF
│   ├── GolfExchange/          RoundBundle BundleText RoundArchive
│   ├── GolfMap/               17 files — hole view, editor, readout, styling
│   ├── GolfTranscription/     Transcriber WhisperEngine WhisperVAD WhisperTranscriber
│   │                          WhisperLiveTranscriber AppleTranscriber LiveTranscriber
│   │                          SessionTranscriber AudioExcerpt GolfVocabulary
│   ├── AnthropicClient/       raw /v1/messages
│   ├── GolfReconstruction/    LogExtraction CardReading
│   ├── GolfStore/ GolfInsight/ GolfEval/     placeholders
│   └── golfctl/               main CourseImport CourseOSMCommand CourseElevation
│                              RoundArchiveCommand
├── Tests/MarkerTests/         ~500 tests
├── Resources/                 prompt.md  round.schema.json
├── Prompts/                   course-card.md  course-card.schema.json
├── Courses/                   <id>.json  +  <id>.dem
└── Apps/Naelgol Marker/       the iOS app
```

Approximate sizes, as a sanity check on your own build: SessionFormat 2.6k lines, Course
3.3k, Map 5.5k, Transcription 2.4k, CaptureCore 1.1k, Exchange 1.0k, golfctl 1.7k, app
8.8k, tests 7.5k.

### 2.1 `Package.swift` — VERBATIM

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Marker",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GolfSessionFormat", targets: ["GolfSessionFormat"]),
        .library(name: "GolfCaptureCore", targets: ["GolfCaptureCore"]),
        .library(name: "GolfCaptureMotion", targets: ["GolfCaptureMotion"]),
        .library(name: "GolfTranscription", targets: ["GolfTranscription"]),
        .library(name: "AnthropicClient", targets: ["AnthropicClient"]),
        .library(name: "GolfReconstruction", targets: ["GolfReconstruction"]),
        .library(name: "GolfStore", targets: ["GolfStore"]),
        .library(name: "GolfInsight", targets: ["GolfInsight"]),
        .library(name: "GolfCourse", targets: ["GolfCourse"]),
        .library(name: "GolfCourseOSM", targets: ["GolfCourseOSM"]),
        .library(name: "GolfTerrain", targets: ["GolfTerrain"]),
        .library(name: "GolfExchange", targets: ["GolfExchange"]),
        .library(name: "GolfMap", targets: ["GolfMap"]),
        .library(name: "GolfEval", targets: ["GolfEval"]),
        .executable(name: "golfctl", targets: ["golfctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
    ],
    targets: [
        .target(name: "GolfSessionFormat"),
        .target(name: "GolfCaptureCore", dependencies: ["GolfSessionFormat"]),
        .target(name: "GolfCaptureMotion", dependencies: ["GolfSessionFormat", "GolfCaptureCore"]),
        .target(name: "GolfTranscription",
                dependencies: ["GolfSessionFormat",
                               .product(name: "WhisperKit", package: "WhisperKit")]),
        .target(name: "AnthropicClient"),
        .target(name: "GolfReconstruction",
                dependencies: ["GolfSessionFormat", "AnthropicClient"]),
        .target(name: "GolfStore", dependencies: ["GolfSessionFormat"]),
        .target(name: "GolfInsight", dependencies: ["GolfSessionFormat", "GolfStore"]),
        .target(name: "GolfCourse", dependencies: ["GolfSessionFormat"]),
        .target(name: "GolfCourseOSM", dependencies: ["GolfCourse"]),
        .target(name: "GolfTerrain", dependencies: ["GolfCourse"]),
        .target(name: "GolfExchange", dependencies: ["GolfSessionFormat", "GolfCourse"]),
        .target(name: "GolfMap", dependencies: ["GolfSessionFormat", "GolfStore", "GolfCourse"]),
        .target(name: "GolfEval", dependencies: ["GolfSessionFormat", "GolfReconstruction"]),
        .executableTarget(name: "golfctl",
                          dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                         "GolfCourse", "GolfCourseOSM", "GolfTerrain",
                                         "GolfExchange", "GolfTranscription",
                                         "AnthropicClient", "GolfReconstruction",
                                         "GolfEval"]),
        .testTarget(name: "MarkerTests",
                    dependencies: ["GolfSessionFormat", "GolfCaptureCore",
                                   "GolfCourse", "GolfCourseOSM", "GolfTerrain", "GolfMap",
                                   "GolfExchange", "GolfReconstruction", "GolfTranscription",
                                   .product(name: "WhisperKit", package: "WhisperKit")]),
    ]
)
```

The only external dependency is **WhisperKit 1.1.0**
(`1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`), which pulls **swift-argument-parser 1.8.2**
(`6a52f3251125d74daf04fcbd5e6f08a75d074382`) transitively. `golfctl` parses arguments by
hand and does *not* use argument-parser.

### 2.2 The four rules encoded in that manifest

1. **One platform floor, and it is the lowest any target needs.** SPM declares platforms
   per *package*, not per target. iOS 16 / macOS 13 lets a host app on an older OS import
   the low-floor libraries. Higher-floor APIs are gated with `@available` in source. Never
   raise the floor to match the app.
2. **`GolfCaptureCore` stays cross-platform** so the recorder runs on a Mac. iOS-only
   motion and barometer APIs live in `GolfCaptureMotion` — that split is the entire reason
   that target exists.
3. **`GolfCourse` is network-free**, and the two sockets that feed it are separate targets
   (`GolfCourseOSM`, `GolfTerrain`). This is what keeps the assembly logic — which is where
   the subtle bugs are — testable with no network and with synthetic fixtures.
4. **`GolfReconstruction` declares no `resources:`.** Declaring them generates
   `Bundle.module`, and prompt/schema must resolve from `--prompt` / `--schema` *paths* so
   that tuning a prompt is edit-and-rerun rather than rebuild-per-edit.

Note that **WhisperKit is reachable only through `GolfTranscription`**. A consumer wanting
the hole view or the course model does not take it, or its half-gigabyte of runtime model
downloads. Preserve that.

---

## 3. `GolfSessionFormat` — the contract

Zero dependencies. Every other target speaks this. Build it first and get it exactly
right; a mistake here is a mistake in files that already exist on disk.

### 3.1 The session folder

```
session-2026-09-14-1430/
  meta.json                SessionMeta
  audio.jsonl              AudioSegment   — which .m4a covers which millis
  audio-000.m4a            one file per uninterrupted stretch
  audio-001.m4a
  gps.jsonl                GPSFix
  motion.jsonl             MotionSample
  altitude.jsonl           AltitudeSample
  journal.jsonl            JournalEntry   — GROUND TRUTH; the card is derived from it
  marks.jsonl              Mark           — GROUND TRUTH, never enters a prompt
  corrections.jsonl        Correction     — GROUND TRUTH, never enters a prompt
  scorecard.json           Scorecard      — DERIVED from journal.jsonl
  transcript.jsonl         Utterance      — golfctl transcribe output (cached)
  transcript.coverage.json TranscriptCoverage
  log.jsonl                LogEntry       — what the golfer said. MODEL-VISIBLE.
  events.jsonl             Event          — MIXED provenance; filter per row
  extraction.coverage.json ExtractionCoverage
  bundle.json              golfctl bundle output
  round.json               golfctl reconstruct output
```

Folder name: `session-yyyy-MM-dd-HHmm` in **local** time (a golfer looks for "the Sunday
morning round" by name), formatter locale `en_US_POSIX`.

**The rounds list reads session folders; there is no database.** `SessionIndex` scans a
root directory, parses each `meta.json`, and classifies. A store in front of that would be
a schema, a migration policy and a translation layer over data that is already durable.

### 3.2 The firewall

This is the single most important rule in the codebase and it is currently **convention,
not structure** — `GolfReconstruction` depends on `GolfSessionFormat`, so the compiler will
not stop you.

```swift
public enum File: String, CaseIterable, Sendable {
    case meta = "meta.json", audio = "audio.jsonl", gps = "gps.jsonl"
    case motion = "motion.jsonl", altitude = "altitude.jsonl"
    case marks = "marks.jsonl", corrections = "corrections.jsonl"
    case scorecard = "scorecard.json", transcript = "transcript.jsonl"
    case transcriptCoverage = "transcript.coverage.json"
    case log = "log.jsonl", journal = "journal.jsonl"
    case extractionCoverage = "extraction.coverage.json"
    case events = "events.jsonl", bundle = "bundle.json", round = "round.json"

    /// Must never enter an evidence bundle or a prompt.
    public static let groundTruth: Set<File> = [.marks, .corrections, .scorecard, .journal]
    public var isGroundTruth: Bool { File.groundTruth.contains(self) }

    /// Holds model output AND ground truth on alternating lines, so the whole-file
    /// check above cannot decide it. Filter row by row — `Event.modelVisible(_:)`.
    public static let mixedProvenance: Set<File> = [.events]
    public var isMixedProvenance: Bool { File.mixedProvenance.contains(self) }
}
```

`mixedProvenance` is listed rather than left to a comment because "is this file safe to
send?" is otherwise answered by `isGroundTruth == false`, which is **wrong for
`events.jsonl` and wrong in the direction that leaks**.

`log.jsonl` is deliberately in *neither* set: a log is an observation, so **every** row is
model-visible. "A human typed it" does not make it the answer key — reading it that way
would put the entire product input behind the firewall and leave extraction with nothing.

The one thing that legitimately crosses: **course geometry**. You cannot place a shot on a
hole without knowing where the hole is. A MARK-button survey must be *exported* to
`Courses/<id>.json` first; `GolfReconstruction` reads that file and never a session's
`marks.jsonl`.

### 3.3 Core types

```swift
public typealias Millis = Int64          // milliseconds since the Unix epoch

public struct Player: Codable, Sendable, Hashable, Identifiable {
    public var id: String                // stable key; defaults to `name`
    public var name: String              // display name, and the one on a scorecard
}
```

**A player is `Player`, not `String`, and a player is one name.** The type exists for the
**id**: `Mark.player`, `Correction.player` and `LogEntry.player` all store `Player.id`, so a
rename does not orphan anything, and attribution matches on the **name**, *never* on a roster
position — removing somebody slides every later slot down one, so an index would go on
answering under another person's name. A roster is `--players 'steve,dave'`.

Do not add a nicknames or aliases field. It is a natural thing to reach for — a player really
is "steve" on the card and something else out loud — and it was **deliberately refused**: one
name per player, everywhere. The consequence has to be accepted rather than worked around: a
card row or a spoken name in the other script than the roster matches nobody, and
`CardReading` **reports that as an unmatched row rather than guessing** (§11.4). Since
diarization is also cut (§9.1), one name is the whole attribution signal, which is why every
matcher downstream is phonetic and fuzzy rather than exact.

```swift
public struct SessionMeta: Codable, Sendable, Equatable {
    public var sessionID: String
    public var course: String?
    public var players: [Player]
    public var start: Millis
    public var end: Millis?              // nil == unfinished (the app was killed)
    public var device: String
    public var audioFormat: String       // "m4a-aac-16k-mono-32kbps"
    public var audioRoute: String?       // "MicrophoneBuiltIn" — see §9.2
}

public struct GPSFix: Codable, Sendable {
    public var t: Millis
    public var lat: Double, lon: Double
    public var alt: Double?              // GNSS altitude: ±10–20 m. Do not use for elevation.
    public var hAcc: Double, vAcc: Double?
    public var speed: Double?, course: Double?
}

public struct MotionSample: Codable, Sendable {
    public var t: Millis
    public var activity: String          // stationary | walking | automotive | unknown
    public var confidence: Int
    public var steps: Int?
    public var distance: Double?         // CMPedometer cumulative metres
}

public struct AltitudeSample: Codable, Sendable {
    public var t: Millis
    public var relative: Double          // metres since session start — accurate to ~0.3–1 m
    public var pressureKPa: Double?
    public var absolute: Double?         // CMAbsoluteAltitudeData when available
    public var absoluteAccuracy: Double?
}

public struct Utterance: Codable, Sendable {
    public var t0: Millis, t1: Millis
    public var speaker: String?          // acoustic cluster id, NOT a name. Always nil — see §9.5
    public var text: String
    public var conf: Double?
    public var locale: String?           // "en_US" / "ko_KR" — which recognizer produced it
}

public struct AudioSegment: Codable, Sendable, Equatable {
    public var index: Int
    public var file: String              // "audio-000.m4a"
    public var t0: Millis
    public var t1: Millis?               // nil == never closed (crash, or recording now)
    public var endReason: String?        // "interruption" | "route-change" | "stop" | "error"
}
```

### 3.4 `JSONLWriter` — `O_APPEND` plus `flock`, and both are needed

**VERBATIM — implement exactly.** This looks like plumbing and is not.

```swift
public init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { throw JSONLError.cannotOpen(url, errno) }
    // closeOnDealloc: false — close() and deinit already own the lifetime, and
    // letting FileHandle close it too is a double close on a descriptor number the
    // process may by then have reused for something else.
    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
}

public func append<T: Encodable>(_ value: T) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    lock.lock()                       // orders writers inside this process
    defer { lock.unlock() }
    guard !closed else { throw JSONLError.writerClosed }
    let fd = handle.fileDescriptor
    flock(fd, LOCK_EX)                // orders writers ACROSS processes
    defer { flock(fd, LOCK_UN) }
    try handle.write(contentsOf: data)
}
```

Why each half: `seekToEnd()` resolves the offset **once**, so a second writer overwrites
the first from a stale position and rows vanish silently — `O_APPEND` re-resolves inside
every `write(2)`. But `O_APPEND` guarantees only that the *offset* is taken atomically, not
that one `write` lands as a contiguous run; `flock` stops a line being torn by an
interleave, which is the one failure a reader cannot recover from (it skips a bad *line*,
and an interleave corrupts two).

JSONL rather than one JSON array because a round can end in battery death: an append-only
file is still readable, worst case one torn final line. `JSONLReader` **skips undecodable
lines rather than throwing** — a round that ended badly still has to open.

Whole-file JSON (`meta.json`, `scorecard.json`) is written temp-file-then-`replaceItemAt`,
with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`. There is **no `flock` on
that path**, so `meta.json` is never rewritten from a replay — two processes replaying at
once would clobber it. `scorecard.json` survives that because it is a cache the journal
rebuilds; the roster is not, so the on-screen roster comes from `JournalReplay`'s output and
`meta.json` stays as the round was started.

### 3.5 Never compare two session-folder URLs with `==`

```swift
public static func isSame(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.resolvingSymlinksInPath().path
        == b.standardizedFileURL.resolvingSymlinksInPath().path
}
```

`URL.appendingPathComponent(_:)` consults the filesystem and appends a trailing slash when
the component names an **existing** directory. A round's URL is built before `create()` and
the same path is built again afterwards; the two compare unequal. **Measured on device
2026-08-27:** the round screen's refresh guard dropped every notification during a burst, so
twenty-nine logs were on disk and the screen said "Nothing on this hole".

### 3.6 Audio segments and the clock

Audio is segmented: `audio-%03d.m4a` plus an `audio.jsonl` index. A 4.5-hour recording
**will** be interrupted — a call, Siri, another app taking the mic. Each interruption closes
a segment and the resume opens the next. **Do not collapse this to one file.**

```swift
/// The highest segment index this folder already holds — files AND index rows,
/// maximum of the two.
public func lastAudioIndex() -> Int? { ... }
```

A crash mid-segment leaves an `.m4a` with no row in `audio.jsonl`. That is a deliberate
property of the format — recoverable, and better than a row that lies. Resuming from the
rows alone hands the next burst a filename that already exists and **overwrites a real
recording**. A fresh round starts its counter at `-1` so it opens `audio-000.m4a`; a
reopened round adopts what is on disk.

**`AudioTimeline` maps a decoder's file-relative time back onto the session clock, per
segment, never cumulatively.** VERBATIM:

```swift
public enum AudioTimeline {
    public static func sessionTime(_ offset: TimeInterval, in segment: AudioSegment) -> Millis {
        segment.t0 + Millis((offset * 1000).rounded())
    }

    public static func window(from start: TimeInterval, to end: TimeInterval,
                              in segment: AudioSegment) -> (t0: Millis, t1: Millis) {
        var t0 = sessionTime(start, in: segment)
        var t1 = sessionTime(max(start, end), in: segment)
        if let hardEnd = segment.t1 {          // clamp ONLY when the end is known
            t0 = min(t0, hardEnd)
            t1 = min(t1, hardEnd)
        }
        t0 = max(t0, segment.t0)
        t1 = max(t1, t0)
        return (t0, t1)
    }

    public static func duration(of segment: AudioSegment) -> TimeInterval? {
        segment.t1.map { Double($0 - segment.t0) / 1000 }
    }
}
```

**There is deliberately no API that takes a list of segments.** "Segment 1 is 600 s long so
segment 2 starts at 600 s" is the obvious thing and it is wrong: a segment boundary is a
*real gap in time*, and an accumulated offset silently compresses the round so that every
timestamp after the first interruption drifts by the total of all previous interruptions —
which nothing downstream can detect, because the numbers stay plausible. Verified on a
two-segment fixture with a five-minute gap: the second segment's content lands at 305.32 s,
not 5.32 s.

A window is clamped to its segment's end **only when that end is known**: a decoder reports
ranges a few ms past the last sample, and an utterance ending after the recording did is a
claim nothing supports — but a segment with `t1 == nil` never closed, so there is nothing to
clamp against and substituting "now" would invent recording that never happened.

### 3.7 `TranscriptCoverage` and `ExtractionCoverage`

Both exist for the same reason and it is not obvious:

```swift
public struct TranscriptCoverage: Codable, Sendable, Equatable {
    public var transcriber: String       // "apple" | "whisperkit:openai_whisper-small"
    public var locales: [String]         // what actually RAN, canonical + sorted
    public var segments: [Int]           // indices fully transcribed, INCLUDING silent ones
}
```

**A silent segment produces no utterances**, so "does any utterance fall in this segment's
window?" is not a done-test — a quiet stretch would look untranscribed and be re-run
forever. Coverage is recorded explicitly.

`locales` is **what ran, never what was asked for**. A bilingual round asks for `en_US` and
`ko_KR`; a device with no Korean model resolves only English. Recording the *request* marks
the segment done and the Korean half is never transcribed, on any later pass, with nothing
showing it was missing.

`ExtractionCoverage` is the same trap one level up: a log that yields **no proposal at all**
("we're on the ninth", "players are A, B, C, D") is cited by nothing, so a
has-an-event-cited-this check reports it unread on every pass, and every pass that
hallucinates appends another event — an infinite loop. It is keyed on the **row id, never
the chain root**, because an edited log is a new id and *must* be re-read.

### 3.8 `LogEntry` — the app's primary input

```swift
public struct LogEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Source: String, Codable, Sendable { case spoken, typed }
    public enum HoleSource: String, Codable, Sendable {
        case fix         // Course.nearestHole's proposal from a measured position
        case user        // a person's answer. NEVER recomputed.
    }

    public var id: String                // 8 hex chars
    public var t: Millis                 // when it was SAID, not when it finalised
    public var text: String
    public var tEnd: Millis?             // session-clock end — what makes audio resolvable
    public var lat: Double?, lon: Double?
    public var hAcc: Double?
    public var hole: Int?                // 1-based PLAYING index, never Hole.ref
    public var holeSource: HoleSource?   // nil decodes as .fix
    public var player: String?           // Player.id
    public var shot: Int?                // 1-based; 1 is the tee shot
    public var source: Source
    public var locale: String?
    public var supersedes: String?       // id of the row this replaces
    public var deleted: Bool?            // tombstone

    public var isShot: Bool { player != nil && shot != nil }
    public var hasPosition: Bool { lat != nil && lon != nil }
    public func isPlaced(within accuracy: Double) -> Bool   // position + accuracy ONLY
}
```

**A log is amended by appending.** `supersedes` plus a `deleted` tombstone carries all four
mutations — the late coordinate, an edited sentence, a moved hole, a deletion. It lives in
`log.jsonl` rather than the journal because a log is **model-visible** and the journal is
ground truth: an edit recorded in the journal would be invisible to extraction, so a user
would fix a misheard name and the model would go on reading the old one. Delete is a
tombstone rather than an absence because a proposal cites logs by id and would otherwise
render a claim resting on nothing. `LogEntry.current(_:)` collapses chains for display;
`byID` keeps every version.

Traps, each of which was a real bug:

- **`isPlaced` looks at position and accuracy only — never the hole.** `Course.nearestHole`
  declines beyond 250 m, so a perfectly good fix taken anywhere but on a mapped hole
  resolves to a nil hole. Treating that as "still unplaced" makes the placement pass
  converge, append a superseding row, see the nil hole again, and converge again — forever,
  refiring the extraction pass each lap.
- **A coordinate with no accuracy is not placed.** `hAcc ?? .infinity` — so handing a
  coordinate without an accuracy leaves the log unplaced however good the fix was, and it
  then joins the backlog asking the radio for fifteen seconds for a position it already had.
- **A `.user` hole is never recomputed.** The refusal lives in the `placed(...)` method, not
  in the calling code, so it holds for every caller. The *position* still updates — that is a
  measurement and a better fix is better. Only the claim about which hole is left alone.
  Without this, a hole set by hand was replaced ~15 s later by `nearestHole`'s coin toss
  between two fairways forty metres apart.
- **Never extend a log from a cached copy — re-read the chain head from disk.** Two writers
  grow the same chain (live transcription extends a burst's entry; placement appends a
  placed row). Editing a stale copy forks it, and `current` keeps one head, so the
  coordinate that convergence just spent fifteen seconds of radio acquiring is silently
  dropped.
- **A live-derived log is stamped with the *utterance's* start**, not `now` — a sentence
  finalises after it was said — and carries **no hole of its own choosing**.

### 3.9 `Event` — mixed provenance

```swift
public struct Event: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case shot, score, penalty, holeChange, note, pin
    }
    public enum Provenance: String, Codable, Sendable {
        case model       // a proposal; MAY be fed back to the model as context
        case user        // what a person typed or corrected — GROUND TRUTH
    }
    public var id: String
    public var t: Millis
    public var kind: Kind
    public var provenance: Provenance
    public var player: String?, hole: Int?, club: String?
    public var strokes: Int?, lie: String?
    public var lat: Double?, lon: Double?
    public var text: String?
    public var confidence: Double?
    public var evidence: [Millis]        // transcript times this rests on
    public var logs: [String]?           // log ids this rests on
    public var supersedes: String?

    public var isGroundTruth: Bool { provenance == .user }
    public static func modelVisible(_ events: [Event]) -> [Event]   // filters to .model
}
```

**`provenance` is a firewall, not a label.** Incremental extraction naturally feeds prior
events back as context, and one unfiltered pass puts the answer key in the prompt. **Every
bundle builder reading `events.jsonl` goes through `modelVisible(_:)`.** `Event.init` also
drops `confidence` on a `.user` event: a person who typed a score is not expressing a
probability, and storing one invites code that averages the two.

`Kind.pin` carries a dragged flag position — a fact about *this round*, since a pin is cut
fresh every morning. Writing it to the course file would make every later round inherit one
afternoon's flag.

### 3.10 The journal — the record; the card is a view of it

```swift
public struct JournalEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Act: String, Codable, Sendable, CaseIterable {
        case setScore, setStat, setIndex, setTee
        case addPlayer, editPlayer, removePlayer
        case setCourse, acceptEvent, rejectEvent, undo
    }
    public enum Stat: String, Codable, Sendable, CaseIterable {
        case putts, gir, fairway, ob, hazard, penalty
        public var isCount: Bool { self == .putts || self == .ob || self == .penalty }
    }
    public var id: String
    public var t: Millis
    public var act: Act
    public var player: String?, hole: Int?, strokes: Int?
    public var stat: Stat?, statValue: Int?
    public var index: Double?, tee: String?
    public var rating: Double?, slope: Int?, par: Int?
    public var name: String?, course: String?
    public var eventID: String?
    // Previous values, so an undo can restore rather than guess:
    public var prevStrokes: Int?, prevStatValue: Int?, prevIndex: Double?, prevTee: String?
    public var undoes: String?           // id of the row this undoes
}
```

`journal.jsonl` holds **every act a person performed**; `scorecard.json` and the roster are
**derived** by `JournalReplay.replay`. Before this, `setScore` rewrote the whole dictionary
and the previous value was simply gone — nothing to undo, nothing to retrace.

Five consequences that are easy to undo by accident:

1. **`JournalEntry` is flat with optionals, not an enum with associated values.** These
   files are the user's own scores; a new act or field must not stop an old row decoding.
2. **Undo is a row** (`act: .undo`, `undoes: id`), and an undo can itself be undone — that
   is redo. `JournalReplay.live` resolves it by walking **newest to oldest**, so every undo
   that could cancel a row is decided before that row is reached. A forward pass gets
   three-deep chains wrong; a fixpoint loop over the whole set is not guaranteed to converge.
3. **`live` and `inForce` answer different questions.** `live` drops every `.undo` row,
   because replay must never apply one as an act. `inForce` keeps the ones still standing,
   because a history screen asks "is this row in force?". Using `live` for the screen struck
   through every undo and labelled it UNDONE — the opposite of what happened.
4. **Replay is seeded from `scorecard.json` and `meta.json`.** A round played before the
   journal existed has no journal, and that snapshot is the only record there is.
5. **One act is one row.** Accepting a `.score` proposal writes **only** `.acceptEvent`; the
   score it claims is applied inside `JournalReplay` at that row. Writing a `.setScore`
   alongside it means one Undo reverses half the act.

**Handicap is three numbers and only the ends are stored.** *Index* is the player's,
journaled. *Rating and slope* are journaled too and **frozen at round start** — re-importing
a course must never rewrite a card already played. *Course handicap* is computed and never
stored, and returns **nil** when rating or slope is missing rather than inventing a number
several shots wrong. None of this is `Hole.handicap`, which is the stroke-index row — same
word, unrelated quantity. They meet only in `strokesReceived`, which allocates by **1-based
playing order**, never by `Hole.ref` (a Korean 27 has three holes called "3").

### 3.11 `SessionIndex` — unfinished rounds and crash recovery

```swift
public enum SessionSummary.State { case recording, unfinished, finished }
```

"Active rounds" is plural because of **crash recovery, not concurrency**. One microphone and
one `AVAudioSession` mean exactly one round can be *recording*, and only the running process
knows which — hence `summaries(in:recordingID:)`. What piles up is `unfinished`:
`meta.end == nil`, i.e. the app was killed mid-round.

**`closeOut` stamps the last evidence in the folder, never `now`.** The app died at some
point and the clock ran on; stamping the present invents hours of round and that number
lands in every duration and every rate derived from it. For the same reason
`SessionSummary.duration` is **nil** for an unfinished round — "now minus start" on a round
killed three days ago reads as a three-day round.

### 3.11a `SessionTrash` — deleting a round is a move, not a removal

**Deleting a round is the one destructive act in this app**, and it is destructive in a way
nothing else here is: a round holds a GPS track, a card, the sentences four people said out
loud, and on a `golfctl`-recorded round the recordings themselves. Everywhere else the
codebase refuses to destroy — a log is tombstoned, an event superseded, a player removed from
the roster keeps their scores. A hard `removeItem` would be the only place that rule does not
hold, and a stray swipe on a list is exactly how it would get exercised.

So a delete **moves the folder to `Sessions/.trash/`** and the round is still there until the
user says otherwise or the retention window runs out.

```swift
public enum SessionTrash {
    public static let directoryName = ".trash"
    static let stampName = ".deleted"                    // Millis, written inside
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public struct Deleted: Sendable, Identifiable, Equatable {
        public var summary: SessionSummary
        public var deletedAt: Millis?      // nil when the stamp is missing
        public var url: URL
        public var expires: Date?
    }

    @discardableResult
    public static func discard(_ folder: SessionFolder, in root: URL, at: Millis) throws -> URL
    public static func contents(in root: URL) -> [Deleted]
    @discardableResult
    public static func restore(_ trashed: URL, to root: URL) throws -> URL
    public static func purge(_ trashed: URL) throws
    @discardableResult public static func empty(in root: URL) throws -> Int
    @discardableResult
    public static func purgeExpired(in root: URL, now: Millis) -> [String]
}
```

Six decisions:

- **A dot directory, so the trash disappears from the rounds list by construction.**
  `SessionIndex.summaries` scans with `.skipsHiddenFiles`, so nothing has to remember to
  filter it out. It is also hidden from Finder and the Files app, which `UIFileSharingEnabled`
  exposes — a golfer dragging their sessions off the phone gets what they still have, not
  what they threw away.
- **The deletion time is a sidecar, not the folder's modification date.** A move may or may
  not preserve mtime and anything touching the folder resets it; the retention window has to
  be anchored to an *act*. Dot-prefixed so the byte count never sees it, and **removed on
  restore**, so a round that comes back is exactly the round that left.
- **A missing stamp is said, never guessed.** `deletedAt` and `expires` are nil, and
  `purgeExpired` leaves that round alone. Substituting "now" would restart the window on every
  scan — keeping it forever while claiming a date. Same rule as an unfinished round's nil
  duration.
- **Neither move may overwrite.** A folder of that name can appear while the round is in the
  trash — an import, or a round started in the same minute — and quietly replacing it would
  destroy a live round *through the control that exists to undo a destruction*. Both ends go
  through `SessionFolder.freeName`, which is **one copy** shared with the round importer
  (§12.5.4): three private uniquifiers would be three chances for one to overwrite instead of
  suffix.
- **Nothing here knows which round is recording**, and it must not guess — the same reason
  `SessionIndex.summaries` takes `recordingID`. The caller does not offer the control on that
  row. Moving the folder out from under a live `RoundSession` leaves the recorder writing to a
  path that no longer exists: the segment never closes, the last audio is lost, and nothing
  reports it.
- **Purging runs when the rounds list appears, not on a timer.** This app has no background
  work, and a golfer who does not open it should not have rounds vanishing behind them.
  `purgeExpired` returns what went, so the caller can account for it.

### 3.12 `TrackingState` — mode and phase are different claims

```swift
public enum TrackingMode: String { case off, slow, fast }
public struct TrackingState {
    public enum Phase: String { case off, searching, stabilizing, locked }
    public var mode: TrackingMode, phase: Phase
    public var accuracy: Double?, fixCount: Int, lastFixAt: Millis?

    public static let lockAccuracy: Double = 15     // metres
    public static let lockRun = 3                   // consecutive fixes inside that
    public static let staleAfter: TimeInterval = 20 // a lock decays after this
}
```

Mode is what the radio is doing; phase is whether the number is worth clubbing off. A first
fix arrives fast and can be hundreds of metres out — showing a yardage off it looks like the
app working and is wrong by a hole. A lock breaks on one bad fix and **decays after 20 s**,
because under trees the last fix can be minutes old and was being presented as current.

It lives in `GolfSessionFormat` — the zero-dependency contract — so a map view can draw a
status dot without depending on the capture stack.

---

## 4. `GolfCourse` — geometry, terrain, projection

Network-free. Everything here is testable with synthetic fixtures, which is the point.

### 4.1 The three acquisitions

**A card and geometry are two separate acquisitions, and no free source gives both.** A
card (par / handicap / per-tee yardage) comes off a course's web page or a photograph;
coordinates come from a track, a survey, or OSM; terrain comes from a DEM. Therefore `Hole`
represents *either* half alone: `Green.center` and `TeeBox.at` are **optional**, and
`Hole.hasGeometry` is checked before anything geometric.

| | Gives | Never gives |
|---|---|---|
| OpenStreetMap | centre lines, greens, tees, fairways, hazards, cart paths, par | yardage (`dist` on 0.3% of US hole ways), stroke index (`handicap` on 38%) |
| A scorecard | par, stroke index, per-tee yardage, rating, slope | any coordinate |
| USGS 3DEP | terrain | everything else; anything outside the US |

### 4.2 `Coordinate` and `Geodesy`

```swift
public struct Coordinate: Codable, Sendable, Hashable {
    public var lat: Double, lon: Double
    public var alt: Double?
}
```

**VERBATIM — implement exactly.** Haversine for distances (honest at any separation);
an equirectangular local plane for offsets (a hole is 400 m, and the flat-plane error
there is far below a GPS fix's own).

```swift
public enum Geodesy {
    public static let earthRadius = 6_371_008.8      // IUGG mean

    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = (b.lat - a.lat) * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2)
            + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees, 0 = north, clockwise.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Metres east and north of `origin` — the local plane the hole is drawn on.
    public static func offset(of p: Coordinate, from origin: Coordinate)
        -> (east: Double, north: Double) {
        let mPerDegLat = .pi * earthRadius / 180
        let mPerDegLon = mPerDegLat * cos(origin.lat * .pi / 180)
        return (east: (p.lon - origin.lon) * mPerDegLon,
                north: (p.lat - origin.lat) * mPerDegLat)
    }

    /// Inverse of `offset`. NOTE the altitude default — see the warning below.
    public static func coordinate(from origin: Coordinate, east: Double, north: Double,
                                  alt: Double? = nil) -> Coordinate {
        let mPerDegLat = .pi * earthRadius / 180
        let mPerDegLon = mPerDegLat * cos(origin.lat * .pi / 180)
        return Coordinate(lat: origin.lat + north / mPerDegLat,
                          lon: origin.lon + east / mPerDegLon,
                          alt: alt ?? origin.alt)          // <-- defaults to the ORIGIN's
    }

    /// Which side of the tee→green line `p` is on, as a signed area.
    /// NEGATIVE means RIGHT of the line looking tee to green.
    public static func side(of p: Coordinate, tee: Coordinate, green: Coordinate) -> Double {
        let v = offset(of: green, from: tee)
        let w = offset(of: p, from: tee)
        return v.east * w.north - v.north * w.east
    }

    public static func playsLike(distance: Double, elevationDelta: Double,
                                 factor: Double = 1.0) -> Double {
        distance + elevationDelta * factor
    }
}
```

Two things to get right:

- **`coordinate(from:east:north:alt:)` defaults a nil altitude to the *origin's*.** That is
  useful for synthesising sample geometry and dangerous everywhere else: it stamps the tee's
  elevation onto a point up the fairway. `Geodesy.interpolate` and `HolePlane.unproject`
  therefore both build their result explicitly with `alt: nil` afterwards.
- **`side` is the one assertion that pins the renderer's handedness.** A mirrored projection
  still puts the green above the tee and still looks like a golf hole, so "green is up"
  proves nothing. The test is: a point with `side` negative must project to a **larger x**.

`Geodesy.centroid` is the **area-weighted (shoelace) centroid, not the mean of the
vertices**. OSM greens are traced by hand and their vertices bunch where the mapper slowed
down, so a vertex mean drifts several metres toward the fiddly edge — a club, on a green.
Fall back to the vertex mean only for a degenerate zero-area ring.

### 4.3 `playsLike` — the researched answer, and why the factor is 1

Every general-audience source states the same rule in the same words: **one yard per yard of
elevation.** Variants that put numbers on it land within 15% — a ballistics simulation gives
20 yd uphill costing 21 and 20 yd downhill gaining 18; a common rule of thumb gives +8 yd per
25 ft up against drop ÷ 3.5 down.

**The asymmetry is real** (≈1.0 up, ≈0.86–0.90 down) **and is smaller than a GPS fix's own
error over these distances**, so `factor` stays 1 and the asymmetry is the first thing to try
once there is a played round to fit against. No rangefinder maker publishes their adjustment,
so there is nothing to match and nothing to check against.

It lives in **one named function** precisely so it can be replaced by a measured model
later, rather than being inlined into a view and lost.

### 4.4 The course model

```swift
public enum DistanceUnit: String, Codable, Sendable, CaseIterable {
    case metres, yards
    public var toMetres: Double { self == .metres ? 1 : 0.9144 }
    public static let assumedWhenUnstated: DistanceUnit = .yards
    public static func plausibility(total: Double, par: Int) -> String?
}
public enum UnitSource: String, Sendable { case explicit, printed, assumed }

public struct TeeBox: Codable, Sendable, Hashable, Identifiable {
    public var name: String            // "Black", "White", "Members"…
    public var at: Coordinate?         // optional — a card-only tee has none
    public var distance: Double?       // ALWAYS METRES, normalised once at import
    public var rating: Double?         // USGA
    public var slope: Int?
    public var inferredName: Bool?     // this name came from a length rank, not a tag
    public var id: String { name }

    public static let standardRamp = ["black", "blue", "white", "green", "gold", "red"]
    public static func ramp(of n: Int) -> [String] {
        switch n {
        case ..<1: return []
        case 1: return ["black"]
        case 2: return ["black", "white"]
        case 3: return ["black", "white", "red"]
        case 4: return ["black", "blue", "white", "red"]
        case 5: return ["black", "blue", "white", "gold", "red"]
        default: return standardRamp
        }
    }
    /// Case-insensitive, and strips a trailing "Tee"/"Tees".
    public static func sameTee(_ a: String, _ b: String) -> Bool
}

public struct Green: Codable, Sendable, Hashable {
    public var center: Coordinate?     // area-weighted centroid of `polygon`
    public var front: Coordinate?, back: Coordinate?
    public var polygon: [Coordinate]
}

public struct Hazard: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case bunker, water, trees, outOfBounds }
    public var kind: Kind
    public var polygon: [Coordinate]
}

public struct Hole: Codable, Sendable, Hashable, Identifiable {
    public var ref: String             // what the card prints: "7", "3"
    public var nine: String?           // "황룡" — a named nine on a 27
    public var par: Int
    public var handicap: Int?          // men's stroke index (or the only row)
    public var handicapWomen: Int?     // the second row an American card prints
    public var tees: [TeeBox]
    public var green: Green
    public var line: [Coordinate]      // centre line, TEE END FIRST
    public var fairway: [Coordinate]
    public var hazards: [Hazard]
    public var paths: [[Coordinate]]   // cart paths — see the storage note below
    public var confidence: Double?
    public var source: Course.Source?

    public var id: String { nine.map { "\($0)/\(ref)" } ?? ref }
    public var hasGeometry: Bool { geometry() != nil }
}

public struct Course: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case track      // derived from our own recorded GPS
        case survey     // walked with the MARK button
        case osm        // OpenStreetMap. ODbL.
        case traced     // hand-placed on imagery — see §14
        case card       // par/handicap/yardage from a published scorecard
        case api, sample
    }
    public var id: String              // Course.slug(name)
    public var name: String
    public var aliases: [String]
    public var source: Source
    public var attribution: String?
    public var cardUnit: DistanceUnit?
    public var updated: Millis?
    public var holes: [Hole]

    public static func slug(_ name: String) -> String
    public func hole(_ key: String) -> Hole?          // "황룡/3"
    public func nearestHole(to p: Coordinate, within limit: Double = 250) -> Int?
    public func merging(card new: Course) -> Course
}
```

Rules encoded here, each of which produced a real fault:

- **`Hole.ref` is not a key — `Hole.id` is.** Korean 18s are two of three named nines, each
  numbered 1–9 (천룡: 황룡 / 청룡 / 흑룡). `nine` plus `ref` makes the composite id.
- **A new `Hole` field is stored optional and read non-optional.** A missing key for a
  non-optional array is a *decode failure*, so adding `paths` as `[[Coordinate]]` made every
  course file already on disk unreadable. The stored property is `storedPaths:
  [[Coordinate]]?` behind explicit `CodingKeys` (`case storedPaths = "paths"`), the public
  accessor is non-optional, and it is written back as nil when empty so a course with no cart
  paths encodes exactly as it did before the field existed. **This is the pattern for any
  future field.**
- **`nearestHole` returns the 1-based *playing-order index*** — what a scorecard column
  means — and declines beyond 250 m. It is a **proposal, not a fact**: adjacent fairways run
  tens of metres apart and a fix is ±3–5 m, so between two fairways it is a coin toss. Store
  the answer on the log (§3.8) rather than recomputing it.
- **`Course.slug` lives in the package**, because two importers build ids. Two copies is two
  id schemes that agree right up until the day importing a card over an OSM file writes a
  second course instead of merging. **Note:** two Korean names can slug to the same ASCII —
  `slug("천룡") == "course"`.
- **`merging(card:)` must never destroy placed coordinates.** It takes par and yardage from
  the new card, keeps every `at` and `green.center` already placed, keeps tees that exist
  only in the old file, and keeps holes the new card does not mention — importing one nine of
  a 27 must not delete the other two. Tee names are matched with `sameTee`
  (case-insensitive): OSM tags `black`, an American card prints `BLACK`, the editor writes
  `Black`, and an exact match silently drops every card tee's coordinate.
- **`inferredName` survives the merge, deliberately.** A card confirms the course *has* a
  white tee; it says nothing about which polygon that is.

### 4.5 `nil` means exactly one tee — the `defaultTee` trap

This produced the worst single measured error in the project's history.

`defaultTee` preferred a tee *named* white, while `geometry(tee:)` independently preferred
the first tee with *coordinates*. Two answers to "which tee does nil mean?". On a hole where
black, blue and white are all placed, `cardLength(from: nil)` meant white and
`geometry(tee: nil)` meant black — so **`length(from: nil)` returned black's 483 m under
white's name: 59 yards, four clubs, on hole 1 of the only real course file there was.**

The fix, and the rule:

- `defaultTee` filters to **placed** tees first, so a card-only hole keeps its white and a
  placed-black hole keeps its hole view.
- `geometry(tee:)` **defers to `defaultTee`** rather than deciding for itself.
- **No tee may answer with another tee's numbers.** `cardLength(from:)` and `geometry(tee:)`
  both return **nil** for a tee lacking the value asked for, rather than falling back to the
  longest or first-placed one. The fallback looked harmless and rendered another tee's
  distance under this tee's name, and framed the camera on a tee the screen was not labelled
  with.

It was found by probing the real file after a screenshot disagreed with the CLI — not by
reading either.

### 4.6 `HoleGeometry` — the resolved pair

```swift
public struct HoleGeometry: Sendable, Hashable {
    public let hole: Hole
    public let tee: TeeBox
    public let teeAt: Coordinate
    public let greenCenter: Coordinate
    public let teeInferred: Bool      // this end came from `line.first`, not a tee
    public let greenInferred: Bool

    public var bearing: Double { Geodesy.bearing(from: teeAt, to: greenCenter) }
    public var measuredLength: Double // walks the centre line — the DOGLEG distance
    public var length: Double { tee.distance ?? measuredLength }
    public var lengthDisagreement: Double?
    public var playLine: [Coordinate]
    public func point(along metres: Double) -> Coordinate
    public var suggestedTarget: Coordinate
    public var allPoints: [Coordinate]
}
```

**Renderers take `HoleGeometry`, never a raw `Hole`.** `HolePlane` is unguarded arithmetic,
so a nil-coalesced coordinate would draw the hole at the equator instead of failing. The
resolved type makes that unrepresentable.

- **`measuredLength` walks the dogleg; a shot leg is straight-line.** Different numbers on
  purpose — one real hole is 469 yd on the card and 426 to the green from the same tee.
  Nobody carries the corner of a dogleg.
- **`lengthDisagreement`** is what falsifies an assumed distance unit: a metric card read as
  yards is 9.4% short, far past the 25 m flag, as soon as a tee and green are placed.
- **A hole with a centre line is drawable with no tee and no green point.** `geometry(tee:)`
  falls back to `line.first` / `line.last`, and `hasGeometry` is simply `geometry() != nil`
  so the two cannot disagree. These are **real surveyed points**, not a nil coalesced to
  something plausible — the line runs tee end to green end and its orientation is decided from
  the data. **Only when nothing on the hole is placed:** once any tee has coordinates, an
  unplaced one still returns nil (§4.5). `teeInferred` / `greenInferred` say which end was
  inferred, and the UI prints `~ White Tee`.
- **`suggestedTarget`**: two thirds of the way in on a par 3 (one shot, so a fraction is the
  only useful reference); **250 yards measured along `playLine`** on a par 4 or 5 — along the
  line, so a dogleg lands it on the fairway rather than in the trees the corner cuts across —
  clamped to 85% so it never lands on the green.

### 4.7 `Elevation` — the terrain grid

**Terrain is the third acquisition and it behaves like geometry, not like imagery.** A DEM is
ours to store, does not change between rounds, and is public domain, so it goes in a file
beside the course and works with no signal.

```swift
public struct Elevation: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case usgs3DEP, copernicusGLO30, survey, sample
    }
    public enum Datum: String, Codable, Sendable {
        case navd88            // 3DEP: orthometric
        case egm2008
        case wgs84Ellipsoid    // CLLocation.ellipsoidalAltitude
    }

    public struct Sample: Sendable, Equatable {
        public var height: Double
        public var datum: Datum
        public var source: Source
        public var nativeResolution: Double

        /// Nil when the two datums disagree. This is the whole point of the type.
        public static func delta(from a: Sample, to b: Sample) -> Double? {
            guard a.datum == b.datum else { return nil }
            return b.height - a.height
        }
    }

    static let noData: Int16 = .min

    public var source: Source
    public var datum: Datum
    public var nativeResolution: Double
    /// Centre of sample [0][0] — the NORTH-WEST corner. The CENTRE, not the corner.
    public var lat0: Double, lon0: Double
    /// Post spacing in degrees. Both positive; ROWS RUN SOUTH.  Row r is at lat0 - r*dLat.
    public var dLat: Double, dLon: Double
    public var width: Int, height: Int
    /// Row-major DECIMETRES, north to south. base64 in JSON.
    var samples: [Int16]
}
```

#### The datum rule — why there is no public `Double` height

3DEP is **NAVD88 orthometric**; `CLLocation.altitude` is above mean sea level and
`ellipsoidalAltitude` is above the WGS84 ellipsoid, and those differ by roughly **−30 m in
California**. Over a *difference* the datum cancels — but **only if both ends share it**. One
end from the DEM and one from the phone is a plays-like number thirty metres wrong that reads
like an ordinary large number.

So `sample(at:)` returns a `Sample` carrying its `datum`, and `Sample.delta` **returns nil
when they disagree**. `Hole.elevationDelta(from:)` also **stopped reading the point's own
`alt`** — it used to prefer it, which was correct only for a coordinate that came out of the
course file and silently wrong for a fix. Relying on every future caller to remember is
exactly what the type removes.

#### Sampling — VERBATIM, implement exactly

```swift
public func sample(at c: Coordinate) -> Sample? {
    guard width > 0, height > 0, dLat > 0, dLon > 0 else { return nil }
    var fx = (c.lon - lon0) / dLon
    var fy = (lat0 - c.lat) / dLat
    // Clamped inside a millionth of a post, not tested exactly. A point derived
    // arithmetically from the grid's own corner lands a few ulps outside it —
    // measured, the last row of an 8x6 grid came out at 5.0000000001 — and a green
    // on the edge post would then have no height at all, for no visible reason.
    let epsilon = 1e-6
    guard fx >= -epsilon, fy >= -epsilon,
          fx <= Double(width - 1) + epsilon,
          fy <= Double(height - 1) + epsilon else { return nil }
    fx = min(max(fx, 0), Double(width - 1))
    fy = min(max(fy, 0), Double(height - 1))
    let x0 = min(Int(fx), width - 1), y0 = min(Int(fy), height - 1)
    let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
    let tx = fx - Double(x0), ty = fy - Double(y0)
    // A corner with NO WEIGHT is not consulted. Reading all four unconditionally
    // makes a point sitting exactly on a known post return nil whenever the post
    // diagonally next to it is a void — a hole beside water losing its number for
    // no reason the golfer could see. Zero weight cannot affect the answer, so
    // requiring it is a refusal with nothing behind it.
    var total = 0.0
    for (x, y, w) in [(x0, y0, (1 - tx) * (1 - ty)), (x1, y0, tx * (1 - ty)),
                      (x0, y1, (1 - tx) * ty), (x1, y1, tx * ty)] where w > 0 {
        guard let v = at(x, y) else { return nil }
        total += v * w
    }
    return Sample(height: total, datum: datum, source: source,
                  nativeResolution: nativeResolution)
}

/// Raw post in metres, nil for a void. Row 0 is the northernmost.
public func at(_ x: Int, _ y: Int) -> Double? {
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    let v = samples[y * width + x]
    guard v != Self.noData else { return nil }
    return Double(v) / 10
}
```

**Bilinear rather than nearest** because posts are metres apart and a nearest-post answer
steps by a whole post as the golfer walks — on a sloping fairway the plays-like number jumps
while they stand still. **A void with any weight makes the whole sample nil**: averaging a
known height with an unknown one produces a number nothing measured.

#### Storage — Int16 decimetres, base64, explicit little-endian

```swift
public init(source: Source, datum: Datum, nativeResolution: Double,
            lat0: Double, lon0: Double, dLat: Double, dLon: Double,
            width: Int, height: Int, metres: [Double?]) {
    // ... assignments ...
    self.samples = metres.map { m in
        guard let m, m.isFinite, m > -3276, m < 3276 else { return Self.noData }
        return Int16((m * 10).rounded())
    }
}

static func encode(_ v: [Int16]) -> Data {
    var out = Data(capacity: v.count * 2)
    for s in v {
        let u = UInt16(bitPattern: s)
        out.append(UInt8(u & 0xff)); out.append(UInt8(u >> 8))
    }
    return out
}

static func decode(_ d: Data) -> [Int16] {
    var out = [Int16](); out.reserveCapacity(d.count / 2)
    d.withUnsafeBytes { raw in
        for i in stride(from: 0, to: raw.count - 1, by: 2) {
            out.append(Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)))
        }
    }
    return out
}
```

Little-endian on both sides **explicitly**, so a file written on one architecture reads on
another. Decoding validates `data.count == width * height * 2`. Round-trip accuracy is 0.06 m
(decimetre storage). Base64 rather than a JSON array of a quarter-million numbers.

Derived reads:

```swift
public var bounds: (north: Double, west: Double, south: Double, east: Double) {
    (north: lat0, west: lon0,
     south: lat0 - Double(height - 1) * dLat,
     east: lon0 + Double(width - 1) * dLon)
}

/// Ground post spacing in metres, east–west and north–south. They DIFFER, because
/// the grid is stored in degrees — 2.2 m east against 2.8 m north at 37°N.
public var nativePosts: (east: Double, north: Double) {
    let mPerDegLat = .pi * Geodesy.earthRadius / 180
    let midLat = lat0 - Double(height - 1) * dLat / 2
    return (east: dLon * mPerDegLat * cos(midLat * .pi / 180),
            north: dLat * mPerDegLat)
}
```

Also `contains(_:)`, `delta(from:to:)` (both ends from this grid, so the datum cancels by
construction), `profile(from:to:count:)` (a void is a nil *in* the list, so a caller can draw
the break rather than joining across it), and `coverage(of:)`.

**The sidecar file is `Courses/<id>.dem`, and the extension is load-bearing.**
`CourseStore.loadAll()` decodes **every `.json`** in that directory as a `Course`, so a
sidecar named `<id>.elevation.json` would fail to parse on every scan. It is separate from
the course file because a grid is hundreds of kilobytes of base64 and a course file is read
and edited by hand. **Missing is the ordinary case** and means only that the plays-like
number does not appear.

### 4.8 `HolePlane` — projection, pan and zoom

Lays one hole out **tee at the bottom, green at the top**, rotated to the tee→green bearing.
Pure arithmetic — no CoreGraphics, no SwiftUI — so handedness is testable without a renderer.

**Pan and zoom live inside `HolePlane`, never in a SwiftUI modifier.** A
`.scaleEffect`/`.offset` on the canvas moves the pixels while `project` and `unproject` keep
describing the *unfitted* layout, so every tap lands somewhere other than the finger — and it
looks perfectly correct until someone places a target while zoomed.

```swift
public struct View: Sendable, Equatable {
    public var zoom: Double            // multiplier on the fitted scale; 1 == whole hole fits
    public var panX: Double, panY: Double   // POINTS, SCREEN-ORIENTED: +panY moves the hole DOWN
    public static let fitted = View(zoom: 1, panX: 0, panY: 0)
    public static let zoomRange: ClosedRange<Double> = 0.6...40

    /// Zoom is clamped; PAN IS NOT.
    public func clamped(size: (width: Double, height: Double)) -> View {
        View(zoom: min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound),
             panX: panX, panY: panY)
    }
}
```

- **`panY` is screen-oriented** — positive moves the hole *down*, the way `y` grows. Stated on
  the type because the drag gesture originally negated it and the layer scrolled against the
  finger; the convention belongs on the type, not in whichever gesture sets it.
- **Zoom to 40×.** The old ceiling of 8 fitted a hole and a bit of rough; a putt is read at a
  scale where the green fills the screen. Measured: 5.5 yards across a 390-point screen at 40×.
- **Pan is not clamped.** Holding it to half a screen made "go to my location" impossible
  whenever the golfer was not standing on the hole they were looking at — which is most of the
  time, and exactly when they want it. *Fit hole to screen* is the recovery.

#### Fitting, projection, inverse — VERBATIM

```swift
public init(origin: Coordinate, heading: Double, fitting points: [Coordinate],
            size: (width: Double, height: Double),
            insets: Insets = .uniform(24), viewport: View = .fitted) {
    self.origin = origin
    self.headingRadians = heading * .pi / 180
    let θ = self.headingRadians

    func local(_ c: Coordinate) -> Local {
        let o = Geodesy.offset(of: c, from: origin)
        return Local(forward: o.north * cos(θ) + o.east * sin(θ),
                     right: o.east * cos(θ) - o.north * sin(θ))
    }

    let ls = points.isEmpty ? [Local(forward: 0, right: 0)] : points.map(local)
    let minF = ls.map(\.forward).min()!, maxF = ls.map(\.forward).max()!
    let minR = ls.map(\.right).min()!,   maxR = ls.map(\.right).max()!
    let spanF = max(1, maxF - minF), spanR = max(1, maxR - minR)

    let usableW = max(1, size.width - insets.leading - insets.trailing)
    let usableH = max(1, size.height - insets.top - insets.bottom)
    let s = min(usableW / spanR, usableH / spanF)

    let v = viewport.clamped(size: size)
    let zs = s * v.zoom
    self.view = v
    self.scale = zs
    self.minForward = minF
    self.minRight = minR
    let baseX = insets.leading + (usableW - spanR * s) / 2
    let baseY = insets.bottom + (usableH - spanF * s) / 2
    self.offsetX = baseX - (spanR * (zs - s)) / 2 + v.panX
    self.offsetY = baseY - (spanF * (zs - s)) / 2 - v.panY
    self.height = size.height
    // Kept so a zoom can be re-solved ABOUT A SCREEN POINT: the arithmetic is not
    // invertible from a finished plane.
    self.baseScale = s
    self.spanForward = spanF; self.spanRight = spanR
    self.baseX = baseX; self.baseY = baseY
}

/// Screen point. y grows downward, as every canvas does — the flip lives HERE and nowhere else.
public func project(_ c: Coordinate) -> (x: Double, y: Double) {
    let l = local(c)
    return (x: (l.right - minRight) * scale + offsetX,
            y: height - ((l.forward - minForward) * scale + offsetY))
}

/// Screen point → coordinate. The exact inverse of `project` under the same `view`.
public func unproject(x: Double, y: Double) -> Coordinate {
    let right = (x - offsetX) / scale + minRight
    let forward = ((height - y) - offsetY) / scale + minForward
    let θ = headingRadians
    let north = forward * cos(θ) - right * sin(θ)
    let east  = forward * sin(θ) + right * cos(θ)
    let p = Geodesy.coordinate(from: origin, east: east, north: north, alt: nil)
    // Rebuilt explicitly: `coordinate(from:...)` defaults a nil alt to the ORIGIN's,
    // which would stamp the tee's elevation onto a point up the fairway.
    return Coordinate(lat: p.lat, lon: p.lon, alt: nil)
}

/// A viewport at `zoom` that keeps the ground under `point` UNDER `point`.
/// Analytic — the projection is affine in zoom, so the pan that pins one point is
/// one line of algebra. Centre-zooming at 40x throws the green being read several
/// screens away, which reads as the zoom not working.
public func zooming(to zoom: Double, about point: (x: Double, y: Double)) -> View {
    let z = min(max(zoom, View.zoomRange.lowerBound), View.zoomRange.upperBound)
    let right = (point.x - offsetX) / scale + minRight
    let forward = ((height - point.y) - offsetY) / scale + minForward
    let s = baseScale
    return View(zoom: z,
                panX: point.x - (right - minRight) * s * z - baseX
                    + spanRight * s * (z - 1) / 2,
                panY: point.y - height + (forward - minForward) * s * z + baseY
                    - spanForward * s * (z - 1) / 2)
}
```

**`unproject` returns a coordinate with no altitude, and that is the right answer rather than
a placeholder.** A tapped point's height is looked up in the DEM *at the moment it is
needed*, by whoever needs it — because a `Coordinate` carrying an `alt` has no datum on it,
which is the whole failure the grid exists to prevent.

**Test that must exist:** `project`/`unproject` round-trip under pan and zoom, and the
handedness assertion from §4.2.

**`Insets`** default to 24 on every edge and are not decoration: the HUD sits over the top and
bottom of the hole screen, and a hole fitted to the raw view puts its tee box underneath the
controls.

---

## 5. `OSMCourse` — assembling a course from OpenStreetMap

This is the subtlest code in the project. **A wrong partition and a crossed green both look
exactly like success** — they produce a file that passes every structural check and reads a
club and a half wrong. Everything below exists because one of them happened.

### 5.1 Coverage, measured

| | `golf=hole` ways | Courses | Share of facilities | `ref` | `par` | `handicap` | `dist` |
|---|---|---|---|---|---|---|---|
| **US** | 150,178 | ~7,900 | **~half** | 98% | 89% | 38% | 0.3% |
| **Korea** | 597 | 28 | **~3%** | — | — | 6% | 1.8% |

So: **in the US check OSM first; in Korea expect nothing and derive from the recorded
track.** An earlier version of the project doc said "not from OSM … do not re-plan around
OSM" as an absolute — that was measured on Korea only and is wrong for the primary market.
The track path stays primary wherever OSM is thin, and it is the only one that improves per
round.

### 5.2 The input

```swift
public struct Element: Decodable, Sendable {
    public struct Point: Decodable { public let lat: Double; public let lon: Double }
    public struct Member: Decodable {
        public let type: String
        public let role: String?          // "outer" | "inner"
        public let geometry: [Point]?
    }
    public let type: String               // "way" | "relation"
    public let id: Int
    public let tags: [String: String]
    public let geometry: [Point]?         // ways
    public let members: [Member]?         // relations
    public var coordinates: [Coordinate]  // answers for BOTH — see below
    public var golf: String? { tags["golf"] }
}
```

**A multipolygon's outline is its `outer` members, stitched — inner rings are dropped.** One
real course has 28 fairway relations carrying 28 outer members and **32 inner** ones (the
bunkers and greens cut out of the fairway); concatenating every member draws a spike from the
outer ring across to the inner one and back.

`stitch(_:)` chains several outer ways end to end and **reverses as needed** — OSM lets one
ring be several ways, in any order and either direction — and returns the **longest piece
alone** when they will not chain, because a partial outline is visibly partial where a ring
with a jump in it looks like a surveyed shape.

### 5.3 Reach — the distance budget

```swift
public struct Reach: Sendable {
    public var green: Double = 130
    public var tee: Double = 110
    public var namedTee: Double = 300     // a tee whose own label names its hole
    public var hazard: Double = 70
    public var fairway: Double = 90
    public var path: Double = 60          // tighter: a wrong cart path is a line across a hole
    public var simplify: Double = 1.0     // Douglas–Peucker tolerance, metres
}
static let maxWalk: Double = 350          // green to next tee, for the routing split
```

**One metre of simplification is below one pixel.** A hole draws ~400 m in ~700 points
(0.6 m/px) and a fix is ±3–5 m. One real course's 132 bunkers arrive as 4,610 vertices and
197 KB of a 240 KB file, all of it detail nothing downstream can resolve. **The centroid is
taken *before* simplification.**

**Douglas–Peucker on a *ring* must split at the far vertex first.** First and last are the
same point, so the naive baseline is degenerate and the whole outline collapses to a
triangle. `simplify(open:tolerance:)` is a **second, separate function** for paths — a path
has real ends and keeps both, and doing the ring trick to it moves one of its ends.

### 5.4 Greens — nothing in OSM links a green to a hole

There is **no relation and no shared `ref`**. At one real site, 32 greens and 100 tee
polygons carry no hole number at all. So every association is geometric and **exclusive**:
match by distance, assign **nearest-pair-first** so two holes can never claim one green, and
**report everything that failed to associate** instead of leaving a nil.

**A *named* green is never a hole's green.** A real green is unnamed — the hole's number is
its name; a named one ("Practice Putting Green") is practice. Count them into
`report.practiceGreensSkipped`.

### 5.5 Tees — three rules, in priority order

**1. A tee whose own label names a hole goes to that hole, and only that hole.** One real
course tags five tees "Hole 1 Black" … "Hole 1 Red"; proximity put four on hole 1 and **the
red one on hole 13** — an ordinary-looking file, a hole out for anyone playing the reds. A
surveyor writing the number down beats a centroid being nearest. A stated hole narrows the
candidates to one; an out-of-reach tee is dropped and counted rather than falling back to the
guess this exists to overrule. `namedTee` is 300 m because distance is then only a sanity
bound (hole 1's red sits 112 m out, two metres past the ordinary reach); anything past `tee`
is reported.

`holeNumber(in:)` reads **the first standalone number, not the word "hole"**: the white tee
there is tagged `Holw 1 White`, and a surveyor's typo must not cost the number beside it.

**2. An untagged `golf=tee` polygon is adopted, not dropped.** *(Reversed by the user
2026-08-30.)* The old rule was written when the cost looked like 11 of one site's 100
polygons; at another it is **107 of 112, and 16 of 18 holes with no tee at all** — the hole
view falling back to a centre line on a course OSM describes perfectly well.

What survives the reversal, and is still load-bearing: a **practice-named polygon is
refused**; a polygon **inside a `golf=driving_range` is refused** (`OSMCourse.inside`);
`Reach.tee` still applies; and the name is marked **`TeeBox.inferredName`** all the way to
the screen, where the hole box prints `~ White Tee`.

**3. An adopted tee's name comes from the length order, against one ramp chosen for the whole
course.** `TeeBox.ramp(of:)` degrades by dropping the middles (§4.4), and
`TeeBox.standardRamp` is the single source the colour palette reads its *names* from, so the
two cannot drift into a course whose "blue" tee is painted green.

**The ramp is per course, sized to *every* tee on the widest hole that has an adopted one** —
never per hole, never from a modal count, and never from the adopted count alone. A per-hole
ramp makes the third-longest tee "white" on a five-tee hole and "red" on a three-tee one, and
the UI remembers a tee *name*, so the hole view would lose its yardages on exactly the holes
where that name did not exist. Two narrower sizings were tried and both produced a `tee N` on
a real file: the *modal total* gave `tee 5` on one course's single five-tee hole, and the
*adopted count alone* gave another a one-entry ramp whose single entry a tagged black tee had
already taken — a ramp entry a tagged tee holds is skipped, so a hole with one tagged and one
adopted tee needs two entries to name one. A name a tagged tee on that hole already uses is
skipped rather than duplicated.

### 5.6 Splitting a site into courses

**Per-ref matching, never a greedy chain.** Refs repeat: a 27 has three holes called "1". The
greedy "nearest next tee" chain was written first and it walked out of one site's par-3 nine
into another course's back nine, reporting a confident **18 holes, par 63**. Courses at a
site are geographically *interleaved*, so a per-hole decision cannot see it has crossed.

`split` decides a whole hole **number** at once, matching all candidates to all routings by
**minimum total green-to-next-tee walk**, capped at `maxWalk` (350 m).

**`golf:course:name` beats the routing walk, all or nothing.** It is on all 28 hole ways at
one real site (Tournament 18, Valley 10) where the minimum-walk split, handed ten clipped
holes of the neighbouring course, produced **two spurious candidates of 7 and 3**. A
surveyor's statement is evidence; a walk is an inference. The tag is used **only when *every*
hole carries one** — partitioning on a partial tagging puts the tagged holes in named groups
and quietly loses the rest — and a disagreement with the walk is **reported, not silently
resolved** (`Report.splitDisagreement`).

**A group name is qualified by the site name.** `golf:course:name` reads "Tournament Course",
which slugs to `tournament-course` and would collide with the tournament course of every
other facility on earth. `displayName(course:site:)`: when the site name already contains the
group name it wins outright; otherwise join the two with the site's generic tail ("Golf
Course" / "Club" / "Links") dropped, so one site reads "Corica Park South Course". **Both the
CLI and the app go through it** — two id schemes agree right up until the day importing a
card over an OSM file writes a second course instead of merging.

### 5.7 Verification — three checks, and you must run all of them

```swift
public struct Candidate: Sendable {
    public var name: String?
    public var holes: [Hole]
    public var report: Report
    public var par: Int
    public var handicapIsPermutation: Bool
    public func measuredTotal(tee: String? = nil) -> (metres: Double, holes: Int)
}
```

1. **Stroke index is a complete 1…n permutation.** Where OSM tags `handicap` (38% of US
   holes) it is a free labelled partition of the site.
2. **Measured length per par**, through `DistanceUnit.plausibility`.
3. **`teeAnomalies`** — see below.

**`teeAnomalies` compares tee colours *pairwise*** — is black longer than yellow? — which is
the same answer on every hole of a course and is exactly what a misassigned tee breaks. It
caught three real faults on the first real import; on two of them a yellow polygon **64 m
behind the black tee** was the nearest yellow to that hole's tee end. The black-tee length
still matched the raw OSM way to the metre, so only someone playing yellows would ever have
found out.

Two sizings were tried first and both fail: **rank position** is not comparable between a
five-tee hole and a three-tee one, and **share-of-back-tee** cascades — once a stray tee is
the longest on a hole, every other tee there looks short and four false alarms follow the one
fault.

**It reports and never corrects.** Geometry cannot tell a real back tee from a neighbour's,
and silently deleting a tee that turned out to be real is the worse error.

Two reporting rules:

- **`holesWithoutGreen` / `holesWithoutTee` are per candidate, not per site.** Computed over
  every draft before the split, a course with all its tees still listed *"no tee found for
  hole(s) 1, 2, 2, 3 …"* — the duplicates being the **other** course at the site, whose refs
  repeat. In the CLI that is a confusing line; in the app `report.lines` **is** the row a
  golfer reads in front of Save, and a check that cries wolf about holes that are fine is a
  check nobody reads.
- **`Report.teeAnomalies` is appended to, never assigned.** `assignTees` writes into it and
  the candidate builder used to overwrite it one line later — a report that exists to be read,
  deleted immediately after it was written.

### 5.8 Two more assembly rules

- **A `golf=hole` way's direction is a convention, not a guarantee.** Orientation is decided
  from the data — whichever end sits nearer a green *is* the green end — because a reversed
  way renders the hole backwards with the camera pointing at the tee.
- **Cart paths are clipped per vertex, not assigned whole** (`OSMCourse.clip`). A path runs
  the length of one hole and carries on to the next, so "nearest hole to the midpoint" draws a
  neighbour's path across this hole and loses this hole's own.

---

## 6. `GolfCourseOSM` — the two sockets

Split out of the CLI so the **app** can search and download a course too: an executable
target cannot be imported. Deliberately not folded into `GolfCourse`, which stays
network-free.

```swift
public static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
public static let userAgent = "naelgol-marker/0.1 (golf course geometry import)"
static let attempts = 3
```

### 6.1 The feature query — `out geom;`, never `out tags geom;`

```
[out:json][timeout:180];
(
  way["golf"](s,w,n,e);
  relation["golf"](s,w,n,e);
);
out geom;
```

These look interchangeable and are not. **`tags` is a print mode in which a relation returns
tags and a bounding box with `members` absent entirely**, so every multipolygon was
unreadable whatever the parser did. Measured at one course: `out tags geom` gave 28 relations
and **zero** members; `out geom` gave the same 28 carrying 60 members with full geometry, and
keeps the way tags. Also not `out center`, which gives a point and throws away the outline
green distances are measured against.

The `around:` variant takes `(around:radius,lat,lon)` in place of the bbox.

### 6.2 Name search goes to Nominatim, not Overpass

```swift
static let endpoint = "https://nominatim.openstreetmap.org/search"
static let politePause: Duration = .milliseconds(1100)
```

**Measured 2026-08-30:** the Overpass name query is a regex over every `leisure=golf_course`
way and relation on the planet with no bounding box — one search took **12.5 s and returned
504**, Overpass timing itself out — against **0.72 s** from Nominatim, which answers with the
facility, its tags, and exactly the bounding box the feature query needs. Overpass still
fetches the geometry; that part is a spatial query and is fast once there is a box.

**The old Overpass name query stays as the fallback**, because a course the geocoder has not
indexed may still be in OSM, and a geocoder miss must not become "this course is not in
OpenStreetMap" — the message that sends somebody off to trace a hole by hand:

```
[out:json][timeout:120];
(
  way["leisure"="golf_course"]["name"~"<escaped>",i];
  relation["leisure"="golf_course"]["name"~"<escaped>",i];
);
out tags bb;
```

Filter results to `leisure=golf_course`: a search for a course name also matches the road and
the bus stop named after it, and **a bus stop's bounding box is a point**, which fetches
nothing and looks exactly like an unmapped course.

**Nominatim's usage policy is a condition, not etiquette:** one request per second (1100 ms
here) and a real `User-Agent`.

### 6.3 A name search is structured, and climbs a three-rung ladder

Measured against the live geocoder, free-form `q` returned **nothing at all** for "Coyote
Creek Tournament Course" and for "Coyote Creek Tournament Course, Morgan Hill, CA", and
returned **eighteen rivers and no golf course** for "Coyote Creek". Free-form has to guess
which words are the name and which are the place, and on a course name ending in a common
noun it guesses wrong.

`Nominatim.Query` splits on `" in "` or the commas, and the rungs are:

1. **`amenity=<name>` + `city`/`state`** — structured. The only rung that finds "Coyote Creek
   Tournament Course" at all.
2. **`q = "golf course <name> <place>"`** — Nominatim reads a leading category phrase as a
   filter, which is what turns those eighteen rivers into six courses.
3. **plain free-form `q`.**
4. **the planet-wide Overpass regex** (§6.2).

One request per second between rungs.

**"Found nothing" and "could not be asked" are different answers.** The site lookup was
`try? await Nominatim.sites(…)`, so any geocoder failure fell straight through to the Overpass
regex, which then timed out and reported *"Overpass timed out. Narrow the area"* — for a fault
in a different service, about an area that has nothing to narrow. Name it: `Failure.geocoder`.

### 6.4 Overpass fails transiently — retry, and classify the timeout

**Measured 2026-08-30: four of seven identical requests** for one 1.4 km box returned **504**,
and the body says `Dispatcher_Client::request_read_and_idx::timeout. The server is probably
too busy to handle your request.` That is load on a free shared service, not a query that is
too big, and a plain retry a second later succeeded every time.

Retry `attempts` (3) times with a growing backoff, and **read the body**:

- a **dispatcher** timeout → `.overpassBusy` → *"wait a moment"*
- a **query** timeout → `.overpassTimeout` → *"narrow the area"*

Giving the second advice for the first sends the golfer to shrink a box that was already
small. A mirror was tried and is **not** shipped — `overpass.kumi.systems` did not answer at
all, and retrying the host measured to recover is the fix with evidence behind it.

**A network error is a sentence, not an `NSError`.** The first run printed forty lines of
`NSURLErrorFailingURLPeerTrustErrorKey` at the user. Name the three shapes that matter — no
signal, Overpass busy, TLS being inspected — because the action is different for each.

---

## 7. `GolfTerrain` — USGS 3DEP and a GeoTIFF reader

**United States only.** There is no source for Korea and nothing writes one, so a Korean
course's plays-like number simply does not appear — which is the honest answer. Copernicus
GLO-30 is modelled in the enums and is a **surface** model that carries canopy and roofs as
ground, so it is a worse answer than it looks.

```swift
public enum Elevation3DEP {
    public static let imageService =
        "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer"
    public static let pointService = "https://epqs.nationalmap.gov/v1/json"
    public static let datum: Elevation.Datum = .navd88
    public static let attribution =
        "Elevation: USGS 3D Elevation Program (3DEP), public domain"
    public static let maxPixels = 8000

    public struct Report: Sendable {
        public var width: Int, height: Int
        public var postsEast: Double, postsNorth: Double
        public var minimum: Double, maximum: Double
        public var voids: Int
        public var nativeResolution: Double
        public var bytes: Int
    }
}
```

### 7.1 The fetch — VERBATIM, implement exactly

```swift
public static func fetch(bounds: (south: Double, west: Double, north: Double, east: Double),
                         spacing: Double = 3,
                         session: URLSession = .shared)
    async throws -> (grid: Elevation, report: Report) {

    let mPerDegLat = .pi * Geodesy.earthRadius / 180
    let midLat = (bounds.south + bounds.north) / 2
    let metresNorth = (bounds.north - bounds.south) * mPerDegLat
    let metresEast = (bounds.east - bounds.west) * mPerDegLat * cos(midLat * .pi / 180)
    let w = max(2, Int((metresEast / spacing).rounded()))
    let h = max(2, Int((metresNorth / spacing).rounded()))
    guard w <= maxPixels, h <= maxPixels else { throw Failure.tooLarge(w, h) }

    var c = URLComponents(string: imageService + "/exportImage")!
    c.queryItems = [
        URLQueryItem(name: "bbox", value:
            "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"),
        URLQueryItem(name: "bboxSR", value: "4326"),
        URLQueryItem(name: "imageSR", value: "4326"),      // NOT 3857 — see below
        URLQueryItem(name: "size", value: "\(w),\(h)"),
        URLQueryItem(name: "format", value: "tiff"),        // NOT bsq — see below
        URLQueryItem(name: "pixelType", value: "F32"),
        URLQueryItem(name: "interpolation", value: "RSP_BilinearInterpolation"),
        URLQueryItem(name: "f", value: "image"),
    ]
    var req = URLRequest(url: c.url!)
    req.timeoutInterval = 120
    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw Failure.http(http.statusCode, String(decoding: data, as: UTF8.self))
    }
    // An ArcGIS service reports an error as a 200 with a JSON body. Reading that
    // as a raster produces a grid of noise rather than a failure.
    if data.count < 8 || (data.first == 0x7b /* { */) {
        throw Failure.service(String(decoding: data.prefix(300), as: UTF8.self))
    }

    let tiff = try GeoTIFF(data)
    guard tiff.epsg == nil || tiff.epsg == 4326 else { throw Failure.notGeographic(tiff.epsg) }
    let native = (try? await resolution(atLat: midLat,
                                        lon: (bounds.west + bounds.east) / 2,
                                        session: session)) ?? 0

    // GEOREFERENCED FROM THE RETURNED RASTER, never from the bbox that was asked for.
    let centre = tiff.firstSampleCentre
    var metres = [Double?](); metres.reserveCapacity(tiff.width * tiff.height)
    var lo = Double.infinity, hi = -Double.infinity, voids = 0
    for y in 0..<tiff.height {
        for x in 0..<tiff.width {
            if let v = tiff.value(x, y) { metres.append(v); lo = min(lo, v); hi = max(hi, v) }
            else { metres.append(nil); voids += 1 }
        }
    }
    guard voids < metres.count else { throw Failure.empty }

    let grid = Elevation(source: .usgs3DEP, datum: datum,
                         nativeResolution: native > 0 ? native : spacing,
                         lat0: centre.y, lon0: centre.x,
                         dLat: tiff.scaleY, dLon: tiff.scaleX,
                         width: tiff.width, height: tiff.height, metres: metres)
    let posts = grid.nativePosts
    return (grid, Report(width: tiff.width, height: tiff.height,
                         postsEast: posts.east, postsNorth: posts.north,
                         minimum: lo, maximum: hi, voids: voids,
                         nativeResolution: native, bytes: data.count))
}
```

### 7.2 The four things that produce a file which looks entirely correct

All four measured 2026-08-30.

1. **`imageSR=4326`, not `3857`.** Web Mercator is the obvious request and it hands back a
   pixel scale in *Mercator* units — at 37.2°N that is 1/cos(37.2°) = **1.26× the ground
   metre**, so a grid stored as if it were metres displaces a sample by **~270 m** at the far
   corner. Degrees also keep every projection out of `GolfCourse`, so sampling is two
   divisions.
2. **Georeference from the returned raster, never from the bbox you asked for.** The service
   **snaps a requested box outward to whole posts** — by **146 m** in one measured call.
3. **`format=tiff`, never `format=bsq`.** The headerless raw dump returned **990,000 bytes
   for a 300 × 800 request** — 247,500 floats, not 240,000 — while `f=json` for the same call
   said 300 × 800. A raster whose dimensions have to be inferred from a byte count is one
   transposed grid away from a course file that is silently a hole out of place. TIFF states
   its own width, height, tiling and georeferencing.
4. **The native resolution must be asked for separately.** `exportImage` resamples
   1/3-arc-second data onto a 3 m grid **without comment**, and the result is byte-identical
   in shape to one built over lidar — a metre of vertical error against ten centimetres.
   `resolution(atLat:lon:)` hits the point service once at the centre of the course, and the
   answer is stored on the grid. Same rule as a guessed par being indistinguishable from a
   surveyed one.

**The vertical datum is not in the raster either** — the geokeys describe the *horizontal*
CRS — so `.navd88` is asserted by the fetcher from the product it requested and written into
the file.

The point service takes `x`, `y`, `units=Meters`, `wkid=4326`.

### 7.3 `GeoTIFF` — what the reader must handle

Single-band, uncompressed, F32. Both byte orders (`II` = 0x4949 little, `MM` = 0x4d4d big).
3DEP returns **tiled** 128 × 128 F32; the **stripped** path exists because the layout is the
service's choice, and a stripped file would otherwise decode as an empty grid rather than as
an error.

```swift
public struct GeoTIFF: Sendable {
    public var width: Int, height: Int
    public var samples: [Double]
    public var originX: Double, originY: Double     // ModelTiepoint  (33922)
    public var scaleX: Double, scaleY: Double       // ModelPixelScale (33550)
    public var rasterType: Int                      // GTRasterTypeGeoKey; 1 == PixelIsArea
    public var epsg: Int?                           // GeoKeyDirectory (34735)
    public var noData: Double?                      // GDAL_NODATA    (42113)

    /// The PixelIsArea half-post shift, applied ONCE, here.
    public var firstSampleCentre: (x: Double, y: Double) { ... }

    public func value(_ x: Int, _ y: Int) -> Double?   // nil for NaN, |v| >= 1e6, or noData
}
```

Tags to parse: width 256, height 257, bits 258, compression 259, sample format 339 (**3 =
IEEE float**), strips 273/278/279, tiles 322/323/324/325, plus the four geo tags above.

Under the default `RasterPixelIsArea`, the tiepoint maps raster (0,0) to the **corner** of the
first pixel; `Elevation` stores the **centre**, so the half-post shift is applied here and
sampling never has to know which convention the source used.

### 7.4 What the CLI prints, and why that is the feature

```sh
golfctl course elevation Courses/<id>.json [--spacing 3] [--pad 150] [--out Courses]
```

Bounds are the extent of every coordinate in the course file — `line + fairway +
green.polygon + tees.at + green.center` — padded by `--pad`. **Padded deliberately:** a
golfer standing on the next hole's tee is still measuring from where they are, and a grid
clipped to the course's own extent returns nil for exactly those shots.

Print: native resolution, relief (min/max), voids, coverage over the course's own points, and
**per-hole tee-to-green rise**. A grid built over coarse data instead of lidar, or one
clipping a corner of the course, is byte-identical in shape to a good one — so what the
command prints *is* the verification.

Measured: a whole course is one request, 6–15 s. Two real files are **491 KB** and **753 KB**.
Both report **1 m lidar**. Grid values agree with the independent point service to **3–34 cm**
and tee-to-green deltas to **0.37 m**.

### 7.5 On the phone, terrain is a button

*(User decision 2026-08-30.)* The course finder stays geometry-only: a DEM is another
request, three quarters of a megabyte, 6–15 s, and it finds **nothing outside the United
States** — a golfer searching for a course is answering a different question. Terrain is its
own step in the course menu, and the cost of the split is the one thing the sheet says out
loud: **do it before the round**, because a course has no signal.

**The three checks are the sheet, not a detail behind it** — same rule the finder follows, and
a sharper reason here.

### 7.6 Licensing, stated once

- **3DEP is public domain.** Ours to store outright. Carry the attribution string anyway.
- **OSM is ODbL**, and in the US that will be most course files. Share-alike is the normal
  case, not an edge case. `Course.Source.osm` and per-hole `Hole.source` model it; nothing
  enforces it. **This project is private use, so share-alike has nothing to discharge** — the
  moment a file leaves the group, it comes back exactly as written.
- **Map imagery may not be stored.** No provider licenses persistent storage: Google's terms
  bar offline use outright, Apple's licence allows only temporary caching. See §10.1.

---

## 8. `GolfCaptureCore` — audio and location

Cross-platform, so the recorder runs on a Mac. **CoreLocation needs a bundle identifier**, so
an unbundled CLI captures audio and marks but no GPS — report that (`locationAvailable`)
rather than hanging, which is what the CLI used to do.

### 8.1 `AudioRecorder` — one tap, one converter per consumer

```swift
public struct Config: Sendable {
    public var sampleRate: Double = 16_000        // what ASR resamples to anyway
    public var channels: Int = 1
    public var bitRate: Int = 32_000
    public var formatID: AudioFormatID = kAudioFormatMPEG4AAC
    public var stallTimeout: TimeInterval = 10
    public var describedFormat: String            // "m4a-aac-16k-mono-32kbps" → meta.json
}
public enum State: Sendable { case idle, recording, interrupted, stopped }
```

16 kHz mono: a quarter the bytes of 44.1 kHz, and far-field intelligibility is limited by
distance and wind, not by bandwidth above 8 kHz.

**Built on `AVAudioEngine`, not `AVAudioRecorder`.** Live transcription was an
audio-plumbing problem, not a model problem: `AVAudioRecorder` exposes no buffers at all,
which is the only reason a round could not be transcribed until a segment closed. Every
engine needs the same tap, so swapping the recognizer would not have avoided it.

```swift
public struct AudioTap: @unchecked Sendable {
    public let format: AVAudioFormat
    public let receive: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
}
public func listen(_ tap: AudioTap?)
```

**One `installTap`, one converter per consumer.** The tap carries **its own format**, because
the file's format is not the analyzer's — `SpeechAnalyzer.bestAvailableAudioFormat` names what
it wants and it is not the 16 kHz mono the `.m4a` is written in. Ask for it; never assume.
Each converter is **reused across buffers**: one rebuilt per buffer re-primes its resampler
and clicks at every tap boundary, twelve times a second, in a file nobody plays back until
after the round.

**The `.m4a` keeps being written whatever happens.** Live transcription is additive to the
file, never a replacement — a discarded recording makes the ASR comparison unrunnable forever.

Rules that each cost a debugging session:

- **Releasing the `AVAudioFile` is what finalises an `.m4a`, and it must happen before the
  segment-close call returns.** `AVAudioRecorder.stop()` gave that for free; an `AVAudioFile`
  does not. **Measured 2026-08-27:** a file whose `AVAudioFile` is still alive **fails to open
  at all** (`ExtAudioFileOpenURL`), and even one that opens is missing the encoder's last
  frames — `length` read 45,056 before release and 45,880 after.
- **`listen(nil)` must clear the *pending* listener too.** The engine parks a listener's
  request in `pendingListener` so a restart re-attaches it across an interruption — but a
  burst ends with the engine stopped and the listener already moved there, so clearing only
  the active one left the finished burst's tap armed. The next start then fed live buffers
  into an analyzer that had already been finalised: no output, and nothing saying why.
- **A burst is torn down audio-first, then analyzer, then tap.** Audio first closes the
  segment with a real `t1` and stops the buffers; draining the analyzer second lets the last
  phrase finalise instead of being thrown away — which is the end of a hole, which is when
  scores get said; detaching the tap third keeps the next burst clean. Any other order loses
  something.
- **A stall watchdog, because a tap that stops delivering buffers fails silently.** Engine
  running, no error, no buffers (a developer-forum report has this after a phone-call
  interruption — precisely the event this recorder is built around). "No buffer for
  `stallTimeout` (10 s)" is a fault: restart the engine into a **new** segment, not the same
  one, because the audio between the last buffer and the restart does not exist and writing
  what comes next into the same file puts a hidden gap inside a stretch the clock says is
  continuous. **Disarm it while `state == .interrupted`** — the tap is *supposed* to be silent
  during a call, and restarting under the interruption fights the OS for the microphone every
  two seconds.
- **A segment ends when its last sample arrived, not when the code noticed.**
  `endTime(lastBuffer:notBefore:)`, floored at the segment's own `t0`. The watchdog waits ten
  seconds before declaring a stall, so stamping `now` gave a segment claiming **18.0 s while
  holding 6 s of audio** — the dead stretch landed *inside* a window the session clock says is
  continuous recording. Stamped properly, the twelve silent seconds appear where they belong:
  as the gap *between* two segments.
- **`onStateChange` must be consumed by the UI**, because the record button can otherwise
  lie. An interruption closes the segment and sets `.interrupted`, and the resume is
  best-effort. Rendering only "is listening" leaves a red button counting up over nothing
  being written.
- **`AVAudioEngine.inputNode` can abort the process rather than throw.** Seen twice in the
  simulator: `AURemoteIO::Initialize()` RPC-timed out and `AudioToolboxCore` called `abort()`,
  with nothing catchable anywhere. A reboot cleared it. The saving grace is the default —
  recording is off — so a wedged audio server costs one tap and not a launch-crash loop. Do
  not add a `try?` and think you have covered it.

### 8.2 The audio session — three settings, each load-bearing

- **`.record`, and `setActive(true)` before the engine starts.** *The category is what grants
  background recording*, not `UIBackgroundModes: audio`. Remove it and the app records fine
  with the screen on and stops the moment the phone goes in a pocket — i.e. the whole round,
  and macOS tests cannot catch it. `.record` and **not** `.playAndRecord`: nothing is played
  back during a round, and `.playAndRecord` takes the output route as well and ducks whatever
  the group has on.
- **No `.allowBluetooth`, ever.** Connected AirPods would become the input over HFP —
  narrowband and beamformed at the wearer's own mouth, recording the phone's owner nicely
  while suppressing the other three players. That is the exact capture the product depends on.
  Pin `.builtInMic`, and write the **resolved route** to `meta.audioRoute` so a bad round is
  distinguishable from a bad premise.
- **`stop()` deactivates the session** with `setActive(false, .notifyOthersOnDeactivation)`.
  `.record` silences every other app's playback and a session is deactivated only explicitly,
  so without this the first burst kills the group's music for the whole round with the orange
  microphone dot lit the entire time the app claims not to be listening.

**`meta.audioFormat` / `audioRoute` are stamped on the first burst, not at round start** —
`start()` writes `"none"` when the round begins silent, which is the default, so a round that
recorded three bursts would otherwise claim it never recorded.

### 8.3 `LocationRecorder` — duty-cycled

```swift
public struct Config: Sendable {
    public var accuracy: CLLocationAccuracy = kCLLocationAccuracyBest
    public var distanceFilter: CLLocationDistance = 1
    public var slowAccuracy: CLLocationAccuracy = kCLLocationAccuracyNearestTenMeters
    public var slowDistanceFilter: CLLocationDistance = 25
    public var maxHorizontalAccuracy: CLLocationAccuracy = 50   // fixes worse than this are dropped
    public var startMode: TrackingMode = .slow
}
public func setMode(_ next: TrackingMode)      // ignores a mode it is already in
```

**Slow by default, fast for a burst and for an open hole view.** State the power saving as an
**estimate**: the full-rate baseline round was voided by the user, so there is no
before-number and never will be. The visible cost: `gps.jsonl` is too coarse between bursts to
derive geometry from.

`allowsBackgroundLocationUpdates = true` whenever Always has been granted, and
`pausesLocationUpdatesAutomatically = false` — a golfer stands still a lot.

**`escalate()` / `escalateAuthorization()` must return early unless something has actually
asked for Always.** Assigning `CLLocationManager.delegate` fires
`locationManagerDidChangeAuthorization` **immediately**, so without that guard the app throws
a location dialog on launch before the user has typed a name.

### 8.4 A location delegate must own itself until it answers

**Found on device 2026-08-27; it cost a whole session — control reached the app and no log
appeared, with nothing in any log file.**

`CLLocationManager.delegate` is a **weak** reference. With the timeout block capturing
`[weak self]`, nothing held the delegate once `start` returned — and ARC may release a local
at its *last use*, not at end of scope. Released, it fires no callback and its own timer
no-ops, so the continuation is **never resumed**.

The fix has two halves and you need both:

1. A `keepAlive` strong self-reference, released **a run loop turn after** it answers —
   dropping it inside a `CLLocationManager` callback deallocates the manager mid-call.
2. **Race the whole location step against a deadline held *outside* CoreLocation.** The
   promise was otherwise being kept by the object that had already vanished.

### 8.5 `RoundSession` — the round's lifecycle

- **Recording is off by default** (`recordAudio: false`). That means "do not open the
  microphone *with* the round", not "the feature is disabled". `startAudio()` / `stopAudio()`
  open and close a **burst** mid-round as often as the user taps, so a round holds several
  `.m4a` segments with **real gaps between them**. Keep the `AVAudioEngine` **lazy**, so a
  round nobody records builds none of it.
- **`stop()` tears audio down on `audioRunning`, never on `recordAudio`.** With a button the
  mic can be live on a round that started without it, and gating the teardown on the
  constructor flag leaves the engine running and the last segment unclosed.
- **A round can be reopened, and Record is offered on a finished one.** A round does not end
  when the golfer stops talking — the scores get said on the way to the car park — and the
  alternative is a second folder holding half a hole. `resume()` clears `meta.end`, reopens
  the marks and corrections writers **in append mode**, restarts the sensors, and leaves
  `start` alone. The round therefore reads *unfinished* while it runs again and `duration` is
  nil until it stops.
- **Reopening rewires the sensors, not just the writers.** `location.onFix` is what fills the
  current position, and that is what gives a log its coordinate; a reopen that only reopened
  the files would record and place nothing, which looks like working.
- **Reopening refuses while another round is recording.** One microphone.
- **A resumed round must adopt the segments already on disk** (§3.6).

---

## 9. `GolfTranscription` — bilingual ASR

### 9.1 The engine decision, and what it cost to reach

**WhisperKit with a multilingual model, no language ever specified, and no translation.**
*(User decision 2026-08-27.)* Those three settings are the whole reason it works here and
they live in one place.

The history matters because it eliminates three tempting alternatives:

- **Siri / App Intents: scrapped after one day.** Two turns per sentence, and single-language
  — which fails the bilingual requirement outright.
- **Apple `FoundationModels` for extraction: scrapped the same day.** ~4,096 tokens of context
  *including output* so a round does not fit, no image input, on-device only (Private Cloud
  Compute is not exposed to third-party apps), and it generated garbage on real input. **Do
  not write another on-device model path without new measurement.**
- **Parakeet: out, on no Korean.**

Apple's `SpeechAnalyzer` / `SpeechTranscriber` path is still built and still reachable
(`--asr apple`), because the comparison is a measurement and `Transcriber` is a protocol for
exactly that.

Two objections to Whisper are real and stand: **one language token per 30-second window**,
and weak code-switching (HiKE: Whisper-Small 48.1% PIER at Korean-English switch points). The
third — "it translates the minority language" — turned out to be a *setting*, not the model.

### 9.2 `WhisperDecoding.options` — VERBATIM, and the three options only work as a set

```swift
public static func options(volatile: Bool) -> DecodingOptions {
    var o = DecodingOptions()
    o.task = .transcribe
    o.language = nil
    o.detectLanguage = true
    o.usePrefillPrompt = true
    o.skipSpecialTokens = true
    o.withoutTimestamps = false
    o.temperature = 0
    if volatile {
        // A partial pass exists to put words on screen while someone is still
        // talking; it must not spend time on fallbacks it re-runs in half a second.
        o.temperatureFallbackCount = 0
        o.wordTimestamps = false
    } else {
        o.chunkingStrategy = .vad
    }
    return o
}
```

- **`task = .transcribe`, never `.translate`.** Whisper will happily render Korean speech as
  English prose. A translated line reads as a perfectly fluent thing nobody said.
- **`language = nil`.** Never pinned. Pinning is what makes one language disappear.
- **`detectLanguage = true`.** Required, not implied: it defaults to `!usePrefillPrompt`, so
  leaving `language` nil on its own gets a prefilled `<|en|>` and silently English-only output.
- **`usePrefillPrompt = true` — the one that is easy to get backwards.** `task` is not a
  switch the decoder reads; it is expressed *as* the `<|transcribe|>` token in the prefill.
  Turn the prefill off and `.transcribe` becomes a value nothing acts on. **Measured
  2026-08-27:** with `usePrefillPrompt = false`, Korean came back detected as `ko` and
  rendered in fluent English — "스티브가 버디를 했어요" as "Steve did a Buddy". Translation,
  produced by the setting meant to forbid it, reported under the right language tag.

Pin all four with a test.

### 9.3 VAD — the single most effective thing in this path

**Do not ask Whisper what was said when nothing was said.** Measured over 301,317 inferences
on non-speech audio, Whisper hallucinates **40.3%** of the time and **"thank you" alone is
24.76%** of those; a VAD in front of it takes that to **0.2%** and *improves* WER
(arXiv:2501.11378). The same paper measured Whisper's own knobs as barely helping — which is
exactly what happened here: `noSpeechProb` / `avgLogprob` caught pure noise and let every
realistic case through, and the user came back from a real round with "so many phantom thank
you's".

It also fixes a bug that looks unrelated. **Whisper decides the language from the first
30-second frame**, so leading non-speech decides it. Measured on one English sample: clean
speech with 4 s of digital silence either side → `en`; quiet noisy speech with no padding →
`en`; quiet noisy speech *with* noisy padding → **`nn`** (Norwegian) plus a looping glyph
hallucination. **Neither low SNR nor padding alone breaks it — noisy non-speech does**, and a
golf course is never digitally silent. That was the user's "I spoke English and it came out
Korean".

The fix is to drop leading non-speech **by advancing the window itself**, never by trimming a
copy — a trimmed copy shifts every timestamp silently, which is the accumulation bug
`AudioTimeline` exists to prevent, one level down.

**VERBATIM — implement exactly:**

```swift
public struct WhisperVAD: Sendable {
    public var frameSeconds: Double = 0.1      // usual energy-VAD frame
    public var floorRatio: Float = 1.6         // ~4 dB above the window's own floor
    public var absoluteFloor: Float = 0.0035   // for a genuinely near-silent window
    public var preRollSeconds: Double = 0.3    // so a soft word onset is not clipped

    public func frameEnergies(_ samples: [Float], sampleRate: Double) -> [Float] {
        let step = max(1, Int(frameSeconds * sampleRate))
        guard samples.count >= step else { return [] }
        var out: [Float] = []; out.reserveCapacity(samples.count / step)
        var i = 0
        while i + step <= samples.count {
            var sum: Float = 0
            for j in i..<(i + step) { sum += samples[j] * samples[j] }
            out.append((sum / Float(step)).squareRoot())
            i += step
        }
        return out
    }

    public func threshold(for energies: [Float]) -> Float {
        guard !energies.isEmpty else { return absoluteFloor }
        let sorted = energies.sorted()
        // Tenth percentile, not the minimum: one artificially quiet frame should
        // not define the floor for the whole window.
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        return max(absoluteFloor, floor * floorRatio)
    }

    public func speechFrames(_ samples: [Float], sampleRate: Double) -> (first: Int, last: Int)? {
        let energies = frameEnergies(samples, sampleRate: sampleRate)
        guard !energies.isEmpty else { return nil }
        let t = threshold(for: energies)
        guard let first = energies.firstIndex(where: { $0 > t }),
              let last = energies.lastIndex(where: { $0 > t }) else { return nil }
        return (first, last)
    }

    public func speechStart(_ samples: [Float], sampleRate: Double) -> Int? {
        guard let frames = speechFrames(samples, sampleRate: sampleRate) else { return nil }
        let step = max(1, Int(frameSeconds * sampleRate))
        return max(0, frames.first * step - Int(preRollSeconds * sampleRate))
    }

    public func trailingSilence(_ samples: [Float], sampleRate: Double) -> Double {
        guard let frames = speechFrames(samples, sampleRate: sampleRate) else {
            return Double(samples.count) / sampleRate
        }
        let step = max(1, Int(frameSeconds * sampleRate))
        let lastSample = min(samples.count, (frames.last + 1) * step)
        return Double(samples.count - lastSample) / sampleRate
    }
}
```

**The threshold is relative to the window's own noise floor, and that is load-bearing.** A
fixed 0.02 was tried first and **ate a whole spoken phrase**: quiet far-field speech at 0.031
peak over a 0.009 floor lost a third of its frames, and "Steve is away." vanished from a
transcript. No absolute number is right in a wind gust and a car park at once.

**The asymmetry is deliberate.** A frame wrongly called speech costs one hallucinated line
that the output filters catch; a frame wrongly called silence costs **what somebody said**,
permanently. So a window is declared speechless only when *nothing anywhere in it* stands out
from its floor.

Output filters (a bag of known hallucinations) stay as the residue-catcher the same paper
describes (VAD 0.2% → 0%), **not** as the fix.

### 9.4 The language a line is in comes from its script, not from the model

```swift
public enum ScriptLocale {
    public static func detect(_ text: String) -> String? {
        var hangul = 0, latin = 0, other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x41...0x5A, 0x61...0x7A:                          latin += 1
            case 0x3040...0x30FF, 0x4E00...0x9FFF:                  other += 1
            default: break
            }
        }
        guard hangul + latin + other > 0 else { return nil }
        if hangul >= latin && hangul >= other { return "ko" }
        if latin >= other { return "en" }
        return nil
    }
    /// The script when unambiguous, otherwise whatever the model said.
    public static func resolve(text: String, modelSaid: String?) -> String? {
        detect(text) ?? modelSaid
    }
}
```

**More reliable than asking Whisper, and free.** Whisper reports a language per 30-second
frame and gets it wrong on short or noisy windows — measured here as correct English text
tagged `ko`, and elsewhere as `nn`. The text it produced says what language it is without
ambiguity.

**Nil for a line with no letters** ("240", "3"): a number is not evidence of a language, and
guessing puts a wrong tag on a row that could have stayed honest. **Each segment then falls
back to the language of the result it came from, never `results.first`'s** — a pass over a
long window returns several results, one per 30-second frame, each with its own detected
language.

### 9.5 The consequences of one pass, one language

**One pass, one language, decided per 30-second frame.** This is the cost of the engine and no
setting removes it: a sentence that switches language halfway is decided by whichever language
most of it is in.

It replaces the **Apple path's two-recognizers-over-one-audio arrangement**, which is worth
recording because it is the comparison arm and it is why an English-only model is never
offered anywhere in this codebase. Measured on that path: **`en_US` silently drops every
Korean utterance** — not garbage, *absence* — and `ko_KR` transcribes both but turns 보기
(bogey) into 고기 (meat) and mangles English names. So two `SpeechTranscriber`s, `en_US` and
`ko_KR`, run simultaneously as two modules of **one** `SpeechAnalyzer`, both produce output,
each `Utterance` is tagged with the locale that produced it, and **both transcripts are kept
— not merged in code**: their errors are uncorrelated (the Korean model recovered "you're
away" where the English one produced "your way"), and the model step is the reconciler.
Verified end to end on a real recording: one pass, both locales, **43× realtime**.

**English-only Whisper builds are never offered, and that is a correctness rule.** `.en` and
`distil-*` cannot produce Korean at all and the failure is *silence* — indistinguishable from
nobody having spoken, the same shape as `en_US` dropping Korean. Filter them out of the model
picker and out of `golfctl models`.

**Diarization is not needed** *(user, 2026-08-26)*. Attribution is content-only — the model
resolves who did what from what was said. `Utterance.speaker` simply stays nil. The bet is
that corrections carry the load; **attribution accuracy is still the metric that decides the
feature.**

That decision has a sharp consequence. **`AnalysisContext.contextualStrings` does nothing for
`SpeechTranscriber`** — measured 2026-08-27, identical output with the strings and without,
over words the recognizer demonstrably fails on ("Chungmin" → "Chungman", "Naelgol" →
"Nielgal"). The cause is now known: contextual strings are honoured by `DictationTranscriber`
and ignored by `SpeechTranscriber`. Not our bug. Keep the code (it costs nothing and would
apply to a `DictationTranscriber` module) but **nothing may depend on it**. Since diarization
was cut, a spoken name is the *only* attribution signal, and this was the knob protecting it.
Therefore: **name matching in the model step must be phonetic/fuzzy against the roster,
never exact** — and with one name per player (§3.3) there is nothing else to fall back on.

### 9.6 Live transcription — a rolling window, committed at a silence

```swift
public struct Config: Sendable {
    public var sampleRate: Double = 16_000
    public var minSeconds: Double = 1.0
    public var maxWindowSeconds: Double = 14      // backstop, NOT the commit rule
    public var silenceSeconds: Double = 0.7       // what a sentence boundary sounds like
    public var maxLeadingSilence: Double = 0.3
}
```

**A hypothesis is shown and a commit is stored**, and that split survived the engine change.
Whisper has no volatile/final distinction of its own, so the live transcriber *makes* one: a
rolling window is re-decoded every pass and published as a hypothesis, and a phrase is
committed at a silence. A caption that only appears when a phrase finalises looks like an app
that is not listening; a file full of rewritten hypotheses is not a transcript. **A non-final
line is drawn dimmed and italic and is never stored** — a hypothesis that renders like a fact
is the same failure as a simulated position drawn like a fix.

**A phrase commits at a silence, not on a timer.** `maxWindowSeconds` (14 s) is only the
backstop for a golfer who does not pause, and it must stay **well under Whisper's 30-second
frame**, past which the model silently drops the oldest audio.

**A fresh transcriber per burst, never one reused across a pause.** Reusing one means feeding
a finalised analyzer, and the clock would have to absorb a gap it saw no buffers for.

**Never pass `bufferStartTime` on live input** *(Apple path, measured 2026-08-27)*. Stamping
each buffer with its wall-clock position produced one volatile word ("I"), repeated, and **no
finalized results at all** over speech the same analyzer transcribes cleanly with the times
left off. `SpeechAnalyzer` keeps its own clock by counting the samples it is handed; a second,
jittering clock makes its input look overlapped. Map on the way *out* instead.

**`LiveAudioClock` maps the analyzer back onto the session clock and absorbs gaps rather than
averaging them.** The analyzer's clock is "delivered samples", not elapsed time — the same
number only while buffers keep arriving. A four-minute phone call stops delivery, the
analyzer's clock does not advance, and every word afterwards lands four minutes early with
nothing downstream able to tell. Each buffer is stamped on arrival and a drift past
`gapTolerance` (**1 s**) moves the anchor. Same rule as `AudioTimeline`, one layer up: stamp,
never accumulate.

**The live transcript never writes `transcript.jsonl`.** The authoritative transcript stays
the file pass over closed `.m4a`s: a file pass sees each segment whole, which is a better
recognition problem than a stream, and the ASR comparison is run over those files — a live
pass standing in for them makes it unrepeatable. What the live path **does** write is
`log.jsonl`: a finalised sentence becomes a `LogEntry` with `source: .spoken`.

**The file transcriber only ever sees closed segments**, which is what live transcription
exists to route around: an `.m4a` still being written is not a readable file, so a round in
progress has nothing transcribable in its current segment — for an uninterrupted round, nothing
until the eighteenth hole. `rotateSegment()` is the other half of the answer and is built but
unused: on `AVAudioEngine` a rotation is one file close and one file open with the tap still
running.

### 9.7 One log entry per recording, not per phrase

*(User decision 2026-08-27.)* A burst is one thing the golfer did — pressed record, said what
happened, stopped — so it reads as one row rather than however many times they paused for
breath. Grown by **superseding** rather than buffered until Stop, so a round that dies
mid-burst keeps what was already said.

Two consequences:

- A phantom line inside a three-minute entry costs a text edit rather than a swipe, which
  raises the stakes on the VAD work.
- Every supersede is a new id, so **extraction must read a burst entry when the burst *ends*,
  not while it grows**, or `ExtractionCoverage` re-reads the whole accumulated text on every
  phrase — the runaway shape that file exists to prevent.

### 9.8 Re-reading one entry with a bigger model

**Two Whisper models, because the two jobs have opposite constraints** *(user, 2026-08-28)*.
The live model decodes continuously for 4.5 hours on a phone, so it is small and mishears
names; the final model runs on one entry, once, when somebody is looking at a line that came
out wrong, so it can be the biggest thing that fits.

The measurement is the argument: `small` runs at **1.5–2.7× realtime** on a Mac, so a big
model over a whole round is hours and over one entry is seconds.

```swift
public struct AudioSpan: Sendable, Equatable {
    public var segment: AudioSegment
    public var start: TimeInterval, end: TimeInterval    // WITHIN that segment's file
}
public enum AudioSpans {
    public static func resolve(from t0: Millis, to t1: Millis, in segments: [AudioSegment]) -> [AudioSpan]
}
```

**A log names its own audio, and `tEnd` is the only thing that makes that true.** `[t, tEnd]`
resolves against `audio.jsonl`. **Session times, never a file name and an offset** — one clock,
and `AudioTimeline` already owns the segment↔session mapping, so a second copy on the row
would be a second authority that can disagree.

**A span is a list, because a burst can cross a segment boundary.** The stall watchdog rotates
mid-burst and an interruption closes a segment, and the audio between two segments **does not
exist** — it is a phone call. Each piece is decoded on its own and only the **text** is joined.
Concatenating the samples hands the decoder a join that never happened, inside a 30-second
frame.

**A segment with `t1 == nil` is skipped, and usually it is not the crashed round** — it is the
burst recording *right now*, and an `.m4a` still being written cannot be opened at all. So a
log spoken into the open burst resolves to no spans, and the menu says so instead of offering a
button that cannot work.

**The re-transcribe reads the whole entry's span, never one phrase.** Measured 2026-08-28: the
4.5–7.0 s excerpt of a real file read 포기했어요 as 고기 했어요 where the whole-file pass got it
right. Less context is worse context, and the burst — pauses included — is the context.

**It writes no coverage and no transcript.** A sub-range pass is not a whole-segment pass;
marking `transcript.coverage.json` would record segments transcribed when only part of them was
read, and a segment marked done is never read again. What it *does* write is a **superseding
row in `log.jsonl`** — so nothing is overwritten, a citation still renders its evidence, and the
new id makes `ExtractionCoverage` re-read it, which is correct because the text changed.

### 9.9 `promptTokens` — wired for the on-demand pass only

**Whisper reads the prompt as *previous text*, so it is evidence about the language.** A
couple of hundred English golf words in front of a Korean phrase argues for exactly the
failure the user reported twice. So only the **roster's names** reach a
decoder, written as prose (" Players: a, b, c.") rather than a bare list, because the prompt
slot holds previous text and prose is what the model was trained to see there.

**Return nil when there are no names** — WhisperKit drops a prompt that trims to nothing, but a
bare `<|startofprev|>` biases the model toward ending the segment early.

**The live path stays unwired**: least context, most to lose. Measured on four fixtures with
and without a bilingual roster: no language flipped, nothing looped — but the fixtures are
`say` output, so the half it exists for is still unmeasured.

**`GolfVocabulary.synonyms` is a glossary the model reads, never a rewrite of a log.** Half the
Korean list is not a recognition problem at all: Whisper transcribes 고구마 perfectly and it
means *sweet potato*. 따블, 트, 유틸, 오비 are the same shape. Several keys are ordinary Korean
syllables, so a mechanical substitution would corrupt sentences about lunch. It goes to the
model as **context** and the log stays exactly as it was heard. **Injected, never imported** —
importing `GolfTranscription` into `GolfReconstruction` would drag WhisperKit into the one
target whose point is being framework-agnostic.

### 9.10 `WhisperEngine` — model residency and the download traps

```swift
public static let defaultID = "openai_whisper-small"
public static let repo = "argmaxinc/whisperkit-coreml"
public static let capacity = 2        // an LRU, not a single slot
```

- **More than one model, because a single slot was a bug.** It cached one `(id, kit)` pair, so
  the live and final models evicted each other: re-transcribe an entry and the next Record tap
  reloaded the listening model, which is exactly what "loading is seconds, reloading per burst
  misses the first sentence" forbids. It only appeared once the two models *differed* — the
  entire configuration the feature exists for. Proven with `--model small,tiny,small`: 17.5 s,
  then 3.9 s, then **0.66 s marked "already resident"**.
- **Loads are deduplicated in flight.** An actor suspends at every `await`, so two callers that
  both miss the cache before either finishes would both load the same model. The in-flight
  handle is `Task<Void, Never>`, **never** `Task<WhisperKit, Error>` — `WhisperKit` is not
  `Sendable`, so it must not cross a task boundary; the task writes into the actor and callers
  re-read the cache.
- **Both models are preloaded at round start, live model first, and never downloaded.** At
  round start rather than app launch, because most launches are not rounds — a gigabyte of
  CoreML at launch is paid by people who never press Record. Live model **first** because
  preload is sequential. **Skip a variant that is not on the phone, in silence** — a course has
  no signal, and a fetch belongs in the picker where it has a progress bar. Stopping the round
  cancels the *warming*, never the models: a finished round can be reopened.

**`downloadBase` must carry the `huggingface` component.** `HubApi` reads `if let downloadBase
{ use it } else { documents.appending("huggingface") }`, then resolves a repo to
`<downloadBase>/models/<repo>`. Passing a bare Application Support directory therefore wrote to
`<base>/models/…` while the code looked in `<base>/huggingface/models/…`, **so the cache was
never found and every launch re-downloaded half a gigabyte** *(reported twice)*. It survived
one round of "fixing" because the simulator copy had been placed **by hand** at the path the
wrong assumption expected — a real download with an explicit base had never once been made.
The general lesson: a path convention read off the library's source is fine; a path convention
*inferred from where files happened to be* is not, and the test for it must exercise a real
download.

**Where the model is, is answered by looking, not by computing.** Prefer the folder the
download call actually *returned* (persisted per variant), then anywhere the weights really
are — **including the broken layout**, so a phone that already downloaded under it adopts the
model instead of fetching again — and only then the canonical path. Surface `bytesOnDisk` in
the picker: "is it cached?" got the wrong answer twice from reasoning about paths, and a size
on screen is a fact.

**Pass `modelFolder` the moment the *weights* exist, not once everything does.** `setupModels`
reads `if let modelFolder { use it } else if download { … }`, so supplying it short-circuits
the weights download entirely and `download` then only governs the tokenizer. Gating on
"weights **and** tokenizer" made the app **download the model twice**: the download call
fetches the weights and then loads, and at that instant the tokenizer is not there yet, so the
check said "not downloaded", took the online path with no `modelFolder`, and pulled half a
gigabyte again. The user watched it download, finish, and start over. Keep `hasWeights` and
`isDownloaded` as **separate questions**.

**Load offline-first, or a phone holding the model still fails on the course.** `WhisperKit`
resolves a variant name against the model index **over the network** before it looks at disk,
so pass `modelFolder` + `tokenizerFolder` and `download: false` whenever the files are already
there. Seen exactly that way in the simulator with the network blocked: the weights were
present and the error was a TLS failure. **The tokenizer is a separate download from a
different repo** and is just as required — it is the half you do not notice until the first
tee.

**Models live in Application Support, not Documents.** `UIFileSharingEnabled` exposes Documents
to Finder and the Files app — the whole device→Mac transfer story for session folders — and
half a gigabyte of CoreML next to them is clutter and an invitation to delete it. A model is a
cache.

**A model must be on the phone before the round, and the picker downloads it.** A course has no
signal; leaving the download to the first tap loses exactly the words the button was pressed
for. `isDownloaded` decides whether the pane says *Downloading* or *Loading* — two very
different waits that look identical if it just says "loading".

### 9.11 The `Transcriber` protocol

```swift
public protocol Transcriber: Sendable {
    static var id: String { get }
    /// `id` plus anything that changes the output — an INSTANCE member, because for
    /// some engines the model is a runtime choice. A cache keyed on "whisperkit"
    /// alone would serve `tiny`'s transcript for a `large-v3` run.
    var runID: String { get }
    /// Times returned are OFFSETS WITHIN THIS FILE. The caller owns the mapping.
    func transcribe(file: URL, context: TranscriptionContext) async throws -> TranscriptionResult
    /// Resolved BEFORE any audio is read — it is what the cache is keyed on.
    func effectiveLocales(for context: TranscriptionContext) async -> [String]
}

public struct TranscriptionContext: Sendable {
    public var locales: [String]              // plural; defaults to en_US + ko_KR
    public var contextualStrings: [String]    // the whole vocabulary (inert on SpeechTranscriber)
    public var names: [String]                // the roster — the ONLY thing reaching a decoder
}
```

`SessionTranscriber` walks the segments, maps clocks per segment, and caches per segment keyed
on `runID` **and the effective locales**. It **reports missing segments out loud** — an
`audio.jsonl` row whose file is gone would otherwise yield a short transcript that looks
complete.

---

## 10. `GolfMap` — the hole view

Two renderers over one model: **`VectorHoleView`** (a SwiftUI `Canvas`, offline, drawn from
the course file) and **`SatelliteHoleView`** (MapKit `.imagery` with vector overlays), both
driven by **`HoleScreen`**, which owns the state and the HUD.

### 10.1 The two-layer rule

**Imagery is decoration and nothing may depend on it being present** — *not for licensing
reasons but for coverage.* Courses have poor cell service and MapKit's cache is opaque and
unguaranteed. So the vector layer carries every number the golfer acts on and works with no
network; the photograph goes underneath when there is signal.

- **Store coordinates, never tiles.** A course file holds coordinates; imagery is fetched at
  display time and cached by MapKit however it likes. That is the *supported* use.
- **What crosses the line is a deliberate persistence step**: `MKMapSnapshotter` writing a PNG
  per hole, or panning the camera over all eighteen on load to warm the cache. That is the
  offline store the terms exclude, and `MKMapSnapshotter` is exactly what someone reaches for
  after reading "cache the imagery". Asked twice by the user and refused twice. If a photograph
  must survive a round with no signal it comes from **public-domain NAIP orthoimagery stored as
  our own asset** — a different feature.
- **Apple's logo and Legal link are not optional, private use included.**
  `.mapControlVisibility(.hidden)` suppresses the compass and scale, **not** attribution. The
  satellite layer takes a measured `bottomReserve` and the comments saying why must stay, or
  the padding reads as dead weight and gets deleted.

**Hand-placing points on Apple imagery is allowed; bulk tracing and redistribution are not.**
A hole placed **by tap** is marked `source: .traced` and **a traced file cannot be published**;
a hole placed from the live fix ("Standing here") is `.survey` and never touches imagery.
Building a course *database* by tracing either provider's imagery is out of the question.

### 10.2 `HoleReadout` — the numbers

```swift
public struct HoleReadout: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case tee(Coordinate), player(Coordinate) }
    public struct Leg: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case toTarget(Int), toGreen }
        public var kind: Kind
        public var from: Coordinate, to: Coordinate
        public var metres: Double
        public var rise: Double?          // PER LEG
    }
    public var origin: Origin
    public var green: GreenDistances      // front / centre / back
    public var legs: [Leg]
    public var rise: Double?              // the APPROACH leg's, read back
    public var riseSource: Elevation.Source?
    public var targets: [Coordinate]
    public var pin: Coordinate?
    public var playerAt: Coordinate?
    public static let onHoleRadius: Double = 150
}
```

- **`origin` and `playerAt` answer different questions.** `origin` is what a distance is
  measured *from* and falls back to the tee when the fix is off this hole; `playerAt` is where
  the golfer actually is. Drawing the map marker from `origin` meant a fix off the hole drew no
  marker at all — so "go to my location" panned to an empty patch of rough, in precisely the
  case the button exists for. Draw from `playerAt`; dim it when `origin.isPlayer` is false.
- **`Leg.rise` is per leg, not one number for the hole.** A layup over a ridge and the approach
  down off it are two different shots. The legs partition the tee-to-green climb exactly.
- **`HoleReadout.rise` is the *approach* leg's, read back rather than derived a second time** —
  two derivations of one number is two numbers that can differ. It is measured **from the last
  waypoint to the flag**, matching `green.center`: a rise from where the golfer stands and a
  distance from their layup target are two halves of two different shots.
- **Front and back stay measured against the green outline** (geometry, which does not move);
  the **approach is measured to the pin** when one has been dragged, and the caption says
  `TO PIN`.
- **A shot-marker leg's rise is sampled in the renderer, and it is the only one that is.**
  Every other elevation number arrives already resolved on the readout; a track leg is not part
  of the plan, so nothing upstream computed it. It is also the only place a plays-like figure
  can ever be checked against a shot somebody actually hit.

### 10.3 `DistanceDisplay` — the one formatter

**VERBATIM — implement exactly.**

```swift
public struct DistanceDisplay: Sendable, Equatable {
    public var unit: DistanceUnit
    public static let `default` = DistanceDisplay(unit: DistanceUnit.assumedWhenUnstated)

    public func value(_ metres: Double) -> Double { metres / unit.toMetres }
    /// Whole units: a decimal implies a precision no GPS fix has, and nobody clubs
    /// off a tenth of a yard.
    public func number(_ metres: Double) -> String { "\(Int(value(metres).rounded()))" }
    public var symbol: String { unit == .metres ? "M" : "YD" }

    /// The elevation suffix that follows a distance: `.~334▲1`
    public func plays(rise: Double?, distance metres: Double, factor: Double = 1) -> String? {
        guard let rise else { return nil }
        // THE ARITHMETIC IS DONE IN THE UNITS THE NUMBERS ARE PRINTED IN.
        let up = (value(rise) * factor).rounded()
        guard abs(up) >= 1 else { return nil }
        let base = value(metres).rounded()
        return ".~\(Int(base + up))\(up > 0 ? "▲" : "▼")\(Int(abs(up)))"
    }

    /// `333.~334▲1`, or just `333` on flat ground. No space: the `.` is the separator.
    public func withPlays(_ metres: Double, rise: Double?, factor: Double = 1) -> String {
        number(metres) + (plays(rise: rise, distance: metres, factor: factor) ?? "")
    }
}
```

Format is `<dist>.<plays like><arrow><elevation>` *(user, 2026-08-30)*. The two distances sit
together because they are the same quantity twice — what it measures and what it plays — and
the rise trails as the *reason*.

- **`~` marks the plays-like number and nothing else.** The rise is *measured* (lidar, 10 cm
  spec); the plays-like figure is a model. Same mark a measured length standing in for a card
  number gets: a different quantity, not a substitute. It also stops `333.334` reading as a
  decimal.
- **The arithmetic must be done in display units.** Doing it in metres and rounding afterwards
  puts three numbers on screen that **do not add up**: a 0.49 m rise over 164 m rendered
  `180 ▲1 · ~180`, because the rise rounds *up* to a yard while the plays-like distance rounds
  *down* to the same 180. Found by screenshot; it reads as an arithmetic error in the app, not
  as rounding. Since the model is 1:1, rounding first makes `distance + rise = plays like`
  exact on screen, always.
- **Nil when the rise rounds to nothing.** `▲0 · ~353` beside `353` is three claims that all
  say the same thing. Nil is what makes the suffix mean "this shot is not flat".
- **No number on the hole carries its unit** *(user: "No YD")*. It is stated once, in the
  caption under the big distance — `YARDS TO GREEN`.
- **The suffix is inline on the distance, in four places, and there is no capsule** — the big
  distance, **both** target legs, and the leg between two shot markers. The orange pill it
  replaced was a second object saying something about a number three lines above it, which the
  eye had to join up.

**The big distance stays centred whatever the suffix does, and the suffix is placed by
arithmetic.** An `HStack` centres the *pair*, so the one yardage a golfer reads at a glance
slid sideways the moment a hole stopped being flat. Draw the number alone and hang the suffix
in an `.overlay` offset by a **measured monospaced advance**:

```swift
let bigSize = 68.0, subSize = 20.0
let gap = 0.0
let bigWidth = Double(text.count) * PlanLayout.advance * bigSize
let subWidth = Double(plays?.count ?? 0) * PlanLayout.advance * subSize
Text(text)
    .font(.system(size: bigSize, weight: .bold, design: .monospaced))
    .overlay(alignment: .center) {
        if let plays {
            Text(plays)
                .font(.system(size: subSize, weight: .semibold, design: .monospaced))
                .fixedSize()
                .offset(x: (bigWidth + subWidth) / 2 + gap, y: bigSize * 0.22)
        }
    }
```

The obvious `.overlay(alignment: .bottomTrailing)` with the child's `trailing` guide resolved
at its own `leading` — which should sit it just outside — landed it **on** the number instead:
screenshotted, `.~97▼4` written across the `1` of `101`. **The gap is zero**, because a
20-point `.` beside a 68-point digit already has that glyph's right sidebearing between them
and anything more orphaned the dot.

**Verified by measurement, not by eye:** the same hole rendered with the `.dem` removed and
with it puts the big number's left edge at **35.24%** and **35.27%** of screen width —
identical inside a third of a pixel, against **21.98%** on the `HStack` build.

### 10.4 `PlanLayout` — the leg labels, and the measured advance

```swift
static let advance: Double = 0.618      // em, measured — NOT 0.6
```

`NSFont.monospacedSystemFont` reports **0.618 em** for every glyph these labels use, `▲ ▼ · ~`
included (so none of them falls back to a proportional face). At the estimated 0.6 the box ran
3% narrow: absorbed by the padding at three characters, not at thirty. **It is load-bearing in
three places** (leg boxes, hit-testing, the big-distance overlay), so pin it with a test
against the real face at 14, 20 and 68 points — a wrong value silently overlaps rather than
failing a build.

`PlanLayout` places the leg distance boxes, and **drawing and hit-testing both go through it**:
the box *is* the drag handle for its target (a 28-point ring is a poor thing to catch with a
gloved thumb), so the rectangle filled and the rectangle tested must be the same rectangle. It
measures text arithmetically rather than through `GraphicsContext.resolve` because the gesture
has no context; a monospaced advance is fixed, so the estimate is exact enough to *be* the
definition.

The approach leg's box anchors at the **target** end of its line, not the flag end, or it reads
as a label on the green rather than on the shot. Labels de-collide against each other **and**
against the target rings.

**On the plan legs the box grows with the text**, which is required rather than tolerated: the
rectangle drawn is the rectangle the drag gesture tests, so a suffix roughly triples it and it
stays the handle for its target.

### 10.5 Style constants

```swift
public var targetRadius: Double = 13        // what an eye gets
public var grabRadius: Double = 39          // what a FINGER gets — 3x, same on both layers
public var markerGrabRadius: Double = 17    // a marker gets the size of what is drawn
public var markerGrabRise: Double = 34      // the handle reaches AWAY FROM THE LABEL
public var markerLabelGap: Double = 14      // pill clears its own 11-point dot
public var shotLineWidth: Double = 1.5      // ONE constant; neither renderer has an opinion
public var fairwayWidth: Double = 52        // METRES — scales with the hole
public var cartPathWidth: Double = 3        // metres, so it stays honest at 40x
public static let playerColors: [Color]     // 4, separating against fairway AND imagery
public static let measureColors: [Color]    // a SEPARATE set — see below
```

`MarkerDisplay` is a **tri-state**: `on` / `ghost` / `off`, defaulting to **ghost**, behind its
own preference key (the old boolean key must not be read as a string). `ghost` is `opacity 0.8`
and `allowsHitTesting(false)`.

- **Ghost is the point.** A hole carries a dozen entries, each with a handle, and every one is
  something a finger can pick up while reaching for a target. Off answers that by throwing the
  information away; ghost keeps what happened on the hole readable and takes it out of every
  gesture. **Half-transparent is the only signal that the layer has stopped responding**, so the
  dimming is load-bearing.
- **0.8, not 0.45** *(user, 2026-08-30)*: at 0.45 the readability half was losing.
- **The tracks dim with it** — a full-strength line between two faded pills says the pills are
  what was switched off.

`fairwayWidth` and `cartPathWidth` are **metres, not points**, so a par 3 and a par 5 read the
same and a cart path does not swell into a road at 40×. A `trackWidth` in metres once sat
beside a points-based one — two numbers called the same thing in two different units.

### 10.6 Gestures — the hole view has exactly one drag, and it classifies itself

**Four competing gestures (drag, magnify, double-tap, tap) is what shipped first, and SwiftUI
resolved the arbitration in the tap gestures' favour — a drag starting on a target never
reached the handler, so nothing on the hole could be moved at all.**

Now: a single `DragGesture(minimumDistance: 0)` deciding tap / hold / move-marker / pan from
where the finger went down and how long it stayed, with only a two-finger `MagnifyGesture`
alongside. **Do not add a fifth** — "Fit hole to screen" lives in the pin menu for this reason.

The two that remain still overlap, and that broke the zoom outright:

> The magnify gesture and the drag are `simultaneousGesture`, so a pinch drives **both**. The
> first finger travels far past the slop, the drag calls itself a pan, and the pan branch
> rebuilt the viewport from `panStart.zoom` — the zoom from *before* the pinch — on every
> callback. The two wrote alternate frames and the zoom went nowhere, which would have looked
> identical at any ceiling.

`pinchBlockedDrag` stands the one-finger gesture down **for the rest of the touch** — cleared
when the finger **lifts**, not when the pinch ends, because a drag's translation is measured
from where that drag began and resuming mid-touch jumps the hole by however far the fingers
travelled — and that touch ends with no tap, no move and no confirmation. The pan branch keeps
`viewport.zoom` rather than `panStart.zoom` as the belt.

**A retired gesture is not retired until the branch that reads it is gone.** Press-and-hold was
removed but `onHoldGround` stayed on both renderers with nothing passing it, so
`held ? onHoldGround?(c) : onTapGround?(c)` meant **a deliberate slow tap on open ground placed
nothing at all**, and the satellite layer's long-press swallowed every long press to call a nil
closure. A dead callback here is not dead code — it is a control that silently stops working.

Draw order and hit order:

- **Drawn is tested.** The simulated position is drawn last and picked up **first**; markers are
  drawn low and tested **last**, and a tap that hits a marker still falls through to the ground.
- **The one deliberate exception is the flag**: it is drawn last but *not* tested first, because
  the green is where a golfer taps to place a target and a flag that took those taps would be
  worse than one needing a second attempt to pick up.
- **Shot layer order: lines and their numbers, then the dots, then the markers.** A shot marker
  is a numbered circle and the number is what *identifies* the dot beneath it, so a track line
  drawn across it makes the one unreadable thing on the hole the one thing the layer exists for.
  Everything a golfer is about to **act on** — the plan, the rulers, the player, the flag — is
  drawn after the markers. Vector does this in **three passes**, not one loop, so the order
  holds *between* players.

**A drag holds the gap between the finger and the object** (`DragAnchor`). Setting the object's
centre to the fingertip on the first gesture event is *placing*, not dragging: picking a target
up moves it before the drag starts, and nudging something by less than the grab offset becomes
impossible. Measure once on finger-down, derive every later position from it. **Both layers do
this**; the satellite one works in degrees because `MapProxy` is what projects there.

**A control that is invisible is indistinguishable from one that does not work.** The target
drag handle was three times the ring and completely undrawn, and was reported as broken. Draw
it at **5% fill** — enough to find with a thumb, not enough to compete with the numbers — and
as **area with no edge**: an outline reads as an object in its own right and competes with the
ring it sits behind.

**A target's drag handle is an invisible circle three times the drawn ring, concentric with
it.** The distance box was tried as the handle and is worse: the box is repositioned as its
number changes, so the handle crawls out from under the thumb mid-drag. **Anything that moves
while being dragged cannot be the thing you drag.**

### 10.7 Targets, rulers, the flag

- **Tap places, tap-on-a-target removes, nothing is ever auto-placed.** Tap won the category in
  the prior-art review and removal is undocumented in all of it; one competitor auto-placed its
  crosshair into a grove of trees, which is why there is no default target.
- **Two is the cap. Tap owns target 1, press-and-hold once owned target 2 — now a button does.**
  Fixed slots, not "next free": a tap must never surprise anyone with a second target, and the
  first must stay adjustable with the cheapest gesture.
- **Distances are measured from the *last target*, not from the player** — otherwise the target
  is decorative.
- **A leg's distance is drawn on its own line, near the target end.** A number floating in a
  strip at the top has to be matched to its line by eye every time it is read.
- **A `MeasureSegment` is not a target and must not become one.** A target is a point a shot is
  aimed at; a ruler is between two arbitrary points and has nothing to do with where the golfer
  stands. Folding it in would put a point in the shot sequence that is not a shot. It is laid
  **square to the line of play**, not east–west, or it sits at a different angle on every hole.
  Its label is its dismiss control **and its drag handle** — the one place the "a distance box is
  a bad handle" rule does not apply, because a ruler dragged by its box is translated **rigidly**,
  so the length and the box width are identical at the end of the drag and at the start. **Each
  ruler carries its own `colorIndex`**, never derived from its position in the array, or
  dismissing one repaints every ruler that outlives it. A separate palette from the players':
  a ruler in a player's colour reads as that player's track.
- **The flag is draggable, and it is an `Event`, never the course file.** A pin is cut fresh
  every morning, so it is a fact about *this round*. **The drag is drawn from local state and
  written once, on release** — reporting from `onChanged` appends a row per gesture callback and
  one two-second adjustment leaves a hundred `pin placed` lines in the stream. No confirmation,
  unlike a marker: a pin is cheap to correct by dragging it again.
- **`flag.fill`'s anchor is measured, not a corner.** `.bottomLeading` is the corner of the
  *box*: the glyph has padding on every side and the staff sits a few points in from the left,
  so the flag stands short of the hole. Rendered at 60 pt bold the symbol is 69 × 70 with ink
  from x 8…62, y 6…64 and the staff centred on x 11.5 ending at y 64 → **(0.167, 0.929)**.
  **Nothing may pad the glyph**, because the fraction is of the rendered box.

### 10.8 Framing, and what must stay out of the fit

**The hole's framing is fitted to the hole, its tees and the round's shots — never to the
player or the targets.** Both of those are placed *by looking at the screen*, so they are
already on it. Feeding them to the fit caused three separate reported bugs at once: dragging a
target re-fitted the plane so the hole slid the opposite way to the finger; dragging the
simulated player did the same; and a fix off the hole shrank the hole toward a dot to keep a
point in another county in frame.

Same rule, arriving by other roads:

- A `PlayerTrack` is **filtered to the hole on screen** before its points reach the fit — a shot
  logged on the ninth would shrink this hole to a dot.
- A closing leg's **pin end is kept out of `allPoints`** — harmless today because a pin sits on a
  green, which is exactly how a stray point gets in and stays.
- The **focus ring** marking where a log was said is **panned to, never fitted to**.

### 10.9 Markers, tracks and the legend

```swift
public struct PlayerTrack {
    public struct Shot { public var number: Int?; public var at: Coordinate }
    public var id: String, name: String, colorIndex: Int
    public var shots: [Shot]
    public var nextShot: Int?
    public var aiming: Coordinate?
    public var score: Int?                       // non-nil == holed out
    public var shotsTaken: Int? { nextShot.map { max(0, $0 - 1) } }
}
```

- **A track starts at shot 1, not at the tee.** Prepending the tee drew a leg from the tee box
  to wherever the drive finished: the one leg on the hole nobody logged, in the same weight as
  the legs that were. A one-shot player draws no line — a line needs two ends. **The half that
  had to go with it:** both renderers drew the dots as `shots.dropFirst()`, which existed
  *only* to skip the tee, so leaving it erased shot 1's dot on both layers.
- **`shots` is `[Shot]` with a number on each, ordered by shot number, not by time** — the
  numbers are what a person assigned.
- **Only a leg between *consecutive* shots carries a number.** A leg from 2 to 3 *is* a shot and
  its length is how far it went; a leg from 1 to 3 with no 2 measures nothing anybody played.
- **A closed-out hole runs its track into the flag** — to `pinAt` as dragged today, not the
  green's centre, since that is where the ball went. It carries a number **only when
  `shots.last?.number == score`**: the two agreeing means exactly one shot spans marker to cup.
- **A marker is drawn only on the hole it belongs to.** They were drawn wherever their
  coordinates put them, so a hole running back alongside the previous one carried the previous
  one's captions. **A row with no hole is still drawn on every hole** — it could not be placed,
  so it belongs to all of them rather than to none.
- **A marker's label sits *under* its point; the handle reaches the other way.** The rule is
  *away from the label*, so a fingertip is never on top of the thing being dragged. Flip one
  without the other and the handle lands back on the label. Clash stacking goes **downward** and
  the leader line runs **up**.
- **A shot marker is a numbered circle and that is all** *(user, 2026-08-30)*: `ShotName.of(shot)`
  and nothing else — no club icon, no name; the colour and the legend already say who. It keeps
  the pill's height, because the satellite annotation's anchor is computed from it.
- **A dragged shot carries its track with it** — the pill and the track through it are two
  drawings of one row. Substitute the in-flight position **matched by coordinate**, which is the
  only key there is.
- **A dragged marker is confirmed on release, and only if the finger went somewhere.** The
  confirmation was raised from `onChanged`, so it appeared on the first pixel and asked about a
  point the finger had already left. **While the confirmation is up, the proposed position is
  drawn as a proposal** — a hollow ring on a dashed tether — because nothing is written yet.
- **The confirmation is a strip in the layout, not an alert and not a `confirmationDialog`.**
  The question is whether the entry is now in the right place, and an alert lands in the middle
  of the display over the pill, the hole and the numbers — over everything that answers it.
  `confirmationDialog` on iOS 26 comes up as a centred card of much the same size: the same fault
  in a different shape.

**The legend is a column of switches, one per player**, bottom left, a third of the width, hard
against the edge. Always drawn, because it is the round's **roster** and not a key to what
happens to be on this hole. **Keyed on `PlayerTrack.id`, never on `colorIndex`** — the colour
index is a roster *position*, and a removal slides everyone after it down a slot, so a set of
indexes would go on hiding "slot 1" and silently start hiding a different person. **A hidden
player is drawn switched off, never removed** (hollow swatch, dimmed name, struck through):
dropping the row takes away the control that brings them back. **Not persisted** — hiding
somebody is something a golfer does to read one hole. The plate behind a switched-off row
**does not dim**: dimming made the row look disabled when what is off is the player's markers.

**The number on the right is that player's next shot, and tapping it files one** where the
golfer is standing — simulated position first, then the round's fix, then the view's feed. **The
button is dead without one, visibly**: its whole meaning is "where I am standing", so the number
still shows and stops being a button.

### 10.10 `ShotName` — named on screen, numbered in storage

```swift
public enum ShotName {
    public static func of(_ n: Int) -> String { n <= 1 ? "T" : "\(n - 1)" }
}
```

Nobody calls the drive "shot 1" — it is the tee shot. Stored 1, 2, 3, 4 displays as T, 1, 2, 3,
in **both** places a shot number is rendered. **Storage is deliberately untouched** (§3.8).

**The legend prints shots *taken*; the button files the *next* one.** `shotsTaken` is
`nextShot - 1` and **not** `shots.count` — a shot with no position is not on the track and still
counts.

**Holing out is *having a score*, not a flag.** A local flag dies on relaunch, never reaches the
scorecard, and makes the golfer write the same number twice. So `score` is the state, reported
through a journal act, and **nil is reopen**. **The number committed is the one already on
screen**: the cell shows the next shot's *name*, so a player reading `3` has played T, 1 and 2
and scores 3. It follows that **the `T` state cannot hole out** — nothing has been played — so
the swipe is refused there and **the chevron is not drawn**, because an affordance for a refused
gesture is worse than none. A hole in one costs one tap first. `+0` prints **literally**, never
`0` or `E`: the sign is the only thing telling "two shots so far" from "two over par" in a cell
that shows both.

### 10.11 Two SwiftUI facts that cost real time

- **`ImageRenderer` cannot draw a SwiftUI `Menu`, a `List`, or a MapKit `Map`.** All come out as
  a yellow prohibition box. Proven, not assumed — the same SF Symbol renders correctly outside a
  `Menu`. So screens are reviewed by **screenshotting the real app in the simulator**, which is
  closer to the truth anyway. Do not chase it as a bug.
- **`Text` parses markdown only from a `LocalizedStringKey`, so `"a" + "b"` does not.** A
  concatenated footer rendered `**United States only**` as literal asterisks. One literal fixes
  it. Caught by screenshot, which is the only way it could have been.

Two more that present as SwiftUI runtime warnings:

- **A measured length is assigned only when it actually changed.** Several measurements feed back
  into the layout they were taken from, and a value settling a hundredth of a point from itself
  oscillates forever — reported as `AttributeGraph: cycle detected`. Guard on half a point.
- **A one-shot command binding is cleared on the next turn, never inside its own `onChange`.**
  Writing a `@Binding` back to the parent's `@State` from within an `onChange` of that same
  binding is a self-referential update. Hop through `Task { @MainActor in }`.

And two that are type-checker budget, not style:

- **`CourseView.body` and its `HoleScreen` call are both at the budget.** The call needs
  pre-typed locals **in declaration order** or it fails outright with "unable to type-check this
  expression in reasonable time"; adding one more `.sheet` to the body tipped that over too. The
  fixes are **structural** — pull the call into its own function, move the sheet into a
  `ViewModifier` — not a reordering of arguments.
- **A `@ViewBuilder` slot needs `extension … where Bar == EmptyView`** for the no-bar
  initialiser: a **default argument does not take part in generic inference**.

### 10.12 Menus and identity

- **The pin menu is `Equatable` and split into its own view.** The hole screen is handed a
  tracking state that changes on every fix and on a five-second ticker, and the hole is one view
  body — so each redrew the subtree the `Menu` lives in, SwiftUI tore the open menu down and put
  a fresh one up, and the golfer lost whatever they were reaching for. **Its closures are
  excluded from `==` on purpose**: they are new objects on every parent body evaluation and would
  make it always-unequal, which is safe because each only reads current state when it runs.
- **`HoleScreen` needs `.id(course.id)` at its call site.** It seeds the hole index and the
  remembered tee in `init`, and a `@State` initial value applies once per view *identity* — so
  switching course keeps the same identity, `init` never re-runs, and the previous course's tee
  carries over **unvalidated**. The hole index does the same: hole 14 of an 18 renders "no holes
  in this course" on a nine.
- **The hole view remembers the tee per course; it does not remember the hole.** The tee key is
  per course id and is **validated against the course's own tee names on load** — a single global
  tee name applies "Black" to a course that has none, and then §4.5 correctly returns nil and the
  screen loses its yardages with nothing saying why. The hole is deliberately not remembered: the
  map button opens the hole the card is on.
- **The top inset comes from the status-bar manager, not `safeAreaInsets.top`.** The view ignores
  the top safe area so the distance can run through the navigation bar's band to the edge of the
  display — which is exactly what makes the proxy report an inset of zero. **The nav bar is made
  transparent, never hidden**: hiding it takes the back button and the course switcher with it.
- **The bottom reserve is measured**, and it is Apple's attribution reserve. A constant goes
  stale the first time a bar gains a row, and the symptom is a covered logo and Legal link — a
  licence problem, not a visual one. The HUD measurement covers the legend **and** the move
  confirmation as one block: two separate measurements would need two rules about which is stale.

### 10.13 Simulated position

**MARK is disabled while simulation mode is on.** A dragged position is not a fix, and
`marks.jsonl` is ground truth **and** the eval answer key. Disabling by construction beats a
`simulated` flag every consumer must remember to filter — one that forgets corrupts an accuracy
number silently.

**The marker is visually unmistakable — orange, dashed, a golfer glyph — and that styling is now
the *only* on-screen signal**, since the banner that used to say so was removed. Do not tidy the
orange dashes away as leftovers. **The accuracy ring is nil while simulating, refused in three
places at once**: a hand-placed point has no accuracy, and a ring around one would draw a
measurement nobody took in the language of one somebody did.

**It re-seeds on every switch-on, from what is *visible*: the tee if it is on screen, otherwise
the middle of the map area.** It used to seed from the phone's fix — wrong in exactly the case
simulation exists for. The visible region is reported **up** from whichever renderer is drawing
and is a **quad, not a lat/lon box**: the vector layer rotates the hole, so a box around a
rotated screen calls a tee visible while it sits off the corner. Never re-derived in the parent —
a second copy of the transform is a second answer that can disagree with the one on screen.

**A simulated position *is* used for a log, and that is a knowing trade.** Simulation exists to
try the app somewhere other than where the phone is, so a log recording the desk would make the
mode useless. The consequence: a hand-placed coordinate sits in `log.jsonl` looking exactly like
a measured one, because `LogEntry` has no discriminator. `Mark` is protected by the rule above; a
log is not, because a log is an observation rather than ground truth.

**Three mechanisms for making the simulated marker win the touch on the satellite layer have been
tried and reverted.** The findings survive and are the reason not to try a fourth without
something new: `_MapKit_SwiftUI` has **no z-order API for an `Annotation`** (checked against the
iOS 26.5 interface — `mapOverlayLevel` applies to `MapPolygon`/`MapPolyline` only); MapKit decides
annotation stacking for itself, so declaration order is not a guarantee; an annotation *added
later* does land on top; and **none of that touches the gesture** — a pill carries its own
`DragGesture` on a `contentShape`, so it takes the touch whatever is painted above it. Moving it
out of the map into a `ZStack` overlay wins the touch and **loses camera tracking through a pan**,
which is worse: a marker that lags the ground it claims to be on. The **vector** layer orders
drawing and hit-testing explicitly and has never had the problem.

### 10.14 The satellite layer's own floors

**The zoom floor is `MapCameraBounds(minimumDistance:)` and has nothing to do with `HolePlane`.**
The 40× ceiling is the *vector* layer's own arithmetic; MapKit has its own camera and its own
floor. It is **12 metres** here — about a ten-yard span. Verified by pinning the camera to 12 m
and screenshotting: the camera goes there, **the imagery blurs** past its tile detail and the
vector overlays stay sharp. That is the honest limit, and it is the two-layer design's own
argument — the photograph runs out, the numbers do not.

**"Go to my location" works on satellite too** — the command had been driven for as long as the
button existed and **only the vector layer ever read it**, so on satellite the menu item did
nothing at all, silently, which reads as the app not knowing where the phone is. Move the camera
and **leave the zoom alone**: the golfer chose that zoom, and re-framing on the way to a position
answers a question nobody asked. Target `playerAt`, never `origin` (§10.2).

**On satellite a marker pill is anchored `.bottom`**, so it sits above its point; centred on the
coordinate it covered the very thing it is a claim about.

### 10.15 `TeePalette` — a tee's colour comes from its length order, not its name

Resolve longest-first: a colour name wins; a set with no colour names gets the standard ramp
(black → blue → white → green → gold → red); and a non-colour tee among colours **blends its
neighbours** — "Members" between blue and white is blue-white, which never collides and reads as
"between those two". **Outline colour is picked from fill luminance**, or `white` vanishes on a
light green. The palette reads its names from `TeeBox.standardRamp`, so the ramp and the paint
cannot drift.

### 10.16 The course overview

A MapKit `Map` on `.imagery` with pan, zoom and rotate — **overruled from an earlier
vector-only, gesture-less version** *(the "imagery would be unreadable" argument was wrong)*.
**What survives the overrule is the coverage rule**: the centre lines, tees, pins and numbers are
all vector overlays drawn from the course file, so a course with no signal loses the photograph
and keeps every hole, every number and every tap target.

**Nothing is laid over the bottom of it** — Apple's logo and Legal link live there. The region
span is **floored**, or a file with one placed hole frames a zero span. **The thing naming a hole
is the thing you tap to go there** — the same decision the scorecard makes, and why neither
screen needs a hole picker.

---

## 11. The scorecard card — import and reconciliation

A card gives **par, stroke index, per-tee yardage, rating and slope**, and never a coordinate.
It comes off a course's own web page or a photograph at the tee.

```swift
public struct CourseCard: Codable, Sendable, Hashable {
    public struct Tee { public var name: String; public var distance: Double?
                        public var rating: Double?; public var slope: Int? }
    public struct CardHole { public var ref: String; public var par: Int
                             public var handicap: Int?; public var handicapWomen: Int?
                             public var tees: [Tee] }
    public struct Nine { public var name: String?; public var holes: [CardHole]
                         public var printedPar: Int?; public var printedTees: [Tee] }
    public var courseName: String, aliases: [String]
    public var unit: String                   // "metres" | "yards" | "unknown"
    public var nines: [Nine]
    public var notes: String?

    public func resolveUnit(preferring override: DistanceUnit? = nil) -> (DistanceUnit, UnitSource)
    public func unitWarning() -> String?
    public func course(id: String, source: Course.Source = .card) -> Course
}
```

### 11.1 The unit cannot be inferred, and that was measured

**A card's distance unit is usually not printed, and it cannot be recovered from the numbers.**
Six real cards, sorted by length per par: **the one metric card sits *between* two imperial
ones**, and an ordinary American middle-tee set sits below all of them. **No threshold separates
them.** An earlier "infer it from the total, refuse in the ambiguous band" design **refused the
modal American card while still mis-reading the metric one**.

So:

- `TeeBox.distance` is **always metres**, normalised once at import.
- The unit is resolved `--unit` → **printed on the card** → **`assumedWhenUnstated = .yards`**.
- An assumed unit is **announced as assumed**…
- …and then **falsified** by `HoleGeometry.lengthDisagreement` the moment a tee and green are
  placed: a metric card read as yards is 9.4% short, far past the 25 m flag.

**Do not try to make the inference smarter.** That was measured and it does not work.

### 11.2 An American card has two stroke-index rows

Men's and women's are different allocations and **both are valid 1…18 permutations**, so a
single `handicap` field picks a column and nothing downstream can tell. `Hole.handicap` is the
men's row (or the only row), `Hole.handicapWomen` the second; **both are permutation-checked
separately.** `TeeBox.rating` / `.slope` capture the USGA numbers every American card prints —
**not a unit detector**, since metric cards carry them too.

### 11.3 `CardText.strip` is correctness code, not plumbing

A real card writes hole 4's stroke index as `1<span class="style1">7</span>`. Replacing inline
tags with a space splits it into `1 7`, shifts the whole row, and **still yields eighteen
plausible numbers**. So:

1. Inline tags are **deleted**, not replaced with a space.
2. Source whitespace is flattened **first**.
3. `</td>` / `</tr>` become tabs and newlines **before** the tags are gone, so an empty cell
   stays an empty column.

### 11.4 Reading a photographed card

OCR → text → a model, in that order, and:

- OCR output is arranged as a **grid** — bucketed into rows by vertical position, tab-separated —
  because a card is a table and `VNRecognizeTextRequest` returns a flat reading order. Same
  reason `CardText.strip` preserves columns.
- **`usesLanguageCorrection` off**, because it invents plausible readings of smudged digits.
- **It produces proposals, never writes.** A card read off a photograph is 95% right and silently
  wrong in one cell, and the card is the answer key.
- **`CardReading.match` is fuzzy and never positional, and a row matching nobody keeps its own
  name.** Case- and whitespace-insensitive first, then containment in both directions ("Steve J"
  on the card against `steve` on the roster, and the reverse). Deliberately **not** edit distance:
  at these lengths it starts pairing "min" with "kim", and a wrong pairing files a whole round of
  scores under the wrong person. Row order on a card has nothing to do with roster order.
  A row that matches nobody comes back with a nil `player` rather than being dropped — a card read
  that silently loses a person looks like a card with three players on it. With one name per player
  (§3.3), a card written in the other script than the roster is exactly that case; the *prompt*
  still asks the model to allow misspellings, a nickname and a different script, so the model gets
  the chance our own matcher cannot take.

### 11.5 The scorecard on screen

`CardLayout` and `CardYardage` live in the **package**, because both have a way of being quietly
wrong on screen and exactly right in a screenshot.

- **Out / In assumes holes numbered 1–18**, which is what `Hole.ref` is not. Named nines win when
  a course has them.
- **`cardLength(from: nil)` means "the default tee", not "no tee".** So the obvious
  `hole.tee(named: name).flatMap { … }` prints the *longest* tee's yardage under a heading naming
  a tee the hole does not have — an ordinary-looking number, a club and a half wrong.
  `CardYardage.of` returns `.none` for a tee that is absent. Caught by a test, not by reading it.
- **The yardage row is empty on an OSM course, which is every course file that exists.** A
  measured centre line is offered instead and is **marked with `~`** — a different quantity, not a
  substitute (one real hole: 469 yd on the card, 426 measured, because nobody carries the corner
  of a dogleg).

---

## 12. `AnthropicClient` and `GolfReconstruction`

### 12.1 The client

**Swift has no official Anthropic SDK**, so this is raw HTTPS to `POST /v1/messages`.

```swift
public struct AnthropicClient: Sendable {
    public struct Config: Sendable {
        public var apiKey: String
        public var baseURL: URL              // https://api.anthropic.com
        public var version: String           // anthropic-version header
        public var timeout: TimeInterval
        public static func fromEnvironment() -> Config?   // ANTHROPIC_API_KEY
    }
    public struct ModelConfig: Sendable {
        public enum Thinking: Sendable { /* off | adaptive */ }
        public var model: String = "claude-opus-5"
        public var maxTokens: Int = 16_000
        public var thinking: Thinking
        public var effort: String?
    }
    public enum Content: Sendable { /* text, image, pdf */ }
    public struct Message: Sendable { public var role: String; public var content: [Content] }
    public struct Response: Sendable {
        public var id: String, model: String, text: String
        public var stopReason: String?
        public var inputTokens: Int, outputTokens: Int
    }
}
```

Supports text, image and PDF blocks, `output_config.format` JSON schema, adaptive thinking, and
refusal detection.

**`AnthropicClient` knows nothing about golf.** Messages, model config, JSON schema. No golf
types cross into it.

> If you are rebuilding this with an AI assistant: **do not write model IDs or pricing from
> memory** — they drift. Check current documentation. `claude-opus-5` and adaptive thinking
> (`thinking: {type: "adaptive"}`) were current when this was written.

### 12.2 `GolfReconstruction`

Built: `LogExtraction` (instructions, per-hole prompt, `Proposal` → a `.model` `Event`) and
`CardReading`. Both are **deliberately model-agnostic — no Apple-framework imports** — which is
why both survived the on-device scrap intact.

**Prompt and schema resolve from `--prompt` / `--schema` file paths, never `Bundle.module`.**
Bundle resources force a rebuild per prompt edit; paths keep tuning to edit-and-rerun. This is
why the target declares no `resources:`.

**The glossary is injected, never imported** (§9.9).

The cloud pass that would drive `LogExtraction` **is a placeholder**. See §15.

---

## 12.5 `GolfExchange` — exporting a round and importing it back

One round, complete enough to put on another phone: its every stream **plus the course
file and that course's terrain**, as one document that survives a copy and a paste.

### 12.5.1 What is in a bundle, and what is not

```swift
public struct RoundBundle: Codable, Sendable {
    public static let formatName = "marker.round"
    public static let currentVersion = 2

    public var format: String, version: Int
    public var exported: Millis          // when the ARCHIVE was made, not the round
    public var generator: String?
    public var round: Round
    public var course: CourseData?

    public struct Round: Codable, Sendable {
        public var meta: SessionMeta
        public var logs: [LogEntry]      // EVERY row: superseded and tombstoned included
        public var events: [Event]
        public var gps: [GPSFix]
        public var motion: [MotionSample]
        public var altitude: [AltitudeSample]
        public var audio: Audio
        public var groundTruth: GroundTruth
    }
    public struct Audio: Codable, Sendable {
        public var segments: [AudioSegment]
        public var filesIncluded: Bool   // always false in v1
    }
    public struct GroundTruth: Codable, Sendable {
        public var journal: [JournalEntry]
        public var scorecard: Scorecard?
        public var marks: [Mark]
        public var corrections: [Correction]
    }
    public struct CourseData: Codable, Sendable {
        public var course: Course
        public var elevation: Elevation?
        public var terrainOmitted: Bool     // stored `Bool?`, nil when false — see below
    }
    public var modelVisible: RoundBundle    // the archive with its answer key removed
}
```

Six decisions, each of which the obvious version gets wrong:

- **The journal travels, so the scores do.** `scorecard.json` is *derived* from
  `journal.jsonl`, so an archive carrying only the card comes back as a round nobody can
  undo an edit on. Both are carried: a round played before the journal existed has no
  journal, and then the snapshot is the only record there is.
- **`groundTruth` is a nested object, not four fields spread through the round.** This is
  the firewall, made structural: `marks`, `corrections`, `journal` and `scorecard` are the
  answer key, so stripping them must be one line and a reader must be able to see where the
  line is. `modelVisible` does it — and it also runs `Event.modelVisible(_:)`, because
  `events.jsonl` is mixed provenance and a `.user` event is ground truth on the same stream
  as the proposals.
- **`RoundBundle` is not `RoundExport`, and they must not merge.** `RoundExport`
  (§3, `GolfSessionFormat`) is what the Copy buttons put on the clipboard **for a model**:
  logs and events, nothing else. `RoundBundle` is the archive and is **not safe in a
  prompt**. The separation is also structural — `GolfReconstruction` does not depend on
  `GolfExchange` and cannot import this type at all.
- **Logs go out raw.** Read with `readAll`, never `LogEntry.current(_:)`. A supersede chain
  *is* the history — the sentence as first heard, the coordinate that converged fifteen
  seconds later, the name the golfer corrected — and collapsing it throws away every
  labelled error the eval set is made of, so the round comes back looking like it was right
  the first time.
- **The audio index travels; the `.m4a`s do not.** The rows are the round's clock:
  `LogEntry.tEnd` resolves against them through `AudioSpans`. The recordings are tens of
  megabytes and this has to survive a paste. `filesIncluded` says so out loud rather than
  leaving a reader to infer it from an absence — the same rule `TranscriptCoverage` follows.
- **Terrain is optional, and leaving it out is *stated*.** See §12.5.1a.

### 12.5.1a Terrain is the optional half, and its absence has two meanings

`RoundArchive.bundle` takes `includeTerrain: Bool = true`; false drops the grid and sets
`CourseData.terrainOmitted`. **On by default**, which is the full round-trip the format was
asked for — terrain is the part that *may* be dropped, not the part that must be asked for.

Terrain is nearly the whole cost of an export. Measured on the two real courses:

| course | with terrain | without | grid |
|---|---|---|---|
| Corica Park South (10 m of relief) | 171 KB | 50 KB | 282 × 668 |
| Coyote Creek Tournament (133 m) | 422,882 chars | 33,157 | 570 × 507 |

It is also the one part of a bundle the receiving side can go and fetch for itself, from a
public-domain source, which is the whole argument for making *it* the optional part.

Four rules, all of which the obvious version gets wrong:

- **`nil` elevation now answers two questions, so the flag is carried.** *This course has
  no terrain* (the ordinary case — nothing outside the United States has any) and *this
  export does not carry it* are different facts, and only the second is actionable: open
  the course menu and download it, **before** the round, because a course has no signal.
  Same rule as `Audio.filesIncluded` and `TranscriptCoverage.locales`.
- **Stored `Bool?` behind explicit `CodingKeys`, read non-optional, and written back as
  nil when false — and therefore it did **not** move `currentVersion`.** The `Hole.paths` rule
  (§7): a missing key for a non-optional property is a *decode failure*, so a plain
  `var terrainOmitted: Bool` would make every export already on a clipboard unreadable.
  Writing it back as nil keeps an ordinary export byte-identical to what format 1 always
  produced, so the version must not move: `isSupported` is `version <= currentVersion`, so a
  bump would make an older build refuse, with "update the app", a document it can read
  perfectly well. **The rule that decides a bump is which direction breaks.** An *added* key
  is invisible to an older reader — never bump. A *removed non-optional* property is a hard
  break: the older reader hits `keyNotFound` and reports a missing field of ours, which is
  exactly the confusion the `Envelope` probe exists to prevent, arriving from the other side —
  always bump. The format is at 2 for that second reason, and every v1 document still reads.
- **It cannot contradict `elevation`.** `RoundArchive.bundle` derives it —
  `terrainOmitted: !includeTerrain && elevation != nil` — and `CourseData.init` refuses it
  outright when a grid is present. A course that never had terrain is not an omission.
- **`Report.TerrainOutcome.omitted` fires only when the receiving side ends up with no
  grid.** Four cases: a grid arrived → `.written`; one is already here → `.kept` (the
  omission cost nothing, and a check that cries wolf about a course that is fine is a check
  nobody reads); nothing anywhere and none was carried → silent; **left out and none here →
  `.omitted`**, which is the one line worth printing, because the plays-like chip will
  simply not appear and nothing else on screen would ever say why. `place()` has three
  return sites and they all go through one `terrain(_:wrote:kept:)`.

### 12.5.2 A row that cannot be read is reported, never dropped in silence

```swift
public static func bundle(from folder: SessionFolder, course: Course?, elevation: Elevation?)
    throws -> (bundle: RoundBundle, unreadable: [Unreadable])
```

**`JSONLReader` skips a line it cannot decode** — exactly right for opening a round that
ended in a battery death, and exactly wrong for an archive whose one job is to lose nothing.
So the export counts the lines in each file against the rows it got back and says when they
differ. It cannot repair such a row; an export that says *"1 of 7 rows in log.jsonl could
not be read"* is something somebody can act on, where a bundle quietly holding 6 is not.

**A tuple, not a side channel**, so no caller can forget to look.

### 12.5.3 The wire format — plain when small, compressed when large

```
MARKER-ROUND v1 zlib 1045654
# Coyote Creek Golf Club Tournament Course · 2026-08-30 23:35 · 2 players · 6 logs · 3 events
zL3bcpvH0TZ6/l+FS6dOPs1+858BMCmCiiLDkSzLf+mAoihQpiQq2hhxvvqq1kWsm1i3sS5lXcnq
…
```

- Header: marker, version, algorithm, **decompressed byte count** (so the decoder allocates
  once and can validate). Lines beginning `#` are ignored — the comment is what makes a blob
  on a clipboard say what it is.
- **Threshold `compressAbove = 100_000` on the serialized JSON size.** Not "has terrain":
  relief is entropy, so a hilly course compresses far worse than a flat one. Measured on the
  two real courses: Corica (10 m relief) 850 KB → ~150 KB; Coyote (177 m) 1.0 MB → ~410 KB.
- **Base64 wrapped at 76**, the MIME convention, because chat clients mangle very long lines.
- **The reader accepts either form**, sniffed on the first non-blank, non-`#` character:
  `{` → plain, `MARKER-ROUND` → compressed.
- Compression is Apple's `Compression` framework, `COMPRESSION_ZLIB` — on the platform floor,
  so not a new dependency. `compression_encode_buffer` returns 0 rather than growing its
  destination, so **incompressible input falls back to plain** rather than throwing.

**Two traps, both measured:**

1. **`text.split(separator: "\n")` is wrong, and silently.** A Swift `String` is a sequence
   of grapheme clusters and **`"\r\n"` is ONE of them**, so a document that picked up Windows
   line endings on the way through a chat client contains no `"\n"` character at all: it
   splits into a single line and fails as an unreadable header, for a file that is perfectly
   fine. Use `split(whereSeparator: \.isNewline)` and trim `.whitespacesAndNewlines`. Found
   by pasting a CRLF copy of a real export.
2. **Identity before parseability.** Decoding foreign JSON straight into `RoundBundle`
   reports the first missing field of *some other document* — "a required field is missing
   (exported)" for a file that was never one of ours — which sends the reader looking for a
   field instead of for the right file. Probe `format`/`version` with a two-optional-field
   `Envelope` first.

Errors are **sentences, not `NSError`s** (§6.4's rule): not-a-bundle, unsupported version,
bad header, bad base64, corrupt, malformed JSON. Anything wrong *after* a successful inflate
is reported as damage rather than as bad JSON — nobody hand-writes the compressed form, and
it is also the only way to catch a header claiming **fewer** bytes than the payload really
inflates to, which fills the destination exactly, returns the promised length, and hands
back a truncated document.

`golfctl round show <file>` decodes either form back to readable JSON, so the compact form
never becomes un-inspectable; `--model-visible` prints the stripped version, so the firewall
is something a person can *see* rather than take on trust.

### 12.5.4 Import: nothing is ever overwritten

```swift
public static func restore(_ bundle: RoundBundle, into root: URL, courses: CourseStore?)
    throws -> Report
```

- **The round always lands in a fresh folder.** The conventional name derives from the
  round's start in local time, so re-importing collides by construction; suffix `-2`, `-3`.
- **`sessionID` is preserved, and a duplicate is reported.** It is the round's own identity,
  and keeping it is what lets a second import of the same export be recognised. Safe for the
  rounds list because `SessionSummary.id` is the **folder** name, so two folders sharing a
  session id is not an `Identifiable` collision.
- **A course already on disk is kept.** `CourseStore.save` is a *replace*, so saving over an
  id destroys every tee and green centre placed by hand in the editor — the same rule the
  course finder follows.
- **Terrain is the one thing an import may add to a course it kept.** A `.dem` is
  public-domain measurement with nobody's hand-placed work in it, so writing one where there
  is none loses nothing and gains the plays-like numbers. An existing one is never replaced.

**The sharp case: two different courses, one id.** `Course.slug` is ASCII-only by design, so
*every* Korean course name slugs to `"course"` and unrelated courses collide on the first
import. An id check alone would keep the local file and hand the imported round a course in
another county — everything renders, every number is wrong, nothing says so.

`CourseIdentity.compare` decides it on **geography**: centroids more than
`sameSiteRadius` (1 km) apart are different courses. The radius is deliberately loose — the
same course re-imported from OSM a year later, or one with a nine added, moves its centroid
by hundreds of metres, and forking a file every time somebody refreshes their geometry would
be worse. For card-only files with no coordinates it falls back to hole count and par total,
and the report says which test was used.

When they differ: keep the local file untouched, store the incoming one under a **free id
and a distinct name** (`X (imported)`, original name kept as an alias), write its terrain,
and **repoint the round**. That last step is the one the plain design misses:
`meta.course` is a **name**, and the app resolves a round's course by matching that name
against the library — so a course stored under a different name would leave the round
pointing at the local course of the original name, which is precisely the different course
we just decided it was not.

`RoundArchive.Report` carries every outcome and renders `lines`:

```
round      session-2026-08-30-2335
           6 logs, 3 events, 4 journal, 40 fixes, 1 marks
audio      2 segment(s) indexed — the recordings are not included in an export
course     coyote-creek-… is already here and IS A DIFFERENT COURSE (their centres are 76.3 km apart)
           the imported one was saved as coyote-creek-…-imported and this round now names "… (imported)"
terrain    coyote-creek-…-imported.dem — written
```

### 12.5.5 Two consequences elsewhere

**`LogRetranscribe.spans` must check that the `.m4a` actually exists.** `AudioSpans.resolve`
matches times against `audio.jsonl` and knows nothing about the filesystem, and
`hasAudioSpan` is `tEnd != nil` — a pure field test. An imported round satisfies both for
every spoken log, because the index is carried deliberately. Without the file check
"Transcribe again" is offered on every row of such a round and fails on each, which reads as
the feature being broken rather than as the recordings not having travelled.

**`CourseLibrary.loadTerrain` needs a `force`, because an import can add a `.dem` to a course
that did not change.** The id guard (`terrainID != selectedID`) exists so that re-appearing
on the hole view does not re-read three quarters of a megabyte — and it assumes the only way
terrain changes is that the *course* changed. An import that keeps an existing course and
adds its missing sidecar breaks that: the id is unchanged, the guard returns early, and the
plays-like number stays missing until the next relaunch. `Report.terrainOutcome` names the
id, so the importer asks for the re-read explicitly. Same silent-vanishing failure the
`selectedID` observer was written for, arriving by the one road it cannot see — the
`defaultTee` shape.

**The paste is decoded off the main actor.** 150–400 KB of base64 inflating to a megabyte of
JSON, run inline in `onChange`, hangs the one screen the action lives on — and a golfer reads
that as the paste not having worked. Fast enough on a simulator to look fine and slow enough
on a phone not to be. A token bumped per paste discards a slow decode of superseded text.

### 12.5.6 In the app

Two sheets in `RoundTransfer.swift`, and their labels are load-bearing: the round menu has
**"Copy whole round"** (model-facing, `RoundExport`) directly above **"Export round…"**
(complete, `RoundBundle`), and once either is on a clipboard nothing says which.

- **Export** shows the round, the size, the form, and — in front of the buttons — what did
  *not* travel: a missing course file, and any unreadable rows. Copy to clipboard, or
  `ShareLink` a temp file. The footer says out loud that it holds ground truth.
- **An "Include terrain" toggle, on by default, and only when there is a grid to leave
  out** (§12.5.1a). A toggle that does nothing on most courses — nothing outside the US has
  terrain — is a control that teaches people it does nothing, so `CourseStore.elevationExists`
  decides whether the section is drawn at all. **Both forms are built once**, off the main
  actor, in the same pass: decoding a `.dem` and encoding the bundle is about a megabyte of
  JSON each and doing it inline is the hang the import sheet was already fixed for, and
  building both means the toggle costs nothing and both sizes are *measurements* rather than
  an estimate. **Size and Form are computed from the text actually chosen** — terrain is
  most of the bytes, so turning it off usually drops the export under `compressAbove` and
  flips the wire form. `copied` resets on the toggle, or the button claims to have copied
  the other document. The footer names **both** sizes ("costs 121 KB — 171 KB with it,
  50 KB without"): the first version said "121 KB of this 171 KB export", which contradicted
  the Size row three lines above it the moment the toggle went off — the same class as the
  plays-like rounding that made three numbers on a hole fail to add up.
- **Import** lives on the rounds list, behind the `…` menu beside `+` — a round arriving from
  somebody else has no round to be reached through, the same argument that put "Find a
  course" there. It shows the decoded summary **before** anything is written.
- **Two roads in — the clipboard and a file — and no text box.** The file half is not
  optional: Export offers a `ShareLink`, so a round arrives by AirDrop, Mail or an iCloud
  Drive folder, and it arrives as a *document*, which a clipboard cannot reach. Without a
  picker the only way to take one in is to open it in some other app and hand-copy four
  hundred kilobytes of base64.
  **Do not put a paste box under these buttons.** It is the obvious third control and it
  fails twice: a `TextEditor` **grows to fit its content**, so a real 400 KB paste fills the
  sheet and pushes the summary and the Import button clean off the screen — a failure only a
  screenshot finds, since every test passes on a view that renders nothing a thumb can reach —
  and with two working buttons above it, on arrival it is a blank 110-point void. The one
  thing it would buy, a paste that fails with nothing on screen to look at, is bought properly
  by **reporting an empty clipboard** instead of doing nothing. The same rule sends the whole
  section away the moment anything decodes: nobody reads base64, and what replaces it — the
  course, the date, the players, the scores — is what somebody needs before saying yes.
- **Both roads end in one `decode(_:from:)`, and a chosen file is never poured into a state
  string on the way.** `sourceName` is set *inside* that function, so a paste always clears
  it: "From coyote.marker-round.txt" standing over a round that arrived by another road is a
  plain lie about provenance, on the one screen whose job is to say what is about to be
  written. The preview names the file it came from, because a golfer picking from a folder of
  similarly-named exports has nothing else to tell them apart.
- **`startAccessingSecurityScopedResource()` is required and its absence is silent.** A URL
  from `.fileImporter` points outside the container; reading it without the scope fails with
  a permission error that reads, on this screen, exactly like a corrupt export. Balance it
  with `defer` — a scope left open leaks a sandbox extension for the life of the process.
  The read is **off the main actor** too: a file picked out of iCloud Drive may not be on the
  phone yet, and the read then blocks on a download.
  Allowed types are `[.text, .json]`; `public.json` conforms to `public.text`, so a document
  saved under either name is offered rather than greyed out.

---

## 13. `golfctl` — the CLI

macOS. The iteration surface for everything off-device. **Every stage caches into the session
folder**, so re-tuning a prompt never re-runs a 30-minute transcription.

Arguments are parsed by hand (~40 lines: `--flag value`, `--flag` as `true`, positionals).
swift-argument-parser is a Phase 3 intention, not a current dependency. **Line-buffer stdout**
(`setvbuf(stdout, nil, _IOLBF, 0)`) — piped output from a long-running recorder is useless if it
only appears when the process exits.

```sh
# Record a round from the Mac — no phone needed.
golfctl record --out Sessions --players 'steve,dave' --course "Naelgol CC"
golfctl record --out Sessions --seconds 60 --no-gps
golfctl record --out Sessions --live [--live-volatile] [--locale en-US,ko-KR]
golfctl record --out Sessions --mic-off --live      # `r ENTER` toggles a burst
golfctl inspect Sessions/session-2026-08-24-1430

# Transcription. Caches per audio segment.
golfctl transcribe <session>
golfctl transcribe <session> --asr whisperkit --model openai_whisper-small
golfctl transcribe <session> --asr apple --force --locale en-US,ko-KR
golfctl transcribe <session> --show-vocab | --no-vocab
golfctl models                                       # multilingual only, deliberately
golfctl live recording.m4a --realtime [--model VARIANT]
golfctl relisten recording.m4a --from 4.5 --to 7 --model openai_whisper-small
golfctl relisten recording.m4a --players 'steve,dave'

# A whole round out and back — its streams, its course and that course's terrain.
golfctl round export <session> [--out FILE] [--courses DIR] [--no-terrain]
                               [--plain|--compressed]
golfctl round import <file|->  [--out Sessions] [--courses Courses] [--dry-run] [--no-courses]
golfctl round show   <file|->  [--model-visible]
#   golfctl round export S | pbcopy      /      pbpaste | golfctl round import -
#   export writes the document to stdout and everything else to stderr, so it pipes.
#   --no-terrain leaves the elevation grid out (§12.5.1a); with terrain in, the stderr
#   line names what it costs, measured by encoding the other form once — relief is
#   entropy, so the saving cannot be guessed from the grid's dimensions.

# Course geometry.
golfctl course sample --out Courses
golfctl course show Courses/<id>.json [--hole 7]
golfctl course osm --name "Corica Park" --dry-run
golfctl course osm --name "Corica Park" --id corica-park-south \
    --name-as "Corica Park South" --out Courses [--merge]
#   --at <lat,lon> [--radius m] | --bbox <s,w,n,e> when the name does not resolve
#   --course <n> picks one of several at a site (default: the largest)
golfctl course elevation Courses/<id>.json [--spacing 3] [--pad 150] [--out Courses]
golfctl course import --url <page> --fetch-only            # needs no key
golfctl course import --url <page> --name "X" --out Courses [--merge]
golfctl course import --card card.jpg --name "Pebble Beach"
#   --unit metres|yards ; --unit-default flips the assumption (default: yards)
```

`bundle`, `reconstruct`, `eval` and `sweep` print "not implemented".

**`--mic-off --live` on macOS is the only place the burst path can be watched**: each `r` opens
a segment, closes it with a true `t1`, and starts a fresh recognizer — the exact sequence the
app's record button rides on.

**`golfctl record` on a Mac captures audio and marks but no GPS** (§8). **`golfctl transcribe`
reports missing segments out loud** (§9.11). **`golfctl models` filters out English-only
builds** (§9.5).

### 13.1 The prompt and schema files you must author

These are **inputs, not build products**, and they are not reproduced here — they are ordinary
prompt text and JSON Schema, and they are the part you are most expected to tune. Create them at
the default paths, or pass your own with `--prompt` / `--schema`:

| Path | What it is |
|---|---|
| `Prompts/course-card.md` | Instructions for reading a scorecard (a web page's stripped text, or OCR of a photograph) into the `CourseCard` shape of §11. Must state that par, stroke index and per-tee yardage are wanted, that a distance unit should be reported only when it is *printed*, and that both stroke-index rows exist on an American card. |
| `Prompts/course-card.schema.json` | JSON Schema for `CourseCard` — passed as `output_config.format`. |
| `Resources/prompt.md` | The round-reconstruction instructions. |
| `Resources/round.schema.json` | JSON Schema for the reconstructed round. |

The path-not-bundle rule (§2.2, §12.2) exists so that editing one of these is edit-and-rerun.

---

## 14. The iOS app

Bundle id `com.naelgol.Naelgol-Marker` (**change this**), iOS **26.5** deployment target,
`TARGETED_DEVICE_FAMILY = "1,2"`, automatic signing, `DEVELOPMENT_TEAM` **must be replaced with
your own** — and both settings appear **twice**, in the Debug and Release configurations.

Local package dependency `relativePath = ../..`, linking: `GolfSessionFormat`,
`GolfCaptureCore`, `GolfCaptureMotion`, `GolfCourse`, `GolfMap`, `GolfReconstruction`,
`GolfTranscription`, `GolfCourseOSM`, `GolfTerrain`, `GolfExchange`.

### 14.1 Project setup — four things that fail silently

1. **`UIBackgroundModes` and `UIFileSharingEnabled` live in `Info.plist`, not in
   `INFOPLIST_KEY_*` build settings.** Xcode's Info.plist *generator* drops exactly those two:
   the settings resolve, and the keys never reach the built app. Everything else — every usage
   string, orientation, scene manifest — is an `INFOPLIST_KEY_*`.

   ```xml
   <key>UIBackgroundModes</key>
   <array><string>location</string><string>audio</string></array>
   <key>UIFileSharingEnabled</key><true/>
   ```

   `location`: without it the track stops the instant the screen locks — which is every round,
   since the phone lives in a pocket. `audio`: it does **not** make the app record in the
   background on its own (the `AVAudioSession` category does that, §8.2), but without it a burst
   in progress is killed the moment the screen locks. `UIFileSharingEnabled`: the entire
   device→Mac transfer story.

2. **That `Info.plist` must sit *outside* the synchronized source folder.** Inside it, Xcode also
   copies it as a resource and the build dies with *"Multiple commands produce Info.plist"*.

3. **`NSMotionUsageDescription`** — without it `CMMotionActivityManager` and `CMPedometer` return
   nothing at all, with no error. Elevation and activity just never arrive.

4. **`NSSpeechRecognitionUsageDescription` is set even though `SpeechAnalyzer` may not need it.**
   `SFSpeechRecognizer` did; the on-device successor may not, and **the simulator cannot tell you
   — with no speech model, a missing usage string and a missing model both surface as
   "unavailable".** One line here against a TCC abort four holes from the car park.

All five usage strings must be **real text**; placeholders are an automatic App Review rejection.

The target uses an Xcode 16+ **synchronized root group**: a `.swift` file dropped into the source
folder joins the target automatically, no pbxproj edit.

**Device builds need the phone plugged in.** With no registered devices, provisioning fails with
*"Your team has no devices from which to generate a provisioning profile"*. Compile check without
either:

```sh
xcodebuild -scheme "Naelgol Marker" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

### 14.2 Screens and files

| File | Role |
|---|---|
| `MarkerApp.swift` | App entry. Owns `LiveLocation` and drives `adopt` / `standDown`. |
| `RoundsListView` | First screen. Reads session folders via `SessionIndex`. |
| `RoundView` / `NewRoundView` | Setup: roster, course, capabilities (§14.2a). |
| `RoundScreen` | Three bands: scorecard, timeline, input. Drives log placement. |
| `RoundViewModel` | Owns the hardware — one per app (one mic, one round recording). |
| `RoundDocument` | Owns a folder — any number of these. |
| `CourseView` | Course overview + the hole view host. |
| `MarkerBar` / `MarkerSheet` | Marker · Round · Location, on both screens. |
| `LiveTranscript` | Live ASR → `log.jsonl`. |
| `LogStore`, `LogPlacement`, `StableLocation`, `LogEditor`, `LogRetranscribe` | The log path. |
| `CourseFinder`, `TerrainSheet`, `WhisperModelPicker` | The three downloads. |
| `RoundTransfer` | `RoundExportSheet` and `RoundImportSheet` — clipboard **and** file, §12.5.6. |
| `ScorecardBand`, `HistoryView`, `HoleDetailSheet`, `RosterEditor`, `PlayerEditor` | Card + journal UI. |
| `LiveLocation` | Round-independent position feed. |
| `RenderHarness` | DEBUG-only launch-argument harness (§14.7). |

**`RoundViewModel` owns the hardware; `RoundDocument` owns a folder.** There is one view model
for the life of the app and any number of documents. Conflating them is what left an earlier
single-screen shell unable to open a round that had already ended.

### 14.2a Setting a round up

**A new round starts with exactly one player row and an empty name.** Do not persist the previous
round's roster and restore it here. It is the obvious convenience — the group usually is the same
four people — and what it produces is a **Start button that is live the instant the screen
appears, over names nobody has looked at**, so a round played with a different group silently
records the old one. An empty row cannot be started by accident: `canStart` is `!players.isEmpty`
and a draft with a blank name is not a player.

**The free-text course name is not remembered either**, and it is the same rule, not an
oversight: on a phone with no course files that field is what the screen shows, and a pre-filled
one is a name nobody looked at with Start live over it. What *is* carried over is
`CourseLibrary.selectedID` — a different mechanism doing a different thing. A group replays a
course far more often than it replays a roster, and a picker shows the course **by name**, so what
was remembered is legible on the screen rather than sitting in a box that looks freshly typed.

A player row is **one field**. The roster can be changed mid-round (`RosterEditor`, §14.5) without
losing anyone's scores, which is why the setup screen does not need to be complete.

### 14.3 Permissions

**Permission state is three-valued in the UI, not two, and it must be `@Published`, not a
computed property.** A bool renders a red ✗ next to Location before anyone has been *asked*; a
computed property never refreshes after the user answers a prompt, so the row stays on "?"
forever and the app looks like it never asked. Keep
`Capability.Status = ready | willAsk | denied | unavailable`, keep it published, and refresh on
appear, on `scenePhase == .active`, and after every request.

**Permission is requested from the capability row, not only from Start.** Gating the prompt
behind "fill in the roster, then tap Start" is what made it look like the app never asked. Rows
are tappable; denied rows open Settings.

**`canStart` does not gate on permission at all** *(2026-08-27)*: a round with no fixes still
records logs, marks and motion, and a coordinate-less log is a real row rather than an error.
Refusing to start would throw the sentences away too.

**The setup screen is a `Form`, not a hand-rolled `VStack`.** The VStack version squeezed its
content when the keyboard appeared and the large navigation title landed on top of the players
field. `Form` + `.navigationBarTitleDisplayMode(.inline)` + `.scrollDismissesKeyboard` is the
fix; verified on device and in the simulator with the keyboard up.

### 14.3a Deleting a round

Swipe-to-delete on the rounds list, then a **confirmation dialog naming what goes** in the
round's own numbers (`4h 14m · steve, dave, min · logs · events · 6 KB`) — "Are you sure?"
asks a question the golfer cannot answer without leaving the dialog. The swipe alone must not
delete: a swipe is cheap and easy to do by accident on a scrolling list, and this is the one
control in the app that takes a round away.

- **The action is not offered on the recording round** rather than offered and refused.
- **Deleting an *unfinished* round is allowed** — those are the crash-recovery junk that piles
  up, and they are the main thing anybody wants to clear.
- **"Recently deleted" appears only when the trash is non-empty.** An always-visible empty bin
  is a permanent reminder of a thing that has not happened, on the first screen of the app.
  Its rows are **not `NavigationLink`s** — a deleted round has no live folder for the round
  screen to open, and that screen's logs, journal and placement tasks all write.
- **Swipe leading to put back, trailing to delete for good; "Empty" in the section header.**
  The footer says the window out loud, because a recovery window nobody knows about is not
  one.
- **No separate Undo banner.** "Recently deleted" *is* the recovery path and it is one swipe
  away on the same screen; a transient Undo beside it would be two controls a centimetre apart
  doing one thing, which is how they come to behave subtly differently.
- **The footer carries the total size as well as the window.** That is the whole reason
  `SessionSummary.bytes` exists — "a phone filling up is worth saying out loud" — and a
  thirty-day hold over 4.5-hour rounds with `.m4a`s in them is exactly how one fills. A bin
  whose size is invisible is a silent leak rather than a recovery window.
- **Delete, restore, purge and Empty report their failures, and `purgeExpired` says what it
  took.** A `try?` that silently does nothing reads as the swipe not having registered, and
  rounds that vanish with nothing accounting for them are indistinguishable from rounds the
  app lost. Everything else on this screen says what it declined to do.
- **The remaining days are rounded up, not truncated.** A round deleted a minute ago has 29.99
  days left, and `Int(...)` renders "29 days" — a thirty-day window announcing itself as
  twenty-nine on the day it opens, which reads as the app having already eaten a day.

### 14.4 Location: two feeds, and fast is asked for by *reason*

`LiveLocation` is the **round-independent** feed for the hole view: it writes nothing, and it
**stands down while a round records** — the recorder owns the radio then, and two managers asking
for Best is twice the power for one position. It is owned by the **app**, not by a screen: as a
`@StateObject` inside the course view it was born when that screen appeared and died when it
left, so "on means slow tracking even in the background" could not be true of it and the button
read **Off** on the round screen while the preference said on.

**Fast is asked for by *reason*, never set as a mode two callers overwrite.**

```swift
enum FastReason { case holeView, marker }      // on BOTH feeds; each keeps a Set
```

Booleans were survivable while one thing escalated and are not survivable with two: the radio
hand-back schedules an **unconditional** drop to slow after a burst, and the Marker sheet dropped
to slow outright — so a burst ending, or a sheet closing, over a hole view still on screen took
that screen's fast tracking away, and the hole view never re-asserts because its `appear` already
ran. **A reason is removed by the screen that added it.**

Three more, each a real bug:

- **The `scenePhase` handler must not be an unconditional `track(.slow)`.** `scenePhase` reaches
  `.active` *after* `onAppear`, so the hole view asked for fast and one event later that handler
  took it away — found by screenshot, the Location button reading **Slow** on the screen that had
  just asked for Fast. Drop and **re-assert this screen's own reason**.
- **`standDown(false)` resumes at slow, never at the previously wanted mode.** A `.fast` asked for
  while the feed was stood down came from a screen that has since gone, so replaying it left the
  radio at Best for the rest of the app's life.
- **The indicator shows the recorder's *real* mode.** An `adopt` that hardcoded `.fast` made both
  screens read **Fast** whatever the recorder was doing — and it is slow for all of a round except
  a burst. Same class of error as drawing a simulated position like a fix.

**Slow keeps running in the background, and Always is what makes that true.** Always is requested
from **one place** — the hole view appearing — because the escalation guard (§8.3) means the ask
has to be hung on a moment of intent.

**The fast window ends at a stable fix, not at dismissal** *(user, 2026-08-28)*. The Marker sheet
runs a `StableLocation.best` that returns the moment tracking **locks** (three fixes inside 15 m)
or at a deadline; both feeds drop to slow immediately after, and the fix it found is used by
every log the sheet writes from then on. Holding fast for the life of the sheet meant a golfer
describing a hole for two minutes paid Best for all of it.

**`MarkerSheet` names three managers and runs at most two.** The recorded track exists only
during a round; `LiveLocation` stands down for exactly that period. `StableLocation` is the third
and **always runs at Best whatever the others are set to** — which is what keeps the log path
independent of duty cycling.

### 14.5 The log path

**A log is written first and placed second.** The write takes whatever fix is already warm, or
none; convergence appends the superseding row afterwards, driven by the **foreground app** (which
has a real lifecycle and is reachable in the simulator), holding a `beginBackgroundTask`.

**Recording what was said must never wait on GPS.** `hasPosition == false` is a real answer. The
golfer has spoken a sentence and is walking away; an input path that hangs for a fix is worse than
a log with no coordinate. **Never substitute the last known position** — that places a shot on the
previous hole and looks exactly like a measurement.

Placement task rules:

- **Keyed on the *unplaced* logs, not on every log.** `.task(id:)` cancels and restarts on every
  change of its id, so keying it on all log ids meant an arriving log that needed no placement
  tore down a convergence fifteen seconds into its radio wait.
- **Keyed on ids, not a count.** A delete and an arrival in the same reload leave the count
  identical.
- **`attempted` is a reservation, given back when the attempt never ran.** Taken up front so two
  passes cannot converge one log at once — but a burst restarts that task often, and a log torn
  down before the radio ever ran would otherwise be marked attempted and **never placed at all**.
  Returned *only* when nothing was tried: a convergence that ran and found nothing has had its
  turn.
- **Both the sheet and the round screen converge, and running both is safe by construction.** The
  Marker sheet opens over the hole view, where the round screen is a stack frame down holding a
  *different* document — so the sheet converges what it just wrote and the round screen is the
  backstop. A converged log is no longer unplaced.
- **The radio hand-back needs a belt as well as braces.** A burst that placed everything as it
  went leaves the signature unchanged when Stop is tapped, so the task never fires again; without
  a separate timer the radio sits at Best for the remaining four hours, reached through the
  feature meant to save power.

**The roster is editable mid-round, and its absence caused a bug report.** With no control to add
a player after a round started, the first person who wanted one typed "Players are A, B, C, D"
into the log box — an observation with no shot in it, which fed the extraction loop. The editor
accepts several comma-separated names and strips a leading "players are" / "playing with" — **a
fixed prefix and a separator, not a parser**; anything unrecognised becomes one player with a long
name, visible and one swipe to delete. **Removing a player keeps their scores**, so putting them
back restores the card.

**A cited log is quoted under the event it produced, never given its own row.** Showing it twice
is clutter; hiding it behind a count is worse, because verifying a draft then costs a tap and
verifying drafts is the entire job of that screen. **A log with no event keeps its own row** —
that is the visible signal that nothing has read it yet.

**A row with no hole is drawn on every hole, never on none.** `hole` is nil whenever
`nearestHole` declines — no fix, no course file, or more than 250 m from any hole, which is every
test run anywhere but on the course. Filtering `$0.hole == hole` made a log the app had just
confirmed it saved invisible on all eighteen. Both row types carry a `no hole` chip. **A row shows
its hole, and `no hole` only when it has none** — the same field answered two ways, rather than a
chip that appears only on failure, which read as "this row is broken" instead of "this row is on
7". The label is `Hole.ref`, falling back to the playing index.

**A round's course lives in its own `meta.json`; the library's selection is a global
preference.** Reading the round screen's title and the scorecard's pars from the library put
*another* course's name and pars on this round — twice, in one screen. Match the library by the
round's own course name and be nil when there is no file, which is the honest answer.

**The hole view's roster is the round's, replayed from its journal — never the setup screen's
list.** That list is empty whenever the hole view was reached on a round that is not the one
recording, which is most of the time and every finished round: with it empty a shot pill lost its
name **and its colour** and the connecting line had never once been drawn. Replay `JournalReplay`
over `meta.players` (a player added mid-round exists only in the journal), and **do not go through
`RoundDocument`**, which rewrites `scorecard.json` on every replay — once per phrase during a
burst.

**A marker written on the hole view has to appear on it, and one signal is not enough.** Reading
the log file once on appear misses everything; reloading on sheet-dismissal covers the entry that
had a warm fix and **not** the one that did not, because convergence routinely lands *after* the
sheet has gone. Listen to the store's append notification as well, on the main run loop, comparing
folders with `isSame` (§3.5).

### 14.6 The Marker sheet

**Speak *or* Type, never both** *(user, 2026-08-28)*. They are two **recognizers**: Speak runs the
live Whisper transcriber off our tap; Type hands the sentence to the iOS keyboard and its own
dictation. Both at once is two things listening to one voice and two log rows for one sentence, so
switching to Type **closes the burst**. Closing the sheet ends the burst — a live microphone with
nothing on screen saying so is exactly the failure the record button's own rule was written
against. **The choice is remembered**; **Speak is the default**. Type is the text box and nothing
else, full height, focused on arrival, `.large` forced (the medium detent plus a keyboard leaves
about two lines visible).

**The sheet says what the entry is *about*: hole, player, shot** — above both modes, because they
describe the entry and not the way it was captured.

- The **hole is pre-assigned from the one on screen** and written `.user` (§3.8).
- The **shot auto-fills** to one more than that player's last on that hole, from the **current**
  rows and never the raw file — a burst grows by superseding, so counting raw rows jumps the number
  every time somebody fixes a typo.
- **The hole and shot lead the sentence** — `"7: 2 drive into the left bunker"` — **and are also
  stored as fields.** Not a duplication to tidy away: the prefix is what a person reads in the
  timeline and what extraction reads in `log.jsonl`; the fields are what the hole view draws from.
  Written in one place so the two cannot drift.
- **Two rows: hole and shot, then the roster across.** The players were a `Menu`, so the field
  filled in most often cost a tap to open, a read and a tap to pick. Horizontal costs one row for a
  four-player roster instead of four. **A player toggles** — tapping the selected one clears it,
  the only way back to "about nobody in particular". *(The roster appears on this sheet twice, so
  the MARK row is labelled: the chips are who the entry is about, the pills are the survey button
  writing `marks.jsonl`.)*
- **Player and shot are both optional.** The stepper runs **0…20 with 0 rendering as `—`**;
  bottoming out at 1 made an auto-filled value compulsory. **A number still needs a player** — the
  stepper is disabled with nobody selected and clearing the player clears the number.
- **OK and Cancel, at the bottom of both dialogs**, via `.safeAreaInset(edge: .bottom)` so they
  ride above the keyboard. They were toolbar items — where iOS puts them, and the furthest thing on
  the screen from a gloved thumb, for the two buttons that decide what happens to the entry.
- **Cancel deletes what the burst wrote.** It cannot un-write a spoken phrase — one is committed
  the instant it finalises, deliberately — so it **tombstones**. Tracking which entries this visit
  produced needs its own list: the current burst id is not enough, because it clears when a burst
  ends and one visit can open and close several.
- **OK on an empty box still files a marker, provided the entry is *about* something.** `"7: 2"`
  with nothing after it is a real entry — it is where a shot was played from, which is what the hole
  view draws — and demanding a sentence made a golfer marking a position invent one. Two guards,
  both against writing an empty *nothing*: there must be a hole or a player, and nothing is written
  when the visit already produced a phrase.
- **There is no send button.** There were two ways to commit one sentence a centimetre apart and
  behaving differently — the arrow refused an empty box, OK did not. **Return is a return**: it was
  `.submitLabel(.send)` with `.onSubmit(send)`, so the key that looks like a newline on a
  three-line box filed the entry and closed the sheet.
- **Create and edit are the same three fields; only the keyboard differs.** Creating, the sentence
  does not exist yet, so the field is focused on arrival. Editing, the sentence usually is *right* —
  the common edit is a field — so the text is shown as text and one tap turns it into a field.
  Raising the keyboard there hides the fields underneath it.

**MARK lives in the Marker sheet and nowhere else.** It was a red bar across the bottom of the
hole view — a second capture control doing nearly the same job, which also meant MARK's own rule
(§10.13) had to be enforced in two places.

**Round is a toggle.** On ends the round — **confirmed**, because a green button whose label is a
noun must not do something irreversible-looking on one tap; off reopens it. **It never *creates* a
round**: that needs a roster and a course.

**"Close out this round" is in the ••• menu, not the bottom band.** Moved, **not deleted**: it is
the only crash-recovery control there is, so a round the app was killed during would otherwise stay
unfinished forever. It is rare and does not belong in the thumb zone.

**"Transcribe again" is disabled while the microphone is open — for *attention*, not memory.** Both
models stay resident through a burst, so a re-transcribe straight after one is instant. The button
is off during a burst because a decode competing with the live recognizer for the ANE slows the
thing the golfer is actually doing, and the audio is not going anywhere.

### 14.7 Reviewing without a finger

**Scripted taps do not exist in this environment.** The app therefore carries a DEBUG-only harness
driven by `UserDefaults` launch arguments, then `xcrun simctl io <device> screenshot`.

**Every key needs a value.** A bare `-marker.seed` parses as nothing, the seed silently does not
run, and the screen comes up on whatever was left in the container — which looks exactly like the
change under review having no effect. That cost three rebuilds before the *argument*, rather than
the code, turned out to be wrong.

```
marker.seed YES      marker.wipe      marker.open <session>    marker.hole <n>
marker.sheet history|roster|detail|marker|export        marker.map      marker.course
marker.targets 0.35,0.7        marker.simulate       marker.bump up|down
marker.terrain [fetch]         marker.find + marker.find.query
marker.start   marker.record   marker.speech <path>
marker.trash YES|confirm       marker.export.terrain no
marker.new YES                 marker.player <id>
marker.import + marker.import.file <path>   (opens the file, not the clipboard)
```

Each exists because something is otherwise unreachable: a sheet behind a `Menu` is a sheet nobody
can review before it ships; `marker.targets` exists because a target is placed by *tapping*;
`marker.new` pushes straight to the New round setup screen, which is otherwise reached by tapping
`+`, and `marker.player` pushes one step further into a player's own screen inside the roster
sheet; `marker.import.file` opens that file through the importer's own `load(_:)` — the *file*
road, not the clipboard one, because `.fileImporter` is a system sheet nothing here can drive;
`marker.export.terrain no` exists because "Include terrain" is a `Toggle` and a toggle is
flipped by a finger — without it only the on state could ever be looked at, and the off state is the one
that changes three rows at once; `marker.speech` feeds a file to the recognizer **instead of the
microphone**, looped, because there is no way to speak into this simulator — and it drives the real live transcriber and the real log
store rather than a mock.

**Seeded logs must be placed on the course they name.** They once marched north from a point three
kilometres west of the course, so every seeded log was *placed*, none was on any hole, and **the
marker layer could not be seen in this environment at all** — which hid a real bug behind it.
Interpolate along each hole's own tee-to-green line. Note that **the camera is rotated to put the
green at the top, so increasing latitude moves a point *down* the screen.**

**A render override is not a `@State` seed**, and that distinction cost three attempts at one
animation. Setting and clearing a value in one synchronous block is a single SwiftUI update that
diffs nil against nil, so **no animation runs at all** (clear on a `Task { @MainActor }` hop); and
seeding a debug value through `init` cannot work, because `init` runs on the first body evaluation
and the roster, the tracks and the current hole are all loaded afterwards.

### 14.8 The app icon

Drawn by a checked-in script (`Tools/make-app-icon.swift`) in three appearances — re-runnable and
versioned. **The club *head* is what is fitted**: fitting the whole club is a thin diagonal scratch
at 60 points, while the head fills the canvas and the shaft is deliberately cropped, because the
grooves and the leading edge are what say *wedge* and what survive the shrink. Hosel and shaft are
**one tapered filled shape** — a wide stroke meeting a narrow one leaves a step, and at icon size a
step in a silhouette reads as two objects. The fit is measured from the union of the paths padded
by each stroke's half-width, so editing the club cannot push it off the canvas.

---

## 15. What is not built, and what is unverified

Read this before estimating. The list is the honest state as of 2026-08-30.

### 15.1 The blocking gap

**There is no extraction pass.** Nothing reads `log.jsonl` and proposes events. The prompt
construction is written and model-agnostic; the cloud pass through `AnthropicClient` that would
drive it is a placeholder. **Until it exists, a round accumulates sentences and the card is filled
in by hand.** This is the one thing whose absence changes what the product is.

### 15.2 Not built

- **Replay** (walking a recorded round back through the map) and the **elevation profile**.
- `GolfStore`, `GolfInsight`, `GolfEval` are placeholder files.
- `golfctl bundle | reconstruct | eval | sweep`.
- **Audio in an archive.** `RoundBundle.Audio.filesIncluded` is modelled and is always
  false; carrying the `.m4a`s would have to be a file-only export, never a paste.
- **The "Include terrain" toggle has never been flipped by a finger.** Both states render
  (`-marker.export.terrain no`) and the whole path is exercised by `golfctl round export
  --no-terrain` and by test, but the toggle itself, the re-copy after flipping it, and the
  `ShareLink` handing over the second temp file are unexercised — scripted taps do not
  exist in this environment. Same for the `.omitted` line in the import sheet's report,
  which needs a tap on Import; the CLI prints the same lines.
- **Track-derived course geometry** — the primary path wherever OSM is thin, i.e. Korea. Nothing
  derives a hole from a recorded GPS track yet, and there is no `survey export` either, so the
  MARK-button path has no way to become a course file.
- **No terrain outside the US**, and no way to get any (§7).

### 15.3 Verified, and where

| Verified | Where |
|---|---|
| Session folder round-trip, all streams | macOS + device |
| Segmented audio, burst toggle, real gaps between segments | macOS (`--mic-off --live`) |
| Stall watchdog against a *faked* dead tap | macOS |
| Whisper over real speech, both languages, language per phrase | macOS |
| Live path end to end — captions, commit at silence, log rows | simulator, speech **replayed from a file** |
| Model download on a real phone, burst recorded and transcribed | device, 2026-08-27 |
| OSM import, hole by hole against the raw ways | 2 real courses |
| 3DEP fetch, agreement with the point service to 3–34 cm | 2 real courses |
| Hole view, 5 rounds of hands-on feedback | device |
| Round export/import round-trip, course + DEM byte-identical | macOS, real course |
| Both wire forms, mangled paste, five error paths | macOS + test |
| Terrain optional: 422,882 → 33,157 chars on a real course; all four import outcomes | macOS + test |
| The importer's three states — two roads, a file decoded and named, an unreadable one | simulator |
| One empty player row, and two stale `UserDefaults` rosters ignored | simulator |
| The delegate-retention bug; the invisible nil-hole row | **found on device** |

### 15.4 Never verified anywhere

- **A whole round on a phone.** Motion and barometer over 4.5 hours, background survival in a
  pocket, battery cost, and the session folder as it comes off a phone rather than a Mac.
- **A real microphone with real voices at fairway distance.** This is the product's central
  premise and it has never been tested.
- **The interruption path.** `AVAudioSession` does not exist on macOS, so a real phone call is
  unexercised.
- **The stall watchdog against a genuinely dead tap.**
- **Stopping a burst with a finger** — scripted taps do not exist in this environment, so the
  close path is verified by CLI and by test.
- **`golfctl course import` against the live API.** Everything except the `/v1/messages` call is
  tested; assume the extraction leg is unproven until a real card round-trips.
- **The terrain sheet, the two-model picker, and the re-transcribe button, by a finger.**
- **The course editor's tap-to-place gesture.** `MapProxy.convert` is unproven on a real finger.
- **WhisperKit's iOS floor.**

### 15.5 Known-wrong and known-risky

- **The firewall is convention, not structure.** `GolfReconstruction` depends on
  `GolfSessionFormat`, so nothing stops it importing `Mark` / `Correction`. Moving those into
  their own target that only `GolfEval` depends on would make it real; it was **raised and
  deliberately deferred**. Until then, grep before shipping any bundle change.
- **A guessed par is indistinguishable from a surveyed one.** The OSM importer writes `par: 4`
  where the tag is missing — 11% of US hole ways — and `Hole.par` is a non-optional `Int` with no
  discriminator, so the scorecard, the hole box and the score-to-par all state a number nobody
  surveyed as though somebody had. The fix is an optional or a `parSource`.
- **The shot a pill names and the shot a stepper numbers differ by one** (§10.10). Deliberate;
  the fix, if it is worth closing, is to display `ShotName` in the sheet and the log prefix too —
  **not** to renumber storage.
- **One name per player costs a match, and nothing measures how often.** A card row or a spoken
  name written in the other script than the roster resolves to nobody (§3.3, §11.4). It bites
  hardest for a bilingual group, which is the group this app is for. The extraction prompt asks
  the model to allow a different script, so the loss is bounded by how good that is — and that
  is unmeasured. **Attribution accuracy is the metric that decides the whole feature**; watch it.
- **The roster screens render but have never been typed into.** New round, the roster sheet and
  a player's own screen are all reachable from the harness (`marker.new`, `marker.sheet roster`,
  `marker.player <id>`) and all screenshotted; adding a name, renaming one, and the swipe that
  removes a player are unexercised, because scripted taps do not exist here.
- **Delete, restore, purge and Empty have never been used by a finger.** The list section and
  the confirmation dialog both render under the screenshot harness and `SessionTrash` is
  covered by test, but every swipe action is unexercised by a tap. The confirmation was also
  reviewed under an artificial anchor (presented on launch rather than from a swipe), so its
  placement relative to the row it is about is unverified.
- **The file picker itself has never been opened.** `.fileImporter` presents a system sheet
  nothing here can drive; `marker.import.file` goes down the same `load(_:)` road and proves
  the read, the "From" row and the unreadable-file message, but a path inside the simulator's
  own sandbox **does not exercise the security-scoped call**, which is the half that fails
  silently. That one is settled only on a phone, picking a real file out of Files.
- **The export and import buttons have never been used by a finger.** Both sheets render
  correctly under the screenshot harness and the whole archive path is exercised by
  `golfctl round export|import|show` and by test — but Copy, Share, and Import itself are
  unexercised by a tap, because scripted taps do not exist in this environment.
- **An archive carries no `.m4a`, so an imported round can never be re-transcribed.** That is
  the format's deliberate limit rather than a bug, and §12.5.5 keeps the button from being
  offered — but it means an imported round's logs are final.
- **Nothing on disk records that an entry was re-read.** A re-transcribed burst entry and a
  live-grown one are indistinguishable in `log.jsonl`.
- **The satellite layer's leg labels do not de-collide**, so a short approach leg lands under the
  HUD. The real fix is a **top** reserve on that layer, the way the bottom reserve protects
  attribution.
- **The batch transcription pass is 16× slower than the Apple path**, measured: 43× realtime for
  two-locale Apple against **1.5–2.7×** for `openai_whisper-small` over the same 68-second
  fixture. A 4.5-hour round goes from about six minutes to one to three hours, and a phone will be
  slower. Treat it as a band. It does not affect the live path. It is the strongest argument
  against moving the picker up to `large-v3`.
- **Whisper's realtime cost on a phone is unmeasured, and it is the number that decides the
  model.** Each pass decodes a padded 30-second frame whatever the window holds, so cost is per
  *pass*, not per second of speech, and the loop runs continuously while a burst is open.
- **Only `openai_whisper-small` and `-tiny` have ever been run.** The two-model feature's premise —
  a bigger model hears names the small one misses — is supported by that comparison and nothing
  larger.
- **Golf-vocabulary WER has never been measured**, and neither has the name prompt's benefit (only
  its safety). With diarization cut, a spoken name is the *only* attribution signal. Evidence it is
  needed, from the first real run: "Min is putting" → "Mint is putting".
- **`k = 1` in `playsLike` is unmeasured against a real round**, and nothing records that a hole
  was played, so there is nothing to fit against yet.
- **Only two courses have terrain**, both in California, both reporting 1 m lidar. The coarse-
  product path and the void path have never been exercised against a real response.
- **Nothing checks that a traced file stays out of a published one.** The marking is written; no
  export path enforces it, because there is no export path.
- **GPS duty-cycling's saving is permanently unmeasurable against a real before-number** — the
  full-rate baseline round was voided. State it as an estimate, never as a measurement. And since
  the hole view now runs fast and is open for most of a round, whatever it was, it is smaller.

### 15.6 Environment facts that will waste your time

- **The simulator has no on-device speech model and cannot download one.** The whole path runs —
  locale resolution, transcriber construction, the asset check — and stops there with a message
  about `en_US` that reads like an app bug. **Transcription is testable only on a real iPhone.**
- **The simulator has no barometer and no motion coprocessor**, so those read empty.
- **Recording and transcription fail separately, and the UI must say so separately.** The simulator
  has a working microphone and no speech model at all, so a burst there writes a perfectly good
  `.m4a` while transcription reports unavailable. Collapsing the two into one flag makes that read
  as the record button being broken.
- **`ImageRenderer` cannot draw a `Menu`, a `List`, or a MapKit `Map`** (§10.11).
- **MapKit `.imagery` over Korea is good** — verified at 37.40/127.20, high enough resolution to
  read individual buildings at hole scale.

---

## 16. Verification checklist

Tests in the original: **503, 1 skipped** (a microphone-permission test that skips when the mic is
already authorized). Use that as an order-of-magnitude target, not a quota. The ones below are the
tests that would have caught a real, shipped bug.

**Format and clock**
- [ ] A session folder writes every stream and reads back; timestamps comparable across streams.
- [ ] `AudioTimeline` on a two-segment fixture with a five-minute gap: the second segment's content
      lands at 305.32 s, **not** 5.32 s.
- [ ] A window is clamped only when `segment.t1` is non-nil.
- [ ] `lastAudioIndex` takes the maximum of rows **and** files.
- [ ] `SessionFolder.isSame` returns true for a URL built before `create()` and one built after.
- [ ] `JournalReplay` resolves a three-deep undo chain; `live` and `inForce` differ as specified.
- [ ] `LogEntry.isPlaced` is false with a coordinate and no accuracy; a nil hole does **not** make a
      log a placement candidate.
- [ ] `Event.modelVisible` drops `.user`; `Event.init` drops `confidence` on `.user`.
- [ ] `log.jsonl` is in neither `groundTruth` nor `mixedProvenance`.

**Geometry**
- [ ] `project`/`unproject` round-trip **under pan and zoom**.
- [ ] Handedness: a point with `Geodesy.side` negative projects to a **larger x**.
- [ ] `cardLength(from: nil)` and `geometry(tee: nil)` resolve to **the same tee** on a hole where
      several tees are placed.
- [ ] A tee lacking a value returns **nil**, never another tee's number.
- [ ] `merging(card:)` preserves every placed coordinate, tees only in the old file, and holes the
      new card does not mention.
- [ ] A `Course` written before a new `Hole` field was added still decodes.
- [ ] `Hole.geometry` falls back to the centre line **only** when nothing on the hole is placed.

**Terrain**
- [ ] A point exactly on a known post returns a value when the **diagonal** neighbour is a void.
- [ ] A point derived from the grid's own corner samples successfully (the ulp clamp).
- [ ] `Sample.delta` returns nil across datums.
- [ ] Grid round-trips through base64 to 0.06 m.
- [ ] A synthetic GeoTIFF decodes **tiled and stripped**, both byte orders.
- [ ] `nativePosts` east ≠ north at a non-zero latitude.

**Display**
- [ ] `PlanLayout.advance` matches `NSFont.monospacedSystemFont` at 14, 20 and 68 points.
- [ ] `distance + rise == plays like` **as printed**, swept over a range of distances and rises.
- [ ] The plays-like suffix is nil when the rise rounds to zero.

**Transcription**
- [ ] The four decoding options are exactly as specified (`transcribe`, nil language,
      `detectLanguage`, `usePrefillPrompt`).
- [ ] `ScriptLocale.detect` returns nil for a line with no letters.
- [ ] The VAD does not call a quiet far-field phrase silent.
- [ ] `namePrompt` returns nil for an empty roster.
- [ ] The roster reaching the decoder is one name per player, deduped.
- [ ] Coverage records the **effective** locales, not the requested ones.
- [ ] `downloadBase` carries the `huggingface` component — **exercising a real download**.

**Roster**
- [ ] A `meta.json`, journal row or export carrying keys this build does not know still decodes.
- [ ] A player's id survives a rename, and scores stay keyed on it.
- [ ] A non-Latin name round-trips byte-for-byte, id included.
- [ ] A card row matching nobody comes back with a nil `player`, never dropped and never
      pattern-matched onto the nearest name.
- [ ] (By screenshot) New round shows one empty player row **and an empty course-name field**,
      with a roster and a course name left over in `UserDefaults` from any earlier scheme both
      planted and both ignored. Check the **empty-library** branch too — that is the one that
      renders the free-text course field at all.

**Archive**
- [ ] Export → import round-trips `log.jsonl` **element-wise**, including a supersede chain
      and a tombstone. (A `current()`-based comparison passes for an exporter that threw the
      whole history away.)
- [ ] The journal survives, and replaying it gives back the same score.
- [ ] `modelVisible` empties `groundTruth` **and** drops `.user` events, and keeps the logs.
- [ ] A syntactically valid row that is not a `LogEntry` is counted and reported, not dropped.
- [ ] A small round emits plain JSON; one carrying a DEM emits the compressed form; both
      round-trip.
- [ ] A compressed export survives CRLF + re-wrapping + indentation.
- [ ] Foreign JSON is refused as "not a bundle", never by naming one of *our* missing fields.
- [ ] Re-importing lands in a new folder and reports the duplicate `sessionID`.
- [ ] An existing course is kept with its hand-placed tees; an existing `.dem` is never
      replaced — including one that is present and does **not decode**, which may be a grid
      a newer build wrote; a missing one is added.
- [ ] A different course under the same id is stored beside it **and the round is repointed**.
- [ ] A carried course with no store to put it in is *reported*, not dropped in silence.
- [ ] (By hand) importing terrain onto the already-selected course makes the plays-like
      suffix appear without a relaunch.

**Terrain in an archive** (§12.5.1a)
- [ ] An export **with** terrain does not write `terrainOmitted` at all, and
      `RoundBundle.currentVersion` did not move for it.
- [ ] A document declaring an older version still decodes; one declaring a newer version is
      refused by version, never by naming a field of ours.
- [ ] A document with no `terrainOmitted` key decodes, and answers `false` — not a decode
      failure. (This is the `Hole.paths` failure; write this test first.)
- [ ] `includeTerrain: false` drops the grid, sets the flag, keeps the course and every
      stream, and survives both wire forms.
- [ ] A course that never had terrain is **not** flagged as an omission.
- [ ] `CourseData(elevation: someGrid, terrainOmitted: true)` reports `false` — the flag
      cannot contradict the grid.
- [ ] `.omitted` is reported in all and only the cases where the importing side ends up with
      no grid: nothing here (written + omitted), terrain already here (kept, silent about the
      omission), course here without terrain (omitted), stored-separately (omitted).
- [ ] (By screenshot) the importer offers both roads; a chosen file decodes, names itself in
      the preview, and an unreadable one says which file it was.
- [ ] (By screenshot) the toggle is absent when the course has no `.dem`; with it, Size, Form
      and the "terrain left out" summary all change together, and the footer's two sizes
      agree with the Size row in **both** states.

**Deleting**
- [ ] A deleted round leaves `SessionIndex.summaries` and its rows are all still on disk.
- [ ] Restore puts back exactly what went, and removes the `.deleted` stamp.
- [ ] Restore into a root where that folder name reappeared suffixes rather than overwrites —
      **both rounds survive**.
- [ ] Deleting two rounds of the same name keeps both.
- [ ] Retention purges what is past the window and leaves what is not; exactly at the window
      is still inside it.
- [ ] An unstamped trashed round is neither dated nor purged.

**OSM**
- [ ] `out geom` returns relation members; a multipolygon's inner rings are dropped.
- [ ] A named tee goes to its stated hole even when another hole's tee is nearer.
- [ ] The split does not chain across two interleaved courses at one site.
- [ ] `teeAnomalies` is appended to, never assigned.

---

## 17. Rules that outrank everything else

If a change would break one of these, it is the wrong change.

1. **Ground truth must never reach model input.** `Mark`, `Scorecard`, `Correction`, and a `.user`
   `Event`. Course geometry is the one legitimate crossing, and only via an exported course file.
2. **One clock, and never accumulate across a boundary.**
3. **Storage is metres; yards are formatting.**
4. **Capture everything; the user corrects the rest.** Never refuse to record because something is
   missing. A log with no coordinate is a real row.
5. **Never substitute a plausible value for a missing one.** Not the last known position, not
   another tee's yardage, not "now" for a crashed round's end, not a nil-coalesced coordinate. Every
   single one of those shipped once and each produced a screen that looked correct and was wrong.
6. **A modelled number is marked as modelled** — `~` for plays-like and for a measured length
   standing in for a card number, dimmed italic for a hypothesis, orange dashes for a simulated
   position. A model rendered like a measurement is the failure mode this product is most exposed
   to.
7. **Drawn is tested.** The rectangle you fill is the rectangle the gesture hits.
8. **A retired control is not retired until the branch that reads it is gone.**
9. **Never commit recorded rounds or credentials** — `Sessions/`, `*.m4a`, `*.wav`, `.env`,
   `secrets.json`. Real audio of a foursome is other people's voices. Course files **are**
   committable: no voices, no credentials, and a course does not change between rounds.

---

## 18. Things you will be tempted to do, that were tried and failed

A short list, because each cost a day or more and each looks correct going in.

| Tempting | What happened |
|---|---|
| `imageSR=3857` for the DEM | 1.26× the ground metre at 37°N; a sample displaced ~270 m |
| `format=bsq` | 990,000 bytes for a 300 × 800 request; dimensions unverifiable |
| Georeference from the requested bbox | The service snaps outward — 146 m in one measured call |
| Infer a card's unit from its numbers | No threshold separates six real cards |
| Replace inline HTML tags with a space | `1<span>7</span>` → `1 7`; the whole row shifts |
| One `(id, kit)` model slot | The two models evict each other, per burst |
| Gate `modelFolder` on weights **and** tokenizer | Downloads the model twice |
| A bare Application Support `downloadBase` | Re-downloads half a gigabyte every launch |
| Accumulate audio offsets across segments | The round silently compresses by the length of every call |
| `bufferStartTime` on live input | One repeated volatile word, no finalized results at all |
| Fixed-threshold VAD | Ate a whole spoken phrase at 0.031 peak over a 0.009 floor |
| `usePrefillPrompt = false` to stop translation | Produced translation, tagged with the right language |
| A single locale for a bilingual round | `en_US` silently drops every Korean utterance |
| Feed the player and targets to the framing fit | Three separate reported bugs at once |
| Four gestures on the hole view | A drag on a target never reached the handler |
| `.overlay(alignment: .bottomTrailing)` + alignment guide | Drew the suffix **on** the number |
| `HStack` for the big distance and its suffix | The number slid 13% of screen width when the ground sloped |
| A greedy nearest-next-tee routing chain | Walked into the neighbouring course; confident 18 holes, par 63 |
| `out tags geom` | 28 relations, zero members |
| Overpass for name search | 12.5 s and a 504, against 0.72 s from Nominatim |
| Free-form geocoding of a course name | Eighteen rivers and no golf course |
| Compare session URLs with `==` | 29 logs on disk, "Nothing on this hole" on screen |
| `[weak self]` on a location delegate | Never resumes; no log, no error, nothing anywhere |
| Rank or share-of-back-tee for tee anomalies | Not comparable across holes; one fault cascades into four |
| Trim leading silence by copying the buffer | Shifts every timestamp silently |
| A `holedOut` flag instead of a score | Dies on relaunch, never reaches the card |
| A `simulated` flag instead of disabling MARK | One forgetful consumer corrupts an accuracy number |
| Set the dragged object's centre to the fingertip | Picking something up moves it |
| `Text("a" + "b")` with markdown | Renders literal asterisks |
| A `.dem` named `<id>.elevation.json` | Fails to parse on every course scan |
| A non-optional new `Hole` field | Every course file already on disk becomes unreadable |
| A non-optional new **archive** field | Same failure, one layer up — see `terrainOmitted` (§12.5.1a) |
| Bumping the archive version for an *added* key | An older build refuses a document it reads perfectly |
| Remembering the previous roster on New round | Start goes live over names nobody looked at (§14.2a) |
| A `TextEditor` beside the import buttons | Grows to fit 400 KB and pushes Import off the screen |
| Reading a picked file without the security scope | A permission error that reads as a corrupt export |
| Describing terrain's cost as "121 KB of this export" | Contradicts the size row the moment the toggle flips |
