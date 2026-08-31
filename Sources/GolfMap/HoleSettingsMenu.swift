#if canImport(SwiftUI)
import SwiftUI
import GolfCourse

/// The pin menu, as its own `Equatable` view.
///
/// **It exists to stop the menu rebuilding while it is open** *(X5, user
/// 2026-08-28: "something keeps updating this menu. when it's up, do not
/// refresh")*.
///
/// `HoleScreen` is handed a `TrackingState` that changes on every fix and on a
/// five-second decay ticker, and the whole hole is one view body — so each of those
/// redraws the subtree the `Menu` lives in, SwiftUI tears the open menu down and
/// puts a fresh one in its place, and the user sees a flicker and loses whatever
/// they were reaching for. Splitting the menu out and marking it `Equatable` puts a
/// boundary there: none of the values below changes while the menu is up, so the
/// diff stops and the menu is left alone.
///
/// > **The closures are deliberately excluded from `==`.** They are recreated on
/// > every parent body evaluation and are never equal, so comparing them would make
/// > this always-unequal and the whole exercise pointless. That is safe here because
/// > each one only reads `HoleScreen`'s current `@State` when it *runs*; none of
/// > them captures a value that the comparison below would have caught.
@available(iOS 17, macOS 14, *)
struct HoleSettingsMenu: View, Equatable {
    let holeRef: String
    let tees: [String]
    let teeName: String
    let layer: HoleLayer
    let unit: DistanceUnit
    let hasTargets: Bool
    let hasPlayer: Bool
    let canEdit: Bool
    let style: HoleStyle

    var onEdit: () -> Void
    var onTee: (String) -> Void
    var onLayer: (HoleLayer) -> Void
    var onUnit: (DistanceUnit) -> Void
    var onGoToMe: () -> Void
    var onFit: () -> Void
    var onClearTargets: () -> Void
    var onCourseView: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.holeRef == b.holeRef && a.tees == b.tees && a.teeName == b.teeName
            && a.layer == b.layer && a.unit == b.unit
            && a.hasTargets == b.hasTargets && a.hasPlayer == b.hasPlayer
            && a.canEdit == b.canEdit
    }

    var body: some View {
        Menu {
            // **First item** *(X4, user 2026-08-28)*. It is the way out to the rest
            // of the round, so it goes where a thumb lands first.
            Button(action: onCourseView) {
                Label("Course view", systemImage: "map")
            }

            if canEdit {
                Button(action: onEdit) {
                    Label("Edit this hole", systemImage: "mappin.and.ellipse")
                }
            }

            if tees.count > 1 {
                Picker("Tee", selection: Binding(get: { teeName }, set: onTee)) {
                    ForEach(tees, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }

            Picker("Layer", selection: Binding(get: { layer }, set: onLayer)) {
                ForEach(HoleLayer.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }

            Picker("Distance", selection: Binding(get: { unit }, set: onUnit)) {
                Text("Yards").tag(DistanceUnit.yards)
                Text("Metres").tag(DistanceUnit.metres)
            }

            Divider()

            // **Simulate position is not here any more** *(X12, user 2026-08-28)*.
            // It is a button in the tool column, which also means this menu no
            // longer rebuilds when it is toggled — one fewer thing that can tear an
            // open menu down.
            Button(action: onGoToMe) {
                Label("Go to my location", systemImage: "location.fill")
            }
            .disabled(!hasPlayer)

            Button(action: onFit) {
                Label("Fit hole to screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            if hasTargets {
                Button(role: .destructive, action: onClearTargets) {
                    Label("Clear targets", systemImage: "scope")
                }
            }
        } label: {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 34)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(style.ink)
        }
        .accessibilityLabel("Hole settings")
    }
}
#endif
