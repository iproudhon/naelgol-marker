import Foundation

/// Milliseconds since the Unix epoch. One clock for every stream in a session.
public typealias Millis = Int64

/// One person in the group, and every name the group actually calls them.
///
/// A single name is not enough. A player is "steve" on the card, "스티브" to one
/// friend, "형" to another, and "Mr. Jung" when someone is being funny — often
/// all within one hole. The reconstruction attributes shots by matching spoken
/// names against this list, so a player addressed only by a nickname for half the
/// round is still attributable. Names are matched, never inferred from a roster
/// position.
public struct Player: Codable, Sendable, Hashable, Identifiable {
    /// Stable key written into marks.jsonl, corrections.jsonl and round.json.
    /// Defaults to `name`, but survives a later rename of the display name.
    public var id: String
    /// Primary display name, and the one used on a scorecard.
    public var name: String
    /// Nicknames, given names, honorifics — anything said out loud.
    public var aliases: [String]

    public init(id: String? = nil, name: String, aliases: [String] = []) {
        self.name = name
        self.id = id ?? name
        self.aliases = aliases
    }

    /// Every name this player answers to, primary first. This is what goes to
    /// the model, not the display name alone.
    public var allNames: [String] { [name] + aliases }

    /// For logs and CLI output: `steve (스티브, 형)`.
    public var summary: String {
        aliases.isEmpty ? name : "\(name) (\(aliases.joined(separator: ", ")))"
    }
}

public struct SessionMeta: Codable, Sendable, Equatable {
    public var sessionID: String
    public var course: String?
    public var players: [Player]
    public var start: Millis
    public var end: Millis?
    public var device: String
    public var audioFormat: String
    /// Which microphone actually recorded, e.g. "MicrophoneBuiltIn". A round that
    /// went out over a Bluetooth headset is a different experiment from a round
    /// recorded by a pocketed phone — without this they look identical afterwards.
    public var audioRoute: String?
    public init(sessionID: String, course: String? = nil, players: [Player] = [],
                start: Millis, end: Millis? = nil, device: String,
                audioFormat: String, audioRoute: String? = nil) {
        self.sessionID = sessionID; self.course = course; self.players = players
        self.start = start; self.end = end; self.device = device
        self.audioFormat = audioFormat; self.audioRoute = audioRoute
    }
}

public struct GPSFix: Codable, Sendable {
    public var t: Millis
    public var lat: Double, lon: Double
    /// GNSS altitude. Poor vertically (±10–20 m) — prefer `AltitudeSample` for elevation.
    public var alt: Double?
    public var hAcc: Double, vAcc: Double?
    public var speed: Double?, course: Double?
    public init(t: Millis, lat: Double, lon: Double, alt: Double? = nil,
                hAcc: Double, vAcc: Double? = nil,
                speed: Double? = nil, course: Double? = nil) {
        self.t = t; self.lat = lat; self.lon = lon; self.alt = alt
        self.hAcc = hAcc; self.vAcc = vAcc; self.speed = speed; self.course = course
    }
}

public struct MotionSample: Codable, Sendable {
    public var t: Millis
    public var activity: String        // stationary | walking | automotive | unknown
    public var confidence: Int
    public var steps: Int?
    public var distance: Double?       // CMPedometer cumulative metres
    public init(t: Millis, activity: String, confidence: Int,
                steps: Int? = nil, distance: Double? = nil) {
        self.t = t; self.activity = activity; self.confidence = confidence
        self.steps = steps; self.distance = distance
    }
}

/// Barometric altitude. Relative is accurate to ~0.3–1 m — this is what carries
/// "this hole plays 8 m uphill". Absolute needs a reference and can be far off.
public struct AltitudeSample: Codable, Sendable {
    public var t: Millis
    public var relative: Double        // metres since session start
    public var pressureKPa: Double?
    public var absolute: Double?       // iOS 15+ CMAbsoluteAltitudeData, when available
    public var absoluteAccuracy: Double?
    public init(t: Millis, relative: Double, pressureKPa: Double? = nil,
                absolute: Double? = nil, absoluteAccuracy: Double? = nil) {
        self.t = t; self.relative = relative; self.pressureKPa = pressureKPa
        self.absolute = absolute; self.absoluteAccuracy = absoluteAccuracy
    }
}

public struct Utterance: Codable, Sendable {
    public var t0: Millis, t1: Millis
    public var speaker: String?        // acoustic cluster id, NOT a name
    public var text: String
    public var conf: Double?
    /// Which recognizer produced this line, e.g. `"en_US"` or `"ko_KR"`.
    ///
    /// **The round is bilingual and two recognizers run over the same audio, so a
    /// transcript holds two overlapping accounts of every moment.** Without this
    /// tag they are indistinguishable and the file reads as one recognizer that
    /// stutters. Optional because a single-locale transcript predates it and
    /// because a transcriber that does not know its own locale should say nil
    /// rather than guess.
    public var locale: String?
    public init(t0: Millis, t1: Millis, speaker: String? = nil,
                text: String, conf: Double? = nil, locale: String? = nil) {
        self.t0 = t0; self.t1 = t1; self.speaker = speaker
        self.text = text; self.conf = conf; self.locale = locale
    }
}


/// One continuous stretch of recorded audio, with its own anchor on the session clock.
///
/// A 4.5-hour recording *will* be interrupted — a phone call, Siri, another app
/// taking the mic. Each interruption ends a segment and the resume starts a new
/// one, so there is never a silent gap that a single file-wide offset would
/// mis-align. This is what keeps "one clock" true for audio.
public struct AudioSegment: Codable, Sendable, Equatable {
    public var index: Int
    /// File name inside the session folder, e.g. "audio-000.m4a".
    public var file: String
    public var t0: Millis
    public var t1: Millis?
    /// Why the previous segment ended: "interruption" | "route-change" | "stop" | "error".
    public var endReason: String?
    public init(index: Int, file: String, t0: Millis, t1: Millis? = nil, endReason: String? = nil) {
        self.index = index; self.file = file; self.t0 = t0; self.t1 = t1; self.endReason = endReason
    }
}
