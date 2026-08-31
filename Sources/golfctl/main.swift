// golfctl — macOS CLI. The iteration surface for everything off-device.
//
// Every stage caches into the session folder, so stages are independently
// re-runnable: re-tuning a prompt never re-runs a 30-minute transcription.
//
//   golfctl record  --out Sessions --players 'steve,dave' --course "Naelgol"
//   golfctl inspect <session>
//   golfctl course  sample --out Courses   |   golfctl course show <course.json>
//   golfctl transcribe <session> --asr apple|whisperkit          (phase 2)
//   golfctl bundle     <session>                                 (phase 3)
//   golfctl reconstruct <session> --model ... --prompt PATH --schema PATH
//   golfctl eval       <session>                                 (phase 4)
//
// --prompt/--schema take PATHS, defaulting to ./Resources/*. That is what keeps
// prompt tuning to an edit-and-rerun loop instead of a rebuild — the package
// deliberately declares no bundle resources, so there is no Bundle.module.

import Foundation
import AVFoundation
import GolfSessionFormat
import GolfCaptureCore
import GolfCourse
import GolfTranscription
import AnthropicClient

// Line-buffer stdout: piped output from a long-running recorder is useless if it
// only appears when the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Tiny arg parsing
// Hand-rolled on purpose: swift-argument-parser arrives in phase 3 with the
// subcommands that need it. One dependency less to move while the shape is still moving.

struct Args {
    let subcommand: String
    let positionals: [String]
    private let flags: [String: String]

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        subcommand = rest.first ?? "help"
        if !rest.isEmpty { rest.removeFirst() }
        var f: [String: String] = [:]
        var p: [String] = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    f[key] = rest[i + 1]; i += 2
                } else {
                    f[key] = "true"; i += 1
                }
            } else {
                p.append(a); i += 1
            }
        }
        flags = f
        positionals = p
    }

    func string(_ k: String, default d: String? = nil) -> String? { flags[k] ?? d }
    func int(_ k: String) -> Int? { flags[k].flatMap(Int.init) }
    func bool(_ k: String) -> Bool { flags[k] == "true" }
    func list(_ k: String) -> [String] {
        (flags[k] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One name per player, comma-separated: `--players 'steve,dave,mike'`.
    ///
    /// It used to be `name=alias|alias`; aliases were removed on 2026-08-31 and the
    /// `=` half went with them, because a syntax still accepted and no longer doing
    /// anything is worse than one that is gone. Anything after an `=` is therefore
    /// **refused out loud** rather than folded into the name, which would file a
    /// round under a player called "steve=스티브".
    func players(_ k: String) -> [Player] {
        list(k).map { entry in
            let name = entry.trimmingCharacters(in: .whitespaces)
            if let head = name.split(separator: "=").first, name.contains("=") {
                fail("--players no longer takes aliases — write '\(head)', not '\(name)'")
            }
            return Player(name: name)
        }
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("golfctl: \(msg)\n".utf8))
    exit(1)
}

// MARK: - record

/// Records a round from the Mac. This is the Phase 1 gate: a session folder
/// that round-trips without a phone in the loop.
func cmdRecord(_ args: Args) {
    let root = URL(fileURLWithPath: args.string("out", default: "Sessions")!)
    let wantsAudio = !args.bool("no-audio")
    if wantsAudio, AudioRecorder.permission != .granted {
        // Blocking here is deliberate: an unauthorized record() hangs, so the
        // answer has to be settled before the round starts.
        let sem = DispatchSemaphore(value: 0)
        var result = AudioRecorder.Permission.denied
        Task { result = await AudioRecorder.requestPermission(); sem.signal() }
        sem.wait()
        if result != .granted {
            fail("microphone permission denied. Run from a terminal so macOS can prompt, "
               + "grant it in System Settings > Privacy & Security > Microphone, "
               + "or record without audio: golfctl record --no-audio")
        }
    }

    let session = RoundSession.create(under: root,
                                      players: args.players("players"),
                                      course: args.string("course"),
                                      recordAudio: wantsAudio && !args.bool("mic-off"),
                                      recordLocation: !args.bool("no-gps"))
    session.location.requestAuthorization()

    do { try session.start() } catch { fail("could not start: \(error)") }

    print("recording -> \(session.folder.url.path)")
    let roster = args.players("players")
    print("players: \(roster.isEmpty ? "(none)" : roster.map(\.name).joined(separator: ", "))")
    print("audio:   \(wantsAudio ? session.audio.describedFormat : "disabled (--no-audio)")")
    if !session.locationAvailable {
        print("gps:     UNAVAILABLE — CoreLocation needs a bundled app, and this is a CLI.")
        print("         Audio and marks still record; the GPS track comes from the phone.")
    }
    // --live proves the whole capture chain in one run: **one** tap feeding the
    // `.m4a` and the recognizer at once. Without it the recorder and the live
    // recognizer are only ever exercised separately, and the thing that actually
    // has to work — both off the same buffers — is the untested part.
    // --live proves the whole capture chain in one run: **one** tap feeding the
    // `.m4a` and the recognizer at once. Without it the recorder and the live
    // recognizer are only ever exercised separately, and the thing that actually
    // has to work — both off the same buffers — is the untested part.
    //
    // **Recording is a burst, not the round** *(user decision, 2026-08-27)*. The
    // app starts with the microphone off and the user taps it on and off, so a
    // round holds several segments with real gaps between them. That sequence —
    // stop the engine, close the segment with a true `t1`, finalise the analyzer,
    // start a fresh one into the next segment — is the new thing that can break,
    // and this is the only machine it can be watched on. `r ENTER` drives it.
    let wantsLive = args.bool("live")
    let showVolatile = args.bool("live-volatile")
    let liveModel = args.string("model", default: WhisperModels.defaultID)!
    let locales = args.list("locale").isEmpty
        ? TranscriptionContext.defaultLocales
        : args.list("locale")
    let liveContext = TranscriptionContext.forRound(players: roster, locales: locales)

    var liveTranscriber: WhisperLiveTranscriber?

    /// Attach a fresh recognizer to the burst that is now recording.
    ///
    /// **A new one per burst.** The *model* is cached by `WhisperEngine` and
    /// survives, which is the part that costs seconds; the window and its clock are
    /// per burst, so a ten-minute pause between bursts costs nothing to get right.
    func beginLiveTranscription() {
        guard wantsLive else { return }
        let live = WhisperLiveTranscriber(model: liveModel)
        let sem = DispatchSemaphore(value: 0)
        var format: AVAudioFormat?
        var failure: Error?
        Task {
            do {
                format = try await live.start(context: liveContext) { line in
                    // Whisper has no volatile/final distinction of its own — this
                    // wrapper makes one, by re-decoding a rolling window and
                    // committing at a silence. A `~` line is a hypothesis that the
                    // next pass will rewrite; only the plain ones are kept.
                    guard line.isFinal || showVolatile else { return }
                    let tag = line.utterance.locale ?? "?"
                    let mark = line.isFinal ? " " : "~"
                    print("  \(mark)[\(tag)] \(line.utterance.text)")
                }
            } catch { failure = error }
            sem.signal()
        }
        sem.wait()
        if let failure { print("  live: unavailable — \(failure)"); return }
        guard let format else { print("  live: no input format"); return }

        session.audio.listen(AudioTap(format: format) { buffer, _ in
            live.append(buffer, at: SessionClock.now())
        })
        liveTranscriber = live
        print("  live:  \(liveModel), language auto-detected, never translated")
    }

    /// Ending a burst has to let the recognizer finalise: the tail of the window is
    /// still an uncommitted hypothesis when the microphone stops, and tearing down
    /// on the spot throws it away — which looks exactly like the recognizer missing
    /// the end of a hole, and the end of a hole is when scores get said.
    ///
    /// Order matters. The audio stops **first**, so the segment closes with a real
    /// `t1` and no further buffers arrive; then the recognizer is drained; then the
    /// tap is detached, which must happen before the next burst or `start()`
    /// re-arms this dead recognizer's tap.
    func endLiveTranscription() {
        guard let live = liveTranscriber else { session.audio.listen(nil); return }
        let sem = DispatchSemaphore(value: 0)
        Task { await live.finish(); sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        session.audio.listen(nil)
        liveTranscriber = nil
    }

    /// The record button, on a keyboard.
    func setRecording(_ on: Bool) {
        if on {
            guard !session.audioRunning else { print("  already recording"); return }
            do { try session.startAudio() }
            catch { print("  could not start recording: \(error)"); return }
            print("  ● recording -> \(SessionFolder.audioFileName(index: session.audio.segments().count))")
            beginLiveTranscription()
        } else {
            guard session.audioRunning else { print("  not recording"); return }
            session.stopAudio()          // closes the segment; the tap goes quiet
            endLiveTranscription()       // then drain, so the last phrase survives
            print("  ■ stopped")
        }
    }

    if wantsAudio, session.audioRunning { beginLiveTranscription() }

    /// One teardown, so every exit path closes the folder the same way.
    func finishRound() {
        if session.audioRunning { session.stopAudio() }
        endLiveTranscription()
        session.stop()
        summarize(session.folder)
    }

    print("")
    print("  ENTER        mark")
    print("  <name>ENTER  mark for that player")
    print("  r ENTER      start/stop recording\(wantsLive ? " + live transcription" : "")")
    print("  q ENTER      stop")
    print("")
    print(session.audioRunning
          ? "  ● recording from the start (pass --mic-off to begin with it off)"
          : "  ■ not recording — press r to start")
    print("")

    // Ctrl-C must still close the folder cleanly, or the round is unreadable.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\ninterrupted")
        finishRound()
        exit(0)
    }
    sigint.resume()
    signal(SIGINT, SIG_IGN)

    let players = roster.map(\.id)
    let duration = args.int("seconds")
    let input = DispatchQueue(label: "golfctl.stdin")
    input.async {
        var quit = false
        while let line = readLine(strippingNewline: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s == "q" || s == "quit" { quit = true; break }
            // The record button. Synchronous on the stdin queue on purpose: two
            // overlapping toggles would race the engine against its own teardown.
            if s == "r" || s == "rec" || s == "record" {
                setRecording(!session.audioRunning)
                continue
            }
            let who = s.isEmpty ? (players.first ?? "me") : s
            guard let m = session.mark(player: who) else { continue }
            if let lat = m.lat, let lon = m.lon {
                print(String(format: "  mark %d: %@ @ %.6f, %.6f (fix %.0fs old)",
                             session.markCount, who, lat, lon,
                             Double(m.fixAgeMs ?? 0) / 1000))
            } else {
                print("  mark \(session.markCount): \(who) @ no fix yet — time recorded")
            }
        }
        // End-of-stdin is not a reason to stop a timed run: piping marks in from
        // a file must not cut the recording short.
        guard quit || duration == nil else { return }
        DispatchQueue.main.async {
            finishRound()
            exit(0)
        }
    }

    if let seconds = duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            finishRound()
            exit(0)
        }
    }
    dispatchMain()
}

// MARK: - models

/// Which Whisper models can be run. English-only builds are never listed.
func cmdModels(_ args: Args) {
    runBlocking {
        let models = await WhisperModels.available()
        print("multilingual Whisper models (\(models.count)):")
        for m in models {
            let mark = m.id == WhisperModels.defaultID ? "*" : " "
            print("  \(mark) \(m.id)")
        }
        print("")
        print("  * default. Pick one with --model <id>.")
        print("  English-only (.en) and distil-* builds are deliberately not listed:")
        print("  they cannot produce Korean at all, and the failure is silence.")
    }
}

// MARK: - live

/// Replay an audio file through the **live** path, in real time.
///
/// **This is the only way to see the live wrapper work without a microphone**, and
/// it is the rig for the thing that is easy to get wrong: Whisper is a batch model,
/// so "live" here means a rolling window re-decoded every pass, published as a
/// hypothesis, and committed at a silence. Whether words actually appear while
/// someone is still talking is a property of that loop, not of the model, and this
/// exercises exactly that loop with exactly the buffers the tap would deliver.
func cmdLive(_ args: Args) {
    guard let path = args.positionals.first else {
        fail("usage: golfctl live <audio-file> [--model VARIANT] [--realtime]")
    }
    let url = URL(fileURLWithPath: path)
    let model = args.string("model", default: WhisperModels.defaultID)!
    let realtime = args.bool("realtime")

    guard let format = WhisperLiveTranscriber.inputFormat(),
          let file = try? AVAudioFile(forReading: url) else {
        fail("live: cannot read \(path)")
    }
    guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        fail("live: cannot convert \(file.processingFormat) to 16 kHz mono float")
    }

    print("live replay: \(url.lastPathComponent)")
    print("model:       \(model) (downloads on first use)")
    print("")

    runBlocking {
        // Loaded up front and out loud: the first run of a variant pulls several
        // hundred megabytes, and a silent minute reads as a hang.
        print("  loading model…")
        do { _ = try await WhisperEngine.shared.kit(model: model) }
        catch { fail("live: could not load \(model): \(error)") }
        print("  ready\n")
        let live = WhisperLiveTranscriber(model: model)
        let start = SessionClock.now()
        _ = try await live.start(context: TranscriptionContext()) { line in
            let tag = line.utterance.locale ?? "?"
            let at = Double(line.utterance.t0 - start) / 1000
            // An empty hypothesis is the *clear* signal a UI needs after a commit;
            // on a terminal it is just a blank line.
            if line.utterance.text.isEmpty { return }
            if line.isFinal {
                print(String(format: "  [%6.2fs] (%@) %@", at, tag, line.utterance.text))
            } else {
                print(String(format: "         ~ (%@) %@", tag, line.utterance.text))
            }
        }

        // A tap buffer is about 85 ms; feeding the same size keeps the window
        // arithmetic honest rather than handing the decoder one giant block.
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.085)
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: chunk) else { break }
            // **Bounded by `file.length`, and a throw is end-of-file.**
            // `AVAudioFile.read` is documented to return zero frames past the end;
            // on the AIFC that `say` writes it throws `nilError` instead, which
            // read as the whole command failing when it had in fact just finished.
            do { try file.read(into: input, frameCount: chunk) } catch { break }
            if input.frameLength == 0 { break }
            guard let out = AudioRecorder.convert(input, with: converter,
                                                  from: file.processingFormat) else { continue }
            live.append(out, at: SessionClock.now())
            if realtime {
                try? await Task.sleep(nanoseconds: UInt64(Double(input.frameLength)
                    / file.processingFormat.sampleRate * 1_000_000_000))
            }
        }
        let fed = Double(file.framePosition) / file.processingFormat.sampleRate
        print(String(format: "\n  fed %.1fs of audio; draining…", fed))
        await live.finish()
        print("")
        print("done")
    }
}

// MARK: - inspect

func cmdInspect(_ args: Args) {
    guard let path = args.positionals.first else { fail("usage: golfctl inspect <session>") }
    summarize(SessionFolder(url: URL(fileURLWithPath: path)))
}

/// Reads a session folder back the way the Mac side will. This is the actual
/// assertion behind "the session folder round-trips".
func summarize(_ folder: SessionFolder) {
    print("")
    print("session: \(folder.url.lastPathComponent)")
    guard let meta = try? folder.readMeta() else {
        print("  no meta.json — not a session folder")
        return
    }
    let start = SessionClock.date(from: meta.start)
    let dur = meta.end.map { Double($0 - meta.start) / 1000 }
    print("  id       \(meta.sessionID)")
    print("  course   \(meta.course ?? "—")")
    print("  players  \(meta.players.isEmpty ? "—" : meta.players.map(\.name).joined(separator: ", "))")
    print("  device   \(meta.device)")
    print("  start    \(start)")
    print("  duration \(dur.map { String(format: "%.1fs", $0) } ?? "(still open)")")
    print("  audio    \(meta.audioFormat)\(meta.audioRoute.map { " via \($0)" } ?? "")")

    let gps = folder.readAll(.gps, as: GPSFix.self)
    let motion = folder.readAll(.motion, as: MotionSample.self)
    let alt = folder.readAll(.altitude, as: AltitudeSample.self)
    let marks = folder.readAll(.marks, as: Mark.self)
    let corrections = folder.readAll(.corrections, as: Correction.self)
    let segments = folder.readAll(.audio, as: AudioSegment.self)

    print("")
    print("  streams")
    print("    gps          \(gps.count)")
    print("    motion       \(motion.count)")
    print("    altitude     \(alt.count)")
    print("    marks        \(marks.count)      [ground truth]")
    print("    corrections  \(corrections.count)      [ground truth]")
    print("    audio        \(segments.count) segment(s)")

    for s in segments {
        let secs = s.t1.map { Double($0 - s.t0) / 1000 } ?? 0
        let bytes = (try? FileManager.default
            .attributesOfItem(atPath: folder.url.appendingPathComponent(s.file).path)[.size]) as? Int ?? 0
        print(String(format: "      %@  %.1fs  %d KB  (%@)",
                     s.file, secs, bytes / 1024, s.endReason ?? "open"))
    }

    if let first = alt.first, let last = alt.last, alt.count > 1 {
        print(String(format: "    elevation    %.1f m net, range %.1f m",
                     last.relative - first.relative,
                     (alt.map(\.relative).max() ?? 0) - (alt.map(\.relative).min() ?? 0)))
    }

    // The one clock: every stream must be comparable without conversion.
    //
    // **A segment contributes both ends, not just `t0`.** Every other stream is
    // instants, so a row is one point; a segment is an interval, and taking only
    // its start reported a two-burst round as ending where its last burst *began*
    // — 8.3s for a 14.2s round, which reads as lost recording rather than a
    // mis-drawn ruler. Now that recording is a toggle, most rounds have several
    // segments and the last one is usually the longest.
    var span: (Millis, Millis)?
    for t in gps.map(\.t) + motion.map(\.t) + alt.map(\.t) + marks.map(\.t)
            + segments.map(\.t0) + segments.compactMap(\.t1) {
        span = span.map { (Swift.min($0.0, t), Swift.max($0.1, t)) } ?? (t, t)
    }
    if let span {
        print("")
        print("  clock span   \(span.0) … \(span.1)  (\(String(format: "%.1f", Double(span.1 - span.0) / 1000))s)")
        if span.0 < meta.start { print("    ⚠︎ a sample predates meta.start — clocks disagree") }
    }
}

// MARK: - course

/// Course geometry: the tee/green/hole file the hole view draws from.
///
/// Geometry is NOT ground truth — a shot cannot be placed on a hole without
/// knowing where the hole is, so `Courses/<id>.json` is a legitimate model input.
/// A survey walked with the MARK button must be *exported* into one of these
/// first; `GolfReconstruction` reads the course file and never a session's
/// `marks.jsonl`. See docs/research-course-map.md §2.5.
func cmdCourse(_ args: Args) {
    let action = args.positionals.first ?? "show"
    switch action {
    case "sample":
        let dir = URL(fileURLWithPath: args.string("out", default: "Courses")!)
        let store = CourseStore(directory: dir)
        do { try store.save(SampleCourse.naelgol) }
        catch { fail("could not write sample course: \(error)") }
        print("wrote \(store.url(for: SampleCourse.naelgol.id).path)")
        describe(SampleCourse.naelgol, holeRef: nil)

    case "show":
        guard args.positionals.count > 1 else { fail("usage: golfctl course show <course.json>") }
        let url = URL(fileURLWithPath: args.positionals[1])
        guard let data = try? Data(contentsOf: url),
              let course = try? JSONDecoder().decode(Course.self, from: data)
        else { fail("could not read a course from \(url.path)") }
        let store = CourseStore(directory: url.deletingLastPathComponent())
        let terrain = store.loadElevation(id: course.id)
        if let terrain {
            let posts = terrain.nativePosts
            print(String(format: "terrain    %@, %@ datum, %d x %d posts at %.1f x %.1f m (native %.0f m)",
                         terrain.source.rawValue as NSString, terrain.datum.rawValue as NSString,
                         terrain.width, terrain.height, posts.east, posts.north,
                         terrain.nativeResolution))
        }
        describe(course, holeRef: args.string("hole"), terrain: terrain)

    case "import":
        cmdCourseImport(args)

    case "osm":
        cmdCourseOSM(args)

    case "elevation":
        cmdCourseElevation(args)

    default:
        fail("course: unknown action '\(action)' — try sample, show, import, osm or elevation")
    }
}

/// `golfctl course import --url URL | --card FILE [--name NAME] [--unit metres|yards]`
///
/// Writes `Courses/<id>.json` with par, handicap and per-tee distance — and no
/// coordinates, because no card has any. Geometry arrives later from a track, a
/// survey, or the editor; `--merge` keeps whatever is already placed.
func cmdCourseImport(_ args: Args) {
    let urlFlag = args.string("url")
    let cardFlag = args.string("card")
    guard urlFlag != nil || cardFlag != nil else {
        fail("""
        usage: golfctl course import --url <page> | --card <file.pdf|.jpg|.png|.txt>
                                     [--name "Angeles National"] [--id angeles-national]
                                     [--out Courses] [--merge] [--dry-run] [--force]
                                     [--fetch-only]     stop before the model; needs no API key
                                     [--unit metres|yards]        this card, overrides everything
                                     [--unit-default metres|yards]  when the card is silent (yards)
                                     [--prompt PATH] [--schema PATH] [--model ID]
        """)
    }

    // --fetch-only stops before the model. Worth having on its own: it shows
    // exactly what the extractor will see, which is the only way to tell "this
    // site has no card" apart from "the fetch got a splash page".
    if args.bool("fetch-only") {
        guard let u = urlFlag else { fail("--fetch-only needs --url") }
        runBlocking {
            let input = try await CourseImport.fetch(u)
            if case .text(let t, let origin) = input {
                print("# \(origin)\n")
                print(t)
            }
        }
        return
    }

    guard let config = AnthropicClient.Config.fromEnvironment() else {
        fail("ANTHROPIC_API_KEY is not set. Extraction runs on the Mac; export it and retry.")
    }
    let client = AnthropicClient(config: config)
    let model = AnthropicClient.ModelConfig(
        model: args.string("model", default: "claude-opus-5")!,
        maxTokens: args.int("max-tokens") ?? 16_000,
        effort: args.string("effort"))

    let promptPath = args.string("prompt", default: "Prompts/course-card.md")!
    let schemaPath = args.string("schema", default: "Prompts/course-card.schema.json")!
    let outDir = URL(fileURLWithPath: args.string("out", default: "Courses")!)

    var unitOverride: DistanceUnit?
    if let u = args.string("unit") {
        guard let parsed = DistanceUnit(rawValue: u) else {
            fail("--unit must be metres or yards, not '\(u)'")
        }
        unitOverride = parsed
    }
    // What to assume when the card is silent. Yards, because the courses this is
    // aimed at are mainly American; --unit-default flips it for a metric region.
    var unitDefault = DistanceUnit.assumedWhenUnstated
    if let u = args.string("unit-default") {
        guard let parsed = DistanceUnit(rawValue: u) else {
            fail("--unit-default must be metres or yards, not '\(u)'")
        }
        unitDefault = parsed
    }

    runBlocking {
        // 1. Get the input in front of the model.
        let input: CourseImport.Input
        if let u = urlFlag {
            print("fetching \(u) …")
            input = try await CourseImport.fetch(u)
            if case .text(let t, _) = input {
                print("  \(t.count) characters of text")
                if t.count < 200 {
                    print("  note: almost nothing came back — the site may be JS-rendered,")
                    print("        or unreachable from outside Korea. Try --card with a screenshot.")
                }
            }
        } else {
            input = try CourseImport.input(fromFile: cardFlag!)
        }

        // 2. Extract.
        print("reading the card with \(model.model) …")
        let (card, rawResponse) = try await CourseImport.extract(
            input, courseName: args.string("name"),
            promptPath: promptPath, schemaPath: schemaPath,
            model: model, client: client)

        // 3. Resolve the unit. This is the step that silently ruins an import, so
        //    an assumed unit is always said out loud — see
        //    research-scorecard-import.md §3.1 for why it is assumed and not inferred.
        let (unit, unitSource) = card.resolveUnit(preferring: unitOverride,
                                                  assuming: unitDefault)
        switch unitSource {
        case .explicit: print("  unit: \(unit.rawValue) — from --unit")
        case .printed:  print("  unit: \(unit.rawValue) — printed on the card")
        case .assumed:
            print("  unit: \(unit.rawValue) — ASSUMED. The card does not say, and no rule based")
            print("        on the totals can tell (an ordinary US card from the tips and a metric")
            print("        card occupy the same range). Pass --unit metres if this course is metric.")
        }
        if let w = card.unitWarning() { print("  warn distanceOutOfRange: \(w)") }

        // 4. Reconcile against the card's own printed totals.
        let issues = card.issues(unit: unit)
        for i in issues { print("  \(i)") }
        let blocking = issues.filter(\.blocking)

        let id = args.string("id") ?? CourseImport.slug(card.aliases.first ?? card.courseName)
        var course = card.course(id: id, source: .card,
                                 attribution: input.origin,
                                 unit: unit, updated: SessionClock.now())

        let store = CourseStore(directory: outDir)
        if args.bool("merge"), let existing = try? store.load(id: id) {
            course = existing.merging(card: course)
            print("  merged into the existing \(id) — placed tees and greens kept")
        }

        describe(course, holeRef: nil)

        if !blocking.isEmpty {
            print("  \(blocking.count) blocking issue(s) above: the extracted holes do not")
            print("  reconcile with the totals printed on the card. Nothing was written.")
            print("  Re-run with --force to write it anyway and fix it in the editor.")
            if !args.bool("force") { fail("card did not reconcile") }
        }
        if args.bool("dry-run") { print("  --dry-run: nothing written"); return }

        try store.save(course)
        // Cache the input and the raw response beside the output. Re-tuning the
        // prompt must never re-fetch a page or re-read a photograph.
        let cache = outDir.appendingPathComponent(".\(id).import")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if case .text(let t, _) = input {
            try? t.write(to: cache.appendingPathComponent("input.txt"), atomically: true,
                         encoding: .utf8)
        }
        try? rawResponse.write(to: cache.appendingPathComponent("response.json"))
        print("wrote \(store.url(for: id).path)")
        print("note: this course has a card and no coordinates. Place tees and greens")
        print("      in the app's course editor, or derive them from a recorded round.")
    }
}

/// The CLI is synchronous top-level code; extraction is not. One place to bridge,
/// rather than an async main that would reshape every existing subcommand.
func runBlocking(_ body: @escaping () async throws -> Void) {
    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    Task {
        do { try await body() } catch { failure = error }
        done.signal()
    }
    done.wait()
    if let failure { fail("\(failure)") }
}

func describe(_ course: Course, holeRef: String?, terrain: Elevation? = nil) {
    print("")
    print("course     \(course.name)  [\(course.id)]")
    print("source     \(course.source.rawValue)\(course.attribution.map { "  — \($0)" } ?? "")")
    if let u = course.cardUnit { print("card unit  \(u.rawValue) as published, stored as metres") }
    let nines = course.nines
    print("holes      \(course.holes.count)\(nines.isEmpty ? "" : "  in \(nines.count) nines: \(nines.joined(separator: ", "))")")
    print("")

    let holes = holeRef.map { r in course.holes.filter { $0.ref == r || $0.id == r } } ?? course.holes
    if holes.isEmpty { fail("no hole '\(holeRef ?? "")' in \(course.name)") }

    print("  HOLE     PAR  HCP   LEN   RISE  BEARING  F/C/B FROM TEE     TEES")
    for h in holes {
        let tee = h.defaultTee
        // %@ ignores width flags on Darwin, so pad the id here rather than in the
        // format string — composite ids ("황룡/3") are wider than a bare number.
        let ref = h.id.padding(toLength: max(7, h.id.count), withPad: " ", startingAt: 0)
        let hcp = h.handicap.map { String(format: "%3d", $0) } ?? "  ?"
        let len = h.length(from: tee).map { String(format: "%4.0f", $0) } ?? "   ?"

        // A card-only hole has par and yardage and no coordinates. Print what it
        // has rather than inventing a plane at (0, 0) — see research-scorecard-import.md §5.
        guard let g = h.geometry(tee: tee) else {
            print(String(format: "  %@  %3d  %@  %@     ?        ?         — no geometry —   %@",
                         ref as NSString, h.par, hcp as NSString, len as NSString,
                         h.tees.map(\.name).joined(separator: "/") as NSString))
            continue
        }
        let d = g.distances(from: g.teeAt)
        // From the sidecar when there is one, so the column says what the DEM
        // says rather than what the file's own (usually absent) altitudes do.
        let rise = h.elevationDelta(from: g.teeAt, using: terrain)
        let riseText = rise.map { String(format: "%+5.0f", $0) } ?? "    ?"
        let plays = rise.map { Geodesy.playsLike(distance: d.center, elevationDelta: $0) }
        print(String(format: "  %@  %3d  %@  %@  %@  %6.0f°  %4.0f/%4.0f/%4.0f  %@   %@",
                     ref as NSString, h.par, hcp as NSString, len as NSString,
                     riseText as NSString,
                     g.bearing, d.front, d.center, d.back,
                     (plays.map { String(format: "plays %.0f", $0) } ?? "         ") as NSString,
                     h.tees.map(\.name).joined(separator: "/") as NSString))
    }
    print("")

    // The card-versus-ground check. Cheap, and it is the one that catches a tee
    // dropped on the wrong hole or a card read in the wrong unit.
    let off = course.holes.compactMap { h -> (String, Double)? in
        guard let g = h.geometry(), let gap = g.lengthDisagreement, gap > 25 else { return nil }
        return (h.id, gap)
    }
    if !off.isEmpty {
        print("  warning: \(off.count) hole(s) where the card and the placed geometry disagree by >25 m:")
        for (ref, gap) in off.prefix(6) { print(String(format: "           hole %@ off by %.0f m", ref as NSString, gap)) }
        print("           one of the two is wrong — check the tee placement, or the card's unit.")
    }
    let cardOnly = course.holesWithoutGeometry
    if !cardOnly.isEmpty {
        print("  note: \(cardOnly.count) hole(s) have a card but no coordinates — nothing to draw yet.")
        print("        Place a tee and a green centre in the app's course editor.")
    }
    let missing = course.holes.filter { $0.hasGeometry && $0.green.polygon.count < 3 }
    if !missing.isEmpty {
        print("  note: \(missing.count) hole(s) have no green outline — front/back fall back")
        print("        to stored points, which are only right from the surveyed angle.")
    }
}

// MARK: - transcribe

func cmdTranscribe(_ args: Args) {
    guard let path = args.positionals.first else {
        fail("transcribe: needs a session folder — golfctl transcribe <session>")
    }
    let folder = SessionFolder(url: URL(fileURLWithPath: path))
    guard let meta = try? folder.readMeta() else {
        fail("transcribe: no readable meta.json in \(path)")
    }

    // **WhisperKit is the default as of 2026-08-27** *(user decision)*. Apple's
    // path stays reachable because Phase 2 is a measurement, not a preference —
    // `Transcriber` is a protocol precisely so both run over the same audio.
    let asr = args.string("asr", default: "whisperkit")!
    guard asr == "apple" || asr == "whisperkit" else {
        fail("transcribe: --asr must be 'whisperkit' or 'apple'")
    }
    let model = args.string("model", default: WhisperModels.defaultID)!

    // Comma-separated, and the default is the pair. A round is bilingual unless
    // told otherwise: one locale cannot cover it, and the failure is silent.
    let locales = args.list("locale").isEmpty
        ? TranscriptionContext.defaultLocales
        : args.list("locale")
    // --no-vocab is an A/B switch, not a convenience: whether contextual strings
    // actually help is measurable, and since diarization was cut it is the only
    // lever left protecting a spoken name from becoming a different word.
    let context = args.bool("no-vocab")
        ? TranscriptionContext(locales: locales)
        : TranscriptionContext.forRound(players: meta.players, locales: locales,
                                        extra: args.list("vocab"))
    if args.bool("show-vocab") {
        print("contextual strings (\(context.contextualStrings.count)):")
        print(context.contextualStrings.joined(separator: ", "))
        return
    }

    if asr == "apple" {
        guard #available(macOS 26, iOS 26, *) else {
            fail("transcribe: SpeechAnalyzer needs macOS 26 / iOS 26")
        }
        guard AppleTranscriber.isAvailable else {
            fail("transcribe: on-device transcription is unavailable on this machine")
        }
    } else {
        print("model:   \(model) (downloads on first use)")
    }

    /// One progress line, whichever engine ran.
    func show(_ p: SessionTranscriber.Progress) {
        print(String(format: "  [%d/%d] %@ — %d utterances, %.0fs audio",
                     p.segment + 1, p.total, p.file, p.utterances, p.seconds))
    }

    runBlocking {
        let driver = SessionTranscriber(folder: folder)
        let report: SessionTranscriber.Report
        if asr == "apple" {
            guard #available(macOS 26, iOS 26, *) else { return }
            report = try await driver.run(AppleTranscriber(), context: context,
                                          force: args.bool("force"), onProgress: show)
        } else {
            report = try await driver.run(WhisperTranscriber(model: model), context: context,
                                          force: args.bool("force"), onProgress: show)
        }

        if !report.unavailableLocales.isEmpty {
            // Loud, because an English-only run over a bilingual round looks
            // exactly like a round in which nobody spoke Korean.
            print("UNAVAILABLE: no on-device model for "
                + report.unavailableLocales.joined(separator: ", ")
                + " — this pass ran " + report.locales.joined(separator: " + ") + " only")
        }
        if !report.skipped.isEmpty {
            print("cached: \(report.skipped.count) segment(s) already transcribed "
                + "(--force to redo)")
        }
        if !report.missing.isEmpty {
            // Never silent: the index claims audio that is not on disk, so the
            // transcript is short and would otherwise look complete.
            print("MISSING: \(report.missing.count) segment(s) in audio.jsonl have no "
                + "file on disk — indices \(report.missing.map(String.init).joined(separator: ", "))")
        }
        if report.transcribed.isEmpty {
            // "0 utterances, 0.0x realtime" on a fully cached run reads as a
            // failure. Nothing to do is not the same as nothing found.
            print("nothing to do — every segment is already transcribed")
            return
        }
        print("wrote \(folder.path(.transcript).path)")
        print("\(report.utterances) utterances from \(report.transcribed.count) segment(s)"
            + " in \(report.locales.joined(separator: " + "))")
        if let x = report.realtimeFactor {
            print(String(format: "%.0fs audio in %.1fs — %.1f× realtime",
                         report.audioSeconds, report.wallSeconds, x))
        }
    }
}

// MARK: - main

/// Re-read part of a recording with a chosen model — the CLI half of the app's
/// "Transcribe again" button.
///
/// **This is the only place that path can be watched on this machine.** The app
/// reaches it from a log entry's menu, and scripted taps do not exist here; what
/// runs underneath is exactly the same two calls, `AudioExcerpt.samples` then
/// `WhisperTranscriber.transcribe(samples:)`, so a bug in either shows up here
/// first. It reads no session and writes nothing.
func cmdRelisten(_ args: Args) {
    guard let path = args.positionals.first else {
        fail("usage: golfctl relisten <audio-file> [--from S] [--to S] [--model VARIANT]")
    }
    let url = URL(fileURLWithPath: path)
    let from = Double(args.string("from", default: "0")!) ?? 0
    let to = Double(args.string("to", default: "1e9")!) ?? 1e9
    // Comma-separated, because "which model should my final one be?" is answered
    // by hearing the same stretch through both — and because running them in one
    // process is also the check that `WhisperEngine` caches rather than evicting.
    let models = args.string("model", default: WhisperModels.defaultID)!
        .split(separator: ",").map(String.init)
    let roster = args.players("players")

    print("relisten: \(url.lastPathComponent)  [\(fmt(from))s … \(to > 1e8 ? "end" : fmt(to) + "s")]")
    print("models:   \(models.joined(separator: ", "))")

    let samples: [Float]
    do { samples = try AudioExcerpt.samples(of: url, from: from, to: to) }
    catch { fail("\(error)") }

    guard !samples.isEmpty else { fail("that range holds no audio") }
    print("audio:    \(fmt(Double(samples.count) / AudioExcerpt.sampleRate))s at 16 kHz mono")

    let done = DispatchSemaphore(value: 0)
    let context = TranscriptionContext.forRound(players: roster)
    let audioSeconds = Double(samples.count) / AudioExcerpt.sampleRate
    Task {
        defer { done.signal() }
        for model in models {
            let warm = await WhisperEngine.shared.isLoaded(model: model)
            print("\n\(model)\(warm ? "  (already resident)" : "")")
            do {
                let started = Date()
                let result = try await WhisperTranscriber(model: model)
                    .transcribe(samples: samples, context: context)
                let elapsed = Date().timeIntervalSince(started)
                print("  decoded \(fmt(elapsed))s  (\(fmt(audioSeconds / max(elapsed, 0.001)))x realtime)")
                if result.utterances.isEmpty {
                    print("  (nothing — no speech in that range, or the VAD gated it)")
                }
                for u in result.utterances {
                    let tag = u.locale.map { " [\($0)]" } ?? ""
                    print(String(format: "  %6.2f  %@%@", Double(u.t0) / 1000, u.text, tag))
                }
            } catch {
                print("  failed: \(error)")
            }
        }
        let resident = await WhisperEngine.shared.residentModels
        print("\nresident: \(resident.joined(separator: ", "))  "
            + "(capacity \(WhisperEngine.capacity), least recently used first)")
    }
    done.wait()
}

private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }

let args = Args(CommandLine.arguments)
switch args.subcommand {
case "record":  cmdRecord(args)
case "inspect": cmdInspect(args)
case "course":  cmdCourse(args)
case "transcribe": cmdTranscribe(args)
case "models":  cmdModels(args)
case "live":    cmdLive(args)
case "relisten": cmdRelisten(args)
case "round":   cmdRound(args)
case "bundle", "reconstruct", "eval", "sweep":
    fail("\(args.subcommand): not implemented yet — phase 3+. See docs/PLAN.md §6.")
default:
    print("""
    golfctl — Marker's off-device CLI

      record   --out DIR --players 'steve,dave' --course NAME
               [--seconds N] [--no-audio] [--no-gps] [--mic-off]
               players are plain names, comma separated
               --mic-off starts with the microphone off, as the app does;
               'r ENTER' then starts and stops recording during the round.
      inspect  <session>
      transcribe <session> [--asr whisperkit|apple] [--model VARIANT]
                 [--locale en-US,ko-KR] [--force]
               WhisperKit by default; --model picks the variant (default
               openai_whisper-small, multilingual). Whisper is never told a
               language and never translates.
      models   list the multilingual Whisper models available
      relisten <audio-file> [--from S] [--to S] [--model A[,B]] [--players ...]
               re-read one stretch of a recording with a chosen model — the
               same two calls the app's "Transcribe again" button makes.
               Several models run in one process, which is also how to see
               that the engine caches them rather than evicting each other.
      record ... [--live] [--live-volatile] [--locale en-US,ko-KR]
               [--vocab word,word] [--show-vocab] [--no-vocab]
               on-device ASR over every audio segment, onto the session clock.
               Caches per segment — re-running does only what is missing.
      round    export <session> [--out FILE] [--courses DIR] [--plain]
               import <file|->   [--out DIR] [--courses DIR] [--dry-run]
               show   <file|->   [--model-visible]
               a whole round — its streams, its course and that course's
               terrain — as one document that survives a copy and a paste.
               golfctl round export S | pbcopy   /   pbpaste | golfctl round import -
      course   sample --out DIR          write the built-in sample course
               show <course.json> [--hole N]
               import --url <page> | --card <file.pdf|.jpg|.png|.txt>
                      [--name NAME] [--id ID] [--out DIR] [--unit metres|yards]
                      [--merge] [--dry-run] [--force] [--fetch-only]
                      [--unit-default metres|yards]   default yards (US cards)
                      [--prompt PATH] [--schema PATH] [--model ID]
                      reads a published scorecard: par, handicap, per-tee yardage.
                      Never coordinates — no card has any.

    Not implemented yet (phase 3+): bundle, reconstruct, eval, sweep.
    """)
}
