#if canImport(MapKit) && canImport(SwiftUI)
import SwiftUI
import MapKit
import GolfCourse

/// Every hole at once, on the imagery, with the hole number in the middle of each.
///
/// *(X4, user 2026-08-28: "provide a whole course view with tees and pins, and hole
/// number at the center of a hole … should be able to go to a hole by clicking hole
/// number". **X8, same day: "meant gps satellite view with normal zoom, pan, etc.
/// action"** — the first version was a fixed vector canvas with no gestures at all.)*
///
/// **The number is the control.** There is no separate list and no picker: the thing
/// that says which hole this is, is the thing you tap to go there. That is the same
/// decision the scorecard makes — tapping a hole column selects the hole — and it is
/// why neither screen needs a hole picker of its own. X8 changed the ground under
/// the numbers, not this.
///
/// **What is drawn comes from the course file; only the ground under it needs
/// signal.** The centre lines, tees, pins and numbers are all vector overlays, so a
/// course with no cell service loses the photograph and keeps every hole, every
/// number and every tap target. Nothing here may come to depend on the imagery
/// having loaded — that is the same coverage rule the hole view follows, and it is
/// why this is a `Map` with overlays rather than a picture with labels on it.
@available(iOS 17, macOS 14, *)
public struct CourseOverview: View {
    public let course: Course
    public var display = DistanceDisplay.default
    public var style = HoleStyle()
    /// The `Hole.ref` that was tapped.
    public var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic

    public init(course: Course, display: DistanceDisplay = .default,
                style: HoleStyle = HoleStyle(),
                onSelect: @escaping (String) -> Void) {
        self.course = course
        self.display = display
        self.style = style
        self.onSelect = onSelect
    }

    /// Only holes with coordinates. A card-only hole has nothing to place — the same
    /// `hasGeometry` gate every renderer goes through, because `HolePlane` is
    /// unguarded arithmetic and a nil-coalesced coordinate draws at the equator.
    private var drawn: [HoleGeometry] {
        course.holes.compactMap { hole in
            guard hole.hasGeometry else { return nil }
            return hole.geometry(tee: hole.defaultTee)
        }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if drawn.isEmpty {
                    ContentUnavailableView(
                        "No holes are placed yet",
                        systemImage: "map",
                        description: Text("Place a tee and a green centre on a hole and it "
                                        + "appears here."))
                } else {
                    map
                }
            }
            .navigationTitle(course.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// **Nothing is laid over the bottom of this map, deliberately.** Apple's logo
    /// and the Legal link live there and are not optional, private use included;
    /// `.mapControlVisibility(.hidden)` suppresses the compass and the scale and
    /// does *not* touch attribution. The hole view reserves space for them with
    /// `bottomReserve`; here the answer is simpler — put nothing there.
    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
            ForEach(drawn, id: \.hole.id) { geo in
                MapPolyline(coordinates: geo.playLine.map(\.clLocation))
                    .stroke(style.ink.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round,
                                               lineJoin: .round))
            }
            ForEach(drawn, id: \.hole.id) { geo in
                Annotation("", coordinate: geo.teeAt.clLocation) {
                    Circle().fill(style.ink.opacity(0.9))
                        .frame(width: 8, height: 8)
                        .shadow(radius: 2)
                }
                .annotationTitles(.hidden)

                // Anchored at the measured foot of the staff, not at a corner of
                // the box — see `SatelliteHoleView.flagFoot`.
                Annotation("", coordinate: geo.greenCenter.clLocation,
                           anchor: SatelliteHoleView.flagFoot) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(style.flag)
                        .shadow(radius: 2)
                }
                .annotationTitles(.hidden)

                Annotation("", coordinate: centre(geo).clLocation) {
                    Button { onSelect(geo.hole.ref) } label: {
                        Text(geo.hole.ref)
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(style.ink)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.66),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.imagery)
        .onAppear { camera = .region(region) }
    }

    /// Where a hole's number goes: the middle of its own playing line, so on a
    /// dogleg it lands on the fairway rather than in whatever the corner cuts across.
    private func centre(_ geo: HoleGeometry) -> Coordinate {
        geo.point(along: geo.measuredLength / 2)
    }

    /// The whole site in one frame, north up.
    ///
    /// The span is **floored**: a course file with a single placed hole — or one
    /// whose holes all run the same line — degenerates to a zero span, and a zero
    /// span is a camera zoomed to nothing.
    private var region: MKCoordinateRegion {
        let all = drawn.flatMap { [$0.teeAt, $0.greenCenter] + $0.playLine }
        guard let first = all.first else {
            return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                      span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        var minLat = first.lat, maxLat = first.lat
        var minLon = first.lon, maxLon = first.lon
        for c in all {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2,
                          longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.25, 0.004),
                        longitudeDelta: max((maxLon - minLon) * 1.25, 0.004)))
    }
}
#endif
