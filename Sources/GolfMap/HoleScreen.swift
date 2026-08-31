#if canImport(MapKit) && canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import GolfSessionFormat
import GolfCourse

/// Which layer the hole is drawn on. Vector is the default everywhere.
public enum HoleLayer: String, CaseIterable, Identifiable, Sendable {
    case vector, satellite
    public var id: String { rawValue }
    public var label: String { self == .vector ? "Vector" : "Satellite" }
    public var symbol: String { self == .vector ? "scribble" : "globe.americas.fill" }
}

/// The hole view: one hole, either layer, with the numbers a golfer acts on.
///
/// At parity with the converged design the whole category uses — front/centre/back
/// always visible, one number big, hole and tee switchable — because fifteen years
/// of iteration already optimised this screen. What is *not* parity: the layer
/// switch, MARK, and a second target (research-course-display.md §9.3 — no app in
/// the matrix chains two).
///
/// **Numbers live at the top; controls live at the bottom.** §5 of that research
/// puts the one-handed reachable band in the bottom third, and numbers are read
/// rather than touched, so they belong out of the thumb's way and the controls
/// belong in it.
@available(iOS 17, macOS 14, *)
public struct HoleScreen<Bar: View>: View {
    public let course: Course
    public var tracks: [PlayerTrack] = []
    /// The phone's fix. Simulation replaces it locally without touching this.
    public var player: Coordinate?
    /// The fix's horizontal accuracy in metres, drawn as the ring around the
    /// position marker on both layers *(user, 2026-08-30)*. **Not passed on while
    /// simulating**: a hand-placed point has no accuracy and a ring around it would
    /// claim a measurement nobody took.
    public var accuracy: Double?
    public var onMark: (() -> Void)?
    /// Opens the geometry editor for the hole on screen. Nil hides the item.
    public var onEditHole: ((String) -> Void)?
    /// How hard the phone is working for a position, shown so "location is on" and
    /// "location is usable" stop being the same claim. Nil hides the chip.
    /// Recorded entries to draw on the hole, when the marker toggle is on. X7.
    public var markers: [HoleMarker] = []
    /// Today's flag per hole, keyed by **1-based playing index** — the same number
    /// `Event.hole` and `LogEntry.hole` store, and the same one a scorecard column
    /// means. Not `Hole.ref`, which is not a key: a Korean 27 has three holes
    /// called "3".
    ///
    /// It comes from the round's events rather than the course file, because a pin
    /// is cut fresh every morning — see `Event.Kind.pin`.
    public var pins: [Int: Coordinate] = [:]
    /// Report a dragged flag: playing index, and where it now is.
    public var onMovePin: ((Int, Coordinate) -> Void)?
    /// File a shot for this player, numbered, where the golfer is now — the legend's
    /// number is the button. Nil hides the number entirely, which is what the render
    /// harness and every test get.
    public var onAddShot: ((String, Int) -> Void)?
    /// This player has holed out on the hole on screen, or has reopened it —
    /// strokes, or **nil to clear the score** *(user, 2026-08-29: "swiping shot #
    /// to right closes it, i.e. hole out, no more shot creation on the hole")*.
    ///
    /// The app writes a journal `setScore`; this view stores nothing, and reads the
    /// answer back through `PlayerTrack.score`. Nil clears, which `JournalReplay`
    /// already does for `strokes == nil` — reopening needs no new act.
    public var onHoleOut: ((String, Int?) -> Void)?
    /// A marker was dragged and the move confirmed. The app writes the superseding
    /// row; this view never touches storage.
    public var onMarkerMoved: ((String, Coordinate) -> Void)?
    /// A marker was tapped — X13. The app opens its dialog; this view knows nothing
    /// about what a log is or how one is edited.
    public var onMarkerTapped: ((String) -> Void)?
    /// Which hole is on screen — `Hole.ref` and the **1-based playing index**, the
    /// two forms the rest of the app needs.
    ///
    /// *(X14, user 2026-08-28: "marker's hole — it should be the current hole".)*
    /// The hole is this view's `@State`: it is changed by the arrows and by the
    /// course view, and nothing outside could previously tell which one was showing.
    /// Fired on appear as well as on change, so a caller is never left guessing
    /// before the first switch.
    public var onHoleChanged: ((String, Int) -> Void)?

    /// Where one recorded log was said. Marks it and pans there on appear.
    ///
    /// **Never fed to the framing fit** — see `VectorHoleView.extraPoints`. A log
    /// with a poor fix, or one made off this hole entirely, would otherwise shrink
    /// the hole to a dot to keep a point in another county on screen.
    public var focus: Coordinate?

    /// The app's own controls, drawn under the hole's own.
    ///
    /// **A slot rather than the buttons themselves, because this view is in
    /// `GolfMap` and they are not.** Marker, Round and Location all need
    /// `RoundViewModel`, `LiveTranscript` and `LogStore`, which live in the app
    /// target — a package that draws a hole must not import the capture stack, the
    /// same rule that keeps `GolfReconstruction` off WhisperKit. `HoleScreen`
    /// already takes `focus`, `targets` and `simulating` from outside for the same
    /// reason; this is that shape, one step further.
    ///
    /// It is laid out **above** the map's attribution reserve, never over it —
    /// `barHeight` is what tells the satellite layer how far to push Apple's logo
    /// and Legal link, and those are not optional even in private use.
    /// The **simulated** position, or nil when nothing is being simulated.
    ///
    /// **X3** *(user, 2026-08-28: "when simulated position is on, use the location
    /// for marker")*. Simulation lives in this view's `@State`, so without this the
    /// app has no way to know a log should be written at the dragged point rather
    /// than wherever the phone actually is — which on a desk is another county.
    ///
    /// It reports *only* the simulated point, not the real one: the caller already
    /// has the phone's fix, and a single channel carrying both would leave it unable
    /// to tell a measurement from a placement.
    public var onPosition: ((Coordinate?) -> Void)?

    @ViewBuilder public var bottomBar: () -> Bar

    /// What the bar occupies, so the satellite layer can clear it. Measured by the
    /// bar itself, because a constant here goes stale the first time the bar
    /// changes and the failure is a covered attribution link, which is a licence
    /// problem rather than a visual one.
    @State private var barHeight: CGFloat = 0
    /// What the bottom HUD — the legend, and the move confirmation when it is up —
    /// occupies, for the same reason as `barHeight` and with the same failure.
    ///
    /// **Found by screenshot, 2026-08-28**: Apple's "Map" and "Legal" links sit at
    /// the bottom left of the satellite layer, exactly where the legend is drawn,
    /// and `bottomReserve` only pushed them clear of the *bar*. It was a covered
    /// link while the legend was a read-only strip; X17 made every row a **button**,
    /// so it also began swallowing taps meant for the link. Attribution is not
    /// optional, private use included.
    ///
    /// Measured as one block rather than per view: the confirmation appears and
    /// disappears, and two separate measurements would need two rules about which
    /// of them is stale.
    @State private var hudHeight: CGFloat = 0

    @State private var holeIndex: Int
    @State private var teeName: String?
    @State private var targets: [Coordinate] = []
    @State private var viewport = HolePlane.View.fitted
    @State private var simulated: Coordinate?
    @State private var simulating = false
    @State private var centerOn: Coordinate?

    /// The legend cell that has just had its score nudged, and which way.
    ///
    /// *(User, 2026-08-30: "up swipe increase score, down swipe decrease. Shows
    /// bounce or enlarging / shrink indicator, so that inadvertent change can be
    /// detected.")* The cell prints a **score to par**, so a stray nudge turns `+1`
    /// into `+2` and nothing else on the screen changes — the number is the only
    /// evidence, and a number that quietly becomes a different number is exactly
    /// what the user asked to be able to catch. So the change is *animated in the
    /// direction it went*: the cell jumps large on the way up and small on the way
    /// down, and springs back. Set without animation and cleared with one, so the
    /// spring runs from the bumped size back to rest.
    @State private var scoreBump: ScoreBump?

    public struct ScoreBump: Equatable, Sendable {
        public var id: String
        public var up: Bool
        public init(id: String, up: Bool) { self.id = id; self.up = up }
    }

    /// Renders one legend cell in its nudged state, so the indicator can be *seen*.
    ///
    /// Scripted swipes do not exist in this environment, so without this the one
    /// thing the user asked for by name — "so that inadvertent change can be
    /// detected" — would ship having been reasoned about and never looked at. Same
    /// argument as `targets` and `simulating` being init parameters.
    ///
    /// **An override, not a `@State` seed.** Seeding it in `init` does not work and
    /// looks as though it does: `init` runs once per view identity, on the first
    /// body evaluation, and everything a caller could key it on — the roster, the
    /// tracks, the current hole — is loaded afterwards, so the seed is always nil.
    /// Read through `shownBump` instead, which the real gesture still overrides.
    public var bump: ScoreBump?

    /// The course's stored terrain, when it has any — `CourseStore.loadElevation`.
    ///
    /// **Passed in rather than loaded here.** `GolfMap` draws a hole; reading a
    /// megabyte off disk on every body evaluation is the caller's job, and the
    /// caller already owns a `CourseStore`. Nil is the ordinary case: no course
    /// imported before 2026-08-30 has a DEM, and Korea has no source yet — the
    /// plays-like chip simply does not appear, which is the honest answer.
    public var terrain: Elevation?

    private var shownBump: ScoreBump? { scoreBump ?? bump }
    /// X4 — the whole-course sheet.
    @State private var showCourse = false
    /// X6 — the measuring segments. Each is two draggable ends and a label.
    @State private var measures: [MeasureSegment] = []
    /// X6 — a monotonic counter, so each new ruler takes the next colour of the
    /// set. **Not `measures.count`**: dismissing one would otherwise recolour every
    /// ruler after it.
    @State private var measureSeq = 0
    /// A marker the finger has moved, waiting to be confirmed.
    ///
    /// **Confirmed rather than applied** *(X7, user 2026-08-28)*. A log's coordinate
    /// is the evidence a proposal rests on, and the hole view is a screen full of
    /// things that *are* dragged — a marker nudged by accident while reaching for a
    /// target would silently move where a shot was said to have happened.
    @State private var pendingMove: MarkerMove?

    /// Remembered between rounds — a golfer who prefers the drawn hole, or yards,
    /// should not have to re-choose on the first tee every week.
    /// X7 — whether recorded log entries are drawn on the hole. **On by default**
    /// *(X9, user 2026-08-28)*: the entries are the round, and a layer that has to
    /// be switched on every time the screen opens is one nobody remembers exists.
    @AppStorage("marker.markerDisplay") private var markerDisplayRaw: String = MarkerDisplay.ghost.rawValue
    /// Three states, not two — see `MarkerDisplay`. **A new key**, because the old
    /// `marker.showMarkers` holds a `Bool` and reading it as a `String` would give
    /// every phone the default on first launch anyway; a fresh key says so instead
    /// of looking like a setting that silently reset.
    private var markerDisplay: MarkerDisplay {
        get { MarkerDisplay(rawValue: markerDisplayRaw) ?? .ghost }
        nonmutating set { markerDisplayRaw = newValue.rawValue }
    }
    /// What ground the renderer currently has on screen, reported back up. Only
    /// used to seed a simulated position; see `simulate(_:geo:)`.
    @State private var ground: GroundView?

    /// Players whose markers **and track** are hidden, by `PlayerTrack.id` *(X17,
    /// user 2026-08-28: "these buttons should be toggleable to show or hide all the
    /// markers of the player")*.
    ///
    /// **Keyed on the player's id, never on `colorIndex`.** The colour index is a
    /// roster *position*, and removing a player in `RosterEditor` slides everyone
    /// after them down a slot — so a set of indexes would go on hiding "slot 1" and
    /// silently start hiding a different person. Colours are resolved back through
    /// `tracks` at the moment of use, which is always current.
    ///
    /// **Not persisted.** Hiding somebody is something a golfer does to read one
    /// hole, not a preference — and a player still hidden next week looks exactly
    /// like markers that stopped being recorded.
    @State private var hiddenPlayers: Set<String> = []
    /// A third of the display *(user, 2026-08-28: "make the width 1/3 of the
    /// screen")*. Measured rather than assumed: the legend's names sit over rough
    /// that carries no numbers, and a fixed width would be a different fraction on
    /// every device.
    @State private var legendWidth: CGFloat = 130

    /// Assign a measured length **only when it really moved**.
    ///
    /// All three of these are measurements that feed back into the layout they were
    /// taken from — `hudHeight` and `barHeight` become the map's `bottomReserve`,
    /// `legendWidth` sizes a view inside the block `hudHeight` measures. A value that
    /// settles a hundredth of a point away from itself then oscillates, and SwiftUI
    /// reports that as `AttributeGraph: cycle detected`. Half a point is below
    /// anything anyone can see.
    private var measurementEpsilon: CGFloat { 0.5 }
    private func setHUD(_ h: CGFloat) {
        if abs(hudHeight - h) > measurementEpsilon { hudHeight = h }
    }
    private func setBar(_ h: CGFloat) {
        if abs(barHeight - h) > measurementEpsilon { barHeight = h }
    }
    private func setLegendWidth(_ w: CGFloat) {
        if abs(legendWidth - w) > measurementEpsilon { legendWidth = w }
    }

    @AppStorage("marker.holeLayer") private var layerRaw: String = HoleLayer.vector.rawValue
    @AppStorage("marker.distanceUnit") private var unitRaw: String = DistanceUnit.assumedWhenUnstated.rawValue

    private let style = HoleStyle()

    /// - Parameters:
    ///   - targets: the targets to start with. Normally empty — nothing is ever
    ///     auto-placed (research-course-display.md §9.4). It exists so the screen is
    ///     a pure function of its inputs and can be *rendered* in any state, which
    ///     is the only way to review a gesture-driven state without a device.
    ///   - simulating: likewise, so the simulated look can be reviewed off-device.
    ///   - showingCourse: opens the whole-course sheet on appear. Same reason: it
    ///     is reachable only through the pin menu, and a sheet only reachable
    ///     through a menu is a sheet nobody can review before it ships.
    public init(course: Course, holeRef: String? = nil,
                player: Coordinate? = nil, accuracy: Double? = nil,
                tracks: [PlayerTrack] = [],
                targets: [Coordinate] = [], simulating: Bool = false,
                showingCourse: Bool = false, bump: ScoreBump? = nil,
                focus: Coordinate? = nil, terrain: Elevation? = nil,
                onMark: (() -> Void)? = nil,
                onEditHole: ((String) -> Void)? = nil,
                onPosition: ((Coordinate?) -> Void)? = nil,
                markers: [HoleMarker] = [],
                pins: [Int: Coordinate] = [:],
                onMovePin: ((Int, Coordinate) -> Void)? = nil,
                onAddShot: ((String, Int) -> Void)? = nil,
                onHoleOut: ((String, Int?) -> Void)? = nil,
                onMarkerMoved: ((String, Coordinate) -> Void)? = nil,
                onMarkerTapped: ((String) -> Void)? = nil,
                onHoleChanged: ((String, Int) -> Void)? = nil,
                @ViewBuilder bottomBar: @escaping () -> Bar) {
        self.course = course
        self.bottomBar = bottomBar
        self.onPosition = onPosition
        self.markers = markers
        self.pins = pins
        self.onMovePin = onMovePin
        self.onAddShot = onAddShot
        self.onHoleOut = onHoleOut
        self.onMarkerMoved = onMarkerMoved
        self.onMarkerTapped = onMarkerTapped
        self.onHoleChanged = onHoleChanged
        self.player = player
        self.accuracy = accuracy
        self.tracks = tracks
        self.onMark = onMark
        self.onEditHole = onEditHole
        self.bump = bump
        self.focus = focus
        self.terrain = terrain
        let idx = holeRef.flatMap { ref in course.holes.firstIndex { $0.ref == ref } } ?? 0
        _holeIndex = State(initialValue: idx)
        _teeName = State(initialValue: Self.rememberedTee(course))
        _targets = State(initialValue: Array(targets.prefix(2)))
        _simulating = State(initialValue: simulating)
        _simulated = State(initialValue: simulating ? player : nil)
        _showCourse = State(initialValue: showingCourse)
    }

}

@available(iOS 17, macOS 14, *)
public extension HoleScreen where Bar == EmptyView {
    /// The hole view with no app controls under it — `golfctl`, the render harness,
    /// and every test.
    ///
    /// **A separate initialiser rather than a default argument**, because a default
    /// value does not take part in generic inference: `Bar` would be unresolvable at
    /// every call site that omits the bar, which is most of them.
    init(course: Course, holeRef: String? = nil,
         player: Coordinate? = nil, accuracy: Double? = nil,
         tracks: [PlayerTrack] = [],
         targets: [Coordinate] = [], simulating: Bool = false,
         showingCourse: Bool = false, bump: ScoreBump? = nil,
         focus: Coordinate? = nil, terrain: Elevation? = nil,
         onMark: (() -> Void)? = nil,
         onEditHole: ((String) -> Void)? = nil,
         onPosition: ((Coordinate?) -> Void)? = nil,
         markers: [HoleMarker] = [],
         pins: [Int: Coordinate] = [:],
         onMovePin: ((Int, Coordinate) -> Void)? = nil,
         onAddShot: ((String, Int) -> Void)? = nil,
         onHoleOut: ((String, Int?) -> Void)? = nil,
         onMarkerMoved: ((String, Coordinate) -> Void)? = nil,
         onMarkerTapped: ((String) -> Void)? = nil,
         onHoleChanged: ((String, Int) -> Void)? = nil) {
        self.init(course: course, holeRef: holeRef, player: player,
                  accuracy: accuracy, tracks: tracks,
                  targets: targets, simulating: simulating,
                  showingCourse: showingCourse, bump: bump,
                  focus: focus, terrain: terrain, onMark: onMark, onEditHole: onEditHole,
                  onPosition: onPosition, markers: markers,
                  pins: pins, onMovePin: onMovePin, onAddShot: onAddShot,
                  onHoleOut: onHoleOut,
                  onMarkerMoved: onMarkerMoved, onMarkerTapped: onMarkerTapped,
                  onHoleChanged: onHoleChanged, bottomBar: { EmptyView() })
    }
}

@available(iOS 17, macOS 14, *)
extension HoleScreen {
    private var layer: HoleLayer {
        get { HoleLayer(rawValue: layerRaw) ?? .vector }
        nonmutating set { layerRaw = newValue.rawValue }
    }
    private var display: DistanceDisplay {
        get { DistanceDisplay(unit: DistanceUnit(rawValue: unitRaw) ?? .yards) }
        nonmutating set { unitRaw = newValue.unit.rawValue }
    }

    private var hole: Hole? {
        course.holes.indices.contains(holeIndex) ? course.holes[holeIndex] : nil
    }
    private func tee(_ hole: Hole) -> TeeBox {
        teeName.flatMap { hole.tee(named: $0) } ?? hole.defaultTee
    }

    /// Which tee this golfer plays **at this course**.
    ///
    /// **Keyed per course and validated against the file, both of which matter.**
    /// A single global tee name applies "Black" to a course that has no black tee;
    /// `cardLength(from:)` and `geometry(tee:)` then correctly return nil rather
    /// than falling back to another tee's numbers, so the screen loses its
    /// yardages and nothing says why. A name that no longer matches is dropped
    /// here instead, which puts the hole back on `Hole.defaultTee`.
    /// A marker drag waiting on the user's word.
    struct MarkerMove: Identifiable {
        let id: String
        let to: Coordinate
    }

    private static func teeKey(_ course: Course) -> String { "marker.tee.\(course.id)" }

    private static func rememberedTee(_ course: Course) -> String? {
        guard let saved = UserDefaults.standard.string(forKey: teeKey(course)) else { return nil }
        return course.teeNames.contains(where: { $0.caseInsensitiveCompare(saved) == .orderedSame })
            ? saved : nil
    }

    private func rememberTee(_ name: String?) {
        let key = Self.teeKey(course)
        if let name { UserDefaults.standard.set(name, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    /// The position the numbers are measured from. In simulation this is the
    /// dragged point; otherwise it is the phone's own fix.
    private var effectivePlayer: Coordinate? { simulating ? simulated : player }

    public var body: some View {
        Group {
            if let hole {
                content(hole)
                    // Panned rather than fitted, and on appear rather than in the
                    // initialiser: `centerOn` is a one-shot command the layer
                    // clears once applied, so it has to *change* to fire.
                    .onAppear {
                        if centerOn == nil { centerOn = focus }
                        onPosition?(simulating ? simulated : nil)
                        announceHole()
                    }
                    .onChange(of: holeIndex) { announceHole() }
                    .onChange(of: simulated) { _, c in onPosition?(simulating ? c : nil) }
                    .onChange(of: simulating) { _, on in onPosition?(on ? simulated : nil) }
                    .onDisappear { onPosition?(nil) }
                    .onChange(of: teeName) { _, name in rememberTee(name) }
                    // X4 — every hole at once.
                    .sheet(isPresented: $showCourse) {
                        CourseOverview(course: course, display: display, style: style) { ref in
                            if let i = course.holes.firstIndex(where: { $0.ref == ref }) {
                                holeIndex = i
                            }
                            showCourse = false
                        }
                    }
            } else {
                ContentUnavailableView("No holes in this course",
                                       systemImage: "map",
                                       description: Text("The course file has no hole geometry yet."))
            }
        }
    }

    @ViewBuilder
    private func content(_ hole: Hole) -> some View {
        let t = tee(hole)
        // A card-only hole — par and yardage imported from a scorecard, no
        // coordinates yet — has nothing to draw. Show what it does have rather than
        // a map of the equator. See docs/research-scorecard-import.md §5.
        if let geo = hole.geometry(tee: t) {
            mapContent(hole, geo: geo)
        } else {
            cardOnlyContent(hole, tee: t)
        }
    }

    /// What the renderers are given: everything except the players switched off in
    /// the legend. **The legend itself still reads `tracks`**, or hiding somebody
    /// would take away the button that brings them back.
    private var visibleTracks: [PlayerTrack] {
        // **The markers switch takes the lines with it** *(user, 2026-08-28: "when
        // global marker display button is off, not just markers, but lines between
        // markers should be hidden as well")*. A line joining pills that are not
        // drawn is a line between nothing and nothing.
        guard markerDisplay.isVisible else { return [] }
        return hiddenPlayers.isEmpty ? tracks : tracks.filter { !hiddenPlayers.contains($0.id) }
    }
    /// The hidden players' colours, resolved **now** rather than stored — see
    /// `hiddenPlayers`. A player who has no shots on this hole contributes nothing,
    /// which is right: they have no markers here either.
    private var hiddenColors: Set<Int> {
        Set(tracks.filter { hiddenPlayers.contains($0.id) }.map(\.colorIndex))
    }
    private var visibleMarkers: [HoleMarker] {
        guard markerDisplay.isVisible else { return [] }
        let hidden = hiddenColors
        guard !hidden.isEmpty else { return markers }
        // An entry belonging to nobody in particular — most of them — has no colour
        // and is never hidden by a player's button.
        return markers.filter { m in m.colorIndex.map { !hidden.contains($0) } ?? true }
    }

    @ViewBuilder
    private func mapContent(_ hole: Hole, geo: HoleGeometry) -> some View {
        let readout = HoleReadout(geometry: geo, player: effectivePlayer,
                                  targets: targets, pin: pins[holeIndex + 1],
                                  terrain: terrain)

        ZStack {
            switch layer {
            case .vector:
                VectorHoleView(geometry: geo, style: style, readout: readout,
                               terrain: terrain,
                               tracks: visibleTracks, simulating: simulating,
                               accuracy: simulating ? nil : accuracy, display: display,
                               focus: focus,
                               viewport: $viewport, centerOn: $centerOn,
                               markerDisplay: markerDisplay, ground: $ground,
                               measures: measures,
                               onMoveMeasure: { i, e, c in
                                   guard measures.indices.contains(i) else { return }
                                   measures[i].move(end: e, to: c)
                               },
                               onCenterMeasure: { i, c in
                                   guard measures.indices.contains(i) else { return }
                                   measures[i].center(on: c)
                               },
                               onTapMeasure: { i in
                                   guard measures.indices.contains(i) else { return }
                                   measures.remove(at: i)
                               },
                               markers: visibleMarkers,
                               pendingMarker: pendingMove.map { ($0.id, $0.to) },
                               pin: pins[holeIndex + 1],
                               onMovePin: { onMovePin?(holeIndex + 1, $0) },
                               onMoveMarker: { id, c in pendingMove = MarkerMove(id: id, to: c) },
                               onTapMarker: { onMarkerTapped?($0) },
                               onTapGround: { setTarget(0, $0) },
                               onTapTarget: remove,
                               onMoveTarget: { targets[$0] = $1 },
                               onMovePlayer: simulating ? { simulated = $0 } : nil)
            case .satellite:
                SatelliteHoleView(geometry: geo, style: style, readout: readout,
                                  terrain: terrain,
                                  tracks: visibleTracks, simulating: simulating,
                                  accuracy: simulating ? nil : accuracy, display: display,
                                  centerOn: $centerOn,
                                  bottomReserve: 110 + barHeight + hudHeight,
                                  measures: measures,
                                  onMoveMeasure: { i, e, c in
                                      guard measures.indices.contains(i) else { return }
                                      measures[i].move(end: e, to: c)
                                  },
                                  onCenterMeasure: { i, c in
                                      guard measures.indices.contains(i) else { return }
                                      measures[i].center(on: c)
                                  },
                                  onTapMeasure: { i in
                                      guard measures.indices.contains(i) else { return }
                                      measures.remove(at: i)
                                  },
                                  markers: visibleMarkers,
                                  markerDisplay: markerDisplay,
                                  ground: $ground,
                                  pendingMarker: pendingMove.map { ($0.id, $0.to) },
                                  pin: pins[holeIndex + 1],
                                  onMovePin: { onMovePin?(holeIndex + 1, $0) },
                                  onMoveMarker: { id, c in
                                      pendingMove = MarkerMove(id: id, to: c)
                                  },
                                  onTapMarker: { onMarkerTapped?($0) },
                                  onTapGround: { setTarget(0, $0) },
                                  onTapTarget: remove,
                                  onMoveTarget: { targets[$0] = $1 },
                                  onMovePlayer: simulating ? { simulated = $0 } : nil)
            }

            // Aerial imagery is bright and busy, and white numbers over a photograph
            // is the exact case that washes out in afternoon sun. The vector layer
            // needs no scrim; this one does.
            if layer == .satellite {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 360)
                    Spacer()
                }
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            // Distance to the pin sits above everything, centred. The hole box is
            // pinned top-left beside it: the two never collide because one is
            // centred and narrow and the other is left-aligned and narrower still.
            // The distance runs to the very top of the display, through the
            // navigation bar's band — `CourseView` makes that bar transparent rather
            // than hiding it, so the back button survives. Only the status bar is
            // kept clear, and the back button sits to the left of a centred number.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    distanceBlock(readout)
                        .padding(.top, Self.statusBarInset)
                    HStack(alignment: .top) {
                        holeBox(hole, tee: geo.tee)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            settingsMenu(hole)
                            toolColumn(geo)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                    // **Measured as one block, because it is one block of HUD
                    // sitting where Apple's attribution goes.** See `hudHeight`.
                    // **The legend is back at the bottom left** *(user,
                    // 2026-08-28: "move them to the bottom left")* — under the hole
                    // box was the previous instruction and this replaces it. It is
                    // measured with the confirmation as one block, because Apple's
                    // attribution sits underneath both; see `hudHeight`.
                    VStack(alignment: .leading, spacing: 0) {
                        if pendingMove != nil { moveConfirm }
                        legend(par: hole.par)
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear
                                // **Assigned only when it actually changed.** This
                                // height feeds `bottomReserve`, which changes the
                                // map's safe area, which is a layout the measured
                                // block sits inside — a measurement that feeds back
                                // into its own layout is the classic
                                // `AttributeGraph: cycle detected` shape, and two
                                // values a fraction of a point apart will oscillate
                                // forever. Half a point is below anything visible.
                                .onAppear { setHUD(g.size.height) }
                                .onChange(of: g.size.height) { _, h in setHUD(h) }
                        })
                    controls(hole)
                    barSlot
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { setLegendWidth(proxy.size.width / 3) }
                .onChange(of: proxy.size.width) { _, w in setLegendWidth(w / 3) }
            }
        }
        .background(style.roughDeep)
        .preferredColorScheme(.dark)
        // A new hole is a new framing; carrying a zoom across would drop the golfer
        // into the middle of a hole they have not seen yet.
        .onChange(of: holeIndex) {
            viewport = .fitted
            targets = []
            snapSimulationToHole(geo)
        }
        .onChange(of: teeName) { viewport = .fitted }
        .onAppear { snapSimulationToHole(geo) }
    }

    /// A simulated position left behind on hole 3 is not a position on hole 11; it
    /// is a number measured from somewhere the golfer is not, and `HoleReadout`
    /// would quietly fall back to the tee and stop saying "simulated" was doing
    /// anything. Snapping puts it somewhere meaningful on arrival instead.
    private func announceHole() {
        guard course.holes.indices.contains(holeIndex) else { return }
        onHoleChanged?(course.holes[holeIndex].ref, holeIndex + 1)
    }

    private func snapSimulationToHole(_ geo: HoleGeometry) {
        guard simulating else { return }
        if case .player = HoleReadout.origin(geometry: geo, player: simulated) { return }
        simulated = geo.teeAt
    }

    // MARK: - Targets

    /// **Tap owns target 1, press-and-hold owns target 2.** Which slot a gesture
    /// addresses is fixed rather than "next free", so tapping never surprises anyone
    /// with a second target and the first is always adjustable with the cheapest
    /// gesture. A hold with nothing placed fills slot 1 rather than being a dead
    /// gesture.
    ///
    /// Nothing is ever auto-placed — research-course-display.md §9.4. GolfLink
    /// auto-placed its crosshair into a grove of trees, which is the argument
    /// against starting with one.
    private func setTarget(_ slot: Int, _ c: Coordinate) {
        if targets.indices.contains(slot) {
            targets[slot] = c
        } else if slot <= targets.count {
            targets.append(c)
        } else {
            targets.append(c)     // hold with nothing placed — fills slot 1
        }
    }
    // MARK: - X6 / X7 — the tool column

    /// Target 1, target 2, measure, markers — under the pin menu, in that order.
    ///
    /// **Buttons for what used to be gestures** *(X6, user 2026-08-28)*. Tap still
    /// places target 1 on the ground, but press-and-hold for target 2 is gone: a
    /// hidden gesture with no affordance is one nobody finds, and the second target
    /// now has both a button and a sensible default position, which is a better
    /// answer than a hold nobody knew about. This also takes the hole view back to
    /// **one** drag gesture with nothing else competing, which is the rule that
    /// exists because four gestures once made nothing on the hole movable at all.
    @ViewBuilder private func toolColumn(_ geo: HoleGeometry) -> some View {
        VStack(spacing: 6) {
            // **Markers first, directly under the pin menu** *(X9, user
            // 2026-08-28: "move button up below 'edit this hole' button")*. It is
            // the one here that is on all the time and the one that changes what
            // the whole hole shows, so it goes where the thumb lands first.
            // **Three states, one button** *(user, 2026-08-29)*. It walks
            // on → ghost → off, and the middle one has to *look* like a third
            // state rather than a dimmer version of on: the layer it controls is
            // itself half transparent then, so a button that only faded would say
            // the same thing twice and answer neither "is it on?" nor "can I touch
            // it?".
            toolButton("mappin.circle", state: markerDisplay) {
                markerDisplay = markerDisplay.next
            }

            toolButton("1.circle", on: targets.indices.contains(0)) {
                if targets.indices.contains(0) { remove(0) }
                else { setTarget(0, geo.suggestedTarget) }
            }
            // Disabled with no first target, because the second is defined *from*
            // the first — two thirds of what is left to the green.
            toolButton("2.circle", on: targets.indices.contains(1)) {
                if targets.indices.contains(1) { remove(1) }
                else if let first = targets.first {
                    setTarget(1, geo.towardGreen(from: first))
                }
            }
            .disabled(targets.isEmpty)
            .opacity(targets.isEmpty ? 0.4 : 1)

            toolButton("ruler", on: !measures.isEmpty) {
                // **Adds one rather than toggling.** "clicking again create a new
                // line segment" — several measurements at once is the point, and a
                // segment is cleared by tapping its own label.
                let centre = targets.first ?? geo.suggestedTarget
                measures.append(.across(centre, bearing: geo.bearing,
                                        colorIndex: measureSeq))
                measureSeq += 1
            }

            // **X12** *(user, 2026-08-28: "promote the button to gps hole view,
            // under measurement line icon from menu")*. Moved out of the pin menu
            // rather than added beside it — two controls for one state is how they
            // come to disagree. Two consequences worth knowing: the menu no longer
            // rebuilds when simulation is toggled, which is one fewer thing that can
            // flicker it (X5); and a **card-only hole loses the toggle**, because
            // the tool column is only drawn where there is a hole to draw. That is
            // the right answer rather than a gap — simulation seeds from the tee and
            // is measured against geometry, and a hole with no coordinates has
            // neither.
            toolButton("figure.golf", on: simulating) { simulate(!simulating, geo: geo) }
        }
    }

    private func toolButton(_ symbol: String, on: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(on ? style.flag.opacity(0.85) : .black.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(on ? .white : style.ink)
        }
        .buttonStyle(.plain)
    }

    /// The markers button, which has three states rather than two.
    ///
    /// Ghost is drawn as the **on** treatment held back — a filled plate at a third
    /// strength with the symbol outlined rather than solid — so it reads as "on, but
    /// not all the way" rather than as a fourth thing. Off keeps the plain plate
    /// every other tool uses when it is off, or the button would stop matching the
    /// column it sits in.
    private func toolButton(_ symbol: String, state: MarkerDisplay,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(state == .off ? AnyShapeStyle(.black.opacity(0.55))
                                          : AnyShapeStyle(style.flag.opacity(state == .on ? 0.85 : 0.3)),
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(state == .on ? AnyShapeStyle(.white)
                                              : AnyShapeStyle(style.ink))
                .opacity(state == .ghost ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Markers: \(state.rawValue)")
    }

    /// Turn simulation on or off, **re-seeding every time it goes on**.
    ///
    /// It lives here rather than in the button's closure because the rule is older
    /// than the button and outlived its previous home in the pin menu: keeping a
    /// previous `simulated` around meant switching it on anywhere but the hole you
    /// were looking at left the marker on another hole — or on the phone's real fix
    /// in another county — so the readout fell back to the tee while the screen
    /// still claimed to be simulating.
    private func simulate(_ on: Bool, geo: HoleGeometry) {
        simulating = on
        guard on else { return }
        // **The tee if it is on screen, otherwise the middle of the map area**
        // *(user, 2026-08-29, restated the same day after this was reverted along
        // with the marker's layering: "not geo positioning: at tee when visible,
        // center of the screen when tee not visible <- this is what I want". The
        // revert was about the **layering**, which is a different change; see
        // `SatelliteHoleView.simulatedMarker`.)*
        //
        // It used to seed from the phone's own fix and fall back to the tee, which
        // is wrong in exactly the case simulation exists for: the golfer is at a
        // desk, the fix is in another county, and the marker lands somewhere the
        // hole on screen cannot see — so `HoleReadout` falls back to the tee and the
        // screen claims to be simulating while nothing moved.
        //
        // `ground` comes from whichever renderer is drawing, never re-derived here:
        // a second copy of the transform is a second answer that can disagree with
        // the one on screen.
        if let ground, !ground.contains(geo.teeAt) {
            simulated = ground.center
        } else {
            simulated = geo.teeAt
        }
    }

    private func remove(_ i: Int) {
        guard targets.indices.contains(i) else { return }
        targets.remove(at: i)
    }

    // MARK: - HUD

    /// Hole number, par, length and tee — stacked, on the left, with the number
    /// itself set large. It was one dense line of monospaced text across the top,
    /// which is the shape of a debug readout rather than the first thing a golfer
    /// looks at on a tee.
    private func holeBox(_ hole: Hole, tee: TeeBox) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(hole.nine.map { "\($0) " } ?? "")HOLE \(hole.ref)")
                .font(.system(size: 19, weight: .bold))
            Text("PAR \(hole.par)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(display.spelled(hole.length(from: tee)))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.8))
            // **`~` when the tee end came from the hole's centre line** — the same
            // mark `CardYardage` uses for a measured length standing in for a card
            // number, and for the same reason: it is a different quantity, not a
            // substitute. Nothing on this hole is placed, so the hole is drawn from
            // the traced way and the "tee" is where that way starts.
            // `~` twice over, for two different unmeasured things: the *position*
            // came from the hole's centre line rather than a tee polygon
            // (`teeInferred`), or the *name* was assigned from the length order
            // because OSM tagged no colour (`inferredName`). Either way nobody
            // surveyed what the row claims, which is the whole of the mark.
            Text(hole.geometry(tee: tee)?.teeInferred == true || tee.inferredName == true
                 ? "~ \(tee.name.capitalized) Tee"
                 : "\(tee.name.capitalized) Tee")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(teeInk(hole, tee))
            if let c = hole.confidence, c < 0.95 {
                Text("DRAFT \(String(format: "%.2f", c))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(style.ink)
    }

    /// Height of the status bar, and **not** `safeAreaInsets.top`.
    ///
    /// The hole view ignores the top safe area so the distance can run up through
    /// the navigation bar's band to the edge of the display. That is exactly what
    /// makes the proxy report an inset of zero, so asking it would put the numbers
    /// under the clock. The status bar is the one thing that must still be cleared,
    /// and UIKit is the only place that knows how tall it is.
    static var statusBarInset: CGFloat {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.statusBarManager?.statusBarFrame.height ?? 20
        #else
        return 8
        #endif
    }

    /// The tee's own colour, so the word and the marker on the hole agree. Nudged
    /// toward white when the colour itself is too dark to read on a dark chip —
    /// `TeePalette.outline` already knows which those are, so this asks it rather
    /// than keeping a second list.
    private func teeInk(_ hole: Hole, _ tee: TeeBox) -> Color {
        let c = TeePalette.colors(for: hole.tees, greenCenter: hole.green.center)[tee.name]
            ?? style.ink
        return TeePalette.outline(for: c) == Color.white.opacity(0.8)
            ? TeePalette.blend(c, .white, 0.55) : c
    }

    // **The tracking chip and everything it read are gone** *(user, 2026-08-28:
    // "remove location tracking state at the bottom left side")*. The mode and the
    // lock live on the Marker bar, which is on screen anyway, and two places saying
    // it is how they come to disagree — `LiveLocation.adopt` hardcoding `.fast`
    // was exactly that. A retired control is not retired while the code that draws
    // it is still here: that is the `onHoldGround` lesson, where a dead callback
    // quietly ate taps for a day. So `trackingChip`, `trackingText` and the
    // `tracking` property itself all went with it.

    private func chip(title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(sub).font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.7))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(style.ink)
    }

    /// Back over centre over front, centre big.
    ///
    /// Replaces the bottom tray: the three numbers are the same three the category
    /// converged on, moved out of the thumb zone because they are read and never
    /// touched. With a target placed these become *what is left from the target* —
    /// the caption says so, because a number whose meaning changed silently is the
    /// one thing worse than no number.
    private func distanceBlock(_ r: HoleReadout) -> some View {
        VStack(spacing: 1) {
            edgeNumber("BACK", r.green.back)
            // **The plays-like number rides the big one, and there is no capsule**
            // *(user, 2026-08-30: "no separate orange box")*. It was an orange pill
            // under the caption — a second object saying something about the number
            // three lines above it, which the eye had to join up.
            //
            // **The big number stays put; the suffix hangs off its right edge**
            // *(user, 2026-08-30: "main number stays in the center regardless of
            // plays like dist")*. An `HStack` centred the *pair*, so the yardage a
            // golfer reads shifted sideways the moment a hole stopped being flat —
            // and shifted back as they walked onto a level lie. The one number on
            // this screen that is read at a glance must not move because a second
            // one appeared beside it. So the suffix is an **overlay** with its
            // leading edge pinned to the number's trailing edge: it takes no part
            // in the layout, and the number is centred on its own.
            bigDistance(r)
            edgeNumber("FRONT", r.green.front)
            Text(caption(r))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.75))
                .shadow(color: .black.opacity(0.9), radius: 4)
                .padding(.top, 3)
        }
        .allowsHitTesting(false)
    }

    private func edgeNumber(_ label: String, _ metres: Double) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.55))
            Text(display.number(metres))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(style.ink.opacity(0.9))
        }
        .shadow(color: .black.opacity(0.8), radius: 4)
    }

    /// Says what the big number is, and where it is measured from — which replaces
    /// the old `M TO CENTRE · FROM TEE, NO FIX YET` shouted across the screen.
    /// The big number, and the plays-like suffix hanging off its right edge.
    ///
    /// **The number stays centred whatever the suffix does** *(user, 2026-08-30:
    /// "main number stays in the center regardless of plays like dist, and plays
    /// like dist shows on the right")*. An `HStack` centred the *pair*, so the one
    /// yardage a golfer reads at a glance slid sideways the moment a hole stopped
    /// being flat, and slid back as they walked onto a level lie.
    ///
    /// **Placed by arithmetic, not by an alignment guide.** The obvious
    /// `.overlay(alignment: .bottomTrailing)` with the child's `trailing` guide
    /// resolved at its own `leading` should put it just outside the number; it
    /// landed *on* the number instead — screenshotted, `.~97▼4` written across the
    /// `1` of `101`. A monospaced advance is fixed and measured (0.618 em, see
    /// `PlanLayout.advance`), so the offset is exact and is the same technique
    /// `PlanLayout` and `measureLabelRects` already rely on.
    @ViewBuilder
    private func bigDistance(_ r: HoleReadout) -> some View {
        let text = display.number(r.green.center)
        let plays = display.plays(rise: r.rise, distance: r.green.center)
        // Locals rather than static constants: `HoleScreen` is generic over its
        // bottom bar, and a generic type cannot hold a static stored property.
        let bigSize = 68.0, subSize = 20.0
        // **Zero.** The separator is a `.` in 20-point text sitting beside a
        // 68-point digit, and the big glyph's own right sidebearing already leaves
        // a few points; adding more orphaned the dot, so it read `101 .~97▼4`
        // rather than as one expression. Screenshotted at 6 and at 0.
        let gap = 0.0
        let bigWidth = Double(text.count) * PlanLayout.advance * bigSize
        let subWidth = Double(plays?.count ?? 0) * PlanLayout.advance * subSize
        Text(text)
            .font(.system(size: bigSize, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 10)
            .overlay(alignment: .center) {
                if let plays {
                    // Smaller and dimmer than the number it annotates,
                    // deliberately: at the same weight it would read as a second
                    // distance competing with the first, which is the one the
                    // golfer is actually clubbing off.
                    Text(plays)
                        .font(.system(size: subSize, weight: .semibold,
                                      design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(style.ink.opacity(0.9))
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .fixedSize()
                        .offset(x: (bigWidth + subWidth) / 2 + gap,
                                y: bigSize * 0.22)
                }
            }
    }


    private func caption(_ r: HoleReadout) -> String {
        // **"TO PIN" when a flag has been placed** — the number really is measured
        // to it, and a caption that still said GREEN would be describing a
        // different measurement to the one on screen.
        let target = r.measuringToPin ? "PIN" : "GREEN"
        var parts = [(display.symbol == "M" ? "METRES TO " : "YARDS TO ") + target]
        if r.hasTargets { parts.append("FROM TARGET \(r.targets.count)") }
        if case .tee(let name, _) = r.origin { parts.append("FROM \(name.uppercased()) TEE") }
        return parts.joined(separator: " · ")
    }

    // **There is no simulation banner** *(X11, user 2026-08-28: "'SIMULATED
    // POSITION - drag it. MARK is off.' is unnecessary")*. Half of it was stale —
    // MARK left the hole view entirely — and the other half described a marker
    // that already says so: orange, dashed, a golfer glyph, unlike anything else
    // drawn here. **That styling is now the only signal on screen that a position
    // is hand-placed**, so it is not decoration and must not be tidied away. The
    // consequence recorded under X3 is unchanged and now carries one fewer
    // warning: a simulated coordinate reaches `log.jsonl` looking exactly like a
    // measured one, because `LogEntry` has no discriminator.

    // MARK: - The settings menu behind the pin

    private func settingsMenu(_ hole: Hole) -> some View {
        HoleSettingsMenu(
            holeRef: hole.ref,
            tees: TeePalette.ordering(hole.tees, greenCenter: hole.green.center).map(\.name),
            teeName: tee(hole).name,
            layer: layer,
            unit: display.unit,
            hasTargets: !targets.isEmpty,
            hasPlayer: effectivePlayer != nil,
            canEdit: onEditHole != nil,
            style: style,
            onEdit: { onEditHole?(hole.ref) },
            onTee: { teeName = $0 },
            onLayer: { layer = $0 },
            onUnit: { display = DistanceDisplay(unit: $0) },
            onGoToMe: { centerOn = effectivePlayer },
            onFit: { withAnimation(.easeOut(duration: 0.25)) { viewport = .fitted } },
            onClearTargets: { targets = [] },
            onCourseView: { showCourse = true })
            // **X5 — the menu must not rebuild while it is open.** `tracking` changes
            // on every fix and on a five-second ticker, and any of those redraws this
            // whole subtree; SwiftUI then tears the open `Menu` down and puts a fresh
            // one up, which is the flicker. `EquatableView` stops the rebuild at the
            // menu's own boundary: none of its inputs change while it is up.
            .equatable()
    }

    // MARK: - Card-only hole    // MARK: - Card-only hole

    /// Deliberately not a map: an empty or default-framed map reads as "the app is
    /// broken", while the card reads as "this hole is not mapped yet", which is the
    /// truth and is actionable.
    private func cardOnlyContent(_ hole: Hole, tee t: TeeBox) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                holeBox(hole, tee: t)
                Spacer()
                settingsMenu(hole)
            }
            .padding(.horizontal, 14).padding(.top, 10)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: "map")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(style.ink.opacity(0.35))
                Text("No map for this hole yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.ink)
                Text("The card is imported — par, handicap and yardage.\nPlace a tee and a green centre to draw it.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(style.ink.opacity(0.65))
                cardRow(hole, tee: t)
            }
            Spacer(minLength: 0)
            controls(hole)
            barSlot
        }
        .background(style.roughDeep)
        .preferredColorScheme(.dark)
    }

    private func cardRow(_ hole: Hole, tee t: TeeBox) -> some View {
        HStack(spacing: 0) {
            trayCell("PAR", "\(hole.par)")
            Divider().background(style.ink.opacity(0.25))
            if let h = hole.handicap {
                trayCell("HCP", "\(h)")
                Divider().background(style.ink.opacity(0.25))
            }
            // Bare, like every other number on this screen. The unit is stated
            // once, in the caption under the big distance.
            trayCell(t.name.uppercased(),
                     hole.cardLength(from: t).map(display.number) ?? "—")
        }
        .frame(height: 54)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.ink.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 40)
        .padding(.top, 6)
    }

    private func trayCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.6))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(style.ink)
        }
        .frame(maxWidth: .infinity)
    }

    /// The dragged-marker confirmation — X7's "never applied silently", asked for
    /// **small and at the bottom** *(user, 2026-08-28: "should not cover too much of
    /// the screen. Make it smaller and down to the bottom")*.
    ///
    /// **Neither an `alert` nor a `confirmationDialog`.** The alert landed in the
    /// middle of the display, over the pill, the hole and the numbers — i.e. over
    /// the only things that let a golfer answer the question, which is whether the
    /// entry is now in the right place. `confirmationDialog` was tried next and
    /// on iOS 26 comes up as a centred card of much the same size, so it is the
    /// same fault in a different shape. This is a strip in the layout, directly
    /// above the hole controls: it takes one row, it is where the thumb already is,
    /// and everything the question is about stays visible above it.
    private var moveConfirm: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Move this entry?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Recorded as said here. The original stays in the log.")
                    .font(.system(size: 11))
                    .foregroundStyle(style.ink.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel") { pendingMove = nil }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(style.ink.opacity(0.8))
            Button("Move") {
                if let m = pendingMove { onMarkerMoved?(m.id, m.to) }
                pendingMove = nil
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(style.flag, in: Capsule())
            .foregroundStyle(.white)
        }
        .foregroundStyle(style.ink)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// One name per line, and **each one is a switch** *(user, 2026-08-28: "these
    /// buttons should be toggleable to show or hide all the markers of the
    /// player")*.
    ///
    /// **Always drawn, bottom left, a third of the width, hard against the edge**
    /// *(user, 2026-08-28)*. Always, because it is the roster of the round and not
    /// a key to what happens to be on this hole — a player with no shots here still
    /// has a next shot to file. A third of the screen because the names sit over
    /// rough that carries no numbers; the middle third is the hole itself.
    ///
    /// **A hidden player is drawn switched off, never removed** — hollow swatch and
    /// a struck-through name. The plate behind it does *not* dim (user, same day):
    /// dimming the background made the row look disabled, when what is off is the
    /// player's markers rather than the button.
    ///
    /// The number on the right is `scoreCell` — shots taken, tapped to file the
    /// next one, swiped right to close the hole out. That is the shortest path
    /// there is from "I just hit it" to a marker on the hole: no sheet, no
    /// keyboard, one tap.
    private func legend(par: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(tracks) { t in
                let on = !hiddenPlayers.contains(t.id)
                HStack(spacing: 6) {
                    Button {
                        if on { hiddenPlayers.insert(t.id) } else { hiddenPlayers.remove(t.id) }
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? t.color : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(t.color, lineWidth: 1.5))
                                .frame(width: 12, height: 12)
                            Text(t.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .strikethrough(!on, color: style.ink)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Either callback earns the cell: it files a shot *and* closes
                    // the hole out, so gating on `onAddShot` alone would render no
                    // score at all for a caller that only passes `onHoleOut`.
                    if t.nextShot != nil, onAddShot != nil || onHoleOut != nil {
                        scoreCell(t, par: par)
                    }
                }
                .padding(.leading, 8).padding(.trailing, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .foregroundStyle(style.ink)
        .frame(width: legendWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    /// The number at the right of a legend row: **shots taken while the hole is
    /// open, the score to par once it is closed**, tapped to file the next shot and
    /// swiped to close the hole out *(user, 2026-08-29)*.
    ///
    /// **One cell, two states, and the sign is what tells them apart.** An open
    /// hole prints a bare count (`0`, `1`, `2`); a closed one prints `-1` / `+0` /
    /// `+1`. The sign is not decoration — it is the only thing distinguishing "two
    /// shots so far" from "two over par" at a glance, which is why `+0` is printed
    /// rather than `0` or `E`.
    ///
    /// **Tap and swipe live on one view and it classifies itself**, the same rule
    /// `VectorHoleView.touch` follows: a `DragGesture` with a real minimum distance
    /// alongside `onTapGesture`, rather than a `Button` with a drag layered over it.
    /// The cell is deliberately wider and taller than the glyph — a 26-point box is
    /// a poor thing to *drag out of* with a thumb, and the whole gesture has to
    /// start inside it.
    ///
    /// **Right closes, left reopens, and the score is the number already on
    /// screen** *(user, 2026-08-29: "hole out swipe means the last shot is in the
    /// hole, meaning, current shot # is the score")*. The cell shows the *next*
    /// shot's name — `T`, `1`, `2` — so a player showing `3` has played T, 1 and 2,
    /// and if the last of those went in the hole the score is 3.
    ///
    /// **"Holing out is a shot" is not reversed by that, it has moved** *(the
    /// user's correction of the same day, which this supersedes)*. The holing-out
    /// stroke is now the last marker the golfer *filed* rather than an increment
    /// added at swipe time — `#3/holeout: 3` in the user's own numbering: the shot
    /// that goes in is one you stood over and marked. So the swipe adds nothing,
    /// and the number read is the number committed.
    ///
    /// It follows that **the `T` state cannot hole out**: nothing has been played,
    /// and a score of zero is not a thing. A hole in one is expressible and takes
    /// one tap first — file the tee shot, the cell reads `1`, swipe. Reopen is the
    /// correction path for a swipe nobody meant, and for a hole where the count was
    /// wrong; the same objection the user made about the Round toggle ("when it's
    /// off, no way to turn it on now").
    @ViewBuilder
    private func scoreCell(_ t: PlayerTrack, par: Int) -> some View {
        // **Dead without a position, and visibly so.** Its whole meaning is "file a
        // shot where I am standing", so with no fix and no simulated point it would
        // write a marker that cannot be drawn — on a screen whose only feedback is
        // the marker appearing. The number still shows, because it is also just
        // information; it stops being a button. A closed hole is dead for the other
        // reason: there are no more shots on it.
        let taken = t.shotsTaken ?? 0
        let canFile = effectivePlayer != nil && !t.holedOut
        // **The next shot's *name*, not its number** *(user, 2026-08-29: "player
        // name <shot count> shows next shot when not holed out: T -> 1 -> 2 ->
        // ...")*. `ShotName` is the one place the offset lives, so the pill on the
        // hole and this cell cannot disagree about what a shot is called. For
        // anything past the tee the name happens to equal `shotsTaken`, which is
        // why only the zero case looks different.
        let open = t.nextShot.map(ShotName.of) ?? "\(taken)"
        let text = t.toPar(par) ?? open
        HStack(spacing: 2) {
            Text(text)
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(t.holedOut ? t.color
                                            : (canFile ? t.color : style.ink.opacity(0.35)))
            // A swipe with no affordance is a gesture nobody finds — the objection
            // that retired press-and-hold. One faint chevron, pointing the way the
            // finger goes: right to close a hole that has shots on it, left to
            // reopen one already closed.
            ForEach(swipeHint(t), id: \.self) { hint in
                Image(systemName: hint)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.ink.opacity(0.35))
            }
        }
        .frame(minWidth: 44, minHeight: 30)
        .background(t.holedOut ? AnyShapeStyle(t.color.opacity(0.22))
                               : AnyShapeStyle(.black.opacity(canFile ? 0.35 : 0.15)),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .scaleEffect(shownBump?.id == t.id ? (shownBump?.up == true ? 1.35 : 0.7) : 1)
        .gesture(DragGesture(minimumDistance: 18)
            .onEnded { v in
                // **Vertical adjusts the score, horizontal opens and closes the
                // hole** *(user, 2026-08-30, asked which control should take it:
                // the score cell)*. One cell owns the score, so both gestures live
                // on it and it decides which was meant from the dominant axis — the
                // same self-classifying rule `VectorHoleView.touch` follows.
                guard abs(v.translation.width) > abs(v.translation.height) else {
                    adjustScore(t, up: v.translation.height < 0)
                    return
                }
                if v.translation.width > 0 {
                    // **The number on screen is the score**, and the `T` state has
                    // no number — nothing has been played, so there is nothing to
                    // have gone in. A hole in one is the tee shot filed and then
                    // swiped, which reads `1` first.
                    guard !t.holedOut, taken > 0 else { return }
                    onHoleOut?(t.id, taken)
                } else if t.holedOut {
                    onHoleOut?(t.id, nil)
                }
            })
        .onTapGesture {
            guard canFile, let next = t.nextShot else { return }
            onAddShot?(t.id, next)
        }
        .accessibilityLabel(t.holedOut
            ? "\(t.name) \(text) — swipe up or down to change the score, left to reopen the hole"
            : (taken > 0
               ? "\(t.name), \(taken) shots — swipe right to hole out in \(taken)"
               : "\(t.name), on the tee"))
    }

    /// **Nudge a closed hole's score by one** *(user, 2026-08-30)*.
    ///
    /// **Only on a closed hole.** An open one has no score to change — its number is
    /// how many shots have been filed, which is a count of markers and not something
    /// a swipe may contradict. Filing or deleting a marker is how that number moves.
    ///
    /// It goes through `onHoleOut` like every other score change, so it is one
    /// `.setScore` journal act and undoes through `HistoryView` exactly like a swipe
    /// to hole out — "the journal is the record; the card is a view of it".
    ///
    /// Floored at 1: a score of zero is not a thing, which is the same reason the
    /// `T` state cannot hole out. Capped at 20 for the same reason the Marker
    /// sheet's stepper is — past that it is a typo, not a hole.
    private func adjustScore(_ t: PlayerTrack, up: Bool) {
        guard let score = t.score else { return }
        let next = min(20, max(1, score + (up ? 1 : -1)))
        guard next != score else { return }
        onHoleOut?(t.id, next)
        // Set flat, cleared with a spring **on a later update turn**: the cell snaps
        // to the bumped size and springs back, so the *direction* of the change is
        // visible and not just the fact of one.
        //
        // **The hop matters.** Setting and clearing in one synchronous block is a
        // single SwiftUI update — it diffs nil against nil, the scale never changes,
        // and there is no animation at all. That version was written first and is
        // indistinguishable from a working one in a diff, which is why there is now
        // a `marker.bump` launch key that renders the bumped state to look at.
        scoreBump = ScoreBump(id: t.id, up: up)
        Task { @MainActor in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { scoreBump = nil }
        }
    }

    /// **No right chevron on the tee**, because the swipe does nothing there — an
    /// affordance for a gesture that is refused is worse than none, which is the
    /// whole reason the chevron exists. A closed hole gets two: left to reopen, and
    /// up/down to nudge the score.
    private func swipeHint(_ t: PlayerTrack) -> [String] {
        if t.holedOut { return ["chevron.left", "chevron.up.chevron.down"] }
        return (t.shotsTaken ?? 0) > 0 ? ["chevron.right"] : []
    }

    /// The thumb zone: hole stepping and MARK, nothing else. Layer and tee moved
    /// into the pin menu when the tray came out.
    private func controls(_ hole: Hole) -> some View {
        HStack(spacing: 10) {
            stepButton("chevron.left", enabled: holeIndex > 0) { holeIndex -= 1 }
            if let onMark {
                // **MARK is off while simulating**, by construction rather than by a
                // flag downstream. `marks.jsonl` is ground truth *and* the eval set
                // for `GolfEval`; a dragged position recorded there would poison the
                // answer key, and one consumer forgetting to filter a `simulated`
                // flag would corrupt an accuracy number silently.
                Button(action: onMark) {
                    Text(simulating ? "MARK OFF · SIMULATING" : "MARK")
                        .font(.system(size: simulating ? 12 : 20, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(simulating ? Color.white.opacity(0.08) : style.flag,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(simulating ? style.ink.opacity(0.5) : .white)
                }
                .buttonStyle(.plain)
                .disabled(simulating)
            } else {
                // The course name lives here and nowhere else — it used to be the
                // navigation title as well, which spent the most valuable strip of
                // the screen repeating something that never changes.
                Text(course.name)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .foregroundStyle(style.ink.opacity(0.85))
            }
            stepButton("chevron.right", enabled: holeIndex < course.holes.count - 1) { holeIndex += 1 }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.black.opacity(0.55))
    }

    /// The app's bar, measured as it is drawn.
    ///
    /// `onGeometryChange` rather than a constant: the height is what the satellite
    /// layer reserves for Apple's attribution, and a number written here by hand
    /// would be wrong the first time the bar gains a row — with a covered Legal
    /// link as the symptom, which is a licence problem and not a visual one.
    private var barSlot: some View {
        bottomBar()
            // `GeometryReader` in a background rather than `onGeometryChange`,
            // which needs a floor above this view's own `@available`.
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { setBar(g.size.height) }
                        .onChange(of: g.size.height) { _, h in setBar(h) }
                })
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(style.ink.opacity(enabled ? 1 : 0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
#endif
