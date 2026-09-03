import Combine
import Foundation
import SwiftUI
import GolfCourse
import GolfSessionFormat
import NaelvolCore
import NaelvolPose
import NaelvolPoseTFLite
import NaelvolUI

/// Marker's side of naelvol.
///
/// **The only place the two worlds meet.** naelvol imports nothing from `Golf*`;
/// this file translates — a `Course` becomes a `SwingCatalog.Course`, a live fix
/// becomes a `SwingLocation`, a round that holds the microphone becomes the
/// sentence printed on a disabled Record button. Lifting `Naelvol/` into its own
/// repository touches nothing but the package path in the project file.
@MainActor
final class SwingFeature: ObservableObject {
    /// Declared explicitly because nothing here is `@Published`: this object is a
    /// holder, and the two things that *do* change — the library and the services
    /// — are observed directly by the views that use them.
    let objectWillChange = ObservableObjectPublisher()

    let library: SwingLibrary
    let services: NaelvolServices
    private let models: MoveNetStore

    /// Swings live in `Documents/Swings/` — under `Documents` deliberately,
    /// because `UIFileSharingEnabled` is already on and a swing should come off
    /// the phone over Finder the way a session folder does. The listing cache goes
    /// to Application Support, where the Whisper models live: it is derived and
    /// deleting it costs one slow scan.
    static var swingsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swings", isDirectory: true)
    }

    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("naelvol", isDirectory: true)
    }

    /// Where the `.tflite` files are.
    ///
    /// **`Documents/Models` first, the app bundle second.** The bundle copy is what
    /// ships; the Documents override is how a newer model gets onto a phone over
    /// Finder without a rebuild — the same "look, do not compute" rule that
    /// `WhisperEngine.modelFolder` exists for.
    static var modelFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        let locator = PoseModelLocator(folder: docs)
        if PoseModel.allCases.contains(where: { locator.isAvailable($0) }) { return docs }
        return Bundle.main.resourceURL ?? docs
    }

    init() {
        library = SwingLibrary(appRoot: Self.swingsRoot, cacheDirectory: Self.cacheRoot)
        services = NaelvolServices()
        models = MoveNetStore(locator: PoseModelLocator(folder: Self.modelFolder))

        let store = models
        // Thunder for a recorded clip somebody is looking at; lightning behind a
        // live preview. `MoveNetStore` is an LRU of two, so both stay resident.
        services.estimator = { try? await store.model(.thunder) }
        services.liveEstimator = { try? await store.model(.lightning) }
    }

    /// Wire the round's state in. Called from the app root, so every screen's
    /// answer to "can I film right now?" and "what courses are there?" is the same
    /// one.
    func bind(model: RoundViewModel, live: LiveLocation) {
        services.captureBlocked = { [weak model] in
            guard let model else { return nil }
            // **Capture is refused while a round burst is recording** *(user,
            // 2026-08-31)*. One microphone: an `AVCaptureSession` with an audio
            // input starting under the round's live `AVAudioEngine` tap either
            // interrupts the burst — which closes a segment — or fails silently.
            // Printed, not merely disabled: a control that does nothing and says
            // nothing reads as a broken app.
            if model.isListening { return "The round is recording. Stop the mic to film a swing." }
            return nil
        }
        services.fix = { [weak model, weak live] in
            guard let coordinate = model?.here ?? live?.here else { return nil }
            return SwingLocation(latitude: coordinate.lat, longitude: coordinate.lon,
                                 altitude: coordinate.alt)
        }
    }

    /// Flatten Marker's types into naelvol's plain values.
    ///
    /// **The hole is the 1-based playing index**, which is what a scorecard column
    /// means and what `Course.nearestHole` answers with; `Hole.ref` rides along as
    /// a label because it is not a key — Korean 18s are two named nines each
    /// numbered 1–9.
    func refreshCatalog(courses: [Course], players: [Player], roundID: String?) {
        services.catalog = SwingCatalog(
            courses: courses.map { course in
                SwingCatalog.Course(
                    id: course.id, name: course.name,
                    holes: course.holes.enumerated().map { index, hole in
                        SwingCatalog.Hole(index: index + 1, ref: hole.ref)
                    })
            },
            players: players.map { SwingCatalog.Player(id: $0.id, name: $0.name) },
            roundID: roundID)
    }
}

/// What a screen asked for: the list, or the camera.
enum SwingRequest: Identifiable {
    case list(SwingFilter)
    case capture(SwingContext)

    var id: String {
        switch self {
        case .list(let f): return "list:\(f.courseID ?? "")/\(f.hole.map(String.init) ?? "")"
        case .capture(let c): return "capture:\(c.courseID ?? "")/\(c.hole.map(String.init) ?? "")"
        }
    }
}

/// The two sheets, as a modifier.
///
/// **A `ViewModifier` rather than two more `.sheet` lines**, because
/// `CourseView.body` and its `HoleScreen` call are both at the type-checker's
/// budget — the same reason `MarkerSheetPresenter` exists, and the same fix.
struct SwingSheetPresenter: ViewModifier {
    @ObservedObject var swings: SwingFeature
    @Binding var request: SwingRequest?
    @State private var path: [Swing] = []

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            switch request {
            case .list(let filter):
                NavigationStack(path: $path) {
                    SwingBrowseView(library: swings.library, filter: filter)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { self.request = nil }
                            }
                        }
                        #if DEBUG
                        // `-marker.swing swing-0001.mov` pushes the player over a
                        // seeded clip. The same argument as every other key here:
                        // it is behind a tap on a cell, scripted taps do not exist
                        // in this environment, and `ImageRenderer` cannot draw a
                        // `Map` or a `Menu` — so without it the player screen
                        // ships unlooked-at.
                        .task {
                            guard let name = DemoSeed.openSwing, path.isEmpty else { return }
                            for _ in 0..<20 {
                                if let swing = swings.library.swings.first(where: {
                                    $0.relativePath == name || $0.name == name
                                }) {
                                    path = [swing]
                                    return
                                }
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                        }
                        #endif
                }
                .environmentObject(swings.services)
            case .capture(let context):
                NavigationStack {
                    SwingCaptureView(library: swings.library, context: context)
                }
                .environmentObject(swings.services)
            }
        }
    }
}
