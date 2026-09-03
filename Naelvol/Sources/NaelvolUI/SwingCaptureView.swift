#if os(iOS)
import AVFoundation
import SwiftUI
import NaelvolCapture
import NaelvolCore
import NaelvolPose

/// Filming a swing.
///
/// The **second entry point** the host offers everywhere the list is offered. What
/// it is about — course, hole, player, round — is handed in and stamped on the
/// file at the moment recording starts, not applied afterwards as a metadata
/// rewrite.
public struct SwingCaptureView: View {
    @ObservedObject private var library: SwingLibrary
    @EnvironmentObject private var services: NaelvolServices
    @StateObject private var session = SwingCaptureSession()
    @Environment(\.dismiss) private var dismiss

    private let context: SwingContext
    @State private var lastCaptured: URL?

    public init(library: SwingLibrary, context: SwingContext = SwingContext()) {
        self.library = library
        self.context = context
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: session.session, mirrored: session.isMirrored,
                          rotationAngle: session.rotationAngle)
                .ignoresSafeArea()
            if session.wantsLivePose, let pose = session.lastPose {
                PoseOverlay(pose: pose, frameSize: frameSize).ignoresSafeArea()
            }
            VStack {
                header
                Spacer()
                controls
            }
            .padding()
        }
        .task { start() }
        .onDisappear { session.stop() }
        // The picture follows the phone, and the session refuses to change it mid-recording —
        // a connection's rotation changes the buffer size, and a writer handed a new size stops
        // accepting frames.
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
            session.deviceRotated()
        }
    }

    private var frameSize: CGSize {
        guard let option = session.current else { return .zero }
        return CGSize(width: CGFloat(option.width), height: CGFloat(option.height))
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if let option = session.current {
                    Menu {
                        ForEach(session.options) { candidate in
                            Button(candidate.label) { session.select(candidate) }
                        }
                    } label: {
                        Text(option.label).font(.footnote)
                    }
                }
            }
            .foregroundStyle(.white)

            if !context.isEmpty {
                // What this recording will be tagged with, said out loud: a swing
                // filed against the wrong hole is invisible until somebody goes
                // looking for it a week later.
                Text(services.catalog.resolve(context).caption)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let failure = session.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if session.triggerState == .arming {
                Text("Hold it…").font(.footnote).foregroundStyle(.yellow)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Toggle(isOn: Binding(get: { session.wantsGestureTrigger },
                                     set: { session.wantsGestureTrigger = $0; session.syncSettings() })) {
                    Image(systemName: "hand.raised")
                }
                .toggleStyle(.button)

                Toggle(isOn: Binding(get: { session.wantsLivePose },
                                     set: { session.wantsLivePose = $0; session.syncSettings() })) {
                    Image(systemName: "figure.walk")
                }
                .toggleStyle(.button)
                .disabled(!hasPoseModel)

                Toggle(isOn: Binding(get: { session.recordsAudio },
                                     set: { session.recordsAudio = $0 })) {
                    Image(systemName: session.recordsAudio ? "mic" : "mic.slash")
                }
                .toggleStyle(.button)
                .disabled(session.isRecording)
            }
            .tint(.white)

            if session.isRecording {
                Text(String(format: "%.1fs", session.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.red)
            }

            Button {
                session.toggleRecording()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    RoundedRectangle(cornerRadius: session.isRecording ? 6 : 30)
                        .fill(.red)
                        .frame(width: session.isRecording ? 32 : 60,
                               height: session.isRecording ? 32 : 60)
                }
            }
            .disabled(!session.isRunning)

            if !session.wantsGestureTrigger {
                Text("Cross your arms or hold up an open palm to start from a distance — turn on the hand icon.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var hasPoseModel: Bool { true }

    private func start() {
        session.isBlocked = services.captureBlocked
        session.fixProvider = services.fix
        session.contextProvider = { services.catalog.resolve(context) }
        session.nextURL = { try library.uniqueURL() }
        session.poseHandler = { buffer in
            // The estimator is the host's, and it is an actor away, so the frame
            // path asks a cached one synchronously. Nil until one is loaded, which
            // simply means no overlay.
            guard let estimator = Self.cachedEstimator else { return nil }
            guard let (person, _) = try? estimator.estimateSinglePose(on: buffer) else { return nil }
            let golfer = Golfer(person)
            return PoseValidator().isValid(golfer) ? golfer : nil
        }
        session.onFinished = { url in
            lastCaptured = url
            Task { await library.scan() }
        }
        session.syncSettings()
        session.start()
        Task { Self.cachedEstimator = await services.liveEstimator() }
    }

    /// Loaded once and held for the life of the process: an interpreter takes a
    /// second to build, and the camera queue cannot wait for one per frame.
    nonisolated(unsafe) private static var cachedEstimator: PoseEstimating?
}
#endif
