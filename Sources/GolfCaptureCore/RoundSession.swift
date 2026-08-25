import Foundation
import GolfSessionFormat

/// Anything that records a stream for the length of a round. Exists so
/// `RoundSession` can drive `GolfCaptureMotion` without depending on it —
/// the core stays cross-platform, and the iOS-only motion target plugs in.
public protocol SessionRecorder: AnyObject {
    func start() throws
    func stop()
}

extension AudioRecorder: SessionRecorder {}
extension LocationRecorder: SessionRecorder {
    public func start() throws { _ = try startTracking() }
}

/// One round: creates the session folder, starts every stream on one clock,
/// takes MARKs while it runs, and closes the folder so it can be read on a Mac.
///
/// **Must be started with the app in the foreground.** iOS will not let an app
/// begin recording audio from the background — it will only let one continue.
/// So a round is an explicit "start round" tap, not something auto-detected
/// from a geofence.
public final class RoundSession: @unchecked Sendable {

    public enum State: Sendable { case idle, recording, ended }

    public let folder: SessionFolder
    public let audio: AudioRecorder
    public let location: LocationRecorder

    private var auxiliary: [SessionRecorder]
    private let queue = DispatchQueue(label: "marker.session")
    private var markWriter: JSONLWriter?
    private var correctionWriter: JSONLWriter?
    private var meta: SessionMeta?

    public private(set) var state: State = .idle
    public private(set) var markCount = 0
    /// False when this process cannot use CoreLocation (an unbundled CLI). The
    /// round is still valid — audio and marks record — it just has no track.
    public private(set) var locationAvailable = false

    /// - Parameters:
    ///   - auxiliary: extra streams, e.g. `MotionRecorder` on iOS. Passing none
    ///     is a complete, if elevation-blind, round — which is what a Mac run is.
    /// - Parameter recordAudio: false records a round with GPS, motion and marks
    ///   but no microphone. Used to exercise the pipeline headlessly, and it is
    ///   the honest fallback when the user declines mic access rather than
    ///   refusing to record at all.
    public init(folder: SessionFolder,
                audioConfig: AudioRecorder.Config = .init(),
                locationConfig: LocationRecorder.Config = .init(),
                recordAudio: Bool = true,
                recordLocation: Bool = true,
                auxiliary: [SessionRecorder] = []) {
        self.folder = folder
        self.audio = AudioRecorder(folder: folder, config: audioConfig)
        self.location = LocationRecorder(folder: folder, config: locationConfig)
        self.recordAudio = recordAudio
        self.recordLocation = recordLocation
        self.auxiliary = auxiliary
    }

    public let recordAudio: Bool
    public let recordLocation: Bool

    /// Convenience: build a session folder under `root`, named for its start time.
    public static func create(under root: URL,
                              players: [Player] = [],
                              course: String? = nil,
                              device: String = defaultDeviceName,
                              recordAudio: Bool = true,
                              recordLocation: Bool = true,
                              auxiliary: [SessionRecorder] = []) -> RoundSession {
        let start = SessionClock.now()
        let url = root.appendingPathComponent(SessionFolder.folderName(start: start))
        let session = RoundSession(folder: SessionFolder(url: url),
                                   recordAudio: recordAudio,
                                   recordLocation: recordLocation,
                                   auxiliary: auxiliary)
        session.pendingMeta = SessionMeta(sessionID: UUID().uuidString,
                                          course: course, players: players,
                                          start: start, end: nil, device: device,
                                          audioFormat: session.audio.describedFormat)
        return session
    }

    private var pendingMeta: SessionMeta?

    public static var defaultDeviceName: String {
        #if os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard state == .idle else { return }
        try folder.create()

        var m = pendingMeta ?? SessionMeta(sessionID: UUID().uuidString,
                                           start: SessionClock.now(),
                                           device: Self.defaultDeviceName,
                                           audioFormat: audio.describedFormat)
        m.audioFormat = recordAudio ? audio.describedFormat : "none"
        // Written before any stream starts: a round that dies thirty seconds in
        // is still an identifiable session folder rather than orphaned files.
        try folder.writeMeta(m)
        meta = m

        try queue.sync {
            markWriter = try folder.writer(.marks)
            correctionWriter = try folder.writer(.corrections)
        }

        if recordAudio {
            try audio.start()
            // Only resolved once the audio session is active, so meta is rewritten
            // here. `meta` must be updated too — stop() rewrites from it, and a
            // stale copy would erase the route at the end of the round.
            m.audioRoute = AudioRecorder.currentRoute
            meta = m
            try folder.writeMeta(m)
        }
        locationAvailable = recordLocation ? try location.startTracking() : false
        for r in auxiliary { try r.start() }
        state = .recording
    }

    public func stop() {
        guard state == .recording else { return }
        for r in auxiliary.reversed() { r.stop() }
        if recordLocation { location.stop() }
        if recordAudio { audio.stop() }

        queue.sync {
            try? markWriter?.close(); markWriter = nil
            try? correctionWriter?.close(); correctionWriter = nil
        }
        if var m = meta {
            m.end = SessionClock.now()
            try? folder.writeMeta(m)
            meta = m
        }
        state = .ended
    }

    // MARK: - During the round

    /// The MARK button. Stamps "something happened, now" with the last known
    /// position — the cheapest ground-truth anchor there is, and the one thing
    /// the phone's owner can contribute that audio cannot.
    ///
    /// Records even with no GPS fix. The timestamp is the load-bearing half;
    /// a mark dropped for want of a fix is gone forever, and the fix can often
    /// be recovered later by interpolating the track around that time.
    /// Returns nil only when there is no round to mark — the writer is closed.
    /// A mark is never dropped while one is open, fix or no fix.
    @discardableResult
    public func mark(player: String, hole: Int? = nil, note: String? = nil) -> Mark? {
        guard state == .recording else { return nil }
        let now = SessionClock.now()
        let fix = location.lastFix
        let m = Mark(t: now, player: player,
                     lat: fix?.lat, lon: fix?.lon,
                     hAcc: fix?.hAcc,
                     fixAgeMs: fix.map { now - $0.t },
                     hole: hole, note: note)
        queue.sync {
            try? markWriter?.append(m)
            try? markWriter?.sync()
            markCount += 1
        }
        return m
    }

    /// Amend the reconstruction. Append-only: the *sequence* of corrections is
    /// the labeled error set `GolfEval` consumes, so nothing here is rewritten.
    public func record(_ correction: Correction) {
        queue.sync {
            try? correctionWriter?.append(correction)
            try? correctionWriter?.sync()
        }
    }

    public func addAuxiliary(_ recorder: SessionRecorder) throws {
        auxiliary.append(recorder)
        if state == .recording { try recorder.start() }
    }
}
