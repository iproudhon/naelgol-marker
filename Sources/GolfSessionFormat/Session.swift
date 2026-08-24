import Foundation

/// Milliseconds since the Unix epoch. One clock for every stream in a session.
public typealias Millis = Int64

public struct SessionMeta: Codable, Sendable {
    public var sessionID: String
    public var course: String?
    public var players: [String]
    public var start: Millis
    public var end: Millis?
    public var device: String
    public var audioFormat: String
    public init(sessionID: String, course: String?, players: [String],
                start: Millis, end: Millis?, device: String, audioFormat: String) {
        self.sessionID = sessionID; self.course = course; self.players = players
        self.start = start; self.end = end; self.device = device; self.audioFormat = audioFormat
    }
}

public struct GPSFix: Codable, Sendable {
    public var t: Millis
    public var lat: Double, lon: Double
    /// GNSS altitude. Poor vertically (±10–20 m) — prefer `AltitudeSample` for elevation.
    public var alt: Double?
    public var hAcc: Double, vAcc: Double?
    public var speed: Double?, course: Double?
}

public struct MotionSample: Codable, Sendable {
    public var t: Millis
    public var activity: String        // stationary | walking | automotive | unknown
    public var confidence: Int
    public var steps: Int?
    public var distance: Double?       // CMPedometer cumulative metres
}

/// Barometric altitude. Relative is accurate to ~0.3–1 m — this is what carries
/// "this hole plays 8 m uphill". Absolute needs a reference and can be far off.
public struct AltitudeSample: Codable, Sendable {
    public var t: Millis
    public var relative: Double        // metres since session start
    public var pressureKPa: Double?
    public var absolute: Double?       // iOS 15+ CMAbsoluteAltitudeData, when available
    public var absoluteAccuracy: Double?
}

public struct Utterance: Codable, Sendable {
    public var t0: Millis, t1: Millis
    public var speaker: String?        // acoustic cluster id, NOT a name
    public var text: String
    public var conf: Double?
}
