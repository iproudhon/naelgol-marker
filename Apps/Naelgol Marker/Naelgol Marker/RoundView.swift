import SwiftUI
import GolfSessionFormat
import GolfCaptureCore

/// One screen. Start a round, MARK while it runs, stop. Everything else is
/// Phase 2+ and off-device.
struct RoundView: View {
    @ObservedObject var model: RoundViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isRecording { RecordingView(model: model) } else { SetupView(model: model) }
            }
        }
    }
}

// MARK: - Before the round

/// A `Form` rather than a hand-rolled `VStack`: it scrolls, it insets for the
/// keyboard, and it keeps the title out of the fields' way. The hand-rolled
/// version squeezed its content when the keyboard appeared and the large
/// navigation title landed on top of the players field.
private struct SetupView: View {
    @ObservedObject var model: RoundViewModel

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

            Section("Course") {
                TextField("Naelgol CC", text: $model.courseText)
                    .focused($focus, equals: .course)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
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
                        Label("Allow microphone and location", systemImage: "hand.raised.fill")
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
                    Task { await model.startRound() }
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

// MARK: - During the round

private struct RecordingView: View {
    @ObservedObject var model: RoundViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(model.players) { player in
                    Button {
                        model.mark(player: player.id)
                    } label: {
                        Text(player.name)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.bordered)
                }

                if let last = model.lastMarkLabel {
                    Text(last).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                status
            }
            .padding()
        }
        .navigationTitle(timeString(model.elapsed))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .opacity(model.audioState == .recording ? 1 : 0.25)
                    Text("\(model.markCount)").monospacedDigit()
                }
                .font(.footnote)
            }
        }
        // Pinned, so ending a round never means hunting for the button.
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive) {
                model.stopRound()
            } label: {
                Text("End round").frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Audio", audioLabel)
            row("GPS", model.fixAccuracy.map { String(format: "±%.0f m · %d fixes", $0, model.fixCount) }
                      ?? "waiting for a fix")
            row("Motion", model.activity)
            row("Elevation", String(format: "%+.1f m since start", model.relativeAltitude))
            if let name = model.sessionName { row("Session", name) }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var audioLabel: String {
        switch model.audioState {
        case .recording: return "recording"
        case .interrupted: return "interrupted — will resume"
        case .stopped: return "stopped"
        case .idle: return "idle"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
