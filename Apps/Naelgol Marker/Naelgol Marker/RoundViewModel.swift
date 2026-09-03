import Foundation
import Combine
import CoreLocation
import AVFoundation
import GolfSessionFormat
import GolfCaptureCore
import GolfCaptureMotion
import GolfCourse
import GolfTranscription

/// The round's hardware, and the roster that starts one.
///
/// **Recording is off by default and the user switches it on** *(decision
/// 2026-08-27)*. A round starts as GPS, motion, altitude and marks; tapping
/// record opens a microphone burst that writes an `.m4a` segment and, on a device
/// with a speech model, feeds `LiveTranscript` at the same time off the one tap.
/// Tapping again closes the segment with a true `t1` and hands the audio session
/// back, so other apps' audio resumes and the orange microphone indicator goes
/// out — a control that looks like it is recording while it is not is the same
/// failure as a simulated position drawn like a fix.
///
/// A round therefore holds *several* audio segments with real gaps between them,
/// which is what the segment format has always expressed and what `AudioTimeline`
/// refuses to accumulate away.
@MainActor
final class RoundViewModel: ObservableObject {

    @Published private(set) var state: RoundSession.State = .idle
    @Published private(set) var markCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var fixAccuracy: Double?
    @Published private(set) var fixCount = 0
    /// Where the phone is now, for the hole view. Altitude is deliberately nil:
    /// `CMAltimeter` relative altitude is measured from session start, not sea
    /// level, so it is not comparable with a course file. `Hole.elevationDelta`
    /// interpolates the surveyed profile instead.
    @Published private(set) var here: Coordinate?
    /// Positions of this round's MARKs, newest last, per player id.
    ///
    /// Marks are ground truth — they must never enter an evidence bundle or a
    /// prompt. Showing them to the person who pressed the button is not that.
    @Published private(set) var markPositions: [String: [Coordinate]] = [:]
    @Published private(set) var activity = "—"
    @Published private(set) var relativeAltitude: Double = 0
    @Published private(set) var lastMarkLabel: String?
    @Published var errorMessage: String?

    /// Whether the microphone is open **right now**. Not the same claim as the
    /// round recording, and not the same claim as transcription working — the
    /// simulator records fine and transcribes nothing.
    @Published private(set) var isListening = false

    /// The live caption feed, and what files a finished sentence as a log.
    let liveTranscript = LiveTranscript()

    /// Which Whisper model the next burst will run.
    ///
    /// **User-selectable** *(decision 2026-08-27)*, because the trade is theirs to
    /// make: `tiny` starts instantly and mishears names, `large-v3` is a gigabyte
    /// and a half and hears them. Persisted, and read at the start of each burst
    /// rather than held, so changing it takes effect on the next tap and disturbs
    /// nothing that is already running.
    ///
    /// **Only multilingual variants are ever offered** — `WhisperModels`
    /// filters `.en` and `distil-*` out, because those cannot produce Korean at all
    /// and the failure is silence, not garbage.
    @Published var whisperModel: String = UserDefaults.standard
        .string(forKey: "marker.whisper.model") ?? WhisperModels.defaultID
    {
        didSet {
            UserDefaults.standard.set(whisperModel, forKey: "marker.whisper.model")
            warmModels()
        }
    }

    /// Which Whisper model reads **one entry again** when the golfer asks.
    ///
    /// **Two models, because the two jobs have opposite constraints.** The live
    /// one has to keep up with speech on a phone for 4.5 hours, so it is small and
    /// mishears names. This one runs on twenty seconds of audio, once, when
    /// somebody is looking at a line that came out wrong — it can afford to be
    /// the biggest thing that fits. Measured: `small` decodes at 1.5–2.7× realtime
    /// on a Mac, so a big model over a whole round is hours and over one entry is
    /// seconds. See `LogRetranscribe`.
    ///
    /// Defaults to the same variant as the live one, so the feature never demands
    /// a second half-gigabyte download before it will do anything at all — picking
    /// a bigger one is an explicit choice with a visible size next to it.
    @Published var whisperFinalModel: String = UserDefaults.standard
        .string(forKey: "marker.whisper.model.final")
        ?? UserDefaults.standard.string(forKey: "marker.whisper.model")
        ?? WhisperModels.defaultID
    {
        didSet {
            UserDefaults.standard.set(whisperFinalModel, forKey: "marker.whisper.model.final")
            warmModels()
        }
    }

    /// When the current burst opened, for the running time on the button. Nil
    /// when not recording — which is the default state of a round.
    @Published private(set) var listeningSince: Date?

    /// What the microphone is doing according to the *recorder*, not according to
    /// the button that started it.
    ///
    /// **The button alone can lie.** An interruption closes the segment and sets
    /// `AudioRecorder.state = .interrupted`, and the resume afterwards is
    /// best-effort — "if the OS declines, the round continues with a gap". Without
    /// consuming this, a declined resume leaves a red button counting up over
    /// nothing being written, which is precisely the failure the simulated-marker
    /// and orange-dot arguments exist to prevent.
    @Published private(set) var audioState: AudioRecorder.State = .idle

    /// The current fix **with its accuracy**, which is what makes a log placed.
    ///
    /// `LogEntry.isPlaced` reads `hAcc ?? .infinity`, so a coordinate handed over
    /// without one is never placed however good it was — and every log then joins
    /// the convergence backlog for fifteen seconds of radio it did not need. That
    /// went unnoticed while the typed box appended a row every few minutes; a
    /// bilingual burst appends one every few seconds.
    var fix: (Coordinate, Double)? {
        guard let here, let acc = fixAccuracy, acc > 0 else { return nil }
        return (here, acc)
    }

    /// One row per player, and a row is a name.
    ///
    /// It carried an aliases field until 2026-08-31; see `Player`.
    struct PlayerDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""

        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var player: Player? { trimmedName.isEmpty ? nil : Player(name: trimmedName) }
    }

    /// **A new round starts with one empty row, every time** *(user, 2026-08-31:
    /// "no set names when starting a new round — start with just one player with
    /// empty name")*.
    ///
    /// It used to restore the previous round's roster from `UserDefaults`, on the
    /// argument that the group is usually the same four people. What that actually
    /// produced was a Start button that was live the moment the screen appeared,
    /// over names nobody had looked at — so a round played with a different group
    /// records the old one unless somebody notices and edits three rows. An empty
    /// row cannot be started by accident: `canStart` is `!players.isEmpty` and a
    /// draft with a blank name is not a player.
    ///
    /// The old key is not read and not written. Nothing migrates it: it holds
    /// names, which the golfer can retype, and leaving a reader for it would make
    /// the previous roster reappear on exactly the launch this rule exists to stop.
    @Published var drafts: [PlayerDraft] = [PlayerDraft()]
    /// The free-text course name, for a course nobody has mapped. **Not
    /// remembered either**, for the same reason the roster is not: it is the other
    /// branch of the same screen — on a phone with no course files it is a text
    /// field that came up pre-filled with a name nobody had looked at, and Start
    /// was live over it. What *is* remembered is `CourseLibrary.selectedID`, which
    /// is a different thing: a picker showing the course by name, so what was
    /// carried over is legible on the screen rather than sitting in a box that
    /// looks like it was just typed.
    @Published var courseText: String = ""

    var players: [Player] { drafts.compactMap(\.player) }
    var playerIDs: [String] { players.map(\.id) }

    func addPlayer() { drafts.append(PlayerDraft()) }
    func removePlayers(at offsets: IndexSet) {
        drafts = drafts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    private var session: RoundSession?
    private var motion: MotionRecorder?
    private var ticker: Timer?
    private var startedAt: Date?

    var isRecording: Bool { state == .recording }
    var sessionName: String? { session?.folder.url.lastPathComponent }

    /// Sessions live in Documents so `UIFileSharingEnabled` exposes them to
    /// Finder and the Files app. That is the whole device→Mac transfer story
    /// for Phase 1 — no sync service, no account.
    ///
    /// **`nonisolated`** so it is reachable from code with no main-actor work to
    /// do. It reads a constant path; there is nothing to isolate.
    nonisolated static var sessionsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    // MARK: - Round lifecycle

    func startRound() async {
        guard state != .recording else { return }
        errorMessage = nil

        // **`recordAudio: false` is the default, not a disabled feature.** It
        // means "do not open the microphone *with the round*" — recording is a
        // button, and `RoundSession.startAudio()` opens a burst whenever the user
        // asks. Starting a round must never throw a microphone prompt at someone
        // who is only typing.
        let s = RoundSession.create(under: Self.sessionsRoot,
                                    players: players,
                                    course: courseText.isEmpty ? nil : courseText,
                                    device: deviceName,
                                    recordAudio: false)
        s.location.requestAuthorization()

        let m = MotionRecorder(folder: s.folder)
        try? s.addAuxiliary(m)
        motion = m

        s.location.onFix = { [weak self] fix in
            Task { @MainActor in
                self?.fixAccuracy = fix.hAcc
                self?.fixCount += 1
                self?.here = Coordinate(lat: fix.lat, lon: fix.lon)
            }
        }
        m.onActivityChange = { [weak self] a in
            Task { @MainActor in self?.activity = a }
        }

        do {
            try s.start()
        } catch {
            errorMessage = "Could not start: \(error)"
            return
        }

        session = s
        startedAt = Date()
        state = .recording
        // The Action Button writes into this folder, from a process that may have
        // no view model at all. See `QuickMark.activeRoundKey`.
        QuickMark.setActiveRound(s.folder.url.lastPathComponent)
        markCount = 0
        fixCount = 0
        markPositions = [:]
        startTicking()
        warmModels()
    }

    /// Reopen a round that was ended, so more can be recorded into it.
    ///
    /// **Because a round does not end when the golfer stops talking.** Recording is
    /// a series of bursts; ending the round was just the last one, and wanting one
    /// more after the fact — the scores on the way to the car park — is ordinary.
    /// The alternative is a second round folder holding half a hole.
    ///
    /// Refuses while another round is recording: there is one microphone, and
    /// `SessionIndex.summaries(recordingID:)` is built on exactly one.
    func reopenRound(id: String) async {
        errorMessage = nil
        if state == .recording {
            guard sessionName == id else {
                errorMessage = "Another round is still recording. End that one first."
                return
            }
            return
        }

        let folder = SessionFolder(url: Self.sessionsRoot.appendingPathComponent(id))
        guard let meta = try? folder.readMeta() else {
            errorMessage = "That round's meta.json could not be read."
            return
        }

        // `recordAudio: false` for the same reason a new round uses it — the
        // microphone opens when the button is tapped, not when the round does.
        let s = RoundSession(folder: folder, recordAudio: false)
        s.location.requestAuthorization()

        // **The sensors have to be rewired, not just the writers.** `location.onFix`
        // is what fills `here`, and `here` is what gives a log a coordinate; a
        // reopened round that skipped this would record and place nothing, which
        // looks like working and is not.
        let m = MotionRecorder(folder: folder)
        try? s.addAuxiliary(m)
        motion = m
        s.location.onFix = { [weak self] fix in
            Task { @MainActor in
                self?.fixAccuracy = fix.hAcc
                self?.fixCount += 1
                self?.here = Coordinate(lat: fix.lat, lon: fix.lon)
            }
        }
        m.onActivityChange = { [weak self] a in
            Task { @MainActor in self?.activity = a }
        }

        do {
            try s.resume()
        } catch {
            errorMessage = "Could not reopen the round: \(error)"
            motion = nil
            return
        }

        session = s
        // Elapsed is measured from when the round *began*, not from the reopen —
        // it is the round's duration, and the gap in the middle is real.
        startedAt = SessionClock.date(from: meta.start)
        state = .recording
        QuickMark.setActiveRound(folder.url.lastPathComponent)
        markCount = 0
        markPositions = [:]
        startTicking()
        warmModels()
    }

    /// **Synchronous again**, as of 2026-08-27. It was async only because the
    /// live recognizer had to be drained and the last `.m4a` released before the
    /// folder could be read; with no audio there is nothing to wait for. Call
    /// sites keep `await` off it deliberately — a needless `Task` around a stop
    /// button is a window in which the round is neither running nor ended.
    func stopRound() {
        // `RoundSession.stop()` closes an open burst itself, so the segment and
        // the folder are correct the instant this returns and the button can flip
        // to "ended" with nothing pending. Draining the recognizer is what has to
        // be awaited, and it only costs the *live view* its last line — the words
        // are in the `.m4a` either way — so it is finished off to the side rather
        // than holding the round open. A late arrival appends one more log, which
        // is exactly what an append-only file is for.
        let live = isListening
        isListening = false
        listeningSince = nil
        audioState = .stopped
        // Stop *warming*, not the models themselves. A finished round can still be
        // reopened and its entries re-transcribed, so the loaded graphs stay —
        // unloading here would make the first thing anyone does after a round pay
        // for it again.
        warming?.cancel(); warming = nil
        handback?.cancel(); handback = nil
        session?.audio.onStateChange = nil
        session?.stop()
        if live {
            let transcript = liveTranscript
            let audio = session?.audio
            Task { await transcript.stop(); audio?.listen(nil) }
        }
        ticker?.invalidate(); ticker = nil
        state = .ended
        motion = nil
        // Cleared here as well as guarded on `meta.end` in `QuickMark.activeRound`,
        // because a pointer at a finished round is a button that looks live.
        QuickMark.setActiveRound(nil)
    }

    // MARK: - The record button

    /// Open a microphone burst, and a recognizer over it if the device has one.
    ///
    /// **Recording and transcription fail separately and are reported
    /// separately.** If the recognizer will not start — which is every run in the
    /// simulator, where there is no speech model and none can be downloaded — the
    /// burst still records its `.m4a`. That file is what the batch pass and Phase
    /// 2's ASR comparison need, and throwing it away because the live caption is
    /// unavailable would be losing the round to save the subtitle.
    func startListening(players: [Player]) async {
        guard let session, !isListening else { return }

        if AudioRecorder.permission == .undetermined {
            _ = await AudioRecorder.requestPermission()
            refreshCapabilities()
        }
        do {
            try session.startAudio()
        } catch {
            errorMessage = AudioRecorder.permission == .denied
                ? "Marker cannot record without microphone access — Settings > Naelgol Marker > Microphone."
                : "Could not start recording: \(error)"
            return
        }
        isListening = true
        listeningSince = Date()
        audioState = .recording
        // A burst is the one stretch of a round where a dense track is worth its
        // power: the golfer is standing where something happened and is about to
        // say what. Off again after the placement window; see `handBackRadio`.
        handback?.cancel(); handback = nil
        trackFast(true, for: .marker)
        session.audio.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.audioState = state }
        }

        // The analyzer's format, not the file's — they are different, and it comes
        // back from the analyzer that resolved it rather than being asked for a
        // second time. See `AudioRecorder.listen`.
        guard let (live, format) = try? await liveTranscript.start(
            folder: session.folder,
            players: players.isEmpty ? self.players : players,
            model: whisperModel,
            fix: { [weak self] in self?.fix })
        else { return }                 // status already says why; the .m4a runs on

        session.audio.listen(AudioTap(format: format) { buffer, _ in
            live.append(buffer, at: SessionClock.now())
        })

        #if DEBUG
        // Screenshot support only — see `DemoSeed.speechFile`. Replays a file
        // through the *real* recognizer because there is no way to speak into the
        // simulator. The microphone tap above stays attached and the `.m4a` keeps
        // recording; this only adds samples the recognizer also hears.
        if let path = DemoSeed.speechFile {
            Task.detached { await Self.replay(path, into: live, format: format) }
        }
        #endif
    }

    #if DEBUG
    /// Feed a file to the recognizer in real time, as the tap would.
    nonisolated private static func replay(_ path: String,
                                           into live: WhisperLiveTranscriber,
                                           format: AVAudioFormat) async {
        let url = URL(fileURLWithPath: path).isFileURL && FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path)
            : Self.sessionsRoot.deletingLastPathComponent().appendingPathComponent(path)
        guard let file = try? AVAudioFile(forReading: url),
              let converter = AVAudioConverter(from: file.processingFormat, to: format)
        else { NSLog("marker.speech: cannot read \(url.path)"); return }

        // **Looped.** A clip is a few seconds and the pane is what is being
        // looked at, so playing once leaves a two-second window to catch a
        // screenshot in. Looping makes the burst behave like a talkative
        // foursome, which is also the load case worth seeing.
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.085)
        while !Task.isCancelled {
            file.framePosition = 0
            while file.framePosition < file.length {
                if Task.isCancelled { return }
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: chunk) else { return }
                // A throw here is end-of-file on some containers, not a failure.
                do { try file.read(into: input, frameCount: chunk) } catch { break }
                if input.frameLength == 0 { break }
                if let out = AudioRecorder.convert(input, with: converter,
                                                   from: file.processingFormat) {
                    live.append(out, at: SessionClock.now())
                }
                try? await Task.sleep(nanoseconds: UInt64(Double(input.frameLength)
                    / file.processingFormat.sampleRate * 1_000_000_000))
            }
            // A beat of quiet between takes, so the commit rule sees a real
            // silence and files a phrase rather than running to the backstop.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }
    #endif

    /// Close the burst.
    ///
    /// **Order is load-bearing.** The audio stops first, so the segment closes
    /// with a real `t1` and no further buffers arrive; then the analyzer is
    /// drained, so the last phrase of the burst finalises instead of being thrown
    /// away; then the tap is detached — which must happen before the next burst,
    /// because `stopEngine` parks the listener for re-attachment on restart and
    /// the next `start()` would otherwise feed a recognizer that has already been
    /// finalised.
    func stopListening() async {
        guard let session, isListening else { return }
        session.audio.onStateChange = nil
        session.stopAudio()
        isListening = false
        listeningSince = nil
        audioState = .stopped
        // **Drained to the side, not awaited.** The decode loop is mid-`transcribe`
        // when Stop is tapped and then runs one more committing pass, which is
        // seconds — awaiting it here leaves the button dead with nothing on screen
        // saying why, and the burst is already closed and correct by this point.
        // The last phrase still lands: it is appended to `log.jsonl`, which is
        // append-only, and the pane clears when `stop()` returns. Same shape as
        // `stopRound()`.
        let transcript = liveTranscript
        let audio = session.audio
        Task { await transcript.stop(); audio.listen(nil) }
        // **Stays fast past the end of the burst**, because the convergence that
        // places what was just said starts now — `RoundScreen` runs
        // `LogPlacement` over the new logs and hands the radio back when it is
        // done. Dropping to slow here would ask for ten-metre fixes during the
        // fifteen seconds the app is specifically waiting for a three-metre one.
        handBackRadio()
    }

    /// Load both Whisper models now, so nothing waits for one during the round
    /// *(user decision, 2026-08-28)*.
    ///
    /// **At round start rather than at app launch.** Most launches are not rounds —
    /// recording is off by default and the app is opened to read a card as often as
    /// to play — so a gigabyte of CoreML at launch would be paid by people who
    /// never press Record.
    ///
    /// **Live model first, and the order is the point.** Preload runs sequentially,
    /// so by the time the bigger one is loading the one the Record button needs is
    /// already cached: a tap during the preload is instant instead of queued behind
    /// half a gigabyte. `WhisperEngine.preload` never downloads — a variant that is
    /// not on the phone is skipped, because a course has no signal and a fetch
    /// belongs in the picker where it has a progress bar.
    ///
    /// Both stay resident for the round, including while the microphone is open.
    private func warmModels() {
        // Only for a round in progress. Picking a model from the rounds list, or
        // opening the picker to read the sizes, must not pull a gigabyte into
        // memory for someone who is not about to record anything.
        guard state == .recording else { return }
        warming?.cancel()
        let ids = [whisperModel, whisperFinalModel]
        warming = Task.detached(priority: .utility) {
            await WhisperEngine.shared.preload(ids)
        }
    }

    private var warming: Task<Void, Never>?

    /// The belt to `RoundScreen`'s braces: put the radio back on its own clock.
    ///
    /// **The placement task cannot be relied on to do it**, and the reason is
    /// subtle. That task is `.task(id: logSignature)` over the *unplaced* logs, so
    /// it re-runs only when that set changes. A burst that placed everything as it
    /// went — or one that produced no logs at all — leaves the signature unchanged
    /// when Stop is tapped, so the task never fires again and nothing ever asks
    /// for slow. The radio would then sit at `kCLLocationAccuracyBest` for the
    /// remaining four hours, which is exactly the cost duty cycling exists to
    /// avoid, arrived at through the feature meant to save it.
    ///
    /// Both paths are safe to run: `LocationRecorder.setMode` ignores a mode it is
    /// already in.
    /// Schedules the drop. **Internal, because the Marker sheet and the hole view
    /// both need to be able to guarantee one**: a burst whose `startListening`
    /// failed early — no speech model, most obviously — never reaches
    /// `stopListening`, so nothing else would ever ask for slow and the radio sat at
    /// Best for the rest of the round. Cancels and reschedules, so calling it twice
    /// is free.
    func handBackRadio() {
        handback?.cancel()
        handback = Task { [weak self] in
            let wait = LogPlacement.deadline + 5
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isListening else { return }
            self.trackFast(false, for: .marker)
        }
    }

    private var handback: Task<Void, Never>?

    /// What the *recorded* track is asking the radio for.
    ///
    /// **Slow is the round's resting state** *(user decision, 2026-08-26; TODO
    /// 16)*. Fast is for **the Marker sheet** — a burst and the placement window
    /// after it — and for nothing else.
    ///
    /// *(Corrected 2026-08-28, TODO 17. This comment used to claim it also covered
    /// "a hole view someone is reading a yardage off", and it had no such call
    /// site — a promise the code did not keep. The user's answer was the other
    /// direction: the hole view is open for most of a round and reading a yardage
    /// does not need a fix a second, so **the hole view is slow too** and Marker is
    /// the only thing that escalates. `MarkerSheet` drives both feeds.)*
    ///
    /// The saving is an **estimate** — the full-rate baseline round PLAN §5 wanted
    /// was never collected and is not coming, so there is nothing to measure it
    /// against.
    /// What the recorded track is *actually* asking for, so the indicator can show
    /// it rather than assuming.
    var trackMode: TrackingMode { session?.location.mode ?? .off }

    /// Why the recorded track is being asked to run fast.
    ///
    /// **A set of reasons, not a boolean** *(2026-08-30, when the hole view became
    /// a second caller)*. With two independent setters the last one to fire won:
    /// `handBackRadio` schedules an unconditional drop to slow, so a burst that
    /// ended while the hole view was still on screen took the hole view's fast
    /// tracking away with it — and the hole view never re-asserts, because its
    /// `appear` already ran. Every caller now names itself, and slow is what happens
    /// when nobody is asking.
    enum FastReason: Hashable {
        /// The GPS hole view is on screen *(user, 2026-08-30)*.
        case holeView
        /// A burst, and the placement window after it.
        case marker
    }

    private var fastReasons: Set<FastReason> = []

    func trackFast(_ fast: Bool, for reason: FastReason) {
        if fast { fastReasons.insert(reason) } else { fastReasons.remove(reason) }
        session?.location.setMode(fastReasons.isEmpty ? .slow : .fast)
    }

    /// The MARK button. Records even with no fix — the timestamp is the point,
    /// and a mark not taken is gone for good.
    func mark(player: String) {
        guard let session else { return }
        guard let m = session.mark(player: player) else { return }
        markCount = session.markCount
        if let lat = m.lat, let lon = m.lon {
            markPositions[player, default: []].append(Coordinate(lat: lat, lon: lon))
        }
        lastMarkLabel = m.lat == nil
            ? "\(player) — time only, no fix yet"
            : String(format: "%@ — %.5f, %.5f", player, m.lat!, m.lon!)
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.relativeAltitude = self.motion?.lastRelativeAltitude ?? 0
            }
        }
    }

    private var deviceName: String {
        #if canImport(UIKit)
        return "iOS"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Capability report

    /// Permission is three-valued, not two. A plain checkmark/cross shows a red
    /// ✗ next to Microphone on first launch — before anyone has been *asked* —
    /// which reads as "broken" when the real answer is "we'll ask when you tap".
    struct Capability: Identifiable {
        enum Kind: String { case location, microphone, motion, barometer }
        enum Status { case ready, willAsk, denied, unavailable }
        var id: String { kind.rawValue }
        let kind: Kind
        let name: String
        let status: Status
        let detail: String?
        /// True when tapping the row will produce a system prompt.
        var isRequestable: Bool { status == .willAsk }
        /// True when the only remedy is the Settings app.
        var needsSettings: Bool { status == .denied }
    }

    /// **Published, not computed.** A computed property never refreshes the row
    /// after the user answers a prompt — nothing publishes, so the "?" stays put
    /// forever and the app looks like it never asked. Recompute explicitly:
    /// on appear, on returning from Settings, and after every request.
    @Published private(set) var capabilities: [Capability] = []

    private let permissionMonitor = LocationPermissionMonitor()

    func refreshCapabilities() {
        let motion = MotionRecorder.availability

        let location: Capability.Status
        switch permissionMonitor.status {
        case .authorizedAlways: location = .ready
        case .authorizedWhenInUse: location = .ready
        case .notDetermined: location = .willAsk
        default: location = .denied
        }

        // Three-valued here too, and for the sharper version of the same reason:
        // the app records nothing until someone taps the button, so the honest
        // state before that is "we'll ask when you do", not a red ✗.
        let mic: Capability.Status
        switch AudioRecorder.permission {
        case .granted: mic = .ready
        case .undetermined: mic = .willAsk
        case .denied: mic = .denied
        }

        capabilities = [
            Capability(kind: .location, name: "Location", status: location,
                       detail: {
                           switch location {
                           case .willAsk: return "Tap to allow. Choose Always, or a log made from a pocket has no position."
                           case .denied: return "Denied. Settings > Naelgol Marker > Location."
                           case .ready:
                               return permissionMonitor.status == .authorizedWhenInUse
                                   ? "While Using only — tap to upgrade to Always, or the track stops when the screen locks."
                                   : nil
                           case .unavailable: return nil
                           }
                       }()),
            Capability(kind: .microphone, name: "Microphone", status: mic,
                       detail: {
                           switch mic {
                           case .willAsk: return "Tap to allow. Recording stays off until you start it during a round."
                           case .denied: return "Denied. Settings > Naelgol Marker > Microphone. The round still records everything else."
                           case .ready, .unavailable: return nil
                           }
                       }()),
            Capability(kind: .motion, name: "Motion activity",
                       status: motion.motionActivity ? .ready : .unavailable,
                       detail: motion.motionActivity ? nil : "This device has no motion coprocessor."),
            Capability(kind: .barometer, name: "Barometer (elevation)",
                       status: motion.relativeAltitude ? .ready : .unavailable,
                       detail: motion.relativeAltitude ? nil : "No barometer — the round still records, without elevation."),
        ]
    }

    /// Asked from the row itself, so permission is never gated behind filling in
    /// the roster first — which is what made the app look like it never asked.
    func request(_ kind: Capability.Kind) async {
        switch kind {
        case .location:
            permissionMonitor.request()
        case .microphone:
            _ = await AudioRecorder.requestPermission()
        case .motion, .barometer:
            break                       // hardware, not permission
        }
        refreshCapabilities()
    }

    /// Requests everything still unasked, in order. Two system prompts back to
    /// back is fine here — the user just tapped a button that says so.
    func requestAllPermissions() async {
        if permissionMonitor.status == .notDetermined {
            permissionMonitor.request()
        }
        if AudioRecorder.permission == .undetermined {
            _ = await AudioRecorder.requestPermission()
        }
        refreshCapabilities()
    }

    var hasUnaskedPermissions: Bool {
        capabilities.contains { $0.isRequestable }
    }

    init() {
        permissionMonitor.onChange = { [weak self] in
            Task { @MainActor in self?.refreshCapabilities() }
        }
        refreshCapabilities()
    }

    /// Only a hard denial blocks a round. "Not asked yet" must not.
    ///
    /// **Location denial does not block one either.** A round with no fixes still
    /// records logs, marks and motion, and a log without a coordinate is a real
    /// row rather than an error (`LogEntry.hasPosition`). Refusing to start would
    /// throw away the sentences too.
    ///
    /// **Nor does the microphone**, and there it is not even a judgement call:
    /// recording is off when a round starts, so mic permission is irrelevant to
    /// starting one. It is asked for by the record button, at the moment it is
    /// first needed.
    var canStart: Bool { !players.isEmpty }
}

/// Location authorization only reports changes through a delegate, and the
/// WhenInUse -> Always escalation cannot happen on the line after the request —
/// the status does not change until the user answers. Owning a manager here
/// means the setup screen can ask before a round exists, and refresh when the
/// answer arrives.
private final class LocationPermissionMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?
    private var wantsAlways = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func request() {
        wantsAlways = true
        escalate()
    }

    /// Only ever prompts because the user asked. Assigning the delegate fires
    /// `locationManagerDidChangeAuthorization` immediately, so without the
    /// `wantsAlways` guard on `.notDetermined` the app throws a location dialog
    /// in the user's face on launch, before they have typed a single name.
    private func escalate() {
        guard wantsAlways else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            wantsAlways = false          // ask once; nagging gets an app rejected
            manager.requestAlwaysAuthorization()
        default:
            wantsAlways = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        escalate()
        onChange?()
    }
}
