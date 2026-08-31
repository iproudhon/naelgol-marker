import SwiftUI
import GolfTranscription

/// Which Whisper models listen — the one that keeps up, and the one that gets it
/// right.
///
/// **Two slots, because the two jobs have opposite constraints** *(2026-08-27)*.
/// The live model decodes continuously for 4.5 hours on a phone in a pocket, so it
/// has to be small and it will mishear names. The final model is run on one entry,
/// on demand, when the golfer is looking at a line that came out wrong — twenty
/// seconds of audio, once — so it can be the biggest thing that fits.
///
/// Both are downloaded here and for the same reason: a course has no signal, and a
/// model that is not on the phone before the first tee cannot do anything at all.
///
/// **The trade is the user's to make** *(decision 2026-08-27)*: `tiny` is seventy
/// megabytes and will mishear a name every hole; `large-v3` is a gigabyte and a
/// half, takes a while to arrive, and hears them. Nothing here can pick for them,
/// because it depends on the phone, the signal at the course and how much they
/// care about the transcript versus the battery.
///
/// **Only multilingual variants are listed, and that is not a preference.**
/// `WhisperModels.available()` filters out `.en` and `distil-*`, which cannot
/// produce Korean at all — and the failure is *silence*, not garbage, which is
/// indistinguishable from nobody having spoken. Offering them in a picker would be
/// offering a way to lose half the round without noticing.
struct WhisperModelPicker: View {
    @ObservedObject var model: RoundViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var models: [WhisperModelChoice] = WhisperModels.fallback
    @State private var loading = true
    /// Variant being fetched, and how far along. One at a time on purpose: these
    /// are hundreds of megabytes each and a picker that lets you start four is a
    /// picker that fills the phone.
    @State private var downloading: String?
    @State private var progress: Double = 0
    @State private var failure: String?
    /// Recomputed rather than stored, so a finished download updates every row.
    @State private var onDisk: Set<String> = []
    @State private var sizes: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                modelSection(
                    title: "Listening",
                    selected: model.whisperModel,
                    select: { model.whisperModel = $0 },
                    footer: "Bigger models hear names better and take longer to arrive. "
                          + "Picking one downloads it now — do that before you leave, because "
                          + "a course has no signal and a model that is not on the phone "
                          + "cannot listen. Changing this takes effect the next time you tap "
                          + "Record; it never interrupts a burst that is already running.")

                modelSection(
                    title: "Transcribe again",
                    selected: model.whisperFinalModel,
                    select: { model.whisperFinalModel = $0 },
                    footer: "Used only when you ask one entry to be read again, so it can be "
                          + "much bigger than the listening model — it runs on a few seconds "
                          + "of audio instead of the whole round. It still has to be on the "
                          + "phone before you need it.")

                if let failure {
                    Section { Text(failure).font(.caption).foregroundStyle(.red) }
                }

                Section {
                    Text("Whisper is never told which language is being spoken and is never "
                       + "asked to translate. It works out English or Korean per phrase and "
                       + "writes down what it heard.")
                    .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Languages")
                } footer: {
                    // The honest caveat, stated where someone reading about
                    // languages will see it rather than buried in a doc.
                    Text("A sentence that switches language halfway is decided by whichever "
                       + "language most of it is in. Two languages inside one sentence is the "
                       + "known weak spot of this engine.")
                }
            }
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                refreshOnDisk()
                // The published list, not the built-in one — but the built-in one
                // is already on screen, so a course with no signal still gets a
                // usable picker instead of a spinner.
                models = await WhisperModels.available()
                refreshOnDisk()
                loading = false
            }
        }
    }

    /// One list of models, for one slot.
    ///
    /// **Only multilingual variants are listed, and that is not a preference.**
    /// `WhisperModels.available()` filters out `.en` and `distil-*`, which cannot
    /// produce Korean at all — and the failure is *silence*, not garbage, which is
    /// indistinguishable from nobody having spoken. Offering them would be
    /// offering a way to lose half the round without noticing.
    @ViewBuilder
    private func modelSection(title: String,
                              selected: String,
                              select: @escaping (String) -> Void,
                              footer: String) -> some View {
        Section {
            ForEach(models) { choice in
                Button {
                    select(choice.id)
                    // **Selecting fetches it, here and now.** The alternative is
                    // discovering on the first tee that the model is half a
                    // gigabyte away over a signal the course does not have — and
                    // the words worth pressing Record for are the ones lost to
                    // that.
                    if !onDisk.contains(choice.id) { fetch(choice.id) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(choice.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                if onDisk.contains(choice.id) {
                                    // The size, not just a tick: "is it cached?"
                                    // got the wrong answer twice from reasoning
                                    // about paths, and a number on screen is a
                                    // fact.
                                    Label(sizes[choice.id] ?? "on this phone",
                                          systemImage: "checkmark.circle")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        if downloading == choice.id {
                            ProgressView(value: progress).progressViewStyle(.circular)
                                .controlSize(.small)
                        } else if choice.id == selected {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        } else if !onDisk.contains(choice.id) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(downloading != nil)
            }
        } header: {
            HStack {
                Text(title)
                if loading { ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text(footer)
        }
    }

    private func refreshOnDisk() {
        let known = models.map(\.id) + [model.whisperModel, model.whisperFinalModel]
        onDisk = Set(known.filter(WhisperEngine.isDownloaded))
        sizes = Dictionary(uniqueKeysWithValues: onDisk.compactMap { id in
            WhisperEngine.bytesOnDisk(id).map {
                (id, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
            }
        })
    }

    private func fetch(_ id: String) {
        downloading = id
        progress = 0
        failure = nil
        Task {
            do {
                try await WhisperEngine.shared.download(model: id) { p in
                    Task { @MainActor in progress = p }
                }
            } catch {
                failure = "Could not get \(WhisperModels.prettyName(id)): \(error)"
            }
            downloading = nil
            refreshOnDisk()
        }
    }
}
