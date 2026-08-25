// golfctl — macOS CLI. The iteration surface for everything off-device.
//
// Every stage caches into the session folder, so stages are independently
// re-runnable: re-tuning a prompt never re-runs a 30-minute transcription.
//
//   golfctl record  --out Sessions --players 'steve=스티브|형,dave' --course "Naelgol"
//   golfctl inspect <session>
//   golfctl transcribe <session> --asr apple|whisperkit          (phase 2)
//   golfctl bundle     <session>                                 (phase 3)
//   golfctl reconstruct <session> --model ... --prompt PATH --schema PATH
//   golfctl eval       <session>                                 (phase 4)
//
// --prompt/--schema take PATHS, defaulting to ./Resources/*. That is what keeps
// prompt tuning to an edit-and-rerun loop instead of a rebuild — the package
// deliberately declares no bundle resources, so there is no Bundle.module.

import Foundation
import GolfSessionFormat
import GolfCaptureCore

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

    /// `name=alias|alias` per player, comma-separated. Aliases are the names the
    /// group actually says out loud, which is what the reconstruction matches on:
    ///     --players 'steve=스티브|형,dave=데이브,mike'
    func players(_ k: String) -> [Player] {
        list(k).map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let aliases = parts.count > 1
                ? parts[1].split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            return Player(name: name, aliases: aliases)
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
                                      recordAudio: wantsAudio,
                                      recordLocation: !args.bool("no-gps"))
    session.location.requestAuthorization()

    do { try session.start() } catch { fail("could not start: \(error)") }

    print("recording -> \(session.folder.url.path)")
    let roster = args.players("players")
    print("players: \(roster.isEmpty ? "(none)" : roster.map(\.summary).joined(separator: ", "))")
    print("audio:   \(wantsAudio ? session.audio.describedFormat : "disabled (--no-audio)")")
    if !session.locationAvailable {
        print("gps:     UNAVAILABLE — CoreLocation needs a bundled app, and this is a CLI.")
        print("         Audio and marks still record; the GPS track comes from the phone.")
    }
    print("")
    print("  ENTER        mark")
    print("  <name>ENTER  mark for that player")
    print("  q ENTER      stop")
    print("")

    // Ctrl-C must still close the folder cleanly, or the round is unreadable.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\ninterrupted")
        session.stop()
        summarize(session.folder)
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
            session.stop()
            summarize(session.folder)
            exit(0)
        }
    }

    if let seconds = duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            session.stop()
            summarize(session.folder)
            exit(0)
        }
    }
    dispatchMain()
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
    print("  players  \(meta.players.isEmpty ? "—" : meta.players.map(\.summary).joined(separator: ", "))")
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
    var span: (Millis, Millis)?
    for t in gps.map(\.t) + motion.map(\.t) + alt.map(\.t) + marks.map(\.t) + segments.map(\.t0) {
        span = span.map { (Swift.min($0.0, t), Swift.max($0.1, t)) } ?? (t, t)
    }
    if let span {
        print("")
        print("  clock span   \(span.0) … \(span.1)  (\(String(format: "%.1f", Double(span.1 - span.0) / 1000))s)")
        if span.0 < meta.start { print("    ⚠︎ a sample predates meta.start — clocks disagree") }
    }
}

// MARK: - main

let args = Args(CommandLine.arguments)
switch args.subcommand {
case "record":  cmdRecord(args)
case "inspect": cmdInspect(args)
case "transcribe", "bundle", "reconstruct", "eval", "sweep":
    fail("\(args.subcommand): not implemented yet — phase 2+. See docs/PLAN.md §6.")
default:
    print("""
    golfctl — Marker's off-device CLI

      record   --out DIR --players 'steve=스티브|형,dave' --course NAME
               [--seconds N] [--no-audio] [--no-gps]
               players are name=alias|alias, comma separated
      inspect  <session>

    Not implemented yet (phase 2+): transcribe, bundle, reconstruct, eval, sweep.
    """)
}
