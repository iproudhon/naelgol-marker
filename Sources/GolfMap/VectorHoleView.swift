#if canImport(SwiftUI)
import SwiftUI
import GolfCourse

/// The hole drawn from the course file alone — **no network, no map provider, no
/// licence**.
///
/// This is the layer that always works, not a fallback. Two independent reasons put
/// it first: no provider (Google or Apple) permits storing imagery, so a photograph
/// can never survive a mountain dead zone; and text over photography is the worst
/// case for a screen in afternoon sun. 골프버디 already ships graphic and satellite
/// as user-selectable views, so a drawn hole is a mode golfers choose rather than a
/// downgrade they tolerate.
///
/// **It pans, zooms and takes taps, exactly as the satellite layer does.** Before
/// that it was a fitted still image, which made the primary layer feel like the
/// degraded one every time you switched. The transform lives in `HolePlane.View`
/// and never in a SwiftUI modifier — see the note on that type for why a
/// `.scaleEffect` here would put every tap somewhere other than the finger.
///
/// See `docs/research-course-map.md` §3.3 and `docs/research-course-display.md`.
@available(iOS 17, macOS 14, *)
public struct VectorHoleView: View {
    /// The resolved hole. Taking `HoleGeometry` rather than `Hole` is what keeps a
    /// card-only hole — par and yardage, no coordinates — from rendering silently
    /// at the equator; there is nothing to nil-coalesce.
    public let geo: HoleGeometry
    public var hole: Hole { geo.hole }
    public var tee: TeeBox { geo.tee }
    public var style = HoleStyle()
    /// Everything measured: origin, targets and the legs between them.
    public var readout: HoleReadout?
    /// The course's terrain, for the **shot-marker legs only** — every other
    /// elevation number on this screen arrives already resolved on `readout`.
    /// A track leg is not part of the plan, so nothing upstream had computed its
    /// rise; sampling here is one bilinear lookup per leg. Nil is the ordinary
    /// case and simply drops the suffix.
    public var terrain: Elevation?
    public var tracks: [PlayerTrack] = []
    /// True while the player marker is a hand-placed position rather than a fix.
    public var simulating = false
    /// Where one recorded log was said, when the golfer has asked to see it.
    ///
    /// **Kept out of `extraPoints` on purpose** — see the note there. A log made
    /// while walking between two fairways, or in a kitchen four thousand
    /// kilometres away, would otherwise shrink the hole to a dot to keep it in
    /// frame. It is panned to, not fitted to, and the pan is unclamped, so a
    /// coordinate off this hole is still reachable.
    public var focus: Coordinate?
    /// Yards or metres, for the numbers drawn on the legs.
    public var display = DistanceDisplay.default
    /// Keeps the hole clear of the HUD. Without it the tee box renders behind the
    /// numbers.
    public var insets = HolePlane.Insets(top: 250, bottom: 150, leading: 28, trailing: 28)

    @Binding public var viewport: HolePlane.View
    /// What the markers layer is doing — see `MarkerDisplay`. `off` never reaches
    /// here (the screen sends no markers at all); `ghost` does, because the entries
    /// are still drawn.
    public var markerDisplay: MarkerDisplay = .on
    /// What ground is on screen, reported back out. See `GroundView` — the screen
    /// cannot work this out for itself without a second copy of this view's own
    /// transform.
    @Binding public var ground: GroundView?

    /// A tap that landed on open ground. Nil disables placement entirely.
    public var onTapGround: ((Coordinate) -> Void)?
    /// A press-and-hold on open ground — the second target.
    /// A tap that landed on target `i`.
    public var onTapTarget: ((Int) -> Void)?
    /// Target `i` dragged to a new spot.
    public var onMoveTarget: ((Int, Coordinate) -> Void)?
    /// The simulated player dragged. Nil when the position is a real fix, which is
    /// what keeps a real fix from being draggable.
    public var onMovePlayer: ((Coordinate) -> Void)?

    // MARK: - X6 / X7

    /// Rulers laid on the hole. See `MeasureSegment`.
    public var measures: [MeasureSegment] = []
    public var onMoveMeasure: ((Int, MeasureSegment.End, Coordinate) -> Void)?
    /// The whole ruler dragged by its distance box — X10. Both ends move together.
    public var onCenterMeasure: ((Int, Coordinate) -> Void)?
    /// Tapping a measure's own label clears that measure.
    public var onTapMeasure: ((Int) -> Void)?

    /// Recorded log entries, drawn where they were said. See `HoleMarker`.
    public var markers: [HoleMarker] = []
    /// The unassigned marks to join, **in the order they were pressed**. See
    /// `HoleMarker.line`.
    public var markLine: [String] = []
    /// The move a confirmation is currently asking about, drawn as a **proposal**.
    ///
    /// *(2026-08-28. The confirmation used to be an alert covering the hole, so
    /// there was nothing to see behind it; asking for it small and at the bottom is
    /// what exposed that the pill had already snapped back to where it started, and
    /// the question had no referent on screen.)*
    ///
    /// **Drawn unlike a placed marker, deliberately.** Nothing has been written yet
    /// — the row still says the old position, and `LogEntry` is the truth — so this
    /// is a hollow ring on a dashed tether from the pill, in the same visual
    /// language as the focus ring and for the same reason: a proposal that renders
    /// like a fact is the failure the simulated-position rule is about.
    public var pendingMarker: (id: String, at: Coordinate)?
    /// Today's flag, when one has been placed — drawn instead of the green centre,
    /// and draggable. See `Event.Kind.pin`: it is a fact about this round, not
    /// about the course, so nothing here writes it to the course file.
    public var pin: Coordinate?
    public var onMovePin: ((Coordinate) -> Void)?
    /// A marker was dragged somewhere. The caller confirms before keeping it — a
    /// log's position is evidence, and moving one by accident should not be silent.
    public var onMoveMarker: ((String, Coordinate) -> Void)?
    /// A tap that landed on a marker — X13. The app opens its dialog.
    public var onTapMarker: ((String) -> Void)?

    /// The fix's horizontal accuracy in **metres**, drawn as the ring around the
    /// position marker *(user, 2026-08-30: "current gps location marker's outside
    /// circle should show current estimated radius")*.
    ///
    /// **Nil while simulating, and that is not an oversight.** A hand-placed point
    /// has no accuracy at all, and drawing a radius around it would render a
    /// measurement nobody took in the same visual language as one somebody did —
    /// the failure every simulated-position rule in this file exists to prevent.
    /// The caller passes nil; the renderer also refuses to draw one in the
    /// simulated branch, so neither half can reintroduce it alone.
    public var accuracy: Double?

    public init(geometry: HoleGeometry, style: HoleStyle = HoleStyle(),
                readout: HoleReadout? = nil, terrain: Elevation? = nil,
                tracks: [PlayerTrack] = [],
                simulating: Bool = false, accuracy: Double? = nil,
                display: DistanceDisplay = .default,
                insets: HolePlane.Insets = HolePlane.Insets(top: 250, bottom: 150,
                                                            leading: 28, trailing: 28),
                focus: Coordinate? = nil,
                viewport: Binding<HolePlane.View> = .constant(.fitted),
                centerOn: Binding<Coordinate?> = .constant(nil),
                markerDisplay: MarkerDisplay = .on,
                ground: Binding<GroundView?> = .constant(nil),
                measures: [MeasureSegment] = [],
                onMoveMeasure: ((Int, MeasureSegment.End, Coordinate) -> Void)? = nil,
                onCenterMeasure: ((Int, Coordinate) -> Void)? = nil,
                onTapMeasure: ((Int) -> Void)? = nil,
                markers: [HoleMarker] = [],
                markLine: [String] = [],
                pendingMarker: (id: String, at: Coordinate)? = nil,
                pin: Coordinate? = nil,
                onMovePin: ((Coordinate) -> Void)? = nil,
                onMoveMarker: ((String, Coordinate) -> Void)? = nil,
                onTapMarker: ((String) -> Void)? = nil,
                onTapGround: ((Coordinate) -> Void)? = nil,
                onTapTarget: ((Int) -> Void)? = nil,
                onMoveTarget: ((Int, Coordinate) -> Void)? = nil,
                onMovePlayer: ((Coordinate) -> Void)? = nil) {
        self.geo = geometry
        self.style = style
        self.readout = readout
        self.terrain = terrain
        self.tracks = tracks
        self.simulating = simulating
        self.accuracy = accuracy
        self.focus = focus
        self.display = display
        self.insets = insets
        self._viewport = viewport
        self._centerOn = centerOn
        self.markerDisplay = markerDisplay
        self._ground = ground
        self.measures = measures
        self.onMoveMeasure = onMoveMeasure
        self.onCenterMeasure = onCenterMeasure
        self.onTapMeasure = onTapMeasure
        self.markers = markers
        self.markLine = markLine
        self.pendingMarker = pendingMarker
        self.pin = pin
        self.onMovePin = onMovePin
        self.onMoveMarker = onMoveMarker
        self.onTapMarker = onTapMarker
        self.onTapGround = onTapGround
        self.onTapTarget = onTapTarget
        self.onMoveTarget = onMoveTarget
        self.onMovePlayer = onMovePlayer
    }

    /// Nil for a hole with no coordinates. Callers branch on this rather than the
    /// view drawing an empty plane.
    public init?(hole: Hole, tee: TeeBox? = nil, style: HoleStyle = HoleStyle(),
                 readout: HoleReadout? = nil, tracks: [PlayerTrack] = []) {
        guard let g = hole.geometry(tee: tee) else { return nil }
        self.init(geometry: g, style: style, readout: readout, tracks: tracks)
        _ = ()
    }

    /// What is being dragged right now. A drag means different things depending on
    /// where it started, which is how pan, move-target and move-player coexist
    /// without a long-press to disambiguate them.
    private enum Grab: Equatable {
        case pan, target(Int), player
        case measureEnd(Int, MeasureSegment.End)
        /// The distance box, which drags the whole ruler — X10.
        case measureLabel(Int)
        case marker(String)
        /// The flag. Draggable so a golfer can put it where it was cut today.
        case pin
    }
    /// Recentre the framing on this point. Cleared once applied.
    @Binding public var centerOn: Coordinate?
    @State private var grab: Grab?
    @State private var panStart = HolePlane.View.fitted
    @State private var pinchStart: Double = 1
    /// A pinch is in progress — seeded once per pinch so `pinchStart` is the zoom
    /// the fingers *started* from.
    @State private var pinching = false
    /// **The one-finger gesture stands down for the rest of this touch.**
    ///
    /// *(User, 2026-08-29: "zoom to 40x doesn't seem to work".)* The magnify
    /// gesture and the drag gesture are `simultaneousGesture`, so a pinch drives
    /// **both**: two fingers spreading move the first one well past `slop`, the
    /// drag classified itself as a pan, and its branch rebuilt the viewport from
    /// `panStart.zoom` — the zoom from *before* the pinch — on every callback. The
    /// two gestures then wrote alternate frames and the zoom never got anywhere,
    /// which looks exactly like a ceiling that is not being honoured. Raising the
    /// ceiling to 40 could not have fixed it and did not.
    ///
    /// It stays set until the finger lifts rather than clearing with the pinch: a
    /// drag's translation is measured from where that drag began, so resuming a pan
    /// mid-touch would jump the hole by however far the fingers travelled while
    /// zooming.
    @State private var pinchBlockedDrag = false
    @State private var wandered = false
    /// Where a marker is being dragged **right now**, before anyone has agreed to
    /// it.
    ///
    /// *(X9, user 2026-08-28: "warning is after drag is done. for now it's
    /// before".)* The confirmation used to fire from `onChanged`, so it appeared on
    /// the first pixel of movement and asked about a position the finger had
    /// already left. The move is held here for the length of the drag and reported
    /// once, on release. Cleared on release too: until the caller writes the row,
    /// nothing records the marker anywhere but where it started, and drawing it at
    /// the new place while the alert is still asking would be the same lie as
    /// drawing a simulated position like a fix.
    /// The flag's in-flight position while a finger is on it.
    ///
    /// **Held here and reported once, on release** — the same split as
    /// `markerDrag`, and for a blunter reason: `onMovePin` *writes an event*, so
    /// reporting from `onChanged` appends a row per gesture callback and one
    /// two-second adjustment leaves a hundred `pin placed` lines in the round's
    /// event stream. Drawing continuously and persisting once are different jobs.
    @State private var pinDrag: Coordinate?
    @State private var markerDrag: (id: String, at: Coordinate)?
    /// The gap between the finger and what it picked up. See `DragAnchor`.
    @State private var anchor = DragAnchor(dx: 0, dy: 0)

    /// Where the phone is. **Not** `origin` — see `HoleReadout.playerAt`.
    private var player: Coordinate? { readout?.playerAt }
    /// Whether the numbers are actually being measured from there.
    private var measuringFromPlayer: Bool { readout?.origin.isPlayer ?? false }
    private var targets: [Coordinate] { readout?.targets ?? [] }

    /// What the framing has to contain: the hole, its tees, and the round's shots.
    ///
    /// **Not the player and not the targets**, and that is load-bearing. Both are
    /// placed *by looking at the screen*, so they are on it already — but feeding
    /// them to the fit meant every drag re-fitted the plane and the hole slid the
    /// opposite way to the finger, and a fix at home shrank the hole to a dot to
    /// keep a point four thousand kilometres away in frame.
    private var extraPoints: [Coordinate] {
        var e: [Coordinate] = hole.tees.compactMap(\.at)
        for t in tracks { e += t.allPoints }
        return e
    }

    /// The visible quad and its centre. The centre is the middle of the **map
    /// area**, not of the view — the HUD covers the top, which is the same
    /// correction `centerOn` makes.
    private func groundView(_ plane: HolePlane, size: CGSize) -> GroundView {
        let mid = CGPoint(x: size.width / 2,
                          y: (insets.top + (size.height - insets.bottom)) / 2)
        return GroundView(
            center: plane.unproject(x: mid.x, y: mid.y),
            corners: [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                      CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
                .map { plane.unproject(x: $0.x, y: $0.y) })
    }

    private func plane(_ size: CGSize) -> HolePlane {
        HolePlane(geometry: geo, extra: extraPoints,
                  size: (width: size.width, height: size.height),
                  insets: insets, viewport: viewport)
    }

    /// Which marker a point is on, if any. Generous radii: a fingertip is about
    /// 44 pt across and this is the difference between removing a target and
    /// dropping a second one on top of it.
    /// The ring a target is drawn with, in points.
    static let targetRadius: Double = 13
    /// The circle a *finger* gets, which is three times the one an eye gets. Making
    /// the distance box the handle was tried first and was worse: the box moves as
    /// the number changes, so the handle crawled out from under the thumb mid-drag.
    /// A handle concentric with the ring stays exactly where the target is.
    ///
    /// Drawn, but only just — an invisible handle is indistinguishable from a
    /// handle that does not work, and the first report of this was "dragging outside
    /// the circle doesn't work" when in fact it did and there was no way to tell
    /// where it ended.

    private func hit(_ p: CGPoint, in plane: HolePlane) -> Grab? {
        // **The simulated position is picked up before anything else** *(user,
        // 2026-08-29: "simulate position should be the top in terms of display,
        // drag and click order")*. It is drawn last, i.e. on top, so it has to be
        // tested first or the object under it wins a touch aimed at the thing the
        // eye can see — the same drawn-is-tested rule `PlanLayout` and
        // `markerHandle` follow. It costs nothing when simulation is off, which is
        // every real round: the handle only exists while `simulating`.
        if simulating, let player {
            let q = plane.project(player)
            if hypot(q.x - p.x, q.y - p.y) <= style.grabRadius { return .player }
        }
        for (i, t) in targets.enumerated() {
            let q = plane.project(t)
            if hypot(q.x - p.x, q.y - p.y) <= style.grabRadius { return .target(i) }
        }
        // Measure ends take the same generous handle a target does — the drawn dot
        // is small on purpose, and a ruler nobody can grab is a ruler that does not
        // work. Same argument as `HoleStyle.grabRadius` itself.
        for (i, m) in measures.enumerated() {
            for end in [MeasureSegment.End.a, .b] {
                let q = plane.project(end == .a ? m.a : m.b)
                if hypot(q.x - p.x, q.y - p.y) <= style.grabRadius {
                    return .measureEnd(i, end)
                }
            }
        }
        // The label is a handle too, but **after** the ends: on a short ruler the
        // box covers both of them, and the end is the finer control of the two.
        if let i = measureLabelHit(p, in: plane) { return .measureLabel(i) }
        // **Last, and with a handle the size of what is drawn** — X9's "should be
        // the last to get picked up". Markers are on by default and a hole can
        // carry a dozen; a 39-point disc each would blanket the hole in invisible
        // handles that eat taps meant for the ground.
        // **Nothing on the marker layer takes a touch when it is ghosted** *(user,
        // 2026-08-29)*. That is the whole of the middle state: the entries stay
        // readable and stop competing for every tap on a green covered in them.
        if markerDisplay.isInteractive {
            for m in markers {
                let q = plane.project(m.at)
                if markerHandle(at: CGPoint(x: q.x, y: q.y)).contains(p) { return .marker(m.id) }
            }
        }
        // **The flag is checked last of all**, after the markers. It is drawn on
        // the green, which is where a golfer taps to place a target at the pin —
        // the commonest tap on the screen — so anything that eats those taps is
        // worse than a flag that takes a second attempt to pick up.
        if onMovePin != nil {
            let q = plane.project(pinAt)
            if pinHandle(at: CGPoint(x: q.x, y: q.y)).contains(p) { return .pin }
        }
        return nil
    }

    /// A marker's handle: the point, and a tongue reaching **up** from it.
    ///
    /// *(User, 2026-08-28: "drag handle should be extended toward down, so that I
    /// can see the marker itself while dragging with finger"; flipped 2026-08-29
    /// when the label moved under the point.)* The rule is *away from the label*,
    /// not a direction — a handle on the same side as the pill puts the thumb over
    /// the very thing the extension exists to keep visible.
    ///
    /// **Drawn exactly as tested**, the same rule `PlanLayout` and
    /// `measureLabelRects` follow — a handle you cannot see is bad enough without
    /// it also being somewhere else than it looks.
    private func markerHandle(at c: CGPoint) -> CGRect {
        let r = style.markerGrabRadius
        return CGRect(x: c.x - r, y: c.y - r - style.markerGrabRise,
                      width: r * 2, height: r * 2 + style.markerGrabRise)
    }

    /// The same layout the renderer draws, so the box a finger lands on is exactly
    /// the box on screen. See `PlanLayout`.
    private func planLabels(_ plane: HolePlane) -> [PlanLayout.Label] {
        guard let readout else { return [] }
        return PlanLayout.labels(readout, display: display) { c in
            let q = plane.project(c); return CGPoint(x: q.x, y: q.y)
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let plane = plane(proxy.size)
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(&ctx, size: size, plane: plane)
            }
            .contentShape(Rectangle())
            // **One** drag gesture that classifies itself, and a two-finger magnify
            // that cannot collide with it. There used to be four — drag, magnify,
            // double-tap and tap — and SwiftUI resolved the arbitration in the tap
            // gestures' favour, so a drag that began on a target never reached the
            // handler and nothing could be moved at all. Reset-framing moved into
            // the pin menu rather than being a fifth.
            .gesture(touch(plane: plane, size: proxy.size))
            // An interrupted drag never reaches `onEnded`, and a pill parked at a
            // coordinate no row records looks exactly like a move that succeeded.
            .onChange(of: markers) { markerDrag = nil }
            // The written position has arrived; stop drawing the in-flight one.
            .onChange(of: pin) { pinDrag = nil }
            // **The corners, not a bounding box.** The hole is rotated so the tee
            // is at the bottom, so the screen is a rotated quad on the ground and a
            // lat/lon box around it would call a tee visible while it sat off the
            // corner of the display. Reported after layout rather than during body,
            // which is not a place state may be written.
            .onAppear { ground = groundView(plane, size: proxy.size) }
            .onChange(of: viewport) { ground = groundView(self.plane(proxy.size), size: proxy.size) }
            .onChange(of: proxy.size) { _, size in ground = groundView(self.plane(size), size: size) }
            .onChange(of: centerOn) { _, target in
                guard let target else { return }
                // Pan so the point lands in the middle of the *map area*, which is
                // not the middle of the view — the HUD covers the top of it.
                let q = self.plane(proxy.size).project(target)
                let aim = CGPoint(x: proxy.size.width / 2,
                                  y: (insets.top + (proxy.size.height - insets.bottom)) / 2)
                // No clamp here on purpose: the whole point is to go there even
                // when "there" is nowhere near this hole. `Fit hole to screen` is
                // the way back.
                withAnimation(.easeOut(duration: 0.3)) {
                    viewport = HolePlane.View(zoom: viewport.zoom,
                                              panX: viewport.panX + (aim.x - q.x),
                                              panY: viewport.panY + (aim.y - q.y))
                }
                panStart = viewport
                // **Cleared on the next turn, not inside this handler.** Writing
                // a `@Binding` back to the parent's `@State` from within an
                // `onChange` of that same binding is a self-referential update, and
                // it is one of the shapes SwiftUI reports as
                // `AttributeGraph: cycle detected`. A hop costs a frame and the
                // command is one-shot anyway.
                Task { @MainActor in centerOn = nil }
            }
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if !pinching {
                        pinching = true
                        pinchStart = viewport.zoom
                    }
                    pinchBlockedDrag = true
                    // Zoom about the fingers, not about the middle of the layout —
                    // `HolePlane.zooming(to:about:)`. At 40× the difference is the
                    // whole feature: zooming about the centre puts the green being
                    // read several screens away.
                    viewport = self.plane(proxy.size)
                        .zooming(to: pinchStart * v.magnification,
                                 about: (x: v.startLocation.x, y: v.startLocation.y))
                }
                .onEnded { _ in
                    pinchStart = viewport.zoom
                    panStart = viewport
                    pinching = false
                })
        }
        .background(style.roughDeep)
        .accessibilityLabel("Hole \(hole.ref), par \(hole.par), \(Int(geo.length.rounded())) metres")
    }

    /// How far a finger may wander and still be a press rather than a drag. A
    /// fingertip rolls a few points on any real tap.
    private static let slop: Double = 12

    /// Every touch on the hole, resolved from one gesture:
    ///
    /// | gesture | on an object | on open ground |
    /// |---|---|---|
    /// | tap | remove that target; dismiss that ruler | place / move target 1 |
    /// | drag | move it | pan the hole |
    ///
    /// **There is no hold.** X6 retired it — target 2 has a button — and the branch
    /// that used to read it stayed behind for a while, so a deliberate slow tap on
    /// open ground silently placed nothing.
    ///
    /// `minimumDistance: 0` so a marker starts moving on the first pixel; the
    /// tap-versus-hold decision is taken on release, which makes it a single
    /// gesture with no arbitration and therefore no way for one to swallow another.
    private func touch(plane: HolePlane, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                // A pinch owns this touch — see `pinchBlockedDrag`.
                if pinchBlockedDrag { return }
                if grab == nil {
                    let g = hit(v.startLocation, in: plane) ?? .pan
                    grab = g
                    panStart = viewport
                    wandered = false
                    // Where the object is relative to the finger, held for the whole
                    // drag so the object follows rather than jumping under it.
                    let centre: Coordinate? = {
                        switch g {
                        case .target(let i): return targets.indices.contains(i) ? targets[i] : nil
                        case .player: return player
                        case .measureEnd(let i, let e):
                            guard measures.indices.contains(i) else { return nil }
                            return e == .a ? measures[i].a : measures[i].b
                        case .measureLabel(let i):
                            return measures.indices.contains(i) ? measures[i].midpoint : nil
                        case .marker(let id): return markers.first { $0.id == id }?.at
                        case .pin: return pinAt
                        case .pan: return nil
                        }
                    }()
                    if let centre {
                        let q = plane.project(centre)
                        anchor = DragAnchor(object: CGPoint(x: q.x, y: q.y),
                                            finger: v.startLocation)
                    } else {
                        anchor = DragAnchor(dx: 0, dy: 0)
                    }
                }
                if hypot(v.translation.width, v.translation.height) > Self.slop {
                    wandered = true
                }
                switch grab {
                case .pan:
                    guard wandered else { return }
                    // **The current zoom, never `panStart.zoom`.** A pan must not be
                    // able to reinstate a zoom the user has since left behind; that
                    // is half of what made the pinch unusable.
                    viewport = HolePlane.View(zoom: viewport.zoom,
                                              panX: panStart.panX + v.translation.width,
                                              panY: panStart.panY + v.translation.height)
                        .clamped(size: (size.width, size.height))
                case .target(let i):
                    let p = anchor.object(forFinger: v.location)
                    onMoveTarget?(i, plane.unproject(x: p.x, y: p.y))
                case .player:
                    let p = anchor.object(forFinger: v.location)
                    onMovePlayer?(plane.unproject(x: p.x, y: p.y))
                case .measureEnd(let i, let e):
                    let p = anchor.object(forFinger: v.location)
                    onMoveMeasure?(i, e, plane.unproject(x: p.x, y: p.y))
                case .measureLabel(let i):
                    guard wandered else { return }
                    let p = anchor.object(forFinger: v.location)
                    onCenterMeasure?(i, plane.unproject(x: p.x, y: p.y))
                case .marker(let id):
                    // Held locally, reported once on release — X9.
                    let p = anchor.object(forFinger: v.location)
                    markerDrag = (id, plane.unproject(x: p.x, y: p.y))
                case .pin:
                    // Drawn from here, written on release — see `pinDrag`.
                    let p = anchor.object(forFinger: v.location)
                    pinDrag = plane.unproject(x: p.x, y: p.y)
                case nil: break
                }
            }
            .onEnded { v in
                // The touch that carried a pinch ends here and does nothing else:
                // no tap, no move, no confirmation. A finger lifting off a zoom is
                // not a tap on the hole.
                if pinchBlockedDrag {
                    pinchBlockedDrag = false
                    grab = nil
                    wandered = false
                    panStart = viewport
                    pinchStart = viewport.zoom
                    anchor = DragAnchor(dx: 0, dy: 0)
                    return
                }
                // The move is announced here and only here, and only if the finger
                // actually went somewhere: a press and release on a marker would
                // otherwise raise a confirmation for a zero-length move. X9.
                if wandered, case .marker(let id) = grab, let d = markerDrag, d.id == id {
                    onMoveMarker?(id, d.at)
                }
                markerDrag = nil
                // The flag: one event per drag, not one per callback. No
                // confirmation — a pin is cheap to correct and it is corrected by
                // dragging it again, unlike a marker, which is a claim about where
                // somebody stood.
                if wandered, grab == .pin, let at = pinDrag { onMovePin?(at) }
                pinDrag = nil
                if !wandered {
                    let c = plane.unproject(x: v.location.x, y: v.location.y)
                    switch grab {
                    case .target(let i): onTapTarget?(i)
                    case .player, .pin: break
                    // A ruler's own label is its dismiss control.
                    case .measureLabel(let i): onTapMeasure?(i)
                    case .measureEnd: break
                    // **A tap on a marker opens its dialog; a drag moves it**
                    // *(X13)*. This does not undo X9 — the complaint there was the
                    // *discarded* tap, which placed no target, dismissed nothing and
                    // did nothing at all. The handle is still the size of what is
                    // drawn and markers are still checked last, so a tap that misses
                    // one still reaches the ground.
                    case .marker(let id): onTapMarker?(id)
                    case .pan, nil: onTapGround?(c)
                    }
                }
                panStart = viewport
                pinchStart = viewport.zoom
                grab = nil
                wandered = false
                anchor = DragAnchor(dx: 0, dy: 0)
            }
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, plane: HolePlane) {
        func p(_ c: Coordinate) -> CGPoint {
            let q = plane.project(c); return CGPoint(x: q.x, y: q.y)
        }
        func path(_ cs: [Coordinate], closed: Bool) -> Path {
            var path = Path()
            guard let first = cs.first else { return path }
            path.move(to: p(first))
            for c in cs.dropFirst() { path.addLine(to: p(c)) }
            if closed { path.closeSubpath() }
            return path
        }
        /// Metres → points. Every width in this view is a real-world size.
        func m(_ metres: Double) -> CGFloat { CGFloat(metres * plane.scale) }

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.roughDeep))

        // Fairway — a real outline when we have one, otherwise a band along the hole
        // line. **The outline is now the common case on an imported course**: OSM
        // maps most fairways as multipolygon relations, and since 2026-08-30 those
        // are imported, so the band is the fallback it was always meant to be.
        if hole.fairway.count >= 3 {
            ctx.fill(path(hole.fairway, closed: true), with: .color(style.fairway))
        } else if hole.line.count >= 2 {
            ctx.stroke(path(hole.line, closed: false), with: .color(style.fairway),
                       style: StrokeStyle(lineWidth: m(style.fairwayWidth),
                                          lineCap: .round, lineJoin: .round))
        }

        // Cart paths, over the fairway and under everything else. They are the only
        // thing on the hole that is neither a hazard nor a number — pure orientation
        // — so they go down first and stay quiet.
        for track in hole.paths where track.count >= 2 {
            ctx.stroke(path(track, closed: false), with: .color(style.cartPath.opacity(0.55)),
                       style: StrokeStyle(lineWidth: max(1, m(style.cartPathWidth)),
                                          lineCap: .round, lineJoin: .round))
        }

        for hazard in hole.hazards where hazard.polygon.count >= 3 {
            let color: Color
            switch hazard.kind {
            case .bunker: color = style.sand
            case .water: color = style.water
            case .trees: color = style.rough
            case .outOfBounds: color = style.flag.opacity(0.35)
            }
            ctx.fill(path(hazard.polygon, closed: true), with: .color(color))
        }

        if hole.green.polygon.count >= 3 {
            let g = path(hole.green.polygon, closed: true)
            ctx.fill(g, with: .color(style.green))
            ctx.stroke(g, with: .color(style.ink.opacity(0.6)), lineWidth: 1.5)
        } else {
            let c = p(geo.greenCenter)
            let r = m(14)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(style.green))
        }

        // **Order within the shot layer: lines and their numbers, then the dots,
        // then the markers** *(user, 2026-08-30: "for shot marker drawings — lines
        // and line numbers first, dots next, shot #'s last")*.
        //
        // This narrows the 2026-08-28 "markers are the lowest" rule rather than
        // undoing it. A shot marker is now a numbered circle and the number is what
        // *identifies* the dot underneath it, so a track line drawn across it makes
        // the one unreadable thing on the hole the one thing the layer exists for.
        // Everything a golfer is about to **act on** — the plan, the rulers, the
        // player, the flag — is still drawn after the markers and still covers them,
        // and `hit` still tests markers last.
        //
        // Three passes rather than one loop, so the ordering holds *between* players
        // too: with one pass, the second player's line would cross the first
        // player's dots.
        drawTees(&ctx, plane: plane)

        // The tracks dim with the markers they join *(the middle state of
        // `MarkerDisplay`)*. A line at full strength between two half-visible pills
        // says the pills are the thing that has been switched off, which is not
        // what happened: the whole layer stopped taking touches.
        var trackCtx = ctx
        trackCtx.opacity = markerDisplay.opacity

        // **The marks, joined in press order, under the player tracks** *(user,
        // 2026-09-03)*. Drawn first so a player's track — shots somebody assigned a
        // number to — is never crossed by the fainter claim. It dims with the
        // markers and disappears with them, since the ids resolve against `markers`
        // and an `off` layer is sent none: "a line joining pills that are not drawn
        // is a line between nothing and nothing."
        //
        // **No number on any leg.** A player's leg earns one only when it is
        // `consecutive`, and a mark has no number at all, so "did this leg skip
        // one" is unanswerable here — a distance printed on it would state a shot
        // nobody has said was one. Solid, not dashed: dashed already means aiming,
        // proposed or pending on this screen.
        let marks = HoleMarker.line(markLine, in: markers, moving: markerDrag)
        if marks.count >= 2 {
            trackCtx.stroke(path(marks, closed: false), with: .color(style.markLineInk),
                            style: StrokeStyle(lineWidth: style.markLineWidth,
                                               lineCap: .round, lineJoin: .round))
        }

        for track in drawnTracks {
            // **No early `continue` on the shot count.** It used to skip any track
            // with fewer than two shots, which drew *nothing at all* for a player
            // with one — no line, which is right, but no dot either, which
            // contradicts "every shot gets a dot, shot 1 included" a few lines
            // down. The floorless hole-out made that case reachable in earnest: a
            // hole in one is one marker and a closing leg to the flag, and the
            // guard would have thrown both away. Each piece decides for itself.
            if track.shots.count >= 2 {
                // **Slim** *(user, 2026-08-28: "line between shot markers is too
                // thick, make it much slimmer")*. It is a trace of what happened,
                // drawn behind everything a golfer is about to act on; at 2.6 it
                // competed with the plan's own legs, which are decisions.
                trackCtx.stroke(path(track.points, closed: false), with: .color(track.color),
                           style: StrokeStyle(lineWidth: style.shotLineWidth,
                                              lineCap: .round, lineJoin: .round))
            }
            if let aiming = track.aiming, let last = track.shots.last {
                trackCtx.stroke(path([last.at, aiming], closed: false), with: .color(track.color),
                           style: StrokeStyle(lineWidth: style.shotLineWidth,
                                              lineCap: .round, dash: [7, 5]))
            }
            // **A closed-out hole runs its track into the flag** *(user,
            // 2026-08-29)*. Solid and the same weight as the rest: the shot that
            // holed out is a shot, not an inference. `pinAt` rather than the green
            // centre, because the flag is where the ball actually went and it is
            // drawn there too.
            if let close = track.closingLeg(to: pinAt) {
                trackCtx.stroke(path([close.from, close.to], closed: false),
                                with: .color(track.color),
                                style: StrokeStyle(lineWidth: style.shotLineWidth,
                                                   lineCap: .round, lineJoin: .round))
                if close.labelled {
                    legLabel(&trackCtx, from: p(close.from), to: p(close.to),
                             metres: Geodesy.distance(close.from, close.to),
                             rise: terrain?.delta(from: close.from, to: close.to),
                             color: track.color)
                }
            }
            // **Only a leg between consecutive shots carries a number** — see
            // `PlayerTrack.legs`. That leg *is* a shot and the number is how far it
            // went; a leg spanning a gap in the record measures nothing anybody
            // played. No plate behind it and a small face: it is a note about what
            // happened, not one of the distances the hole is played off, and giving
            // it the plan's treatment would say it was.
            for leg in track.legs where leg.consecutive {
                legLabel(&trackCtx, from: p(leg.from.at), to: p(leg.to.at),
                         metres: Geodesy.distance(leg.from.at, leg.to.at),
                         rise: terrain?.delta(from: leg.from.at, to: leg.to.at),
                         color: track.color)
            }
        }

        // **Pass two: the dots, over every line.** Separate from the loop above so
        // one player's line cannot be drawn across another player's dots.
        //
        // **Every shot gets a dot, shot 1 included.** The `dropFirst` that used to
        // be here skipped element 0 because element 0 was the *tee*, which draws its
        // own marker. The tee is gone, so the drop would now silently erase the
        // first shot of every player.
        for track in drawnTracks {
            for shot in track.shots {
                let q = p(shot.at)
                trackCtx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)),
                         with: .color(track.color))
                trackCtx.stroke(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)),
                           with: .color(style.roughDeep), lineWidth: 1.2)
            }
        }

        // **Pass three: the markers, over the lines and the dots.** A shot marker is
        // a numbered circle and the number identifies the dot beneath it; a line
        // across it makes the label unreadable. It stays below everything a golfer
        // is about to act on, and `hit` still tests it last.
        drawMarkers(&ctx, plane: plane)

        drawPlan(&ctx, plane: plane)
        drawMeasures(&ctx, plane: plane)
        if let focus { drawFocus(&ctx, at: p(focus)) }
        if let player {
            // The ring is a distance on the ground, so it is measured the same way
            // every other distance on this layer is: project a point `accuracy`
            // metres east and take how far that landed. **Never while simulating** —
            // a hand-placed point has no accuracy, and a ring around it would be a
            // measurement nobody took drawn like one somebody did.
            var radius: CGFloat?
            if !simulating, let accuracy, accuracy > 0 {
                let edge = p(Geodesy.coordinate(from: player, east: accuracy, north: 0))
                let at = p(player)
                radius = hypot(edge.x - at.x, edge.y - at.y)
            }
            drawPlayer(&ctx, at: p(player), accuracyRadius: radius)
        }
        // **The flag is drawn last of all, above the simulated position** *(user,
        // 2026-08-29: "simulated position is moved in z position so that it can be
        // above any other marker. pin flag is still above simulated position")*.
        //
        // It used to draw straight after the markers, which put it under the
        // player, the plan and the rulers. The order the two layers now agree on is
        // markers at the bottom, the simulated position above everything a golfer
        // *reads*, and the flag above that — so dragging a simulated ball onto the
        // green never swallows the flag it is being dragged at.
        //
        // **`hit` is deliberately not reordered to match.** The drawn-is-tested
        // rule is broken here and only here: the green is where a golfer taps to
        // place a target, which is the commonest tap on the screen, so a flag that
        // took those taps would be worse than one needing a second attempt to pick
        // up. See the comment at the end of `hit`.
        drawPin(&ctx, at: p(pinAt), moved: pin != nil)
    }

    /// The number on a track leg — one placement rule, so an ordinary leg and the
    /// closing leg into the flag cannot drift apart.
    ///
    /// **Beside the line, not on it, and not above it.** Above the midpoint is
    /// where the next shot's pill sits on a hole played straight up the screen,
    /// which is most of them — that is the "sometimes not shown" case. Offset
    /// perpendicular, so it stands off whichever way the leg runs, and **always to
    /// the left**: a pill extends to the *right* of its point, so the perpendicular
    /// that happens to point right lands the label under the next shot's caption.
    ///
    /// **The number alone** *(user, 2026-08-28: "no YD needed")*. The unit is on
    /// the big number at the top; repeating it on a footnote is noise. No plate and
    /// a small face: it is a note about what happened, not one of the distances the
    /// hole is played off, and the plan's treatment would say it was.
    private func legLabel(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                          metres: Double, rise: Double?, color: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let off: CGFloat = 15
        var n = CGPoint(x: -dy / len * off, y: dx / len * off)
        if n.x > 0 { n = CGPoint(x: -n.x, y: -n.y) }
        // The elevation suffix rides this number too *(user, 2026-08-30: "for
        // distance between shot markers")*. A leg between two markers **is** a
        // shot, so how far it climbed is as much a fact about it as how far it
        // went — and it is the one place on the hole where the plays-like figure
        // can be checked against a shot somebody actually hit.
        ctx.draw(Text(display.withPlays(metres, rise: rise))
                    // **Bigger** *(user, 2026-08-30: "make distance between shots
                    // font bigger")*. 10 points reads on a screenshot and not at
                    // arm's length in sunlight, which is where it is actually used.
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(color),
                 at: CGPoint(x: (a.x + b.x) / 2 + n.x, y: (a.y + b.y) / 2 + n.y))
    }

    // MARK: - X6 — rulers

    /// Where each measure's label sits, so drawing and hit-testing cannot drift.
    /// Same rule as `PlanLayout`: the rectangle filled is the rectangle tested.
    private func measureLabelRects(_ plane: HolePlane) -> [CGRect] {
        measures.map { m in
            let q = plane.project(m.midpoint)
            let text = display.number(m.length)
            // Monospaced digits have a fixed advance, so an arithmetic estimate is
            // exact enough to *be* the definition — `GraphicsContext.resolve` is not
            // reachable from a gesture. `PlanLayout` measures the same way.
            let w = CGFloat(text.count) * 8.0 + 16
            return CGRect(x: q.x - w / 2, y: q.y - 12, width: w, height: 24)
        }
    }

    private func measureLabelHit(_ p: CGPoint, in plane: HolePlane) -> Int? {
        measureLabelRects(plane).firstIndex { $0.insetBy(dx: -8, dy: -8).contains(p) }
    }

    private func drawMeasures(_ ctx: inout GraphicsContext, plane: HolePlane) {
        let rects = measureLabelRects(plane)
        for (i, m) in measures.enumerated() {
            // X10 — its own colour, carried on the segment, so dismissing one does
            // not recolour the others.
            let tint = HoleStyle.measureColor(m.colorIndex)
            let qa = plane.project(m.a), qb = plane.project(m.b)
            let a = CGPoint(x: qa.x, y: qa.y), b = CGPoint(x: qb.x, y: qb.y)

            var line = Path()
            line.move(to: a); line.addLine(to: b)
            ctx.stroke(line, with: .color(tint.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

            for q in [a, b] {
                // The generous grab area is drawn at a whisper, the way the target
                // handle is: findable with a thumb, not competing with the numbers.
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - style.grabRadius,
                                                y: q.y - style.grabRadius,
                                                width: style.grabRadius * 2,
                                                height: style.grabRadius * 2)),
                         with: .color(tint.opacity(0.06)))
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)),
                         with: .color(tint))
            }

            guard rects.indices.contains(i) else { continue }
            let r = rects[i]
            // The box is the ruler's drag handle *and* its dismiss control — X10.
            ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(.black.opacity(0.66)))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 6),
                       with: .color(tint.opacity(0.8)), lineWidth: 1)
            ctx.draw(Text(display.number(m.length))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(tint),
                     at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    /// The tracks as drawn **while a marker is being dragged**.
    ///
    /// *(User, 2026-08-28: "when moving marker with shot associated, line point and
    /// line should move along.")* A shot's pill and the track through it are two
    /// drawings of one row, and moving one without the other says the shot is in two
    /// places at once — which is exactly the kind of lie the "never draw a
    /// hypothesis as a fact" rule is about, one object along.
    ///
    /// **Matched by coordinate, because that is the only key there is.**
    /// `PlayerTrack.shots` is a list of points with no ids on it — it is a view
    /// type, like `HoleMarker` — and both come from the same `LogEntry`, so the
    /// dragged marker's *original* position is bit-for-bit the track point to
    /// replace. Nothing is stored: the in-flight position lives in `markerDrag` and
    /// is thrown away on release, the same as the pill's.
    private var drawnTracks: [PlayerTrack] {
        guard let d = markerDrag,
              let from = markers.first(where: { $0.id == d.id })?.at
        else { return tracks }
        return tracks.map { t in
            var t = t
            t.shots = t.shots.map { $0.at == from ? PlayerTrack.Shot(number: $0.number, at: d.at) : $0 }
            return t
        }
    }

    // MARK: - X7 — recorded entries

    /// **Drawn unlike anything the golfer aims at.** A marker is a claim about the
    /// past, the same category as `focus`; a target and a ruler are things being
    /// decided now. Same reason the focus ring is hollow and cross-haired.
    ///
    /// **One object, not two** *(X9, user 2026-08-28: "marker display: showing two
    /// items now. One item with abbreviated string")*. The icon was a chip and the
    /// text a second box under it, so a hole with several entries read as twice as
    /// many things as there were, and it was not obvious which caption belonged to
    /// which dot. Icon and text now share one pill, anchored at the position.
    private func drawMarkers(_ ctx: inout GraphicsContext, plane: HolePlane) {
        // **Half strength is the only signal that this layer has stopped
        // responding**, so it is not decoration — same argument as the simulated
        // marker's orange dashes.
        var ctx = ctx
        ctx.opacity = markerDisplay.opacity
        var placed: [CGRect] = []
        for m in markers {
            let at = markerDrag?.id == m.id ? (markerDrag?.at ?? m.at) : m.at
            let q = plane.project(at)
            let c = CGPoint(x: q.x, y: q.y)
            // The handle, drawn at a whisper — findable with a thumb, not competing
            // with the numbers. Small on purpose; see `HoleStyle.markerGrabRadius`,
            // and it reaches down past the point so the thumb has somewhere to be
            // that is not on top of the pill.
            ctx.fill(Path(roundedRect: markerHandle(at: c),
                          cornerRadius: style.markerGrabRadius),
                     with: .color(style.ink.opacity(0.05)))

            // Monospaced this is not, so the width is an estimate — but nothing
            // hit-tests the pill (the *point* is the handle), so unlike
            // `measureLabelRects` it only has to be close enough to stack by.
            let title = m.title
            let textWidth = title.isEmpty ? 0 : CGFloat(title.count) * 6.0 + 6
            // An icon only when the entry is a shot — X13. A pill with no icon
            // gives its whole width to the words.
            let iconWidth: CGFloat = m.symbol == nil ? 0 : 16
            // **A shot is a circle carrying its number and nothing else** *(user,
            // 2026-08-30: "no club icon or name. Just show shot # in circle. Color
            // is good enough to distinguish.")* The old pill read `[golfer] 1 ·
            // steve`, which states three times over what the colour and the legend
            // already say once. Same height as a pill, so the leader, the stacking
            // and the gap under the point are one set of rules rather than two.
            // A mark is a circle too — an *empty* one. Same width as a shot's
            // because it is the same object with nothing assigned to it yet, which
            // is what makes the two comparable at a glance on a busy hole.
            let w = (m.isShot || m.isMark) ? 22 : 8 + iconWidth + textWidth + 8
            // Sits **under** the point *(user, 2026-08-29: "marker display label
            // under the point")*, rather than on it — the dot the pill is a claim
            // about must not be the thing the pill covers. **Stacked downward when
            // two entries land on each other**: several logs a few paces apart is
            // the ordinary case on a green, and two captions printed on top of one
            // another are less readable than either alone. Downward, because the
            // handle now reaches up: stacking back toward the thumb would put the
            // captions under the hand that is holding one of them.
            var pill = CGRect(x: c.x - 11, y: c.y + style.markerLabelGap, width: w, height: 22)
            // **Bounded.** The pill's width is an estimate, and an underestimate on
            // a green with a dozen entries would chain rects to the top of the
            // display with leader lines trailing behind them.
            var nudges = 0
            while nudges < 4,
                  let clash = placed.first(where: { $0.intersects(pill.insetBy(dx: -2, dy: -2)) }) {
                pill.origin.y = clash.maxY + 4
                nudges += 1
            }
            placed.append(pill)

            // A shot is drawn in its player's colour, so the pill and the line
            // through it are visibly the same player's.
            let ink = m.tint ?? style.ink
            ctx.fill(Path(roundedRect: pill, cornerRadius: 11),
                     with: .color(.black.opacity(0.66)))
            if m.isMark {
                // **Empty on purpose.** A pill reading "mark" would print the same
                // word a dozen times on one hole, and the ring is the only thing on
                // the layer that says *nobody has claimed this yet* — the state the
                // Action Button leaves a row in. Everything else about it is a
                // shot marker: same slot, same handle, same tap, same drag.
                let r = style.markRadius
                ctx.stroke(Path(ellipseIn: CGRect(x: pill.midX - r, y: pill.midY - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(style.markInk), lineWidth: 1.5)
            } else if m.isShot {
                // Centred, because there is nothing else in it.
                ctx.draw(Text(title)
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundColor(ink),
                         at: CGPoint(x: pill.midX, y: pill.midY))
            } else {
                var x = pill.minX + 8
                if let symbol = m.symbol {
                    ctx.draw(Text(Image(systemName: symbol))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ink),
                             at: CGPoint(x: x + 6, y: pill.midY))
                    x += iconWidth
                }
                if !title.isEmpty {
                    ctx.draw(Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(ink),
                             at: CGPoint(x: x, y: pill.midY), anchor: .leading)
                }
            }
            // A leader up to the point when the pill was pushed off it, or the
            // caption becomes a claim about nowhere in particular.
            if pill.minY > c.y + 12 {
                var leader = Path()
                leader.move(to: CGPoint(x: c.x, y: pill.minY))
                leader.addLine(to: CGPoint(x: c.x, y: c.y + 4))
                ctx.stroke(leader, with: .color(style.ink.opacity(0.45)), lineWidth: 1)
            }
            // The point itself, so what the pill *claims* is visible under it.
            // **A mark's is bigger, and bone rather than red** *(user, 2026-09-03)*:
            // it is the only point on this layer nothing else draws — a shot's dot
            // comes from its track — and it is the thing the ring above it and the
            // line through it are both claims about.
            let dot = m.isMark ? style.markDotRadius : 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot,
                                            width: dot * 2, height: dot * 2)),
                     with: .color(m.isMark ? style.markInk : (m.tint ?? style.flag)))

            // Where it is being *asked* to go. See `pendingMarker`.
            if let pending = pendingMarker, pending.id == m.id {
                let g = plane.project(pending.at)
                let to = CGPoint(x: g.x, y: g.y)
                var tether = Path()
                tether.move(to: c); tether.addLine(to: to)
                ctx.stroke(tether, with: .color(ink.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                let r: CGFloat = 9
                ctx.stroke(Path(ellipseIn: CGRect(x: to.x - r, y: to.y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(ink), lineWidth: 2)
            }
        }
    }

    /// Where a log entry was recorded.
    ///
    /// **Drawn unlike anything else on the hole, deliberately.** It is not a shot,
    /// not a target and not where the golfer is standing now — it is a place a
    /// sentence was said, which is a claim about the past. A hollow ring with a
    /// cross-hair reads as an annotation rather than as a thing you can pick up,
    /// and nothing here responds to touch, so it must not look draggable.
    private func drawFocus(_ ctx: inout GraphicsContext, at q: CGPoint) {
        let r: CGFloat = 13
        let box = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: box.insetBy(dx: -3, dy: -3)),
                 with: .color(.black.opacity(0.28)))
        ctx.stroke(Path(ellipseIn: box), with: .color(.white), lineWidth: 3)
        ctx.stroke(Path(ellipseIn: box), with: .color(style.roughDeep), lineWidth: 1.2)
        var cross = Path()
        cross.move(to: CGPoint(x: q.x - r - 6, y: q.y)); cross.addLine(to: CGPoint(x: q.x - 4, y: q.y))
        cross.move(to: CGPoint(x: q.x + 4, y: q.y)); cross.addLine(to: CGPoint(x: q.x + r + 6, y: q.y))
        cross.move(to: CGPoint(x: q.x, y: q.y - r - 6)); cross.addLine(to: CGPoint(x: q.x, y: q.y - 4))
        cross.move(to: CGPoint(x: q.x, y: q.y + 4)); cross.addLine(to: CGPoint(x: q.x, y: q.y + r + 6))
        ctx.stroke(cross, with: .color(.white), lineWidth: 2.4)
    }

    /// Every tee on the hole, in its own colour, with the chosen one at full
    /// strength. Choosing a tee should be something you can *see* on the hole, not
    /// just a word in a menu — and drawing only the chosen one hid the fact that
    /// there was a choice at all.
    private func drawTees(_ ctx: inout GraphicsContext, plane: HolePlane) {
        let colors = TeePalette.colors(for: hole.tees, greenCenter: hole.green.center)
        // Back to front, so the forward tees sit on top where they overlap.
        for t in TeePalette.ordering(hole.tees, greenCenter: hole.green.center) {
            guard let at = t.at else { continue }
            let q = plane.project(at)
            let selected = t.name == tee.name
            let fill = colors[t.name] ?? style.ink
            let w: CGFloat = selected ? 22 : 15
            let h: CGFloat = selected ? 10 : 7
            let rect = CGRect(x: q.x - w / 2, y: q.y - h / 2, width: w, height: h)
            let shape = Path(roundedRect: rect, cornerRadius: h / 2)
            ctx.fill(shape, with: .color(fill.opacity(selected ? 1 : 0.4)))
            ctx.stroke(shape, with: .color(TeePalette.outline(for: fill)
                .opacity(selected ? 1 : 0.35)),
                       lineWidth: selected ? 1.6 : 1)
        }
    }

    /// Where the flag is: today's, or the middle of the green when nobody has said.
    private var pinAt: Coordinate { pinDrag ?? pin ?? geo.greenCenter }

    /// The flag's handle. **Reaches up from the point**, because that is where the
    /// flag is drawn — the mirror of the marker handle, which reaches down because
    /// its pill is above. Narrow: it sits on the green, where taps place targets.
    private func pinHandle(at c: CGPoint) -> CGRect {
        CGRect(x: c.x - 14, y: c.y - 28, width: 28, height: 36)
    }

    private func drawPin(_ ctx: inout GraphicsContext, at pin: CGPoint,
                         moved: Bool = false) {
        // The handle at a whisper, the same as every other one here.
        ctx.fill(Path(roundedRect: pinHandle(at: pin), cornerRadius: 8),
                 with: .color(style.ink.opacity(moved ? 0.07 : 0.04)))
        var flag = Path()
        flag.move(to: pin)
        flag.addLine(to: CGPoint(x: pin.x, y: pin.y - 22))
        ctx.stroke(flag, with: .color(style.ink), lineWidth: 1.8)
        var cloth = Path()
        cloth.move(to: CGPoint(x: pin.x, y: pin.y - 22))
        cloth.addLine(to: CGPoint(x: pin.x + 13, y: pin.y - 17))
        cloth.addLine(to: CGPoint(x: pin.x, y: pin.y - 12))
        cloth.closeSubpath()
        ctx.fill(cloth, with: .color(style.flag))
        ctx.fill(Path(ellipseIn: CGRect(x: pin.x - 2.5, y: pin.y - 2.5, width: 5, height: 5)),
                 with: .color(style.roughDeep))
    }

    /// The plan: origin → target → target → pin, each leg drawn and each target
    /// numbered. No app in the category chains two targets
    /// (research-course-display.md §9.3), so there is no prior art to copy — the
    /// numbering exists so "240 then 165" is readable at a glance rather than
    /// inferred from which ring is nearer.
    private func drawPlan(_ ctx: inout GraphicsContext, plane: HolePlane) {
        guard let readout, readout.hasTargets else { return }
        func p(_ c: Coordinate) -> CGPoint {
            let q = plane.project(c); return CGPoint(x: q.x, y: q.y)
        }

        for leg in readout.legs {
            var line = Path()
            line.move(to: p(leg.from))
            line.addLine(to: p(leg.to))
            let toGreen = leg.kind == .toGreen
            ctx.stroke(line, with: .color(style.target.opacity(toGreen ? 0.5 : 0.85)),
                       style: StrokeStyle(lineWidth: toGreen ? 1.4 : 2,
                                          lineCap: .round,
                                          dash: toGreen ? [4, 5] : []))
        }

        // The ring is **dim**: it marks the spot, and the distance box beside it is
        // both the thing that is read and the thing that is dragged. A bright ring
        // competed with the numbers for attention and won.
        for (i, t) in readout.targets.enumerated() {
            let q = p(t)
            // The handle, barely there: enough to find with a thumb, not enough to
            // compete with the numbers.
            // Area only, no edge: an outline reads as a thing in its own right and
            // starts competing with the ring it is meant to sit behind.
            let g = style.grabRadius
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - g, y: q.y - g, width: g * 2, height: g * 2)),
                     with: .color(style.target.opacity(0.07)))

            let r = Self.targetRadius
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)),
                       with: .color(style.target.opacity(0.22)), lineWidth: 1.2)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)),
                     with: .color(style.target.opacity(0.5)))
            if readout.targets.count > 1 {
                ctx.draw(Text("\(i + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(style.target.opacity(0.6)),
                         at: CGPoint(x: q.x + 22, y: q.y - 14))
            }
        }

        for label in planLabels(plane) { drawLegLabel(&ctx, label) }
    }

    /// The box. Positioned by `PlanLayout` — the same call the gesture hit-tests
    /// against, so what is drawn and what is grabbable cannot drift apart.
    private func drawLegLabel(_ ctx: inout GraphicsContext, _ label: PlanLayout.Label) {
        var text = Text(label.main)
            .font(.system(size: PlanLayout.mainSize, weight: .bold, design: .monospaced))
            .foregroundStyle(style.ink)
        if let sub = label.sub {
            text = text + Text("\n" + sub)
                .font(.system(size: PlanLayout.subSize, weight: .medium, design: .monospaced))
                .foregroundStyle(style.ink.opacity(0.75))
        }
        let box = label.rect
        ctx.fill(Path(roundedRect: box, cornerRadius: 7), with: .color(.black.opacity(0.35)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 7),
                   with: .color(style.target.opacity(0.3)), lineWidth: 1)
        ctx.draw(ctx.resolve(text), at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    /// Where the phone is — or, in simulation, where it is pretending to be.
    ///
    /// **The two must never look alike.** A hand-dragged position that renders as a
    /// GPS fix is worse than no simulation at all: every number on the screen is
    /// then a plausible lie with nothing marking it as one.
    /// - Parameter accuracyRadius: the fix's accuracy **already projected into
    ///   points**, because the projection lives at the call site and a second copy
    ///   of it here is a second answer that can disagree with the screen.
    private func drawPlayer(_ ctx: inout GraphicsContext, at q: CGPoint,
                            accuracyRadius: CGFloat?) {
        if simulating {
            let g = style.grabRadius
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - g, y: q.y - g, width: g * 2, height: g * 2)),
                     with: .color(Color.orange.opacity(0.06)))
        }
        if simulating {
            let r = CGRect(x: q.x - 13, y: q.y - 13, width: 26, height: 26)
            ctx.fill(Path(ellipseIn: r), with: .color(style.roughDeep.opacity(0.85)))
            ctx.stroke(Path(ellipseIn: r), with: .color(Color.orange),
                       style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            ctx.draw(Text(Image(systemName: "figure.golf"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.orange), at: q)
        } else {
            // Dimmed when the numbers are *not* measured from here — the golfer is
            // off this hole, and the marker is orientation rather than a reading.
            let a = measuringFromPlayer ? 1.0 : 0.45
            // **The accuracy ring is in metres, so it is measured through the
            // plane** — a fixed number of points would be right at the fitted zoom
            // and a lie at every other, and this layer now goes to 40×. Projected
            // rather than derived from `scale`, because the projection is the one
            // thing that cannot disagree with what is on screen.
            if let r = accuracyRadius {
                // Below the dot it says nothing and draws a smudge; a 3 m fix on a
                // fitted hole is about two points across.
                if r > 12 {
                    let box = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: box), with: .color(style.ink.opacity(0.07 * a)))
                    ctx.stroke(Path(ellipseIn: box),
                               with: .color(style.ink.opacity(0.30 * a)), lineWidth: 1)
                }
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 11, y: q.y - 11, width: 22, height: 22)),
                       with: .color(style.ink.opacity(0.55 * a)), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4.5, y: q.y - 4.5, width: 9, height: 9)),
                     with: .color(style.ink.opacity(a)))
        }
    }
}
#endif
