#if canImport(MapKit) && canImport(SwiftUI)
import SwiftUI
import MapKit
import GolfCourse

/// Place a hole's tee and green centre by hand, on aerial imagery.
///
/// This is how a card-only course — par, handicap and yardage imported from a
/// scorecard, no coordinates — becomes a course the hole view can draw. About
/// forty taps for an eighteen, minutes rather than a round.
///
/// > **Licensing, and it is a real constraint.** CLAUDE.md's rule was *"never
/// > trace a course from Google or Apple imagery"*, because both agreements
/// > forbid using their data to build a competing mapping service. That rule was
/// > **deliberately narrowed by the user on 2026-08-26**: hand-placing a few dozen
/// > points for a personal course file is judged not to be that. The consequence
/// > stands and is enforced here — anything placed this way is marked
/// > `Course.Source.traced`, and **a traced file cannot be published or shipped as
/// > data**. Files derived from a recorded track or a walked survey are unaffected.
/// > Do not merge the two into one distributable file.
///
/// The card is not just cargo: with a tee placed and the card saying 383 m, a
/// green dropped 340 m away is visibly wrong *before* anyone walks onto the tee.
/// That check is on screen the whole time.
@available(iOS 17, macOS 14, *)
public struct CourseEditorView: View {

    /// What the next tap places.
    enum Target: Hashable {
        case green
        case tee(String)

        var label: String {
            switch self {
            case .green: return "GREEN"
            case .tee(let n): return n.uppercased()
            }
        }
    }

    @State private var course: Course
    @State private var holeIndex = 0
    @State private var target: Target = .green
    @State private var camera: MapCameraPosition = .automatic
    @State private var hasAnchored = false
    @State private var newTeeName = ""
    @State private var addingTee = false
    /// Measured, not guessed. Apple's logo and Legal link are an attribution
    /// requirement, and the panel's height changes with the hole — a hardcoded
    /// inset covers them the moment the card-versus-ground row appears.
    @State private var panelHeight: CGFloat = 260
    /// The home-indicator inset. The panel is drawn *through* it, so the map's
    /// attribution has to clear the panel plus this, not the panel alone.
    @State private var bottomInset: CGFloat = 0

    /// The phone's current fix, when there is one. Standing on the green centre and
    /// tapping "use my position" is the one placement that needs no imagery at all —
    /// and it is the only one whose provenance is unambiguously ours.
    public var here: Coordinate?
    public var onSave: (Course) -> Void

    private let style = HoleStyle()
    /// The same unit the hole view is showing. Yards by default — the editor was the
    /// last place still printing raw metres, which made a card check read in a unit
    /// the golfer had not chosen.
    @AppStorage("marker.distanceUnit") private var unitRaw: String = DistanceUnit.assumedWhenUnstated.rawValue
    private var display: DistanceDisplay {
        DistanceDisplay(unit: DistanceUnit(rawValue: unitRaw) ?? .yards)
    }

    public init(course: Course, here: Coordinate? = nil,
                startAt holeRef: String? = nil,
                onSave: @escaping (Course) -> Void) {
        _course = State(initialValue: course)
        self.here = here
        self.onSave = onSave
        let idx = holeRef.flatMap { r in course.holes.firstIndex { $0.id == r || $0.ref == r } } ?? 0
        _holeIndex = State(initialValue: idx)
    }

    private var hole: Hole? {
        course.holes.indices.contains(holeIndex) ? course.holes[holeIndex] : nil
    }

    public var body: some View {
        Group {
            if let hole {
                editor(hole)
            } else {
                ContentUnavailableView("This course has no holes",
                                       systemImage: "list.number",
                                       description: Text("Import a scorecard first."))
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private func editor(_ hole: Hole) -> some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    if let c = hole.green.center {
                        Annotation("green", coordinate: c.clLocation) {
                            marker(system: "flag.fill", color: style.flag,
                                   active: target == .green)
                        }
                        .annotationTitles(.hidden)
                    }
                    ForEach(hole.tees) { t in
                        if let at = t.at {
                            Annotation(t.name, coordinate: at.clLocation) {
                                marker(system: "square.fill", color: style.ink,
                                       active: target == .tee(t.name))
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if let g = hole.geometry() {
                        MapPolyline(coordinates: [g.teeAt.clLocation, g.greenCenter.clLocation])
                            .stroke(style.ink.opacity(0.8),
                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    if let here {
                        Annotation("you", coordinate: here.clLocation) {
                            Circle().fill(.blue)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.imagery(elevation: .flat))
                .mapControlVisibility(.hidden)
                .safeAreaPadding(.bottom, panelHeight + bottomInset)
                .onTapGesture { screen in
                    guard let cl = proxy.convert(screen, from: .local) else { return }
                    place(Coordinate(lat: cl.latitude, lon: cl.longitude))
                }
            }
            .ignoresSafeArea()

            panel(hole)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { bottomInset = geo.safeAreaInsets.bottom }
                .onChange(of: geo.safeAreaInsets.bottom) { bottomInset = $1 }
        })
        .background(style.roughDeep)
        .preferredColorScheme(.dark)
        .onAppear { anchor(hole) }
        .onChange(of: holeIndex) { anchor(course.holes[holeIndex]) }
    }

    private func marker(system: String, color: Color, active: Bool) -> some View {
        Image(systemName: system)
            .font(.system(size: active ? 17 : 13, weight: .bold))
            .foregroundStyle(color)
            .padding(active ? 5 : 0)
            .background(active ? Circle().fill(.white.opacity(0.25)) : nil)
            .shadow(radius: 2)
    }

    // MARK: - Placing

    /// - Parameter source: `.traced` for a tap on imagery, `.survey` for the GPS
    ///   button. The distinction is load-bearing, not bookkeeping: a traced hole
    ///   cannot be published (see the type doc), and a course mapped entirely by
    ///   walking it must not inherit that restriction from the editor it was
    ///   entered in.
    private func place(_ c: Coordinate, as source: Course.Source = .traced) {
        guard var h = hole else { return }
        switch target {
        case .green:
            h.green.center = c
        case .tee(let name):
            if let i = h.tees.firstIndex(where: { $0.name == name }) {
                h.tees[i].at = c
            } else {
                h.tees.append(TeeBox(name: name, at: c))
            }
        }
        // Provenance is recorded per hole, whatever the file says. This is the
        // record that decides whether the file can ever be published.
        h.source = source
        h.confidence = min(h.confidence ?? 0.85, source == .survey ? 0.85 : 0.6)
        course.holes[holeIndex] = h
        // The file's marking only ever gets more restrictive: one traced hole taints
        // the file, and a later surveyed hole does not untaint it.
        if course.source == .card || source == .traced { course.source = source }
        advanceTarget(h)
    }

    /// After a green, offer the first unplaced tee; after the last tee, stop. Keeps
    /// eighteen holes to a rhythm of taps rather than a tap and two menu visits.
    private func advanceTarget(_ h: Hole) {
        if case .green = target {
            if let next = h.tees.first(where: { $0.at == nil }) ?? h.tees.first {
                target = .tee(next.name)
            }
        } else if h.green.center == nil {
            target = .green
        }
    }

    private func clear() {
        guard var h = hole else { return }
        switch target {
        case .green: h.green.center = nil
        case .tee(let name):
            if let i = h.tees.firstIndex(where: { $0.name == name }) { h.tees[i].at = nil }
        }
        course.holes[holeIndex] = h
    }

    // MARK: - Where to point the camera

    /// A card-only hole has no coordinates at all, so the first frame has to come
    /// from somewhere else: the phone's fix, then any hole already placed, then the
    /// rest of the course. Without this the editor opens on the Atlantic.
    private func anchor(_ hole: Hole) {
        let span: Double
        let centre: Coordinate

        if let g = hole.geometry() {
            centre = Coordinate(lat: (g.teeAt.lat + g.greenCenter.lat) / 2,
                                lon: (g.teeAt.lon + g.greenCenter.lon) / 2)
            span = max(300, g.measuredLength * 2.2)
        } else if let one = hole.green.center ?? hole.tees.compactMap(\.at).first {
            centre = one; span = 600
        } else if let near = nearestPlaced(to: holeIndex) {
            centre = near; span = 900
        } else if let here {
            centre = here; span = 700
        } else {
            return   // nothing to anchor on; leave the camera where the user put it
        }
        camera = .camera(MapCamera(centerCoordinate: centre.clLocation,
                                   distance: span / 0.42,   // span ≈ 0.42 × distance
                                   heading: 0, pitch: 0))
        hasAnchored = true
    }

    /// Walk outwards from the current hole. Holes next to each other on a card are
    /// next to each other on the ground, so the nearest placed hole is the best
    /// guess available for one that has never been placed.
    private func nearestPlaced(to index: Int) -> Coordinate? {
        for delta in 1..<max(2, course.holes.count) {
            for i in [index - delta, index + delta] where course.holes.indices.contains(i) {
                if let c = course.holes[i].green.center ?? course.holes[i].tees.compactMap(\.at).first {
                    return c
                }
            }
        }
        return nil
    }

    // MARK: - Panel

    @ViewBuilder
    private func panel(_ hole: Hole) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(hole.nine.map { "\($0) " } ?? "")\(hole.ref)번 · PAR \(hole.par)")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(course.holes.filter(\.hasGeometry).count)/\(course.holes.count) mapped")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(style.ink.opacity(0.7))
            }

            check(hole)

            HStack(spacing: 8) {
                targetChip(.green, placed: hole.green.center != nil)
                ForEach(hole.tees) { t in
                    targetChip(.tee(t.name), placed: t.at != nil)
                }
                Button { addingTee = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text("Tap the map to place the \(target.label.lowercased())")
                .font(.system(size: 11))
                .foregroundStyle(style.ink.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let here {
                    action("location.fill", "Standing here") { place(here, as: .survey) }
                }
                action("arrow.uturn.backward", "Clear") { clear() }
                action("checkmark", "Save") { onSave(course) }
            }

            HStack(spacing: 10) {
                step("chevron.left", enabled: holeIndex > 0) { holeIndex -= 1 }
                Text(course.name)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(style.ink.opacity(0.7))
                step("chevron.right", enabled: holeIndex < course.holes.count - 1) { holeIndex += 1 }
            }
        }
        .foregroundStyle(style.ink)
        .padding(14)
        // The panel's ground has to reach the bottom of the screen, or imagery
        // shows through under the hole stepper and the panel reads as unfinished.
        .background(Color.black.opacity(0.78).ignoresSafeArea(edges: .bottom))
        .background(GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { panelHeight = $0 }
        .alert("Tee name", isPresented: $addingTee) {
            TextField("Blue", text: $newTeeName)
            Button("Add") {
                let n = newTeeName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                var h = hole
                guard h.tee(named: n) == nil else { return }
                h.tees.append(TeeBox(name: n))
                course.holes[holeIndex] = h
                target = .tee(n)
                newTeeName = ""
            }
            Button("Cancel", role: .cancel) { newTeeName = "" }
        } message: {
            Text("A tee the card does not list — a members' tee, or one you play from.")
        }
    }

    /// Card versus ground. The cheapest correctness check the editor has, and the
    /// only one that catches a point dropped on the neighbouring hole — which looks
    /// entirely reasonable on imagery.
    @ViewBuilder
    private func check(_ hole: Hole) -> some View {
        if let g = hole.geometry(), let gap = g.lengthDisagreement {
            let bad = gap > 25
            HStack(spacing: 6) {
                Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text("card \(display.text(g.tee.distance)) · measured "
                     + "\(display.text(g.measuredLength)) · off by \(display.number(gap))")
                    .font(.system(size: 11, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(bad ? Color.orange : Color.green)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background((bad ? Color.orange : Color.green).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 8))
        } else if let g = hole.geometry() {
            Text("measured \(display.text(g.measuredLength)) — no card number to check it against")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let card = hole.cardLength() {
            Text("card says \(display.text(card)) · place a tee and a green")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func targetChip(_ t: Target, placed: Bool) -> some View {
        Button { target = t } label: {
            HStack(spacing: 4) {
                if placed { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(t.label).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(target == t ? style.flag : .white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(target == t ? .white : style.ink.opacity(placed ? 1 : 0.55))
        }
        .buttonStyle(.plain)
    }

    private func action(_ symbol: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(style.ink)
        }
        .buttonStyle(.plain)
    }

    private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 46, height: 40)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(style.ink.opacity(enabled ? 1 : 0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Reports the control panel's measured height so the map can keep Apple's
/// attribution above it.
@available(iOS 17, macOS 14, *)
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 260
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
