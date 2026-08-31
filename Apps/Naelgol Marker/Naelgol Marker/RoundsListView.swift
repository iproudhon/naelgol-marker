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
    /// The course library, for the toolbar's course button — this screen shows no
    /// courses itself, it only needs somewhere to put a downloaded one and the ids
    /// already taken, so a save cannot replace a file with placed coordinates in it.
    @StateObject private var library = CourseLibrary()
    @State private var finding = false
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
                    Button { finding = true } label: {
                        Label("Courses", systemImage: "map")
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
            .onAppear {
                reload()
                #if DEBUG
                autoStartIfRequested()
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
                model.drafts = [.init(name: "steve", aliasText: "스티브, 형"),
                                .init(name: "dave", aliasText: "")]
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
