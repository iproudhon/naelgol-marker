import SwiftUI
import UniformTypeIdentifiers
import GolfSessionFormat
import GolfCourse
import GolfExchange

/// Exporting a whole round, and taking one back in.
///
/// **Two sheets, and they are deliberately not the Copy buttons.** The round menu
/// already has "Copy whole round", which puts `RoundExport`'s JSON on the clipboard
/// for a *model* — logs and events, no answer key. This is the other thing: the
/// round's every stream **plus the course file and its terrain**, complete enough to
/// put back on another phone. The labels have to keep them apart, because the
/// difference between them is the ground-truth firewall and it is invisible once a
/// blob is on a clipboard.
struct RoundExportSheet: View {
    let folder: SessionFolder
    @ObservedObject var library: CourseLibrary
    @Environment(\.dismiss) private var dismiss

    /// Both forms of the same export, built once. See `build()`.
    private struct Built: Sendable {
        var summary: String, summaryWithout: String
        var unreadable: [RoundArchive.Unreadable]
        var missingCourse: String?
        var withTerrain: String
        /// Nil when there is no grid to leave out — then there is no toggle either.
        var withoutTerrain: String?
        var file: URL?, fileWithout: URL?
        var grid: String?
    }

    @State private var built: Built?
    @State private var failure: String?
    @State private var copied = false
    /// **On by default**, which is the "full round-trip" this format was asked for.
    /// Terrain is the one part a receiving phone can go and fetch for itself, so it
    /// is the part that may be dropped — not the part that must be asked for.
    #if DEBUG
    @State private var includeTerrain = DemoSeed.exportIncludesTerrain   // screenshot support
    #else
    @State private var includeTerrain = true
    #endif

    private var text: String? {
        guard let built else { return nil }
        return includeTerrain ? built.withTerrain : (built.withoutTerrain ?? built.withTerrain)
    }
    private var file: URL? {
        guard let built else { return nil }
        return includeTerrain ? built.file : (built.fileWithout ?? built.file)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                } else if let built, let text {
                    Section("This export") {
                        LabeledContent("Round",
                                       value: includeTerrain || built.withoutTerrain == nil
                                            ? built.summary : built.summaryWithout)
                        LabeledContent("Size", value: size(text))
                        // Computed from the text actually chosen, never once at
                        // build time: terrain is nearly all the bytes, so turning
                        // it off usually drops the export under the threshold and
                        // flips the wire form from compressed to readable JSON.
                        LabeledContent("Form",
                                       value: text.hasPrefix(BundleText.marker)
                                            ? "Compressed" : "Readable JSON")
                    }

                    // **Offered only when there is a grid to leave out.** A toggle
                    // that does nothing on most courses — no course outside the US
                    // has terrain at all — is a control that teaches people it does
                    // nothing.
                    if let without = built.withoutTerrain {
                        Section {
                            Toggle("Include terrain", isOn: $includeTerrain)
                                .onChange(of: includeTerrain) { _, _ in copied = false }
                        } footer: {
                            // **Both sizes, phrased so neither state contradicts
                            // the Size row above.** The first version said "121 KB
                            // of this 171 KB export" — true with the toggle on and
                            // a plain disagreement with the 50 KB three lines above
                            // it the moment it went off. Same class as the
                            // plays-like rounding that made three numbers on the
                            // hole fail to add up: it reads as an arithmetic error
                            // in the app.
                            Text("\(built.grid ?? "The elevation grid") costs "
                               + "\(size(built.withTerrain, minus: without)) — "
                               + "\(size(built.withTerrain)) with it, \(size(without)) "
                               + "without. Leave it out and the round still carries "
                               + "everything else, but the plays-like distances will not "
                               + "appear until that phone downloads the terrain itself — "
                               + "which needs a signal, and so needs doing before the round.")
                        }
                    }

                    // **What did not travel, in front of the button** — the same
                    // rule the course finder and the terrain sheet follow. An
                    // export that quietly left something behind is the failure this
                    // whole feature exists to avoid.
                    if built.missingCourse != nil || !built.unreadable.isEmpty {
                        Section("Not included") {
                            if let name = built.missingCourse {
                                Label {
                                    Text("No course file for “\(name)”. The round exports "
                                       + "without its map, so the holes and distances will be "
                                       + "missing wherever it lands.")
                                } icon: { Image(systemName: "map").foregroundStyle(.orange) }
                            }
                            ForEach(built.unreadable, id: \.file) { u in
                                Label {
                                    Text("\(u.lost) of \(u.onDisk) rows in \(u.file) could not "
                                       + "be read and are not in this export.")
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy to clipboard",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        if let file {
                            ShareLink(item: file) {
                                Label("Share as a file", systemImage: "square.and.arrow.up")
                            }
                        }
                    } footer: {
                        // Said plainly, because a clipboard has no labels on it and
                        // this is the one thing that must not be pasted into a chat
                        // with a model.
                        Text("Includes this round's scores, marks and corrections — "
                           + "its ground truth. Paste it into Marker, not into a model. "
                           + "Recordings are never included.")
                    }
                } else {
                    Section { HStack { ProgressView(); Text("Reading the round…") } }
                }
            }
            .navigationTitle("Export round")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
            .task { await build() }
        }
    }

    private func size(_ s: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(s.utf8.count), countStyle: .file)
    }
    private func size(_ a: String, minus b: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, a.utf8.count - b.utf8.count)),
                                  countStyle: .file)
    }

    /// **Off the main actor, and both forms in one pass.**
    ///
    /// This used to be a synchronous `build()`. Decoding a `.dem` is about a
    /// megabyte of JSON and encoding the bundle is another, and doing that on the
    /// main actor is the same hang `RoundImportSheet.look()` was already fixed for
    /// — fast enough in a simulator to look fine, slow enough on a phone not to be.
    /// Building both forms here rather than re-encoding per toggle also means the
    /// switch costs nothing and both sizes are real measurements rather than an
    /// estimate: relief is entropy, so how much terrain actually costs cannot be
    /// guessed from the grid's dimensions.
    private func build() async {
        guard built == nil, failure == nil else { return }
        let folder = self.folder
        let store = library.store
        // Resolved **by name**, the way the round screen resolves its course — a
        // second scheme here would find a different file than the one the golfer
        // has been looking at. Done on the main actor because `library.courses` is.
        let meta = try? folder.readMeta()
        let course = meta?.course.flatMap { name in
            library.courses.first { $0.name == name || $0.aliases.contains(name) }
        }
        let missing: String? = {
            guard let name = meta?.course, !name.isEmpty, course == nil else { return nil }
            return name
        }()
        let hasTerrain = course.map { store.elevationExists(id: $0.id) } ?? false

        let result: Result<Built, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let dem = hasTerrain ? course.flatMap { store.loadElevation(id: $0.id) } : nil
                let (full, lost) = try RoundArchive.bundle(
                    from: folder, course: course, elevation: dem,
                    generator: "Naelgol Marker")
                var out = Built(summary: full.summary, summaryWithout: full.summary,
                                unreadable: lost, missingCourse: missing,
                                withTerrain: try BundleText.encode(full),
                                withoutTerrain: nil)
                out.file = Self.temp(out.withTerrain, folder: folder, suffix: "")
                if let dem {
                    let (lean, _) = try RoundArchive.bundle(
                        from: folder, course: course, elevation: dem,
                        includeTerrain: false, generator: "Naelgol Marker")
                    out.summaryWithout = lean.summary
                    out.withoutTerrain = try BundleText.encode(lean)
                    out.fileWithout = Self.temp(out.withoutTerrain!, folder: folder,
                                                suffix: "-no-terrain")
                    out.grid = "The \(dem.width)×\(dem.height) elevation grid"
                }
                return out
            }
        }.value

        switch result {
        case .success(let b): built = b
        case .failure(let e): failure = "Could not read this round: \(e.localizedDescription)"
        }
    }

    /// Written to a temp file so `ShareLink` has something with a name and a type —
    /// AirDrop and Files both want a document, not a string. Two files, because the
    /// toggle picks between two documents and a share sheet holding the other one
    /// is worse than no share sheet.
    private static func temp(_ text: String, folder: SessionFolder, suffix: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(folder.url.lastPathComponent)\(suffix).marker-round.txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }
}

// MARK: - Import

struct RoundImportSheet: View {
    let sessionsRoot: URL
    @ObservedObject var library: CourseLibrary
    /// A file to open on appear, for the screenshot harness only — the picker is a
    /// system sheet nothing here can drive, and an empty importer shows none of what
    /// this screen is for. Nil in a real build.
    var initial: URL?
    /// Called with the imported round's folder name, so the list can open it.
    var onImported: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var preview: RoundBundle?
    @State private var failure: String?
    @State private var report: RoundArchive.Report?
    @State private var reading = false
    /// Bumped per paste, so a slow decode of superseded text is discarded.
    @State private var token = 0
    @State private var choosingFile = false
    /// Named so the preview can say where this came from — a golfer who picked the
    /// wrong file from a list of similarly-named ones has nothing else to go on.
    @State private var sourceName: String?

    var body: some View {
        NavigationStack {
            Form {
                if let report {
                    Section("Imported") {
                        ForEach(report.lines, id: \.self) { Text($0).font(.footnote.monospaced()) }
                    }
                } else {
                    // **Two roads in, and no text box.** There used to be a
                    // `TextEditor` under these buttons, offered on the argument that
                    // a paste failing with nothing on screen is a dead end. It also
                    // grew to fit its content, so a real 400 KB paste once filled the
                    // sheet and pushed the summary and the Import button clean off
                    // the screen — which is why it is hidden the moment something
                    // decodes. Once a file could be chosen, what was left of it on
                    // arrival was a 110-point blank void under two working buttons,
                    // and nobody reads base64 anyway: what replaces it — the course,
                    // the date, the players, the scores — is what somebody actually
                    // needs before saying yes. The dead end it guarded is closed by
                    // an **empty clipboard being reported** rather than doing
                    // nothing, which is what the box was really covering for.
                    if preview == nil && !reading {
                        Section {
                            Button {
                                let text = UIPasteboard.general.string ?? ""
                                if text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty {
                                    sourceName = nil
                                    failure = "There is nothing on the clipboard. Copy the "
                                            + "export first, or choose it as a file."
                                } else {
                                    decode(text, from: nil)
                                }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard")
                            }
                            // **A file, because that is the other half of Export.**
                            // The export sheet offers `ShareLink`, so a round can
                            // arrive by AirDrop, Mail or a Files folder — and it
                            // then lands as a document, which a clipboard cannot
                            // reach. Without this the only way to import one was to
                            // open it in some other app and copy the whole 400 KB
                            // of base64 by hand.
                            Button {
                                choosingFile = true
                            } label: {
                                Label("Choose a file…", systemImage: "folder")
                            }
                        } header: {
                            Text("Bring in an exported round")
                        } footer: {
                            Text("From the clipboard, or from Files — AirDrop, Mail and "
                               + "iCloud Drive all land there. Either form works: the "
                               + "readable JSON or the compact MARKER-ROUND block.")
                        }
                    }

                    if reading {
                        Section { HStack { ProgressView(); Text("Reading…") } }
                    }
                    if let failure {
                        Section { Text(failure).foregroundStyle(.red) }
                    }
                    if let preview {
                        Section("This round") {
                            Text(preview.summary)
                            if let sourceName {
                                LabeledContent("From", value: sourceName)
                            }
                            if let g = preview.generator {
                                LabeledContent("Exported by", value: g)
                            }
                            if !preview.round.groundTruth.isEmpty {
                                LabeledContent("Scores",
                                    value: "\(preview.round.groundTruth.journal.count) journal entries")
                            }
                            if !preview.round.audio.segments.isEmpty {
                                Label("\(preview.round.audio.segments.count) audio segments are "
                                    + "indexed; the recordings are not included in an export.",
                                      systemImage: "waveform")
                                    .font(.footnote)
                            }
                        }
                        Section {
                            Button {
                                perform(preview)
                            } label: {
                                Label("Import this round", systemImage: "square.and.arrow.down")
                            }
                            // The way back, since the box that got here is now
                            // hidden. Without it a wrong paste is a dead end that
                            // needs the sheet closed and reopened.
                            Button(role: .destructive) {
                                decode("", from: nil)
                            } label: {
                                Label("Choose something else",
                                      systemImage: "arrow.uturn.backward")
                            }
                        } footer: {
                            Text("Nothing is overwritten. The round is added as a new one, and "
                               + "a course you already have is kept as it is.")
                        }
                    }
                }
            }
            .navigationTitle("Import round")
            .navigationBarTitleDisplayMode(.inline)
            // `.text` covers the `.marker-round.txt` an export writes and the plain
            // JSON form alike — `public.json` conforms to `public.text` — so a
            // document saved under either name is offered rather than greyed out.
            .fileImporter(isPresented: $choosingFile,
                          allowedContentTypes: [.text, .json]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let e): failure = e.localizedDescription
                }
            }
            .task {
                guard let initial, preview == nil, failure == nil else { return }
                load(initial)
            }
            // **One button, not two.** Before an import "Cancel" and "Close" would
            // be two controls a centimetre apart doing exactly the same thing —
            // which is how they come to mean subtly different things later. After
            // one, "Done" is the only thing left to do, and it carries the round
            // forward so the list opens what just arrived.
            .safeAreaInset(edge: .bottom) {
                Group {
                    if report == nil {
                        Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                    } else {
                        Button("Done") {
                            report.map { onImported($0.folder.lastPathComponent) }
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
        }
    }

    /// Decode `text` so the golfer sees it **before** anything is written.
    /// Nothing here touches the disk.
    ///
    /// **Off the main actor, because this is not a cheap read.** A real export is
    /// 150–400 KB of base64 that inflates to about a megabyte of JSON, and doing
    /// that inline in `onChange` hangs the one screen the action lives on — which a
    /// golfer reads as the paste not having worked. It is fast enough on a
    /// simulator to look fine and slow enough on a phone not to be.
    ///
    /// `token` drops a result that a later paste has already superseded, so a slow
    /// decode of the wrong thing cannot land on top of the right one.
    ///
    /// **Both roads end here**, and neither keeps the text: a bundle is a megabyte
    /// of JSON, and holding the source string in `@State` as well buys nothing once
    /// the summary is on screen. `sourceName` is set here rather than by the caller
    /// so a paste always clears it — "From coyote.marker-round.txt" over a round
    /// that arrived by some other road would be a plain lie about provenance.
    private func decode(_ text: String, from source: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceName = source
        token &+= 1
        let mine = token
        preview = nil
        failure = nil
        guard !trimmed.isEmpty else { return }
        reading = true
        Task {
            let result: Result<RoundBundle, Error> = await Task.detached(priority: .userInitiated) {
                Result { try BundleText.decode(trimmed) }
            }.value
            await MainActor.run {
                guard mine == token else { return }
                reading = false
                switch result {
                case .success(let b): preview = b
                case .failure(let e as BundleText.Failure): failure = e.description
                case .failure: failure = "That could not be read as an exported round."
                }
            }
        }
    }

    /// Read a chosen file and hand it to `decode`, which is the one decode path.
    ///
    /// **The security-scoped call is not optional and its absence is silent.** A URL
    /// from `.fileImporter` points outside the app's container, and reading it
    /// without `startAccessingSecurityScopedResource()` fails with a permission
    /// error that reads, on this screen, exactly like a corrupt export. It is
    /// balanced by `defer`, because a scope left open leaks a sandbox extension for
    /// the life of the process.
    ///
    /// **Off the main actor**, for the same reason `look()` is: an export is a few
    /// hundred kilobytes, and one picked out of iCloud Drive may not be on the
    /// phone yet — the read then blocks on a download, on the screen that is
    /// supposed to be responding to the tap.
    private func load(_ url: URL) {
        reading = true
        failure = nil
        preview = nil
        Task {
            let name = url.lastPathComponent
            let text: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try String(contentsOf: url, encoding: .utf8) }
            }.value
            await MainActor.run {
                reading = false
                switch text {
                case .success(let s):
                    decode(s, from: name)
                case .failure:
                    // Named, because "that file" is the only thing distinguishing it
                    // from the half-dozen others in the folder it came from.
                    sourceName = nil
                    failure = "Could not read \u{201C}\(name)\u{201D}. An exported round is "
                            + "a text file — pick the one Marker wrote, not a photo or a zip."
                }
            }
        }
    }

    private func perform(_ bundle: RoundBundle) {
        do {
            let r = try RoundArchive.restore(bundle, into: sessionsRoot,
                                             courses: library.store)
            library.reload()
            // **An import can add a `.dem` to a course that did not change**, and
            // `loadTerrain`'s id guard cannot see that. `terrainOutcome` names the
            // id, so ask for the re-read here rather than relying on a guard that
            // is right about the case it was written for and blind to this one.
            if case .written(let id) = r.terrainOutcome, id == library.selectedID {
                library.loadTerrain(force: true)
            }
            report = r
        } catch let e as BundleText.Failure { failure = e.description }
        catch { failure = "Import failed: \(error.localizedDescription)" }
    }
}
