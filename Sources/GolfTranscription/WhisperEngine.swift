import Foundation
import WhisperKit

/// Which Whisper model to run.
///
/// **Multilingual only.** Whisper ships `.en` variants that are smaller and more
/// accurate *on English* and cannot produce Korean at all — which is the same
/// silent failure `en_US` had on the Apple path: not garbage, absence. `distil-*`
/// is English-only for the same reason. Neither is ever offered, so the picker
/// cannot be used to break the bilingual requirement by accident.
public struct WhisperModelChoice: Sendable, Hashable, Identifiable, Codable {
    /// The WhisperKit variant name, e.g. `openai_whisper-small`.
    public let id: String
    /// What the picker shows.
    public let label: String
    /// The trade, in one line.
    public let detail: String

    public init(id: String, label: String, detail: String) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

public enum WhisperModels {

    /// **Small, multilingual** *(user decision, 2026-08-27)*. Big enough to be worth
    /// running on a foursome at conversational distance, small enough that a phone
    /// can hold it alongside a round.
    public static let defaultID = "openai_whisper-small"

    /// True unless the variant is one of Whisper's English-only builds.
    ///
    /// Matched on the variant name because that is the only thing the repo listing
    /// gives us. `.en` / `_en` covers `tiny.en`, `small.en`, `base.en` and the
    /// underscore spellings the CoreML repo uses; `distil` covers the distilled
    /// builds, which are English-only.
    public static func isMultilingual(_ variant: String) -> Bool {
        let v = variant.lowercased()
        if v.contains("distil") { return false }
        if v.hasSuffix(".en") || v.hasSuffix("_en") { return false }
        return !v.contains(".en_") && !v.contains("_en_") && !v.contains(".en-") 
    }

    /// What to offer when the model index cannot be reached.
    ///
    /// A course has poor signal and the picker still has to render something, so
    /// this is the last-resort list rather than the source of truth — `available()`
    /// asks the repo, which is what knows.
    public static let fallback: [WhisperModelChoice] = [
        .init(id: "openai_whisper-tiny",  label: "Tiny",
              label2: "~75 MB · fastest, and it will mishear names"),
        .init(id: "openai_whisper-base",  label: "Base",
              label2: "~145 MB · a step up, still light"),
        .init(id: "openai_whisper-small", label: "Small",
              label2: "~470 MB · the default"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo",
              label: "Large v3 Turbo",
              label2: "~1.5 GB · best, and the slowest to load"),
    ]

    /// Every multilingual model the CoreML repo currently publishes.
    ///
    /// Ordered smallest-first by name length as a rough proxy, with the default
    /// pinned to the top so the picker opens on the recommendation.
    public static func available() async -> [WhisperModelChoice] {
        guard let names = try? await WhisperKit.fetchAvailableModels() else {
            return fallback
        }
        let multilingual = names.filter(isMultilingual).sorted()
        guard !multilingual.isEmpty else { return fallback }
        return multilingual.map { name in
            WhisperModelChoice(id: name, label: prettyName(name),
                               detail: name == defaultID ? "the default" : name)
        }
    }

    /// `openai_whisper-large-v3-v20240930_turbo` → `Large v3 Turbo`.
    public static func prettyName(_ variant: String) -> String {
        var s = variant
        if let r = s.range(of: "openai_whisper-") { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: "_", with: " ")
             .replacingOccurrences(of: "-", with: " ")
        return s.split(separator: " ")
            .map { $0.count <= 2 ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }
}

private extension WhisperModelChoice {
    init(id: String, label: String, label2: String) {
        self.init(id: id, label: label, detail: label2)
    }
}

// MARK: - The loaded model

/// Holds the loaded models between bursts.
///
/// **Loading is seconds, and recording is a series of bursts** — reloading per burst
/// would mean the first sentence of every burst is missed, which is exactly the words
/// the button was pressed to catch.
///
/// **More than one slot, because there is more than one model** *(2026-08-28)*. The
/// app runs a small model live and a bigger one on demand
/// (`marker.whisper.model` / `marker.whisper.model.final`), and a single slot keyed on
/// the variant made those two evict each other: re-transcribe an entry and the next
/// Record tap reloads the live model, which is the very failure the paragraph above
/// forbids. It only appeared once the two models differed — which is the entire
/// configuration the feature exists for.
///
/// Bounded at ``capacity`` on a least-recently-used basis, so changing a model in the
/// picker mid-round does not accumulate graphs. Two configured models fit; a third
/// request evicts the one nobody has asked for.
///
/// **Both stay resident while the microphone is open** *(user decision, 2026-08-28)*,
/// so a re-transcribe straight after a burst is instant. That is a real memory bet on
/// a 4.5-hour round — the alternative was dropping the big graph while recording and
/// paying a reload afterwards.
public actor WhisperEngine {
    public static let shared = WhisperEngine()

    /// How many models stay resident. Two: one that listens, one that re-reads.
    public static let capacity = 2

    /// Most-recently-used **last**.
    private var loaded: [(id: String, kit: WhisperKit)] = []

    /// Loads in flight, keyed on variant.
    ///
    /// **Not an optimisation — a correctness fix.** An actor suspends at every
    /// `await`, so two callers that both miss the cache before either finishes
    /// `WhisperKit(config)` would both load the same model. That was survivable
    /// while one thing loaded models; it stopped being survivable when a round
    /// start began preloading in the background and a Record tap could land in the
    /// middle of it.
    /// **`Task<Void, Never>`, not `Task<WhisperKit, Error>`.** `WhisperKit` is not
    /// `Sendable`, so returning one across a task boundary is a Swift 6 error; the
    /// task instead writes into the actor and callers re-read the cache.
    private var loading: [String: Task<Void, Never>] = [:]

    /// Why a load failed, so the callers waiting on it get the real error rather
    /// than a generic one.
    private var failures: [String: Error] = [:]

    public init() {}

    // MARK: - Where models live

    /// **Application Support, not Documents.** `UIFileSharingEnabled` exposes
    /// Documents to Finder and the Files app — that is the entire device→Mac
    /// transfer story for session folders — and half a gigabyte of CoreML sitting
    /// next to them is both clutter and an invitation to delete it. A model is not
    /// user data; it is a cache that can be fetched again.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// What `WhisperKitConfig.downloadBase` is given.
    ///
    /// **The `huggingface` component is ours to add, and forgetting it re-downloaded
    /// the model on every launch** *(reported twice, 2026-08-27)*. `HubApi` reads:
    ///
    ///     if let downloadBase { self.downloadBase = downloadBase }
    ///     else { self.downloadBase = documents.appending(component: "huggingface") }
    ///
    /// — so the component is appended **only** for the default. Passing a bare
    /// Application Support directory therefore wrote to `<base>/models/…` while this
    /// file looked in `<base>/huggingface/models/…`, so `hasWeights` was false every
    /// time and every burst fetched half a gigabyte again. It survived review
    /// because the simulator copy had been placed by hand at the path the wrong
    /// assumption expected; a real download had never been made with an explicit
    /// base. **Do not "simplify" this back to `supportDirectory`.**
    public static var downloadBase: URL {
        supportDirectory.appendingPathComponent("huggingface", isDirectory: true)
    }

    public static let repo = "argmaxinc/whisperkit-coreml"

    /// `HubApi.localRepoLocation`: `<downloadBase>/models/<repo>`. One line of
    /// theirs, mirrored here — everything else in this section exists because that
    /// line was guessed at instead of read.
    private static func repoFolder(_ base: URL, _ repo: String) -> URL {
        base.appendingPathComponent("models/\(repo)", isDirectory: true)
    }

    /// Every place a model could be, newest layout first.
    ///
    /// **The stale ones are not tidiness, they are a migration.** A phone that
    /// downloaded under the broken base already holds the model at
    /// `<AppSupport>/models/…`; without looking there it would be fetched again on
    /// first launch after the fix — which is the bug, one more time.
    private static func modelCandidates(_ variant: String) -> [URL] {
        var bases = [downloadBase, supportDirectory]
        if let documents = try? FileManager.default.url(for: .documentDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: false) {
            bases.append(documents.appendingPathComponent("huggingface", isDirectory: true))
        }
        return bases.map { repoFolder($0, repo).appendingPathComponent(variant, isDirectory: true) }
    }

    /// Where this variant's weights are, or where they will go.
    ///
    /// Prefers the folder a real download **reported** (persisted by `download`),
    /// then anywhere the files actually are, and only then the canonical path.
    public nonisolated static func modelFolder(_ variant: String) -> URL {
        if let remembered = rememberedFolder(variant), weightsExist(at: remembered) {
            return remembered
        }
        let candidates = modelCandidates(variant)
        return candidates.first(where: weightsExist(at:)) ?? candidates[0]
    }

    private static func weightsExist(at url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return false }
        // A partial download leaves the folder behind, so look for the pieces.
        return items.contains("AudioEncoder.mlmodelc") && items.contains("TextDecoder.mlmodelc")
    }

    /// The folder `WhisperKit.download` actually returned, last time it ran.
    ///
    /// **Believed over any path this file computes.** The derivation above is now
    /// read off `HubApi` rather than guessed, but it is still a convention that can
    /// change under us, and the library hands us the answer.
    private static func rememberedFolder(_ variant: String) -> URL? {
        UserDefaults.standard.string(forKey: "marker.whisper.folder.\(variant)")
            .map { URL(fileURLWithPath: $0) }
    }

    private static func remember(_ url: URL, for variant: String) {
        UserDefaults.standard.set(url.path, forKey: "marker.whisper.folder.\(variant)")
    }

    /// The base Whisper size a variant is built from: `large-v3`, `small`, `tiny`.
    ///
    /// The published names carry a turbo marker, a release date and a quantised
    /// size, in varying combinations — `openai_whisper-large-v3-v20240930_turbo_632MB`.
    /// Checked against all fifteen multilingual names the repo publishes
    /// (`WhisperOptionsTests`), because this is derived by string surgery and string
    /// surgery is exactly the kind of thing that is right for the cases you tried it on.
    public static func baseName(_ variant: String) -> String {
        var name = variant.replacingOccurrences(of: "openai_whisper-", with: "")
        for suffix in ["_turbo", "-v20240930"] {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        // What is left after the last underscore is a size tag (`949MB`), never
        // part of a Whisper size name — those use hyphens (`large-v3`).
        if let tag = name.range(of: "_", options: .backwards) {
            name.removeSubrange(tag.lowerBound...)
        }
        return name
    }

    /// The tokenizer's own folder, which is a **separate download from a different
    /// repo** and is just as required.
    ///
    /// Forgetting it is the offline trap: the CoreML weights are the half you
    /// notice, so a phone that has "the model" still reaches for the network on the
    /// first tee and fails there instead of in the car park.
    public static func tokenizerFolder(_ variant: String) -> URL? {
        let base = baseName(variant)
        var bases = [downloadBase, supportDirectory]
        if let documents = try? FileManager.default.url(for: .documentDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: false) {
            bases.append(documents.appendingPathComponent("huggingface", isDirectory: true))
        }
        for root in bases {
            let openai = repoFolder(root, "openai").deletingLastPathComponent()
                .appendingPathComponent("openai", isDirectory: true)
            let guess = openai.appendingPathComponent("whisper-\(base)", isDirectory: true)
            if FileManager.default.fileExists(atPath: guess.path) { return guess }

            // Derived, then verified, then searched: the name is a guess however
            // carefully it is made.
            guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: openai.path) else { continue }
            if let match = entries
                .filter({ "whisper-\(base)".hasPrefix($0) || $0.hasPrefix("whisper-\(base)") })
                .max(by: { $0.count < $1.count }) {
                return openai.appendingPathComponent(match, isDirectory: true)
            }
        }
        return nil
    }

    /// True when the CoreML weights — the half-gigabyte half — are already here.
    public nonisolated static func hasWeights(_ variant: String) -> Bool {
        weightsExist(at: modelFolder(variant))
    }

    /// True when this variant can be loaded **with the radio off** — weights *and*
    /// tokenizer. What the picker means by "on this phone".
    public nonisolated static func isDownloaded(_ variant: String) -> Bool {
        hasWeights(variant) && tokenizerFolder(variant) != nil
    }

    /// Bytes this variant occupies, or nil when it is not here.
    ///
    /// **Shown in the picker on purpose.** "Is the model cached?" was answered
    /// wrongly twice by reasoning about paths; a size on screen is a fact the user
    /// can read off the phone in a second, and it is the difference between the
    /// next report being "it re-downloads" and "it says 0 bytes at <path>".
    public nonisolated static func bytesOnDisk(_ variant: String) -> Int64? {
        guard hasWeights(variant) else { return nil }
        let folder = modelFolder(variant)
        guard let e = FileManager.default.enumerator(at: folder,
                                                     includingPropertiesForKeys: [.fileSizeKey])
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Loading

    /// The loaded model, loading it if need be.
    ///
    /// **Offline first.** If the variant is already on disk it is loaded straight
    /// from that folder with `download: false` — because WhisperKit otherwise
    /// resolves the variant name against the model index *over the network* before
    /// it looks at the disk, so a phone holding the model still fails on a course
    /// with no signal. Seen exactly that way in the simulator with the network
    /// blocked: the files were there and the error was a TLS failure.
    public func kit(model id: String) async throws -> WhisperKit {
        if let i = loaded.firstIndex(where: { $0.id == id }) {
            loaded.append(loaded.remove(at: i))          // most recently used
            return loaded[loaded.count - 1].kit
        }
        // Someone else is already loading this one — wait for theirs rather than
        // starting a second copy. See `loading`.
        if let inflight = loading[id] {
            await inflight.value
            return try resident(id)
        }

        failures[id] = nil
        let task = Task { await self.load(id) }
        loading[id] = task
        await task.value
        loading[id] = nil
        return try resident(id)
    }

    /// The loaded model, or whatever went wrong loading it.
    private func resident(_ id: String) throws -> WhisperKit {
        if let i = loaded.firstIndex(where: { $0.id == id }) {
            loaded.append(loaded.remove(at: i))
            return loaded[loaded.count - 1].kit
        }
        throw failures[id]
            ?? TranscriptionError.modelUnavailable("WhisperKit \(id): load produced nothing")
    }

    private func load(_ id: String) async {
        guard !loaded.contains(where: { $0.id == id }) else { return }
        do {
            let kit = try await Self.build(id)
            loaded.append((id, kit))
            await evictBeyondCapacity()
        } catch {
            failures[id] = error
        }
    }

    /// Drop the least recently used models. Only ever runs when a *third* variant
    /// is asked for, so the two configured models are never each other's victim.
    private func evictBeyondCapacity() async {
        while loaded.count > Self.capacity {
            let dropped = loaded.removeFirst()
            await dropped.kit.unloadModels()
        }
    }

    /// Load models now, so nothing waits for one later.
    ///
    /// **Called at round start, live model first** *(user decision, 2026-08-28)*.
    /// Order is the point: by the time the bigger one is loading, the one the
    /// Record button needs is already cached, so a tap during the preload is
    /// instant instead of queued behind half a gigabyte.
    ///
    /// **Never downloads.** A variant that is not on the phone is skipped in
    /// silence — a course has no signal, and the picker is where a fetch is asked
    /// for explicitly and shown a progress bar. Silently pulling a gigabyte when a
    /// round starts is the opposite of that.
    public func preload(_ ids: [String]) async {
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            guard Self.isDownloaded(id) else { continue }
            if Task.isCancelled { return }
            _ = try? await kit(model: id)
        }
    }

    /// Build one, off the cache. Everything below is about *where* the files are.
    private nonisolated static func build(_ id: String) async throws -> WhisperKit {
        // `GOLFCTL_WHISPER_VERBOSE=1` turns WhisperKit's own logging on. Its load
        // failures surface as a bare `nilError` otherwise, which names nothing.
        let loud = ProcessInfo.processInfo.environment["GOLFCTL_WHISPER_VERBOSE"] == "1"
        let logLevel: Logging.LogLevel = loud ? .debug : .error

        // **`modelFolder` is passed the moment the weights exist, and that is the
        // whole point.** `setupModels` reads `if let modelFolder { use it } else if
        // download { … }` — so supplying it short-circuits the weights download
        // entirely, and `download` then only governs the *tokenizer*, which is a
        // separate fetch from a different repo.
        //
        // Gating this on "weights **and** tokenizer" instead is what made the app
        // download the model twice *(reported 2026-08-27)*. `download(model:)`
        // fetches the weights and then loads, and at that instant the tokenizer is
        // not there yet — so the old check said "not downloaded", took the online
        // path with no `modelFolder`, and pulled half a gigabyte again. The user
        // watched it download, finish, and start over.
        let haveWeights = Self.hasWeights(id)
        let tokenizer = Self.tokenizerFolder(id)
        let config = WhisperKitConfig(
            model: id,
            downloadBase: Self.downloadBase,
            modelFolder: haveWeights ? Self.modelFolder(id).path : nil,
            tokenizerFolder: tokenizer,
            verbose: loud, logLevel: logLevel,
            prewarm: false, load: true,
            // Only ever for what is genuinely missing.
            download: !haveWeights || tokenizer == nil)
        return try await WhisperKit(config)
    }

    /// Fetch a variant now, so the first burst of a round is not a download.
    ///
    /// **A course has no signal and that is the whole point of this method.**
    /// Leaving the download to the first tap means the words that were worth
    /// pressing the button for are the ones lost to a progress bar — or, on a
    /// course with nothing, lost outright. The picker calls this.
    @discardableResult
    public func download(model id: String,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let url = try await WhisperKit.download(variant: id,
                                                downloadBase: Self.downloadBase,
                                                from: Self.repo) { p in
            progress?(p.fractionCompleted)
        }
        // Believe the library about where it put things, rather than this file's
        // idea of where it should have.
        Self.remember(url, for: id)
        // The weights are only half of it — loading once here pulls the tokenizer
        // into the same base, so a later offline load has everything it needs. Safe
        // to do straight after the download because `kit` passes `modelFolder` as
        // soon as the weights exist: this fetches the tokenizer, not the model.
        _ = try? await kit(model: id)
        return url
    }

    /// True when this model is resident **in memory**, i.e. a burst starts
    /// listening immediately rather than after a load from disk.
    public func isLoaded(model id: String) -> Bool { loaded.contains { $0.id == id } }

    /// Variants resident right now, least recently used first. For the CLI and for
    /// telling "loading" apart from "downloading" on screen.
    public var residentModels: [String] { loaded.map(\.id) }

    public func unload() async {
        for entry in loaded { await entry.kit.unloadModels() }
        loaded = []
    }
}

// MARK: - Decoding options

public enum WhisperDecoding {

    /// The three rules, in one place *(user decision, 2026-08-27)*.
    ///
    /// - **`task = .transcribe`, never `.translate`.** Whisper will happily render
    ///   Korean speech as English prose, and it is the documented failure that made
    ///   this engine look wrong for a bilingual round. A translated line reads as a
    ///   perfectly fluent thing nobody said.
    /// - **`language = nil`.** Never pinned. Pinning is what makes one language
    ///   disappear; the round is English *and* Korean and the app is not told which
    ///   sentence is which.
    /// - **`detectLanguage = true`.** Required, not implied: it defaults to
    ///   `!usePrefillPrompt`, so leaving `language` nil on its own gets a
    ///   prefilled `<|en|>` and silently English-only output.
    /// - **`usePrefillPrompt = true`, and this is the one that is easy to get
    ///   backwards.** `task` is not a switch the decoder reads; it is expressed
    ///   *as* the `<|transcribe|>` token in the prefill. Turn the prefill off and
    ///   `.transcribe` becomes a value nothing acts on. **Measured 2026-08-27:**
    ///   with `usePrefillPrompt = false`, Korean speech came back detected as
    ///   `ko` and rendered in fluent English — "스티브가 버디를 했어요" as
    ///   "Steve did a Buddy". Translation, from the setting that was supposed to
    ///   forbid it, reported under the right language tag. The three options only
    ///   work as a set.
    public static func options(volatile: Bool) -> DecodingOptions {
        var o = DecodingOptions()
        o.task = .transcribe
        o.language = nil
        o.detectLanguage = true
        o.usePrefillPrompt = true
        o.skipSpecialTokens = true
        o.withoutTimestamps = false
        o.temperature = 0
        // A partial pass exists to put words on screen while someone is still
        // talking, so it must not spend time on fallbacks it will re-run in half a
        // second anyway. The committing pass keeps the default fallback ladder.
        if volatile {
            o.temperatureFallbackCount = 0
            o.wordTimestamps = false
        } else {
            // **The file pass splits on voice activity.** A recorded segment is
            // mostly a foursome walking, and Whisper fed a quiet 30-second frame
            // does not return nothing — it fabricates. Chunking on VAD means the
            // decoder only ever sees frames that contain speech, which the
            // measured literature puts at a ~200× reduction in hallucination
            // (40.3% of non-speech inferences → 0.2%) *and* a better WER, not a
            // worse one. The live path does the same gating by hand, because it
            // owns its own window.
            o.chunkingStrategy = .vad
        }
        return o
    }

    /// Whisper's working equivalent of the inert `contextualStrings`: prior text
    /// the decoder is conditioned on.
    ///
    /// **Names only, and never on the live path.** `promptTokens` genuinely biases
    /// decoding — which is exactly why it is dangerous here. The decoder reads the
    /// prompt as *previous text*, so it is evidence about what language the audio
    /// is in; a couple of hundred English golf words in front of a Korean phrase
    /// pushes toward the failure the user reported twice, one language stuck
    /// across a whole burst. Names are short, and in a bilingual roster they are
    /// written in both scripts, so they carry the attribution signal without
    /// carrying a verdict.
    ///
    /// The live path stays unwired regardless. There a 30-second frame decides a
    /// language from a rolling window that may open on half a sentence, which is
    /// the arm with the least context and the most to lose. This one runs over a
    /// whole entry that a smaller model has already transcribed once. See
    /// research-live-transcription.md §8.5 and the L5 measurement.
    ///
    /// - Returns: nil when there are no names, which is the common case and must
    ///   stay a *no prompt at all*: WhisperKit drops a prompt that trims to
    ///   nothing, but a bare `<|startofprev|>` biases the model toward ending the
    ///   segment early, so never hand it an empty one.
    public static func namePrompt(_ names: [String], tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer else { return nil }
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        // Written as a sentence rather than as a bare list: the prompt slot holds
        // *previous text*, and prose is what the model was trained to see there.
        let text = " Players: " + cleaned.joined(separator: ", ") + "."
        let tokens = tokenizer.encode(text: text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // WhisperKit itself keeps only the last `(maxTokenContext / 2) - 1` and
        // trims **silently**. Cutting here instead means a long roster loses whole
        // names off the front rather than half of one, and the count is knowable.
        let budget = (Constants.maxTokenContext / 2) - 1
        guard !tokens.isEmpty else { return nil }
        return Array(tokens.suffix(budget))
    }
}

// MARK: - Silence

public enum WhisperSilence {

    /// **Whisper invents speech out of silence, and a golf round is mostly
    /// silence.**
    ///
    /// Fed a quiet window the model does not return nothing — it returns a short,
    /// confident, completely fabricated line. Observed in the app on the gap
    /// between two takes: `"Bye."`. Others in the wild are "Thank you.", "you",
    /// and subtitle-site credits, because that is what the training data has under
    /// quiet audio. Over four and a half hours, most of which is walking, an
    /// unfiltered pass files hundreds of them — and each one is a `LogEntry` the
    /// extraction pass will read as something a golfer said.
    ///
    /// The test is OpenAI's own and needs **both** halves: `noSpeechProb` alone
    /// rejects genuinely quiet speech (someone talking two fairways away, which is
    /// exactly this product's hard case), and `avgLogprob` alone rejects unusual
    /// but real phrasing. Together they mean "the model thinks this is not speech
    /// *and* it is not confident in what it wrote".
    public static let noSpeechThreshold: Float = 0.6
    public static let logProbThreshold: Float = -1.0

    public static func isHallucinatedSilence(noSpeechProb: Float, avgLogprob: Float) -> Bool {
        noSpeechProb > noSpeechThreshold && avgLogprob < logProbThreshold
    }

    public static func isHallucinatedSilence(_ segment: TranscriptionSegment) -> Bool {
        isHallucinatedSilence(noSpeechProb: segment.noSpeechProb,
                              avgLogprob: segment.avgLogprob)
    }

    /// **Whisper's other way of saying "nothing here" is a caption annotation.**
    /// `[BLANK_AUDIO]`, `[MUSIC]`, `(wind blowing)`, `♪` — the training data is
    /// subtitles, so quiet or noisy audio comes back described rather than
    /// transcribed. `skipSpecialTokens` does not touch these: they are ordinary
    /// text the model generated, not `<|…|>` control tokens. Seen in the app as a
    /// log row reading exactly `[BLANK_AUDIO]`.
    ///
    /// The test is "the whole line is one bracketed aside", so a real sentence that
    /// happens to contain a parenthesis is untouched.
    public static func isAnnotation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        if t.allSatisfy({ "♪♫*-–—.…".contains($0) || $0.isWhitespace }) { return true }
        for (open, close) in [("[", "]"), ("(", ")"), ("{", "}"), ("<", ">")] {
            if t.hasPrefix(open), t.hasSuffix(close),
               !t.dropFirst().dropLast().contains(open) {
                return true
            }
        }
        return false
    }

    /// The phrases Whisper reaches for when there is nothing to transcribe.
    ///
    /// **"Thank you" alone is 24.76% of all measured Whisper hallucinations** and
    /// "thanks for watching" another 10.32% (Koenecke-style analysis over 301,317
    /// inferences on non-speech audio, arXiv:2501.11378). The training data is
    /// subtitles, so quiet audio produces the things said at the end of videos.
    /// This is the "bag of hallucinations" that took that paper's VAD result from
    /// 0.2% residual to 0%.
    ///
    /// **Matched only against a segment's entire output**, never as a substring:
    /// people genuinely say thank you on a golf course, and eating a real one to
    /// remove a phantom is the wrong trade in a product whose first invariant is
    /// to capture everything.
    static let commonHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!",
        "thank you for watching", "thank you for watching!", "thank you very much",
        "you", "bye", "bye.", "bye bye", "okay", "ok", "so", "oh",
        "please subscribe", "subscribe to my channel", "stay tuned", "stay tuned.",
        "see you next time", "see you in the next video", "the end", "music",
        "감사합니다", "감사합니다.", "시청해주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
        "다음 영상에서 만나요", "안녕하세요", "네", "어",
    ]

    /// True when a line is *only* one of the stock phrases.
    public static func isStockPhrase(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "!?.,~ "))
            .lowercased()
        return commonHallucinations.contains(t)
    }

    /// A line that is the same short fragment over and over.
    ///
    /// Whisper loops when it is decoding noise — observed on a noisy fixture as a
    /// line of repeated Tibetan brackets. `compressionRatioThreshold` catches some
    /// of this inside the decoder; this catches what reaches us anyway.
    public static func isLooping(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "," })
            .map { String($0) }
        guard parts.count >= 6 else { return false }
        return Set(parts).count * 4 <= parts.count
    }

    /// Everything that is not worth filing as something a golfer said.
    ///
    /// **Belt and braces on purpose.** VAD gating is what actually works — the
    /// measured drop is 40.3% → 0.2% — and these are the residue it leaves. Do not
    /// remove the gate because these exist, or the reverse.
    public static func isNotSpeech(_ segment: TranscriptionSegment) -> Bool {
        if isHallucinatedSilence(segment) || isAnnotation(segment.text) { return true }
        if isLooping(segment.text) { return true }
        // A stock phrase is only suspicious when the model is also unsure or
        // thinks it heard nothing — otherwise it is someone saying thank you.
        return isStockPhrase(segment.text)
            && (segment.noSpeechProb > 0.3 || segment.avgLogprob < -0.7)
    }
}
