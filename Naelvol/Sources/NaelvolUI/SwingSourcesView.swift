#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import NaelvolCore

/// Which folders the grid lists.
///
/// Naelgol's own is first, always, and cannot be removed: a capture has to land
/// somewhere. Everything else is a folder the user picked, held as a
/// security-scoped bookmark and **read in place** — the files belong to whatever
/// put them there, so they are listed and played and never written to.
public struct SwingSourcesView: View {
    @ObservedObject var library: SwingLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var repairing: SwingSource?
    @State private var failure: String?

    public init(library: SwingLibrary) { self.library = library }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(library.sources) { source in
                    row(source)
                }
                Section {
                    Button {
                        repairing = nil
                        picking = true
                    } label: {
                        Label("Add a folder…", systemImage: "folder.badge.plus")
                    }
                } footer: {
                    Text("A folder you add is listed but never written to. To edit or trim one of "
                         + "its swings, save a copy into Naelgol first.")
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        if let repairing {
                            try library.repair(repairing, with: url)
                        } else {
                            try library.addFolder(at: url)
                        }
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                    repairing = nil
                case .failure(let error):
                    failure = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ source: SwingSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(source.kind == .app ? "Naelgol's own · read and write" : "Added folder · read only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if source.needsPermission {
                    // **A first-class state, not an error toast.** A bookmark goes
                    // stale when the folder moves or the app is reinstalled;
                    // re-picking it repairs the source in place, keeping its id so
                    // every cached thumbnail survives.
                    Text("Needs permission again — tap to re-pick")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text("\(library.swings.filter { $0.sourceID == source.id }.count)")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard source.kind == .bookmarked else { return }
            repairing = source
            picking = true
        }
        .swipeActions {
            if source.kind != .app {
                Button("Remove", role: .destructive) { library.remove(source) }
            }
        }
    }
}
#endif
