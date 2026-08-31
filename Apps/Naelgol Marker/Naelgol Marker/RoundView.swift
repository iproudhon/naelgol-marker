import SwiftUI
import GolfSessionFormat
import GolfCaptureCore
import GolfCourse

// MARK: - Before the round

/// Setting a round up, reached from the rounds list.
///
/// A `Form` rather than a hand-rolled `VStack`: it scrolls, it insets for the
/// keyboard, and it keeps the title out of the fields' way. The hand-rolled
/// version squeezed its content when the keyboard appeared and the large
/// navigation title landed on top of the players field.
struct NewRoundView: View {
    @ObservedObject var model: RoundViewModel
    @StateObject private var library = CourseLibrary()
    @State private var finding = false
    /// Called with the new session's folder name once recording has started.
    var onStarted: (String) -> Void

    private enum Field { case course }
    @FocusState private var focus: Field?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                ForEach($model.drafts) { $draft in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $draft.name)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.body.weight(.medium))
                        TextField("also called: 스티브, 형", text: $draft.aliasText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { model.removePlayers(at: $0) }

                Button {
                    model.addPlayer()
                } label: {
                    Label("Add player", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Players")
            } footer: {
                Text("Put every name the group actually says out loud in \"also called\" — "
                   + "nicknames, Korean given names, 형/누나. Attribution matches on spoken "
                   + "names, so a player called only by a nickname is still attributable.")
            }

            Section {
                if library.courses.isEmpty {
                    // A course file is what the hole view draws from, and a fresh
                    // install has none. Typing a name still starts a round — the
                    // capture layer needs no geometry (PLAN §2).
                    TextField("Course name", text: $model.courseText)
                        .focused($focus, equals: .course)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                    // **The finder belongs here too.** This is where somebody
                    // starting a round discovers they have no course, and the hole
                    // view — the other way in — is reached *through* a round.
                    Button("Find a course…") { finding = true }
                    Button("Install sample course") { library.installSample() }
                } else {
                    Picker("Course", selection: Binding(
                        get: { library.selectedID ?? "" },
                        set: { library.selectedID = $0.isEmpty ? nil : $0 })) {
                        ForEach(library.courses) { c in Text(c.name).tag(c.id) }
                    }
                    // **"Find a course" where "Not listed" used to be** *(user,
                    // 2026-08-30)*. "Not listed" was a dead end that only revealed a
                    // text box; the actionable version of "my course is not here" is
                    // to go and get it. The free-text name still exists for a course
                    // nobody has mapped — it is the `library.courses.isEmpty` branch
                    // above, and the round records fine either way.
                    Button("Find a course…") { finding = true }
                    if library.selectedID == nil {
                        TextField("Course name", text: $model.courseText)
                            .focused($focus, equals: .course)
                            .submitLabel(.done)
                            .onSubmit { focus = nil }
                    }
                }
            } header: {
                Text("Course")
            } footer: {
                Text("Course files live in Documents/Courses and can be dropped in over "
                   + "Finder or the Files app. A round records fine without one.")
            }

            Section {
                ForEach(model.capabilities) { capability in
                    CapabilityRow(capability: capability) {
                        Task { await model.request(capability.kind) }
                    }
                }
                if model.hasUnaskedPermissions {
                    Button {
                        focus = nil
                        Task { await model.requestAllPermissions() }
                    } label: {
                        Label("Allow location", systemImage: "hand.raised.fill")
                    }
                }
            } header: {
                Text("This device")
            } footer: {
                Text("Tap a row to grant it. A device without a barometer still records a "
                   + "full round — just no elevation.")
            }

            if let err = model.errorMessage {
                Section { Text(err).foregroundStyle(.red) }
            }

            Section {
                Button {
                    focus = nil
                    if let course = library.selected { model.courseText = course.name }
                    Task {
                        await model.startRound()
                        if let id = model.sessionName, model.isRecording { onStarted(id) }
                    }
                } label: {
                    Text("Start round")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .disabled(!model.canStart)
            } footer: {
                Text("Start with the app open — iOS will not let a recording begin in the background.")
            }
        }
        .sheet(isPresented: $finding) {
            CourseFinder(here: model.here,
                         existingIDs: Set(library.courses.map(\.id))) { course in
                library.save(course)
            }
        }
        .navigationTitle("New round")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        // Permission can change outside the app (Settings), and a prompt answered
        // here has to move the row off "?" — neither happens without an explicit
        // recompute, which is what left it stuck before.
        .onAppear { model.refreshCapabilities() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshCapabilities() }
        }
        .toolbar {
            // Neither field is the last one in the form, so without this the
            // keyboard has no obvious way out on a phone.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }
}

private struct CapabilityRow: View {
    let capability: RoundViewModel.Capability
    let request: () -> Void

    var body: some View {
        Group {
            if capability.isRequestable {
                Button(action: request) { content }
                    .buttonStyle(.plain)
            } else if capability.needsSettings {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { content }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(capability.name)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            if let detail = capability.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch capability.status {
        case .ready: return "checkmark.circle.fill"
        case .willAsk: return "questionmark.circle"     // not yet asked — not a failure
        case .denied: return "xmark.circle.fill"
        case .unavailable: return "minus.circle"
        }
    }

    private var tint: Color {
        switch capability.status {
        case .ready: return .green
        case .willAsk: return .secondary
        case .denied: return .red
        case .unavailable: return .secondary
        }
    }
}
