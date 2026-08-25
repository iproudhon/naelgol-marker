import Foundation
import Combine
import CoreLocation
import GolfSessionFormat
import GolfCaptureCore
import GolfCaptureMotion

/// The whole app shell, such as it is. Phase 1's job is to record a round and
/// hand a session folder to the Mac — no reconstruction, no map, no history.
@MainActor
final class RoundViewModel: ObservableObject {

    @Published private(set) var state: RoundSession.State = .idle
    @Published private(set) var markCount = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var fixAccuracy: Double?
    @Published private(set) var fixCount = 0
    @Published private(set) var activity = "—"
    @Published private(set) var relativeAltitude: Double = 0
    @Published private(set) var audioState: AudioRecorder.State = .idle
    @Published private(set) var lastMarkLabel: String?
    @Published var errorMessage: String?

    /// One row per player, each with its own aliases field. A single
    /// comma-separated box cannot express "steve is also 스티브 and 형", and
    /// nicknames are most of what actually gets said on a course.
    struct PlayerDraft: Identifiable, Equatable {
        let id = UUID()
        var name: String = ""
        /// Comma-separated in the UI, split on the way out.
        var aliasText: String = ""

        var aliases: [String] {
            aliasText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
        var player: Player? {
            trimmedName.isEmpty ? nil : Player(name: trimmedName, aliases: aliases)
        }
    }

    @Published var drafts: [PlayerDraft] = RoundViewModel.loadDrafts()
    @Published var courseText: String = UserDefaults.standard.string(forKey: "course") ?? ""

    var players: [Player] { drafts.compactMap(\.player) }
    var playerIDs: [String] { players.map(\.id) }

    func addPlayer() { drafts.append(PlayerDraft()) }
    func removePlayers(at offsets: IndexSet) {
        drafts = drafts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    // Round-to-round the group is usually the same four people, so the roster —
    // aliases included — is worth remembering.
    private static let draftsKey = "playerDrafts.v1"

    private static func loadDrafts() -> [PlayerDraft] {
        guard let raw = UserDefaults.standard.array(forKey: draftsKey) as? [[String: String]],
              !raw.isEmpty else {
            return [PlayerDraft()]
        }
        return raw.map { PlayerDraft(name: $0["name"] ?? "", aliasText: $0["aliases"] ?? "") }
    }

    private func saveDrafts() {
        let raw = drafts.map { ["name": $0.name, "aliases": $0.aliasText] }
        UserDefaults.standard.set(raw, forKey: Self.draftsKey)
    }

    private var session: RoundSession?
    private var motion: MotionRecorder?
    private var ticker: Timer?
    private var startedAt: Date?

    var isRecording: Bool { state == .recording }
    var sessionName: String? { session?.folder.url.lastPathComponent }

    /// Sessions live in Documents so `UIFileSharingEnabled` exposes them to
    /// Finder and the Files app. That is the whole device→Mac transfer story
    /// for Phase 1 — no sync service, no account.
    static var sessionsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    // MARK: - Round lifecycle

    func startRound() async {
        guard state != .recording else { return }
        errorMessage = nil

        // Must happen in the foreground: iOS refuses to *start* a recording from
        // the background, and always-location is only offered after when-in-use.
        let mic = await AudioRecorder.requestPermission()
        guard mic == .granted else {
            errorMessage = "Marker needs the microphone to hear the round. "
                         + "Enable it in Settings > Privacy > Microphone."
            return
        }

        saveDrafts()
        UserDefaults.standard.set(courseText, forKey: "course")

        let s = RoundSession.create(under: Self.sessionsRoot,
                                    players: players,
                                    course: courseText.isEmpty ? nil : courseText,
                                    device: deviceName)
        s.location.requestAuthorization()

        let m = MotionRecorder(folder: s.folder)
        try? s.addAuxiliary(m)
        motion = m

        s.location.onFix = { [weak self] fix in
            Task { @MainActor in
                self?.fixAccuracy = fix.hAcc
                self?.fixCount += 1
            }
        }
        s.audio.onStateChange = { [weak self] st in
            Task { @MainActor in self?.audioState = st }
        }
        m.onActivityChange = { [weak self] a in
            Task { @MainActor in self?.activity = a }
        }

        do {
            try s.start()
        } catch {
            errorMessage = "Could not start: \(error)"
            return
        }

        session = s
        startedAt = Date()
        state = .recording
        markCount = 0
        fixCount = 0
        startTicking()
    }

    func stopRound() {
        session?.stop()
        ticker?.invalidate(); ticker = nil
        state = .ended
        motion = nil
    }

    /// The MARK button. Records even with no fix — the timestamp is the point,
    /// and a mark not taken is gone for good.
    func mark(player: String) {
        guard let session else { return }
        guard let m = session.mark(player: player) else { return }
        markCount = session.markCount
        lastMarkLabel = m.lat == nil
            ? "\(player) — time only, no fix yet"
            : String(format: "%@ — %.5f, %.5f", player, m.lat!, m.lon!)
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
                self.relativeAltitude = self.motion?.lastRelativeAltitude ?? 0
            }
        }
    }

    private var deviceName: String {
        #if canImport(UIKit)
        return "iOS"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Capability report

    /// Permission is three-valued, not two. A plain checkmark/cross shows a red
    /// ✗ next to Microphone on first launch — before anyone has been *asked* —
    /// which reads as "broken" when the real answer is "we'll ask when you tap".
    struct Capability: Identifiable {
        enum Kind: String { case microphone, location, motion, barometer }
        enum Status { case ready, willAsk, denied, unavailable }
        var id: String { kind.rawValue }
        let kind: Kind
        let name: String
        let status: Status
        let detail: String?
        /// True when tapping the row will produce a system prompt.
        var isRequestable: Bool { status == .willAsk }
        /// True when the only remedy is the Settings app.
        var needsSettings: Bool { status == .denied }
    }

    /// **Published, not computed.** A computed property never refreshes the row
    /// after the user answers a prompt — nothing publishes, so the "?" stays put
    /// forever and the app looks like it never asked. Recompute explicitly:
    /// on appear, on returning from Settings, and after every request.
    @Published private(set) var capabilities: [Capability] = []

    private let permissionMonitor = LocationPermissionMonitor()

    func refreshCapabilities() {
        let motion = MotionRecorder.availability

        let mic: Capability.Status
        switch AudioRecorder.permission {
        case .granted: mic = .ready
        case .undetermined: mic = .willAsk
        case .denied: mic = .denied
        }

        let location: Capability.Status
        switch permissionMonitor.status {
        case .authorizedAlways: location = .ready
        case .authorizedWhenInUse: location = .ready
        case .notDetermined: location = .willAsk
        default: location = .denied
        }

        capabilities = [
            Capability(kind: .microphone, name: "Microphone", status: mic,
                       detail: {
                           switch mic {
                           case .willAsk: return "Tap to allow. Without it there is nothing to reconstruct."
                           case .denied: return "Denied. Settings > Naelgol Marker > Microphone."
                           default: return nil
                           }
                       }()),
            Capability(kind: .location, name: "Location", status: location,
                       detail: {
                           switch location {
                           case .willAsk: return "Tap to allow. Choose Always so the track survives a pocket."
                           case .denied: return "Denied. Settings > Naelgol Marker > Location."
                           case .ready:
                               return permissionMonitor.status == .authorizedWhenInUse
                                   ? "While Using only — tap to upgrade to Always, or the track stops when the screen locks."
                                   : nil
                           case .unavailable: return nil
                           }
                       }()),
            Capability(kind: .motion, name: "Motion activity",
                       status: motion.motionActivity ? .ready : .unavailable,
                       detail: motion.motionActivity ? nil : "This device has no motion coprocessor."),
            Capability(kind: .barometer, name: "Barometer (elevation)",
                       status: motion.relativeAltitude ? .ready : .unavailable,
                       detail: motion.relativeAltitude ? nil : "No barometer — the round still records, without elevation."),
        ]
    }

    /// Asked from the row itself, so permission is never gated behind filling in
    /// the roster first — which is what made the app look like it never asked.
    func request(_ kind: Capability.Kind) async {
        switch kind {
        case .microphone:
            _ = await AudioRecorder.requestPermission()
        case .location:
            permissionMonitor.request()
        case .motion, .barometer:
            break                       // hardware, not permission
        }
        refreshCapabilities()
    }

    /// Requests everything still unasked, in order. Two system prompts back to
    /// back is fine here — the user just tapped a button that says so.
    func requestAllPermissions() async {
        if AudioRecorder.permission == .undetermined {
            _ = await AudioRecorder.requestPermission()
            refreshCapabilities()
        }
        if permissionMonitor.status == .notDetermined {
            permissionMonitor.request()
        }
        refreshCapabilities()
    }

    var hasUnaskedPermissions: Bool {
        capabilities.contains { $0.isRequestable }
    }

    init() {
        permissionMonitor.onChange = { [weak self] in
            Task { @MainActor in self?.refreshCapabilities() }
        }
        refreshCapabilities()
    }

    /// Only a hard denial blocks a round. "Not asked yet" must not.
    var canStart: Bool {
        !players.isEmpty && AudioRecorder.permission != .denied
    }
}

/// Location authorization only reports changes through a delegate, and the
/// WhenInUse -> Always escalation cannot happen on the line after the request —
/// the status does not change until the user answers. Owning a manager here
/// means the setup screen can ask before a round exists, and refresh when the
/// answer arrives.
private final class LocationPermissionMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?
    private var wantsAlways = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    func request() {
        wantsAlways = true
        escalate()
    }

    /// Only ever prompts because the user asked. Assigning the delegate fires
    /// `locationManagerDidChangeAuthorization` immediately, so without the
    /// `wantsAlways` guard on `.notDetermined` the app throws a location dialog
    /// in the user's face on launch, before they have typed a single name.
    private func escalate() {
        guard wantsAlways else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            wantsAlways = false          // ask once; nagging gets an app rejected
            manager.requestAlwaysAuthorization()
        default:
            wantsAlways = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        escalate()
        onChange?()
    }
}
