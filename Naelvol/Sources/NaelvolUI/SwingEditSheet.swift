#if os(iOS)
import SwiftUI
import NaelvolCore

/// What this swing is about: course, hole, player, tags, a note.
///
/// **Pickers where the host has a catalog, free text where it does not.** A phone
/// with no course files is the ordinary state on a fresh install, and a sheet that
/// offers an empty menu is a sheet nobody can fill in.
public struct SwingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var context: SwingContext
    @State private var tagText: String
    private let catalog: SwingCatalog
    private let onSave: (SwingContext) -> Void

    public init(context: SwingContext, catalog: SwingCatalog,
                onSave: @escaping (SwingContext) -> Void) {
        _context = State(initialValue: context)
        _tagText = State(initialValue: context.tags.joined(separator: ", "))
        self.catalog = catalog
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    if catalog.courses.isEmpty {
                        TextField("Course", text: Binding(
                            get: { context.courseName ?? "" },
                            set: { context.courseName = $0.isEmpty ? nil : $0 }))
                    } else {
                        Picker("Course", selection: Binding(
                            get: { context.courseID ?? "" },
                            set: { id in
                                context.courseID = id.isEmpty ? nil : id
                                // A hole number means nothing without the course
                                // it is on, so changing the course clears it.
                                context.hole = nil
                                context.holeRef = nil
                            })) {
                            Text("None").tag("")
                            ForEach(catalog.courses) { course in
                                Text(course.name).tag(course.id)
                            }
                        }
                        holePicker
                    }

                    if catalog.players.isEmpty {
                        TextField("Player", text: Binding(
                            get: { context.playerName ?? "" },
                            set: { context.playerName = $0.isEmpty ? nil : $0 }))
                    } else {
                        Picker("Player", selection: Binding(
                            get: { context.playerID ?? "" },
                            set: { context.playerID = $0.isEmpty ? nil : $0 })) {
                            Text("None").tag("")
                            ForEach(catalog.players) { player in
                                Text(player.name).tag(player.id)
                            }
                        }
                    }
                }

                Section("Tags") {
                    TextField("driver, fade", text: $tagText)
                        .textInputAutocapitalization(.never)
                    TextField("Note", text: Binding(
                        get: { context.note ?? "" },
                        set: { context.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }

                Section {
                    // What another app will show for this file. Printed, because
                    // the record is JSON in a key nobody reads by eye and this
                    // sentence is what vipl and the Files app display.
                    Text(preview.caption.isEmpty ? "No description" : preview.caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Reads as")
                }
            }
            .navigationTitle("Swing details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preview)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var holePicker: some View {
        let holes = catalog.course(id: context.courseID)?.holes ?? []
        if !holes.isEmpty {
            Picker("Hole", selection: Binding(
                get: { context.hole ?? 0 },
                set: { context.hole = $0 == 0 ? nil : $0 })) {
                Text("None").tag(0)
                ForEach(holes) { hole in
                    Text(hole.label).tag(hole.index)
                }
            }
        }
    }

    /// The context as it will be written: tags split, and the host's labels
    /// resolved so the file carries readable names even on a phone that has since
    /// deleted the course.
    private var preview: SwingContext {
        var out = context
        out.tags = SwingMetadata.tags(from: tagText)
        return catalog.resolve(out)
    }
}
#endif
