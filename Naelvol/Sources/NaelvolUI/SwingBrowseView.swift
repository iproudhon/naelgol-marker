#if os(iOS)
import SwiftUI
import NaelvolCore

/// The swing list: a grid of thumbnails, a filter bar above it.
///
/// The **entry point the host presents** from the rounds list, the scorecard and
/// the hole view. The filter it is handed is a *default*: every chip clears, and
/// clearing them all shows every swing in every source.
public struct SwingBrowseView: View {
    @ObservedObject private var library: SwingLibrary
    @EnvironmentObject private var services: NaelvolServices
    @State private var showingSources = false
    @State private var capturing = false

    private let allowsCapture: Bool
    private let seed: SwingFilter
    /// **Applied once, in `task`, not in `init`.** Assigning the library's filter
    /// from an initialiser puts it back on every body evaluation, so a golfer who
    /// cleared a chip would watch it reappear the next time anything in the sheet
    /// changed — and the whole point of a seeded filter is that it is a default,
    /// not a constraint.
    @State private var seeded = false

    /// - Parameter filter: seeded from where this was opened — course from the
    ///   scorecard, course *and* hole from the hole view, nothing from the rounds
    ///   list.
    public init(library: SwingLibrary, filter: SwingFilter = .none, allowsCapture: Bool = true) {
        self.library = library
        self.allowsCapture = allowsCapture
        self.seed = filter
    }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    public var body: some View {
        VStack(spacing: 0) {
            SwingFilterBar(library: library, catalog: services.catalog)
            grid
        }
        .navigationTitle("Swings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $library.sort) {
                        ForEach(SwingSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("Folders…") { showingSources = true }
                    Button("Rescan") { library.refresh() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if allowsCapture {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { capturing = true } label: { Image(systemName: "video.badge.plus") }
                }
            }
        }
        .sheet(isPresented: $showingSources) { SwingSourcesView(library: library) }
        .fullScreenCover(isPresented: $capturing) {
            NavigationStack {
                SwingCaptureView(library: library, context: library.filter.captureContext)
            }
        }
        .navigationDestination(for: Swing.self) { swing in
            SwingPlayerView(swing: swing, library: library)
        }
        .task {
            if !seeded {
                seeded = true
                library.filter = seed
            }
            if library.swings.isEmpty { await library.scan() }
        }
        .refreshable { await library.scan() }
    }

    @ViewBuilder
    private var grid: some View {
        let swings = library.visible
        if swings.isEmpty {
            // Written by hand rather than with `ContentUnavailableView`, which
            // is iOS 17: the package floor is 16, the same as Marker's, so a host
            // on an older phone can still import this.
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "figure.golf").font(.largeTitle).foregroundStyle(.secondary)
                Text(library.scanning ? "Looking…" : "No swings").font(.headline)
                Text(library.filter.isEmpty
                     ? "Recorded swings land here. Add a folder to browse videos filmed elsewhere."
                     : "Nothing matches this filter. Clear a chip above to widen it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(swings) { swing in
                        NavigationLink(value: swing) { SwingCell(swing: swing) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(2)
                if library.unreadable > 0 {
                    // Counted, never rendered as broken cells — a file being
                    // written, or an iCloud placeholder that has not come down.
                    Text("\(library.unreadable) file\(library.unreadable == 1 ? "" : "s") could not be read")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

/// One cell: a frame, a duration, and what the swing is about.
///
/// **The size is set before the image goes in, not by it.** A thumbnail is
/// whatever aspect the phone filmed at — 16:9 landscape, 9:16 portrait, sometimes
/// square — and a cell that takes its size from its content makes the grid jump
/// as each one loads.
struct SwingCell: View {
    let swing: Swing

    var body: some View {
        Color.black
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .overlay {
                if let path = swing.thumbnailPath, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    if let duration = swing.duration {
                        Text(Swing.durationText(duration)).monospacedDigit()
                    }
                    Text(caption).lineLimit(2)
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(4)
            }
            .contentShape(Rectangle())
    }

    private var caption: String {
        let text = swing.meta.context.caption
        return text.isEmpty ? swing.name : text
    }
}

/// The chips: what the list is filtered to, and how to widen it.
struct SwingFilterBar: View {
    @ObservedObject var library: SwingLibrary
    let catalog: SwingCatalog
    @State private var searching = false

    var body: some View {
        VStack(spacing: 6) {
            if searching {
                TextField("Search", text: $library.filter.text)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        searching.toggle()
                        if !searching { library.filter.text = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)

                    if let courseID = library.filter.courseID {
                        chip(courseName(courseID)) {
                            library.filter.courseID = nil
                            library.filter.hole = nil
                        }
                    }
                    if let hole = library.filter.hole {
                        chip("Hole \(holeLabel(hole))") { library.filter.hole = nil }
                    }
                    if let playerID = library.filter.playerID {
                        chip(catalog.player(id: playerID)?.name ?? "Player") {
                            library.filter.playerID = nil
                        }
                    }
                    ForEach(library.filter.tags, id: \.self) { tag in
                        chip(tag) { library.filter.tags.removeAll { $0 == tag } }
                    }
                    ForEach(Array(library.filter.sourceIDs), id: \.self) { id in
                        chip(library.source(id: id)?.name ?? "Folder") {
                            library.filter.sourceIDs.remove(id)
                        }
                    }

                    Menu {
                        ForEach(library.sources) { source in
                            Button(source.name) { library.filter.sourceIDs = [source.id] }
                        }
                        if !library.knownTags.isEmpty {
                            Divider()
                            ForEach(library.knownTags, id: \.self) { tag in
                                Button(tag) {
                                    if !library.filter.tags.contains(tag) { library.filter.tags.append(tag) }
                                }
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease")
                    }
                    .buttonStyle(.bordered)

                    if !library.filter.isEmpty {
                        Button("All swings") { library.filter = .none }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func chip(_ text: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 3) {
                Text(text)
                Image(systemName: "xmark")
            }
            .font(.footnote)
        }
        .buttonStyle(.borderedProminent)
    }

    private func courseName(_ id: String) -> String {
        catalog.course(id: id)?.name
            ?? library.swings.first { $0.meta.context.courseID == id }?.meta.context.courseName
            ?? "Course"
    }

    private func holeLabel(_ index: Int) -> String {
        catalog.course(id: library.filter.courseID)?.holes.first { $0.index == index }?.label
            ?? String(index)
    }
}

extension SwingFilter {
    /// What a capture started from this list should be tagged with. **The filter
    /// is the context**: a list filtered to Corica hole 7 is what somebody
    /// standing on Corica hole 7 opened.
    var captureContext: SwingContext {
        SwingContext(courseID: courseID, hole: hole, playerID: playerID, roundID: roundID)
    }
}
#endif
