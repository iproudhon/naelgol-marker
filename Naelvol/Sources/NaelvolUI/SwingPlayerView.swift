#if os(iOS)
import AVFoundation
import SwiftUI
import NaelvolCore
import NaelvolPose

/// One swing, played.
///
/// **Everything is on the screen** *(user, 2026-08-31)*: the tap zones and the scrub swipe, the
/// transport, the trim range and its presets, the overlays, the silhouette, and the four gravity
/// modes. Only the things that *write* — details, trim, delete — live in the ••• menu, because a
/// control that changes a file should not be next to a thumb that is scrubbing.
public struct SwingPlayerView: View {
    @StateObject private var model: SwingPlayerModel
    @ObservedObject private var library: SwingLibrary
    @EnvironmentObject private var services: NaelvolServices
    @Environment(\.dismiss) private var dismiss

    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var showingInfo = false

    // Zoom and pan live here, not in the model: they are how this screen is being *looked at*,
    // not anything about the swing.
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var scrubStart: Double?

    private static let speeds: [Float] = [0.125, 0.25, 0.5, 1, 2]

    public init(swing: Swing, library: SwingLibrary) {
        _model = StateObject(wrappedValue: SwingPlayerModel(swing: swing))
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            surface
            controls
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            model.nextURL = { try library.uniqueURL() }
            model.onWrote = { url in Task { await library.reload(reloaded(url)) } }
            model.onWroteNew = { _ in Task { await library.scan() } }
            model.estimator = { await services.estimator() }
            await model.load()
        }
        .onDisappear { model.tearDown() }
        .sheet(isPresented: $editing) {
            SwingEditSheet(context: model.swing.meta.context, catalog: services.catalog) { context in
                Task {
                    try? await library.update(model.swing, context: context)
                    if let fresh = library.swings.first(where: { $0.id == model.swing.id }) {
                        model.update(swing: fresh)
                    }
                }
            }
        }
        .confirmationDialog("Delete this swing?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? library.delete(model.swing)
                dismiss()
            }
        }
    }

    private var title: String {
        let caption = model.swing.meta.context.caption
        return caption.isEmpty ? model.swing.name : caption
    }

    // MARK: - The picture

    private var surface: some View {
        GeometryReader { proxy in
            ZStack {
                ZStack {
                    PlayerSurface(player: model.player)
                    if model.showsPose {
                        PoseOverlay(pose: model.pose, ghosts: model.ghosts, frameSize: model.naturalSize)
                    }
                    if !model.visibleMasks.isEmpty {
                        MaskOverlay(masks: model.visibleMasks, frameSize: model.naturalSize)
                    }
                }
                // **Levelling rotates the picture and its overlays together**, so a skeleton
                // stays glued to the body it was measured on. In `grid` mode nothing rotates —
                // the horizon carries the tilt instead, which is what shows how far off level
                // the phone was.
                .rotationEffect(.radians(Double(model.pictureRotation)))
                .scaleEffect(zoom)
                .offset(pan)

                if let rotation = model.gridRotation {
                    GravityOverlay(rotation: rotation)
                }

                if model.extracting {
                    ProgressView(value: model.extractionProgress) { Text("Reading poses") }
                        .progressViewStyle(.linear)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(40)
                }
                if showingInfo { infoPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .gesture(drag(in: proxy.size))
            .simultaneousGesture(magnify)
            .onTapGesture(count: 2) { resetZoom() }
            .onTapGesture { location in tap(at: location, in: proxy.size) }
        }
    }

    /// **One drag, classified by state.** Zoomed in it pans the picture; at 1× it scrubs. Two
    /// gestures over the same pixels is how a swipe ends up doing neither, which is the failure
    /// the hole view's single-gesture rule was written against.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if zoom > 1.01 {
                    pan = CGSize(width: panAnchor.width + value.translation.width,
                                 height: panAnchor.height + value.translation.height)
                    return
                }
                if scrubStart == nil {
                    scrubStart = model.currentTime
                    model.pause()
                }
                guard let start = scrubStart else { return }
                model.seek(to: start + Double(value.translation.width) * secondsPerPoint(width: size.width))
            }
            .onEnded { _ in
                panAnchor = pan
                scrubStart = nil
            }
    }

    /// vipl scrubs a **second per 500 points**, which is right for a swing a few seconds long and
    /// useless on a four-minute clip — a full-width drag would move it four seconds. So the rate
    /// is that constant *or* whatever covers the clip in about one and a half screen widths,
    /// whichever is coarser.
    private func secondsPerPoint(width: CGFloat) -> Double {
        max(1.0 / 500.0, model.duration / Double(max(width, 1) * 1.5))
    }

    /// `MagnificationGesture`, not iOS 17's `MagnifyGesture`: the package floor is 16, the same
    /// as Marker's, so a host on an older phone can still import this.
    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = max(1, min(8, zoomAnchor * value)) }
            .onEnded { _ in
                zoomAnchor = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            zoomAnchor = 1
            pan = .zero
            panAnchor = .zero
        }
    }

    /// vipl's tap zones, kept: **the outer two fifths step a frame, the middle plays**. It is the
    /// one control that works with a thumb anywhere on the screen while the other hand holds a club.
    private func tap(at point: CGPoint, in size: CGSize) {
        if point.x <= size.width * 0.4 {
            model.step(frames: -1)
        } else if point.x >= size.width * 0.6 {
            model.step(frames: 1)
        } else {
            model.togglePlay()
        }
    }

    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.info, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1).multilineTextAlignment(.trailing)
                    }
                }
                if let url = model.mapsURL {
                    Link("Show where it was filmed", destination: url).padding(.top, 4)
                }
            }
            .font(.footnote)
            .padding(12)
        }
        .frame(maxWidth: 320, maxHeight: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
        .onTapGesture { showingInfo = false }
    }

    // MARK: - The controls

    private var controls: some View {
        VStack(spacing: 8) {
            if let status = model.status {
                Button {
                    model.clearStatus()
                } label: {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            overlayRow
            rangeRow
            transportRow
            presetRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    /// Everything that draws *over* the picture, **on screen rather than behind a menu**
    /// *(user, 2026-08-31)*.
    ///
    /// Two rows, not one scrolling row: a control that has to be scrolled into view is a control
    /// nobody finds, which is the same complaint that took press-and-hold off the hole view.
    private var overlayRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                toggle("Pose", systemImage: "figure.walk", on: model.showsPose) {
                    Task { await model.setShowsPose(!model.showsPose) }
                }
                toggle("Body", systemImage: "person.fill.viewfinder", on: model.showsSegments) {
                    model.setShowsSegments(!model.showsSegments)
                }
                // **The gravity cycle, labelled with where it is, not where it goes.** vipl's
                // menu says "Grid->Axis"; a button that names its own state and changes on tap
                // says the same thing in half the width.
                Button {
                    model.gravityMode = model.gravityMode.next
                } label: {
                    chipLabel(model.gravityMode.label, systemImage: model.gravityMode.symbol)
                }
                .buttonStyle(.bordered)
                .tint(model.gravityMode == .none ? .secondary : Color.accentColor)
                .disabled(!model.hasGravity)

                toggle("Info", systemImage: "info.circle", on: showingInfo) { showingInfo.toggle() }
            }
            HStack(spacing: 6) {
                Text("Freeze").font(.caption2).foregroundStyle(.secondary)
                button("All", systemImage: "camera.filters") { model.freezeBoth() }
                button("Pose", systemImage: "figure.stand") { model.freezePose() }
                button("Body", systemImage: "person.crop.rectangle") { model.freezeBody() }
                button("Clear", systemImage: "eraser") { model.resetOverlays() }
                    .disabled(model.ghosts.isEmpty && model.frozenMasks.isEmpty)
                if !model.ghosts.isEmpty || !model.frozenMasks.isEmpty {
                    // What is stacked, said out loud: a faded skeleton over a faded silhouette
                    // is hard to count by eye, and the cap is six.
                    Text("\(model.ghosts.count)+\(model.frozenMasks.count)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
        }
    }

    private var rangeRow: some View {
        VStack(spacing: 2) {
            RangeSlider(lower: $model.lower, upper: $model.upper,
                        bounds: 0...max(model.duration, 0.01),
                        playhead: model.currentTime) { model.seek(to: $0) }
            HStack {
                Text(timeText(model.currentTime)).monospacedDigit()
                Spacer()
                Text("\(timeText(model.lower))–\(timeText(model.upper))")
                    .monospacedDigit()
                    .foregroundStyle(model.isTrimmed ? .primary : .secondary)
            }
            .font(.caption)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 16) {
            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
            Button { model.playBackwards() } label: { Image(systemName: "backward.fill") }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button { model.playForwards() } label: { Image(systemName: "forward.fill") }
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }

            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button {
                        model.setRate(model.rate < 0 ? -speed : speed)
                    } label: {
                        Label(speedText(speed), systemImage: abs(model.rate) == speed ? "checkmark" : "")
                    }
                }
            } label: {
                Text(speedText(abs(model.rate))).monospacedDigit().frame(minWidth: 34)
            }

            Button { model.loops.toggle() } label: {
                Image(systemName: "repeat").foregroundStyle(model.loops ? Color.accentColor : .secondary)
            }
            Button { model.toggleMuted() } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
        }
        .font(.title3)
    }

    /// The range presets, **relative to the playhead** — vipl's, kept, because a swing is found
    /// by scrubbing to impact and then taking a moment either side of it.
    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(SwingPlayerModel.rangePresets, id: \.before) { preset in
                Button(String(format: "−%g / +%g", preset.before, preset.after)) {
                    model.applyRange(before: preset.before, after: preset.after)
                }
                .buttonStyle(.bordered)
            }
            Button("Whole clip") { model.resetRange() }
                .buttonStyle(.bordered)
                .disabled(!model.isTrimmed)
            Spacer()
        }
        .font(.caption)
    }

    private func toggle(_ title: String, systemImage: String, on: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(on ? Color.accentColor : .secondary)
    }

    private func button(_ title: String, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    /// **One line, never wrapped.** A four-letter label that breaks into "Bo / dy" reads as a
    /// broken control; the row is sized to the text instead.
    private func chipLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ShareLink(item: model.swing.url) { Image(systemName: "square.and.arrow.up") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Details…") { editing = true }
                    .disabled(!isWritable)
                Button("Save trim") { Task { await model.exportTrim(asNewFile: false) } }
                    .disabled(!isWritable || !model.isTrimmed)
                Button("Save trim as new") { Task { await model.exportTrim(asNewFile: true) } }
                    .disabled(!model.isTrimmed)
                Divider()
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .disabled(!isWritable)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// A swing in a bookmarked folder belongs to whatever put it there. Editing, trimming in
    /// place and deleting are refused; **"save trim as new" is not**, because that writes a copy
    /// into naelvol's own directory.
    private var isWritable: Bool {
        library.source(id: model.swing.sourceID)?.isWritable == true
    }

    private func reloaded(_ url: URL) -> Swing {
        library.swings.first { $0.url == url } ?? model.swing
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let minutes = Int(seconds) / 60
        return String(format: "%d:%05.2f", minutes, seconds - Double(minutes * 60))
    }

    private func speedText(_ rate: Float) -> String {
        rate < 1 ? "1/\(Int((1 / max(rate, 0.001)).rounded()))×" : "\(Int(rate))×"
    }
}
#endif
