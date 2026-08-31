#if canImport(MapKit) && canImport(SwiftUI)
import SwiftUI
import MapKit
import GolfCourse

@available(iOS 17, macOS 14, *)
extension Coordinate {
    var clLocation: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

@available(iOS 17, macOS 14, *)
extension CLLocationCoordinate2D {
    var asCoordinate: Coordinate { Coordinate(lat: latitude, lon: longitude) }
}

/// The same hole with Apple's aerial imagery under it.
///
/// **Optional by design.** MapKit is free and keyless, and fetch-at-display with
/// MapKit doing its own caching is the supported use — but nothing here may be
/// relied on off-network, and nothing may deliberately persist a tile (no
/// `MKMapSnapshotter` writing PNGs, no camera sweep to warm the cache). The imagery
/// is a layer the golfer turns on when there is signal, and `VectorHoleView` is
/// what carries every number they act on. Never make this the only renderer.
@available(iOS 17, macOS 14, *)
public struct SatelliteHoleView: View {
    /// Resolved geometry, for the same reason `VectorHoleView` takes it: a hole with
    /// no coordinates has nothing to put a camera on.
    public let geo: HoleGeometry
    public var hole: Hole { geo.hole }
    public var tee: TeeBox { geo.tee }
    public var style = HoleStyle()
    public var readout: HoleReadout?
    /// See `VectorHoleView.terrain` — the shot-marker legs only.
    public var terrain: Elevation?
    public var tracks: [PlayerTrack] = []
    public var simulating = false
    public var display = DistanceDisplay.default
    /// How far back the camera sits, as a multiple of hole length.
    ///
    /// `MapCamera.distance` is camera-to-ground, not the span it shows — a 380 m
    /// hole at distance 380 fills only about a third of the screen. Measured against
    /// the simulator: visible span ≈ 0.42 × distance, so fitting a hole plus margin
    /// needs roughly 3×. Tuned so a par 3 and a par 5 both fit.
    public var framing: Double = 4.2

    /// How much of the bottom of the screen the HUD occupies, in points.
    ///
    /// **This is Apple's attribution reserve, not padding.** The logo and the Legal
    /// link are a licence requirement that private use does not excuse, and
    /// `mapControlVisibility(.hidden)` hides the compass and scale rather than them.
    /// The HUD is drawn *over* this view, so the map's ornaments are pushed clear of
    /// whatever the HUD's real height is — and that height changes when `HoleScreen`
    /// is given a bottom bar. A constant would go stale the moment it does.
    public var bottomReserve: CGFloat = 110

    /// X6 / X7 — the same two layers the vector renderer draws, so a tool works on
    /// whichever layer the golfer happens to be on. A button that does something on
    /// one layer and nothing on the other is the failure this codebase already has
    /// a rule about: a control that appears not to work is indistinguishable from
    /// one that does not.
    public var measures: [MeasureSegment] = []
    public var onMoveMeasure: ((Int, MeasureSegment.End, Coordinate) -> Void)?
    /// The whole ruler dragged by its distance box — X10.
    public var onCenterMeasure: ((Int, Coordinate) -> Void)?
    public var onTapMeasure: ((Int) -> Void)?
    public var markers: [HoleMarker] = []
    /// What the markers layer is doing — see `MarkerDisplay`.
    public var markerDisplay: MarkerDisplay = .on
    /// What ground is on screen, reported back out. Here it is MapKit's own camera
    /// region rather than a `HolePlane`; see `GroundView`.
    @Binding public var ground: GroundView?
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
    /// and draggable. See `Event.Kind.pin`.
    public var pin: Coordinate?
    public var onMovePin: ((Coordinate) -> Void)?
    public var onMoveMarker: ((String, Coordinate) -> Void)?
    /// A tap that landed on a marker — X13. The app opens its dialog.
    public var onTapMarker: ((String) -> Void)?

    public var onTapGround: ((Coordinate) -> Void)?
    public var onTapTarget: ((Int) -> Void)?
    public var onMoveTarget: ((Int, Coordinate) -> Void)?
    public var onMovePlayer: ((Coordinate) -> Void)?

    @State private var camera: MapCameraPosition = .automatic
    /// The proxy is captured so the draggable annotations can convert their own
    /// touches. Annotations sit inside `Map`'s content builder, which is not a view
    /// hierarchy `MapReader` reaches into.
    @State private var proxyBox: MapProxy?
    /// Geographic offset from the finger to the centre of whatever it grabbed, held
    /// for the whole drag. Without it the object teleports to the fingertip on the
    /// first event — which is placing, not dragging.
    @State private var dragOffset: (dLat: Double, dLon: Double)?
    /// Where a marker is being dragged right now — X9. Reported once, on release,
    /// and cleared there; see `VectorHoleView.markerDrag` for why.
    /// The flag's in-flight position while a finger is on it.
    ///
    /// **Held here and reported once, on release** — the same split as
    /// `markerDrag`, and for a blunter reason: `onMovePin` *writes an event*, so
    /// reporting from `onChanged` appends a row per gesture callback and one
    /// two-second adjustment leaves a hundred `pin placed` lines in the round's
    /// event stream. Drawing continuously and persisting once are different jobs.
    @State private var pinDrag: Coordinate?
    @State private var markerDrag: (id: String, at: Coordinate)?


    /// The fix's horizontal accuracy in **metres**, drawn as a `MapCircle` around
    /// the position *(user, 2026-08-30)*. Nil while simulating — a hand-placed
    /// point has no accuracy, and a ring around one would read as a measurement.
    public var accuracy: Double?

    /// A one-shot "put this coordinate in the middle of the screen".
    ///
    /// **This layer had none, which is the whole of "go to my location doesn't go
    /// to my location"** *(user, 2026-08-30)*. `HoleScreen` has driven `centerOn`
    /// since the button existed and only `VectorHoleView` ever read it, so on
    /// satellite the menu item did nothing at all — and it does nothing *silently*,
    /// which reads as the app not knowing where the phone is.
    @Binding public var centerOn: Coordinate?

    /// The camera's current distance, so `centerOn` can move the camera without
    /// also changing the zoom the golfer set. Seeded from the framed camera.
    @State private var cameraDistance: Double?

    public init(geometry: HoleGeometry, style: HoleStyle = HoleStyle(),
                readout: HoleReadout? = nil, terrain: Elevation? = nil,
                tracks: [PlayerTrack] = [],
                simulating: Bool = false, accuracy: Double? = nil,
                display: DistanceDisplay = .default,
                centerOn: Binding<Coordinate?> = .constant(nil),
                framing: Double = 4.2, bottomReserve: CGFloat = 110,
                measures: [MeasureSegment] = [],
                onMoveMeasure: ((Int, MeasureSegment.End, Coordinate) -> Void)? = nil,
                onCenterMeasure: ((Int, Coordinate) -> Void)? = nil,
                onTapMeasure: ((Int) -> Void)? = nil,
                markers: [HoleMarker] = [],
                markerDisplay: MarkerDisplay = .on,
                ground: Binding<GroundView?> = .constant(nil),
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
        self.accuracy = accuracy
        self._centerOn = centerOn
        self.simulating = simulating
        self.display = display
        self.framing = framing
        self.bottomReserve = bottomReserve
        self.measures = measures
        self.onMoveMeasure = onMoveMeasure
        self.onCenterMeasure = onCenterMeasure
        self.onTapMeasure = onTapMeasure
        self.markers = markers
        self.markerDisplay = markerDisplay
        self._ground = ground
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

    /// Nil for a hole with no coordinates.
    public init?(hole: Hole, tee: TeeBox? = nil, style: HoleStyle = HoleStyle(),
                 readout: HoleReadout? = nil, tracks: [PlayerTrack] = [],
                 framing: Double = 4.2) {
        guard let g = hole.geometry(tee: tee) else { return nil }
        self.init(geometry: g, style: style, readout: readout, tracks: tracks, framing: framing)
    }

    /// Where the phone is, whatever the numbers measure from — see
    /// `HoleReadout.playerAt`.
    private var player: Coordinate? { readout?.playerAt }
    private var targets: [Coordinate] { readout?.targets ?? [] }

    /// Tee at the bottom, green at the top — the same orientation the vector view
    /// uses, so switching layers does not re-orient the golfer.
    private var framedCamera: MapCameraPosition {
        let t = geo.teeAt, g = geo.greenCenter
        // Biased past the midpoint toward the green: the HUD covers more of the top
        // of the screen than the bottom now that the numbers moved up there.
        let f = 0.46
        let mid = Coordinate(lat: t.lat + (g.lat - t.lat) * f,
                             lon: t.lon + (g.lon - t.lon) * f)
        let length = max(80, geo.length)
        return .camera(MapCamera(centerCoordinate: mid.clLocation,
                                 distance: length * framing,
                                 heading: geo.bearing,
                                 pitch: 0))
    }

    public var body: some View {
        MapReader { proxy in
            ZStack {
            map
                .onAppear { proxyBox = proxy }
                // An interrupted drag never reaches `onEnded` — a sheet comes up, or
                // the log store refreshes the list mid-gesture — and the pill would
                // stay parked at a coordinate no row records, which looks exactly
                // like a move that succeeded. Same rule as never drawing a
                // hypothesis as a fact.
                .onChange(of: markers) { markerDrag = nil }
                .onChange(of: pin) { pinDrag = nil }
                // Tap places target 1 — the same rule as the vector layer. The two
                // layers must not differ in what they can do, or switching becomes
                // a downgrade. `MapProxy.convert` is the satellite equivalent of
                // `HolePlane.unproject`. **There is no hold**: X6 gave target 2 a
                // button, and the `onLongPressGesture` that stayed behind was a
                // no-op that swallowed every long press on the map.
                //
                // Moving a marker is handled by the marker's own annotation view
                // rather than here: a drag on this surface is MapKit's pan, and
                // taking it over would cost the map the gesture it exists for.
                .onTapGesture(coordinateSpace: .local) { location in
                    guard let c = proxy.convert(location, from: .local)?.asCoordinate
                    else { return }
                    onTapGround?(c)
                }
            }
        }
    }

    /// The simulated position's marker, **inside the map as an annotation**
    /// *(reverted 2026-08-29 on the user's word: "revert it was about layering it —
    /// current layering it is broken")*.
    ///
    /// It spent a day as an overlay in the `ZStack` above the whole map, positioned
    /// through `MapProxy.convert`, so that it would win the touch outright. That
    /// placement is broken: the overlay is outside the map's own content, so it does
    /// not move with the camera the way everything it sits among does — it is
    /// re-positioned only when the view body re-evaluates, which is not every frame
    /// of a pan. **A marker that lags the ground it claims to be on is worse than
    /// one that is hard to pick up.**
    ///
    /// So it is an annotation again, declared **last** in the map's content. That is
    /// not a guarantee — MapKit decides annotation stacking for itself, which is why
    /// the overlay was tried — but it is the placement that stays glued to its
    /// coordinate, and that is the property this marker cannot do without.
    @ViewBuilder
    private var simulatedMarker: some View {
        ZStack {
            // Drawn at a whisper, because **a control that is invisible is
            // indistinguishable from one that does not work** — the same reason the
            // marker handle is drawn at 5%.
            Circle().fill(Color.orange.opacity(0.06))
            playerMarker
        }
        // The same generous handle the vector layer gives it, and the same one a
        // target gets: this is a thing that exists to be dragged.
        .frame(width: style.grabRadius * 2, height: style.grabRadius * 2)
        .contentShape(Circle())
        .gesture(DragGesture(coordinateSpace: .global)
            .onChanged { v in
                guard onMovePlayer != nil, let player, let p = proxyBox else { return }
                // `DragAnchor` in degrees, the same rule everything draggable on
                // this layer follows.
                if dragOffset == nil {
                    guard let s = p.convert(v.startLocation, from: .global)?.asCoordinate
                    else { return }
                    dragOffset = (player.lat - s.lat, player.lon - s.lon)
                }
                guard let c = p.convert(v.location, from: .global)?.asCoordinate,
                      let off = dragOffset else { return }
                onMovePlayer?(Coordinate(lat: c.lat + off.dLat,
                                         lon: c.lon + off.dLon))
            }
            .onEnded { _ in dragOffset = nil })
    }

    private var map: some View {
        // **`minimumDistance` is what lets a pinch keep going** *(user, 2026-08-29:
        // "in gps hole view (satellite), I want to zoom in much more with pinch")*.
        // The 40× work was the *vector* layer's `HolePlane`; MapKit has its own
        // camera and its own floor, and nothing in that change touched this one.
        // 12 metres of camera distance is a green filling the screen — past where
        // the imagery has detail left, which is the honest limit: the tiles blur
        // and the vector overlays stay sharp, which is what they are for.
        Map(position: $camera,
            bounds: MapCameraBounds(minimumDistance: 12, maximumDistance: 40_000),
            interactionModes: [.pan, .zoom]) {
            if hole.fairway.count >= 3 {
                MapPolygon(coordinates: hole.fairway.map(\.clLocation))
                    .foregroundStyle(style.fairway.opacity(0.28))
                    .stroke(style.fairway.opacity(0.7), lineWidth: 1)
            } else if hole.line.count >= 2 {
                MapPolyline(coordinates: hole.line.map(\.clLocation))
                    .stroke(style.ink.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }

            cartPathOverlays

            ForEach(Array(hole.hazards.enumerated()), id: \.offset) { _, hazard in
                MapPolygon(coordinates: hazard.polygon.map(\.clLocation))
                    .foregroundStyle((hazard.kind == .water ? style.water : style.sand)
                        .opacity(0.45))
                    .stroke(style.ink.opacity(0.5), lineWidth: 1)
            }

            if hole.green.polygon.count >= 3 {
                MapPolygon(coordinates: hole.green.polygon.map(\.clLocation))
                    .foregroundStyle(style.green.opacity(0.32))
                    .stroke(style.ink.opacity(0.85), lineWidth: 2)
            }

            // **Order, bottom to top: tees, track lines and their numbers, shot
            // dots, then the markers** *(user, 2026-08-30: "for shot marker
            // drawings — lines and line numbers first, dots next, shot #'s last")*.
            //
            // This reverses the 2026-08-28 "markers are the lowest" rule **for the
            // tracks only**: a shot's numbered circle is now above the line and the
            // dot it belongs to, because the number is what identifies the dot and
            // a line drawn over it makes it unreadable. Everything a golfer is about
            // to *act on* — the plan, the rulers, the player, the flag — is still
            // declared after the markers and stays above them.
            //
            // MapKit draws every `Annotation` above every `MapPolyline`/`MapPolygon`
            // whatever the declaration order, so the *lines* were always under the
            // pills; what this fixes is the leg numbers and the shot dots, which are
            // annotations too. And a pill carries its own `DragGesture` on a
            // `contentShape`, so it takes a touch outright — declaration order fixes
            // what is drawn, never what is picked up.
            teeMarkers
            trackOverlays
            markerOverlays
            planOverlays
            measureOverlays

            // **The accuracy ring** *(user, 2026-08-30: "current gps location
            // marker's outside circle should show current estimated radius")*. A
            // `MapCircle` takes a radius in metres and stays the right size at every
            // zoom, which is the whole point — a fixed-point ring would be honest at
            // one camera distance and a lie at all the others. Never while
            // simulating: `accuracy` is nil there by contract and the guard says so
            // again, because a ring around a hand-placed point is a measurement
            // nobody took drawn like one somebody did.
            if !simulating, let accuracy, accuracy > 0, let at = player {
                MapCircle(center: at.clLocation, radius: accuracy)
                    .foregroundStyle(style.ink.opacity(0.10))
                    .stroke(style.ink.opacity(0.35), lineWidth: 1)
            }
            // **The position, then the flag, in plain declaration order** *(user,
            // 2026-08-30: "revert simulate marker z-order changes")*.
            //
            // Three attempts at forcing the simulated marker above the marker pills
            // have now been reverted — a `ZStack` overlay above the map (which
            // stopped tracking the camera through a pan), a token-keyed `ForEach`
            // that re-added both annotations to exploit add-order, and a rule that
            // ghosted pills near the simulated position. **None of it is here any
            // more.** The standing facts, so this is not attempted a fourth time
            // without new information: `_MapKit_SwiftUI` has **no z-order API for an
            // `Annotation`** (checked against the iOS 26.5 interface —
            // `mapOverlayLevel` is overlays only), MapKit decides annotation
            // stacking for itself, and a pill's own `DragGesture` takes the touch
            // whatever is painted on top. The vector layer orders both drawing and
            // hit-testing explicitly and is unaffected.
            if let at = player {
                Annotation("You", coordinate: at.clLocation) {
                    if simulating { simulatedMarker } else { playerMarker }
                }
                .annotationTitles(.hidden)
            }
            // The flag goes on last — the same order the vector layer draws in.
            // **Anchored at the foot of the staff** — `Self.flagFoot`, measured
            // from the glyph rather than guessed at a corner.
            Annotation("Hole \(hole.ref)", coordinate: pinAt.clLocation,
                       anchor: Self.flagFoot) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(style.flag)
                        .shadow(radius: 2)
                        // **No padding around the glyph.** `flagFoot` is a fraction
                        // of the *rendered box*, so padding it moves the foot off
                        // the point by however much was added. The touch target is
                        // the glyph itself, which at 15pt bold is about 20 points
                        // square.
                        .contentShape(Rectangle())
                        .gesture(DragGesture(coordinateSpace: .global)
                            .onChanged { v in
                                guard onMovePin != nil, let p = proxyBox else { return }
                                // The `DragAnchor` rule, in degrees — the same one
                                // the player marker and the targets follow here.
                                if dragOffset == nil {
                                    guard let s = p.convert(v.startLocation, from: .global)?.asCoordinate
                                    else { return }
                                    let at = pin ?? geo.greenCenter
                                    dragOffset = (at.lat - s.lat, at.lon - s.lon)
                                }
                                guard let c = p.convert(v.location, from: .global)?.asCoordinate,
                                      let off = dragOffset else { return }
                                pinDrag = Coordinate(lat: c.lat + off.dLat,
                                                     lon: c.lon + off.dLon)
                            }
                            .onEnded { _ in
                                // One event per drag — see `pinDrag`.
                                if let at = pinDrag { onMovePin?(at) }
                                pinDrag = nil
                                dragOffset = nil
                            })
            }
            .annotationTitles(.hidden)
        }
        // Realistic elevation is the point in Korea: the February 2026 map-export
        // approval excludes contour data, so terrain relief here is Apple's own.
        .mapStyle(.imagery(elevation: .realistic))
        .mapControlVisibility(.hidden)
        // Apple's logo and Legal link are an attribution requirement that private
        // use does not excuse, and `mapControlVisibility(.hidden)` does not hide
        // them — it hides the compass and scale. The HUD sits over this view, so the
        // map's own ornaments are pushed clear of it rather than covered.
        .safeAreaPadding(.bottom, bottomReserve)
        .onAppear { camera = framedCamera }
        .onChange(of: hole.ref) { camera = framedCamera }
        .onChange(of: tee.name) { camera = framedCamera }
        // **Go to my location, on this layer at last.** It pans and leaves the zoom
        // alone: the golfer chose that zoom, and re-framing on the way to a position
        // would answer a question nobody asked. The target is the phone's *actual*
        // position — `HoleReadout.playerAt`, never `origin`, which falls back to the
        // tee — so it works in precisely the case the button exists for, standing
        // somewhere that is not this hole.
        .onChange(of: centerOn) { _, target in
            guard let target else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                camera = .camera(MapCamera(centerCoordinate: target.clLocation,
                                           distance: cameraDistance
                                               ?? max(80, geo.length) * framing,
                                           heading: geo.bearing, pitch: 0))
            }
            // Next turn, not inside this handler — see the same note on the vector
            // layer. Writing the binding back from within its own `onChange` is a
            // self-referential update and a reported `AttributeGraph` cycle shape.
            Task { @MainActor in centerOn = nil }
        }
        // What is on screen, for whoever needs to know whether the tee is —
        // `GroundView`. MapKit hands the region straight over, and this layer does
        // not rotate (`interactionModes` is pan and zoom), so the quad is the box.
        .onMapCameraChange(frequency: .onEnd) { ctx in
            cameraDistance = ctx.camera.distance
            let r = ctx.region
            let n = r.center.latitude + r.span.latitudeDelta / 2
            let s = r.center.latitude - r.span.latitudeDelta / 2
            let w = r.center.longitude - r.span.longitudeDelta / 2
            let e = r.center.longitude + r.span.longitudeDelta / 2
            ground = GroundView(center: Coordinate(lat: r.center.latitude,
                                                   lon: r.center.longitude),
                                corners: [Coordinate(lat: n, lon: w), Coordinate(lat: n, lon: e),
                                          Coordinate(lat: s, lon: e), Coordinate(lat: s, lon: w)])
        }
    }

    /// Cart paths, drawn faint.
    ///
    /// Redundant while the photograph is up — the paths are *in* the imagery — and
    /// that is exactly why they are here: nothing on this screen may depend on the
    /// imagery having loaded, and a course with no signal keeps them. A hairline, so
    /// that when both layers are present they never compete with the numbers.
    @MapContentBuilder
    private var cartPathOverlays: some MapContent {
        ForEach(Array(hole.paths.enumerated()), id: \.offset) { _, track in
            MapPolyline(coordinates: track.map(\.clLocation))
                .stroke(style.cartPath.opacity(0.5), lineWidth: 1.5)
        }
    }

    /// Every tee in its own colour, chosen one at full strength — the same rule the
    /// vector layer draws by, so a tee is the same colour on both.
    @MapContentBuilder
    private var teeMarkers: some MapContent {
        let colors = TeePalette.colors(for: hole.tees, greenCenter: hole.green.center)
        ForEach(hole.tees.filter { $0.at != nil }) { t in
            Annotation(t.name, coordinate: t.at!.clLocation) {
                let selected = t.name == tee.name
                let fill = colors[t.name] ?? style.ink
                RoundedRectangle(cornerRadius: selected ? 5 : 3.5)
                    .fill(fill.opacity(selected ? 1 : 0.45))
                    .overlay(RoundedRectangle(cornerRadius: selected ? 5 : 3.5)
                        .stroke(TeePalette.outline(for: fill).opacity(selected ? 1 : 0.4),
                                lineWidth: selected ? 1.6 : 1))
                    .frame(width: selected ? 22 : 15, height: selected ? 10 : 7)
                    .shadow(radius: 2)
            }
            .annotationTitles(.hidden)
        }
    }

    /// Where the flag is: the one being dragged, else today's, else the green's
    /// centre. The same expression the vector layer calls `pinAt`, named the same
    /// so the two cannot quietly diverge.
    var pinAt: Coordinate { pinDrag ?? pin ?? geo.greenCenter }

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

    @MapContentBuilder
    private var trackOverlays: some MapContent {
        ForEach(drawnTracks) { track in
            if track.shots.count >= 2 {
                // Slim — see the vector layer; the two must not differ in weight or
                // switching layer reads as the track meaning something else.
                MapPolyline(coordinates: track.points.map(\.clLocation))
                    .stroke(track.color.opacity(markerDisplay.opacity),
                            style: StrokeStyle(lineWidth: style.shotLineWidth,
                                               lineCap: .round))
            }
            if let aiming = track.aiming, let last = track.shots.last {
                MapPolyline(coordinates: [last.at.clLocation, aiming.clLocation])
                    .stroke(track.color.opacity(markerDisplay.opacity),
                            style: StrokeStyle(lineWidth: style.shotLineWidth,
                                               dash: [7, 5]))
            }
            // **A closed-out hole runs its track into the flag** — see the vector
            // layer, which draws the same leg the same weight. The shot that holed
            // out is a shot.
            if let close = track.closingLeg(to: pinAt) {
                MapPolyline(coordinates: [close.from.clLocation, close.to.clLocation])
                    .stroke(track.color.opacity(markerDisplay.opacity),
                            style: StrokeStyle(lineWidth: style.shotLineWidth,
                                               lineCap: .round))
                if close.labelled {
                    Annotation("", coordinate: Geodesy.interpolate(close.from, close.to, 0.5)
                                                .clLocation) {
                        Text(display.withPlays(Geodesy.distance(close.from, close.to),
                                               rise: terrain?.delta(from: close.from,
                                                                    to: close.to)))
                            // **Bigger** *(user, 2026-08-30: "make distance between
                            // shots font bigger")*. It was 10 — legible on a
                            // screenshot and not at arm's length in sunlight.
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(track.color)
                            .shadow(radius: 2)
                            .opacity(markerDisplay.opacity)
                    }
                    .annotationTitles(.hidden)
                }
            }
            // Only a leg between consecutive shots. No plate, small face — same
            // rule as the vector layer.
            ForEach(Array(track.legs.filter(\.consecutive).enumerated()), id: \.offset) { _, leg in
                Annotation("", coordinate: Geodesy.interpolate(leg.from.at, leg.to.at, 0.5)
                                            .clLocation) {
                    Text(display.withPlays(Geodesy.distance(leg.from.at, leg.to.at),
                                           rise: terrain?.delta(from: leg.from.at,
                                                                to: leg.to.at)))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(track.color)
                        .shadow(radius: 2)
                        .opacity(markerDisplay.opacity)
                }
                .annotationTitles(.hidden)
            }
            // Shot 1 included — the `dropFirst` here skipped the prepended tee,
            // and the tee is gone.
            ForEach(Array(track.shots.enumerated()), id: \.offset) { _, shot in
                Annotation("", coordinate: shot.at.clLocation) {
                    Circle().fill(track.color)
                        .overlay(Circle().stroke(style.roughDeep, lineWidth: 1.2))
                        .frame(width: 11, height: 11)
                        .opacity(markerDisplay.opacity)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    /// X6 — rulers. Ends drag on themselves, so a drag anywhere else is still
    /// MapKit's pan; the label is the dismiss control, the same as on vector.
    @MapContentBuilder
    private var measureOverlays: some MapContent {
        ForEach(Array(measures.enumerated()), id: \.element.id) { i, m in
            MapPolyline(coordinates: [m.a.clLocation, m.b.clLocation])
                .stroke(HoleStyle.measureColor(m.colorIndex).opacity(0.9),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
        ForEach(Array(measures.enumerated()), id: \.element.id) { i, m in
            Annotation("", coordinate: m.midpoint.clLocation) {
                let tint = HoleStyle.measureColor(m.colorIndex)
                Text(display.number(m.length))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(0.8), lineWidth: 1))
                    .contentShape(Rectangle())
                    // **The box drags the whole ruler and dismisses it, from one
                    // gesture** — X10. A `DragGesture` beside an `onTapGesture`
                    // looked simpler and is wrong: a slow short drag can activate
                    // the drag *and* still deliver the tap on release, so the ruler
                    // you just moved is dismissed. The vector layer decides tap
                    // versus move on release from how far the finger went, and the
                    // two layers must not differ in what a finger does.
                    // The translation is rigid, so the number never changes width
                    // under the thumb.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            guard hypot(v.translation.width, v.translation.height) > 10,
                                  let p = proxyBox,
                                  let c = p.convert(v.location, from: .global)?.asCoordinate
                            else { return }
                            onCenterMeasure?(i, c)
                        }
                        .onEnded { v in
                            if hypot(v.translation.width, v.translation.height) <= 10 {
                                onTapMeasure?(i)
                            }
                        })
            }
            .annotationTitles(.hidden)
        }
        ForEach(Array(measures.enumerated()), id: \.element.id) { i, m in
            ForEach([MeasureSegment.End.a, .b], id: \.self) { end in
                Annotation("", coordinate: (end == .a ? m.a : m.b).clLocation) {
                    ZStack {
                        Circle().fill(HoleStyle.measureColor(m.colorIndex).opacity(0.06))
                            .frame(width: style.grabRadius * 2, height: style.grabRadius * 2)
                        Circle().fill(HoleStyle.measureColor(m.colorIndex))
                            .frame(width: 12, height: 12)
                    }
                    .contentShape(Circle())
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in
                            guard let p = proxyBox,
                                  let c = p.convert(v.location, from: .global)?.asCoordinate
                            else { return }
                            onMoveMeasure?(i, end, c)
                        })
                }
                .annotationTitles(.hidden)
            }
        }
    }

    /// X7 — recorded entries, icon and abbreviated text, draggable.
    ///
    /// **One pill, and a handle no bigger than it** *(X9)*. The icon chip and the
    /// caption used to be two stacked boxes wrapped in a 39-point grab circle, so a
    /// hole with several entries read as twice as many objects as it had and each
    /// one blanketed the map around it — on this layer that circle is a view, so it
    /// takes the touch outright and MapKit never sees the pan.
    /// The pill's height, fixed so `markerAnchor` can be computed rather than
    /// guessed. Font 11 plus room to breathe.
    /// Where the **foot of the staff** sits inside a rendered `flag.fill`, as a
    /// `UnitPoint`.
    ///
    /// *(User, 2026-08-28: "its end of flag pole is not aligned well with the
    /// position. Can you find the offset to the end of flag pole from the icon and
    /// align it.")* `.bottomLeading` was the first attempt and it is the corner of
    /// the *box*, not the end of the pole — the glyph has padding on every side and
    /// the staff is a few points in from the left edge, so the flag still stood
    /// short of the hole.
    ///
    /// **Measured, not guessed**: `flag.fill` rendered at 60pt bold is 69×70 with
    /// ink from x 8…62, y 6…64; the staff is the tallest column group on the left,
    /// centred on x 11.5 and ending at y 64. That is (0.167, 0.929) of the box.
    static let flagFoot = UnitPoint(x: 0.167, y: 0.929)

    private static let pillHeight: CGFloat = 24
    /// Where the coordinate sits inside the annotation: at the bottom of the pill,
    /// i.e. at the top of the grab tongue.
    private var markerAnchor: UnitPoint {
        let total = style.markerGrabRise + style.markerLabelGap + Self.pillHeight
        return UnitPoint(x: 0.5, y: style.markerGrabRise / total)
    }

    /// Split out because the annotation's `VStack` sat at the type-checker's
    /// budget and adding the ghost modifiers tipped it into "unable to type-check
    /// this expression in reasonable time" — the same structural fix `CourseView`
    /// needed, not a reordering.
    private func markerPill(_ m: HoleMarker) -> some View {
        HStack(spacing: 4) {
            if let symbol = m.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            if !m.title.isEmpty {
                Text(m.title)
                    .font(.system(size: 11, weight: m.isShot ? .bold : .medium))
            }
        }
        .foregroundStyle(m.tint ?? style.ink)
        // **A shot is a circle, everything else is a capsule** *(user, 2026-08-30:
        // "just show shot # in circle")*. The height is `pillHeight` either way,
        // because `markerAnchor` is computed from it — change the height here and
        // the grab handle lands back on the label, which is a flip that has already
        // been made and unmade once.
        .frame(width: m.isShot ? Self.pillHeight : nil)
        .padding(.horizontal, m.isShot ? 0 : 7)
        .frame(height: Self.pillHeight)
        .background(.black.opacity(0.66),
                    in: m.isShot ? AnyShape(Circle()) : AnyShape(Capsule()))
    }

    @MapContentBuilder
    private var markerOverlays: some MapContent {
        ForEach(markers) { m in
            // **The pill sits on its point; the handle hangs below it.** Centred
            // on the coordinate the pill covered the very thing it is a claim
            // about — which only showed up once markers moved *under* the tracks
            // and a shot dot landed on the caption. `Self.markerAnchor` puts the
            // seam between the pill and the transparent tongue exactly on the
            // coordinate, which needs both heights to be fixed — hence
            // `pillHeight`.
            Annotation("", coordinate: (markerDrag?.id == m.id ? markerDrag?.at ?? m.at : m.at)
                                        .clLocation,
                       anchor: markerAnchor) {
                VStack(spacing: 0) {
                    // **A transparent tongue reaching up *past* the point** *(user,
                    // 2026-08-28: "drag handle should be extended toward down, so
                    // that I can see the marker itself while dragging with finger";
                    // flipped 2026-08-29 with "marker display label under the
                    // point")*. It is on the opposite side from the pill, which is
                    // the rule — a handle on the label's side puts the thumb over
                    // the thing it exists to keep visible. `markerAnchor` puts the
                    // join between the strip and the pill on the coordinate, so the
                    // label hangs directly under its point; a first attempt padded
                    // the pill instead, which moved it 34 points away and stranded
                    // the dot it is a claim about. `contentShape` is what makes the
                    // empty half grabbable at all.
                    Color.clear.frame(width: 64, height: style.markerGrabRise)
                    // **Clear of the dot** *(user, 2026-08-29: "marker label further
                    // down … it's overlapping right now")*. A shot's own circle is
                    // 11 points across and the pill was starting at the coordinate
                    // itself, so the caption sat on the thing it is a claim about.
                    Color.clear.frame(width: 64, height: style.markerLabelGap)
                    markerPill(m)
                }
                .contentShape(Rectangle())
                .opacity(markerDisplay.opacity)
                // Ghosted: drawn, and out of the way of every gesture — the middle
                // state of `MarkerDisplay`. On this layer that is one modifier
                // rather than a branch in a hit test, because each pill carries its
                // own gesture.
                .allowsHitTesting(markerDisplay.isInteractive)
                // **One gesture: a tap opens the dialog, a drag moves it** — X13,
                // and reported on release, never during — X9. Decided from the
                // translation on release, the same way the vector layer and the
                // ruler's label do it; a `DragGesture` beside an `onTapGesture` can
                // deliver both from one short slow drag.
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        guard hypot(v.translation.width, v.translation.height) > 6,
                              let p = proxyBox else { return }
                        // **Hold the gap between the finger and the marker** — the
                        // `DragAnchor` rule, in degrees because `MapProxy` is what
                        // projects here, and the same thing the player and target
                        // annotations already do. Without it the marker's centre
                        // jumps to the fingertip on the first event, which puts it
                        // straight back under the hand — and the handle reaching
                        // below the point exists precisely so it is not.
                        if dragOffset == nil {
                            guard let s = p.convert(v.startLocation, from: .global)?.asCoordinate
                            else { return }
                            dragOffset = (m.at.lat - s.lat, m.at.lon - s.lon)
                        }
                        guard let c = p.convert(v.location, from: .global)?.asCoordinate,
                              let off = dragOffset else { return }
                        markerDrag = (m.id, Coordinate(lat: c.lat + off.dLat,
                                                       lon: c.lon + off.dLon))
                    }
                    .onEnded { v in
                        if hypot(v.translation.width, v.translation.height) <= 6 {
                            onTapMarker?(m.id)
                        } else if let d = markerDrag, d.id == m.id {
                            onMoveMarker?(m.id, d.at)
                        }
                        markerDrag = nil
                        dragOffset = nil
                    })
            }
            .annotationTitles(.hidden)
        }
        // Where a marker is being *asked* to go, while the confirmation is up.
        if let pending = pendingMarker,
           let from = markers.first(where: { $0.id == pending.id })?.at {
            MapPolyline(coordinates: [from.clLocation, pending.at.clLocation])
                .stroke(style.ink.opacity(0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            Annotation("", coordinate: pending.at.clLocation) {
                Circle().stroke(style.ink, lineWidth: 2).frame(width: 18, height: 18)
            }
            .annotationTitles(.hidden)
        }
    }

    /// Origin → target → target → pin, the same plan the vector layer draws.
    @MapContentBuilder
    private var planOverlays: some MapContent {
        if let readout, readout.hasTargets {
            ForEach(readout.legs) { leg in
                MapPolyline(coordinates: [leg.from.clLocation, leg.to.clLocation])
                    .stroke(style.target.opacity(leg.kind == .toGreen ? 0.6 : 0.95),
                            style: StrokeStyle(lineWidth: leg.kind == .toGreen ? 2 : 3,
                                               lineCap: .round,
                                               dash: leg.kind == .toGreen ? [6, 5] : []))
            }
            ForEach(Array(readout.targets.enumerated()), id: \.offset) { i, t in
                Annotation("Target \(i + 1)", coordinate: t.clLocation) {
                    ZStack {
                        // The same generous, edge-less handle the vector layer
                        // draws. It was vector-only for a while, which made the
                        // satellite target feel ungrabbable.
                        Circle().fill(style.target.opacity(0.07))
                            .frame(width: style.grabRadius * 2, height: style.grabRadius * 2)
                        Circle().strokeBorder(style.target.opacity(0.22), lineWidth: 1.2)
                            .frame(width: style.targetRadius * 2, height: style.targetRadius * 2)
                        Circle().fill(style.target.opacity(0.5)).frame(width: 4, height: 4)
                        if readout.targets.count > 1 {
                            Text("\(i + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(style.target.opacity(0.6))
                                .offset(x: 24, y: -15)
                        }
                    }
                    .contentShape(Circle())
                    // On the marker itself, so a drag anywhere else is still the
                    // map's pan.
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in
                            guard let p = proxyBox else { return }
                            if dragOffset == nil {
                                guard let s = p.convert(v.startLocation, from: .global)?.asCoordinate
                                else { return }
                                dragOffset = (t.lat - s.lat, t.lon - s.lon)
                            }
                            guard let c = p.convert(v.location, from: .global)?.asCoordinate,
                                  let off = dragOffset else { return }
                            onMoveTarget?(i, Coordinate(lat: c.lat + off.dLat,
                                                        lon: c.lon + off.dLon))
                        }
                        .onEnded { _ in dragOffset = nil })
                    .onTapGesture { onTapTarget?(i) }
                }
                .annotationTitles(.hidden)
            }
            // The number beside its own line, near the target end — a distance
            // floating away from what it measures has to be matched up by eye.
            ForEach(readout.legs) { leg in
                Annotation("", coordinate: labelPoint(leg).clLocation) {
                    legLabel(leg, readout: readout)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    /// Near the **target** end of the leg, so the number sits by the thing it is
    /// about without landing on the target ring.
    ///
    /// **Which end that is depends on the leg**, and this had it wrong for the
    /// approach. A leg that *ends* at a target wants the far end (0.72); the
    /// approach leg *starts* at the last target, so it wants the near one — the
    /// same 0.28 `PlanLayout` uses on the vector layer, and the same rule: anchored
    /// at the flag end it reads as a label on the green rather than on the shot.
    /// Here it also **collided with the big distance at the top of the screen**,
    /// which is where a short approach's 72% mark lands. Invisible until the
    /// elevation suffix widened the box; caught by screenshot on Coyote hole 8.
    private func labelPoint(_ leg: HoleReadout.Leg) -> Coordinate {
        let t = leg.kind == .toGreen ? 0.28 : 0.72
        return Coordinate(lat: leg.from.lat + (leg.to.lat - leg.from.lat) * t,
                          lon: leg.from.lon + (leg.to.lon - leg.from.lon) * t)
    }

    /// The approach leg carries front and back as well — that is the shot a golfer
    /// clubs for. The legs before it are layups to a spot, where one number is the
    /// whole answer.
    @ViewBuilder
    private func legLabel(_ leg: HoleReadout.Leg, readout: HoleReadout) -> some View {
        VStack(spacing: 0) {
            // **No `YD`** *(user, 2026-08-30)*. This box was the one place on the
            // hole that repeated the unit, against the rule the vector layer's own
            // leg labels already followed — it is stated once, in the caption under
            // the big distance, and repeating it here is three more characters of
            // box over the hole for nothing.
            Text(display.withPlays(leg.metres, rise: leg.rise))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            if leg.kind == .toGreen {
                Text("F \(display.number(readout.green.front))   B \(display.number(readout.green.back))")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(style.ink.opacity(0.8))
            }
        }
        .foregroundStyle(style.ink)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(style.target.opacity(0.45), lineWidth: 1))
        .allowsHitTesting(false)
    }

    /// A simulated position must never be mistakable for a fix — see the same note
    /// on `VectorHoleView.drawPlayer`.
    @ViewBuilder
    private var playerMarker: some View {
        if simulating {
            Image(systemName: "figure.golf")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.orange)
                .frame(width: 26, height: 26)
                .background(Circle().fill(style.roughDeep.opacity(0.85)))
                .overlay(Circle().strokeBorder(Color.orange,
                                               style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                .shadow(radius: 2)
        } else {
            Circle().fill(style.ink)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(style.ink.opacity(0.5), lineWidth: 2)
                    .frame(width: 22, height: 22))
        }
    }
}
#endif
