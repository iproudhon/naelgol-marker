import SwiftUI
import GolfSessionFormat
import GolfCourse

/// The starting screen: rounds.
///
/// **"Active rounds" is plural because of crash recovery, not concurrency.** One
/// `RoundSession` means exactly one round can be *recording*.
/// What can pile up is rounds that were started and never ended — the app killed
/// in a pocket, a battery death on the 16th. Until this screen existed those
/// folders were orphaned in silence and nothing would ever show them again.
struct RoundsListView: View {
    @ObservedObject var model: RoundViewModel
    /// App-wide feed, threaded to both destinations. Named in full because
    /// `live` is already a local in this file for the recording round.
    @ObservedObject var liveLocation: LiveLocation
    @State private var path: [Route]
    @State private var rounds: [SessionSummary] = []
    @State private var deleted: [SessionTrash.Deleted] = []
    /// The round a confirmation is currently asking about. `nil` means no dialog.
    @State private var confirmingDelete: SessionSummary?
    @State private var confirmingEmpty = false
    /// What the last delete, restore or purge did — an error, or a report of rounds
    /// that expired on their own. **Everything else on this screen says what it
    /// declined to do**; a `try?` that silently does nothing reads as the swipe not
    /// having registered.
    @State private var notice: String?
    /// The course library, for the toolbar's course button — this screen shows no
    /// courses itself, it only needs somewhere to put a downloaded one and the ids
    /// already taken, so a save cannot replace a file with placed coordinates in it.
    @StateObject private var library = CourseLibrary()
    @State private var finding = false
    @State private var importing = false
    /// Screenshot support: a file to open on appear, because neither the clipboard
    /// nor the file picker can be driven here. Nil outside DEBUG.
    private var seededImport: URL? {
        #if DEBUG
        return DemoSeed.importFile
        #else
        return nil
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase

    init(model: RoundViewModel, live: LiveLocation, initial: [Route] = []) {
        self.liveLocation = live
        self.model = model
        _path = State(initialValue: initial)
    }

    enum Route: Hashable {
        case newRound
        /// Session folder name — the round screen resolves the folder itself, so
        /// this stays `Hashable` and survives a navigation restore.
        case round(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let live = rounds.first(where: { $0.state == .recording }) {
                    Section("Recording") { row(live) }
                }
                let open = rounds.filter { $0.state == .unfinished }
                if !open.isEmpty {
                    Section {
                        ForEach(open) { row($0) }
                    } header: {
                        Text("Unfinished")
                    } footer: {
                        Text("Started and never ended — usually the app was closed mid-round. "
                           + "The logs and the track are still there. Open one to close it out.")
                    }
                }
                let done = rounds.filter { $0.state == .finished }
                Section {
                    if done.isEmpty && rounds.isEmpty {
                        ContentUnavailableView("No rounds yet",
                                               systemImage: "figure.golf",
                                               description: Text("Tap New round to start recording."))
                    } else {
                        ForEach(done) { row($0) }
                    }
                } header: {
                    if !done.isEmpty { Text("Past rounds") }
                }

                // **Only when there is something in it.** An always-visible empty
                // bin is a permanent reminder of a thing that has not happened, on
                // the first screen of the app.
                if !deleted.isEmpty {
                    Section {
                        ForEach(deleted) { deletedRow($0) }
                    } header: {
                        HStack {
                            Text("Recently deleted")
                            Spacer()
                            Button("Empty", role: .destructive) { confirmingEmpty = true }
                                .font(.caption)
                        }
                    } footer: {
                        // The window said out loud, because a recovery window nobody
                        // knows about is not one — and **the space**, because that is
                        // the whole reason `SessionSummary.bytes` exists. A thirty-day
                        // hold over 4.5-hour rounds is exactly how a phone fills up,
                        // and a bin whose size is invisible is a silent leak rather
                        // than a recovery window.
                        Text("Kept for 30 days, then deleted for good — "
                           + trashSize + " in all. Swipe a round to put it back.")
                    }
                }
            }
            .navigationTitle("Rounds")
            .toolbar {
                // **Beside the + rather than behind a menu** *(user, 2026-08-30:
                // "Add Courses button next to + button")*. This is the first screen
                // of the app, and on a fresh install it is the only one reachable
                // with no round and no course — so it is where downloading a course
                // has to be offered. The hole view's copy is reached *through* a
                // round, which is the wrong way round for somebody who has neither.
                ToolbarItem(placement: .topBarTrailing) {
                    // **Import lives here and only here.** A round arriving from
                    // somebody else has no round to be reached through, so it has
                    // to be offered on the one screen that exists before there is
                    // one — the same argument that put "Find a course" here.
                    Menu {
                        Button { finding = true } label: {
                            Label("Find a course…", systemImage: "map")
                        }
                        Button { importing = true } label: {
                            Label("Import a round…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.newRound) {
                        Label("New round", systemImage: "plus")
                    }
                    .disabled(model.isRecording)
                }
            }
            .sheet(isPresented: $finding) {
                CourseFinder(here: model.here ?? liveLocation.here,
                             existingIDs: Set(library.courses.map(\.id))) { course in
                    library.save(course)
                }
            }
            .sheet(isPresented: $importing) {
                RoundImportSheet(sessionsRoot: RoundViewModel.sessionsRoot, library: library,
                                 initial: seededImport) { name in
                    reload()
                    path = [.round(name)]
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .newRound:
                    NewRoundView(model: model) { id in
                        path = [.round(id)]      // replace, so Back lands on the list
                    }
                case .round(let id):
                    RoundScreen(id: id, model: model, live: liveLocation)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if rounds.isEmpty {
                    NavigationLink(value: Route.newRound) {
                        Text("New round")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                    .background(.bar)
                }
            }
            .alert("Recently deleted",
                   isPresented: Binding(get: { notice != nil },
                                        set: { if !$0 { notice = nil } })) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
            .confirmationDialog("Delete this round?",
                                isPresented: Binding(get: { confirmingDelete != nil },
                                                     set: { if !$0 { confirmingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: confirmingDelete) { s in
                Button("Delete round", role: .destructive) { delete(s) }
                Button("Cancel", role: .cancel) { }
            } message: { s in
                // Names what goes, in the round's own numbers. "Are you sure?" asks
                // a question the golfer cannot answer without leaving the dialog.
                Text("\(s.courseName ?? "This round") · "
                   + "\(s.startDate.formatted(date: .abbreviated, time: .shortened))\n"
                   + detail(s)
                   + "\n\nIt goes to Recently deleted and is kept for 30 days.")
            }
            .confirmationDialog("Delete \(deleted.count) round\(deleted.count == 1 ? "" : "s") "
                              + "for good?",
                                isPresented: $confirmingEmpty, titleVisibility: .visible) {
                Button("Delete for good", role: .destructive) { empty() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone.")
            }
            .onAppear {
                reload()
                // Purging on appear rather than on a timer: this app has no
                // background work, and a golfer who does not open it should not have
                // rounds vanishing behind them.
                purgeExpired()
                #if DEBUG
                autoStartIfRequested()
                // Both sheets on this screen now live behind a menu, so both need a
                // way in for a screenshot — the same argument as `marker.find`.
                if DemoSeed.wantsFinder { finding = true }
                if DemoSeed.wantsImport { importing = true }
                switch DemoSeed.trashMode {
                case "confirm":
                    // The delete dialog is the most consequential control on this
                    // screen and is two taps behind a swipe, so it needs its own way
                    // in — the same argument as `marker.sheet`.
                    confirmingDelete = rounds.first { $0.state == .finished }
                case let v? where !v.isEmpty:
                    if deleted.isEmpty, let oldest = rounds.last(where: { $0.state == .finished }) {
                        delete(oldest)
                    }
                default: break
                }
                #endif
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
            .onChange(of: model.state) { _, _ in reload() }
        }
    }

    #if DEBUG
    /// Screenshot support: start a round and walk straight into it. See `DemoSeed`.
    private func autoStartIfRequested() {
        guard DemoSeed.wantsAutoStart, !model.isRecording else { return }
        Task {
            if model.drafts.compactMap(\.player).isEmpty {
                model.drafts = [.init(name: "steve"), .init(name: "dave")]
            }
            await model.startRound()
            guard let id = model.sessionName else { return }
            path = [.round(id)]
            if DemoSeed.wantsAutoRecord {
                await model.startListening(players: model.players)
            }
        }
    }
    #endif

    private func reload() {
        rounds = SessionIndex.summaries(in: RoundViewModel.sessionsRoot,
                                        recordingID: model.isRecording ? model.sessionName : nil)
        deleted = SessionTrash.contents(in: RoundViewModel.sessionsRoot)
    }

    // MARK: - Deleting

    /// **Never the round that is recording**, and the control is not offered on that
    /// row rather than offered and refused. Moving the folder out from under a live
    /// `RoundSession` leaves the recorder writing into a path that no longer exists:
    /// the segment never closes, the last audio is lost, and nothing reports it.
    /// Only this process knows which round that is, which is why the check is here
    /// and not in `SessionTrash`.
    private func canDelete(_ s: SessionSummary) -> Bool { s.state != .recording }

    private func delete(_ s: SessionSummary) {
        guard canDelete(s) else { return }
        // **No separate Undo banner.** "Recently deleted" is the recovery path and
        // it is one swipe away on the same screen; a transient Undo beside it would
        // be two controls a centimetre apart doing one thing, which is how they come
        // to behave subtly differently.
        report("Could not delete that round") {
            try SessionTrash.discard(SessionFolder(url: s.url), in: RoundViewModel.sessionsRoot)
        }
    }

    private func restore(_ d: SessionTrash.Deleted) {
        report("Could not put that round back") {
            try SessionTrash.restore(d.url, to: RoundViewModel.sessionsRoot)
        }
    }

    private func purge(_ d: SessionTrash.Deleted) {
        report("Could not delete that round") { try SessionTrash.purge(d.url) }
    }

    private func empty() {
        report("Could not empty Recently deleted") {
            try SessionTrash.empty(in: RoundViewModel.sessionsRoot)
        }
    }

    /// **Says what it purged.** `purgeExpired` returns the names for exactly this:
    /// rounds that disappear with nothing accounting for them are indistinguishable
    /// from rounds the app lost.
    private func purgeExpired() {
        let gone = SessionTrash.purgeExpired(in: RoundViewModel.sessionsRoot)
        guard !gone.isEmpty else { return }
        notice = "\(gone.count) round\(gone.count == 1 ? " was" : "s were") "
               + "past 30 days in Recently deleted and \(gone.count == 1 ? "has" : "have") "
               + "now been deleted for good."
        reload()
    }

    /// Run a file operation, reload, and surface the failure as a sentence rather
    /// than dropping it — the rule the rest of this app follows for anything that
    /// touches the disk.
    private func report(_ what: String, _ work: () throws -> Void) {
        do { try work() } catch { notice = "\(what): \(error.localizedDescription)" }
        reload()
    }

    private var trashSize: String {
        ByteCountFormatter.string(fromByteCount: deleted.reduce(0) { $0 + $1.summary.bytes },
                                  countStyle: .file)
    }

    private func deletedRow(_ d: SessionTrash.Deleted) -> some View {
        // **Not a `NavigationLink`.** A deleted round has no live folder for the
        // round screen to open, and its logs, journal and placement tasks all write.
        // It is a record of something that was, until it is put back.
        VStack(alignment: .leading, spacing: 3) {
            Text(d.summary.courseName ?? "Unnamed course")
                .font(.headline).foregroundStyle(.secondary)
            Text(d.summary.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(expiry(d)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { purge(d) } label: {
                Label("Delete for good", systemImage: "trash.slash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { restore(d) } label: {
                Label("Put back", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
    }

    /// When it goes, or that nothing knows. **A missing stamp is said, not guessed**
    /// — substituting "now" would restart the window on every scan and keep the
    /// round forever while claiming a date.
    private func expiry(_ d: SessionTrash.Deleted) -> String {
        guard let e = d.expires else { return "Kept until you delete it" }
        // **Rounded up, not truncated.** A round deleted a minute ago has 29.99 days
        // left, and `Int(...)` renders that as "29 days" — so a thirty-day window
        // announces itself as twenty-nine on the day it opens, which reads as the
        // app having already eaten a day.
        let days = Int(ceil(e.timeIntervalSinceNow / 86_400))
        return days <= 0 ? "Deleted for good today"
                         : "Deleted for good in \(days) day\(days == 1 ? "" : "s")"
    }

    private func row(_ s: SessionSummary) -> some View {
        NavigationLink(value: Route.round(s.id)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if s.state == .recording {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    } else if s.state == .unfinished {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(s.courseName ?? "Unnamed course")
                        .font(.headline)
                }
                Text(s.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(detail(s))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            if canDelete(s) {
                // The dialog, not the swipe, is what deletes: a swipe is cheap and
                // easy to do by accident on a scrolling list, and this is the one
                // control in the app that takes a round away.
                Button(role: .destructive) { confirmingDelete = s } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func detail(_ s: SessionSummary) -> String {
        var parts: [String] = []
        if let d = s.duration {
            let m = Int(d) / 60
            parts.append(m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m")
        } else if s.state == .recording {
            parts.append("running")
        }
        let names = s.players.map(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        // What a round holds now that it holds no audio: what was said, and what
        // has been made of it.
        if s.hasLogs { parts.append("logs") }
        if s.hasEvents { parts.append("events") }
        if s.audioSegments > 0 { parts.append("\(s.audioSegments) audio") }
        parts.append(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
