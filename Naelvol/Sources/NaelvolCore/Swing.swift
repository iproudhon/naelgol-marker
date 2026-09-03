import Foundation
import CoreGraphics

/// What a swing video is *about*, as naelvol understands it.
///
/// **Every field is a plain value.** Nothing here knows what a `Course`, a `Hole`
/// or a `Player` is — that is the whole reason this package can be lifted out. The
/// host fills these in from its own types and reads them back the same way.
///
/// `hole` is the **1-based playing index**, which is what a scorecard column means.
/// A course's own hole label (`"황룡/3"`) rides along in `holeRef` for display and
/// is never a key: courses exist whose holes are not numbered 1…18.
public struct SwingContext: Codable, Hashable, Sendable {
    public var courseID: String?
    public var courseName: String?
    public var hole: Int?
    public var holeRef: String?
    public var playerID: String?
    public var playerName: String?
    public var roundID: String?
    public var tags: [String]
    public var note: String?

    public init(courseID: String? = nil, courseName: String? = nil,
                hole: Int? = nil, holeRef: String? = nil,
                playerID: String? = nil, playerName: String? = nil,
                roundID: String? = nil, tags: [String] = [], note: String? = nil) {
        self.courseID = courseID
        self.courseName = courseName
        self.hole = hole
        self.holeRef = holeRef
        self.playerID = playerID
        self.playerName = playerName
        self.roundID = roundID
        self.tags = tags
        self.note = note
    }

    public var isEmpty: Bool {
        courseID == nil && courseName == nil && hole == nil && holeRef == nil
            && playerID == nil && playerName == nil && roundID == nil
            && tags.isEmpty && (note ?? "").isEmpty
    }

    /// The hole as a person reads it: the course's own label if there is one,
    /// otherwise the playing index.
    public var holeLabel: String? {
        if let holeRef, !holeRef.isEmpty { return holeRef }
        if let hole { return String(hole) }
        return nil
    }

    /// The one-line sentence written into the QuickTime `description` key.
    ///
    /// **This is a rendering, not the record.** The record is the JSON under
    /// `com.naelgol.naelvol.swing`; the description exists because that field is
    /// vipl's cell caption and its tag search, so a naelvol file dropped in a
    /// shared folder has to read as a sentence there rather than as raw braces.
    public var caption: String {
        var parts: [String] = []
        if let courseName, !courseName.isEmpty { parts.append(courseName) }
        if let holeLabel { parts.append(holeLabel) }
        if let playerName, !playerName.isEmpty { parts.append(playerName) }
        if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// Where a swing came from, as far as its own file can say.
public struct SwingLocation: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// The record a swing video carries inside itself.
///
/// `version` is on the wire so a future reader can tell a v1 payload from a v2 one
/// without guessing. The rule for moving it is the one `RoundBundle` uses: an
/// *added* key is invisible to an older reader and needs no bump; a *removed*
/// non-optional one is a hard break and does.
public struct SwingMeta: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var context: SwingContext
    public var location: SwingLocation?

    /// True when the payload was reconstructed from a plain-text description
    /// rather than read from naelvol's own key — i.e. this is somebody else's
    /// file, most likely vipl's. The UI says so rather than pretending the
    /// structured fields are simply empty.
    public var isForeign: Bool

    public init(context: SwingContext = SwingContext(),
                location: SwingLocation? = nil,
                version: Int = SwingMeta.currentVersion,
                isForeign: Bool = false) {
        self.version = version
        self.context = context
        self.location = location
        self.isForeign = isForeign
    }

    private enum CodingKeys: String, CodingKey { case version, context, location }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? SwingMeta.currentVersion
        context = try c.decodeIfPresent(SwingContext.self, forKey: .context) ?? SwingContext()
        location = try c.decodeIfPresent(SwingLocation.self, forKey: .location)
        isForeign = false
    }
}

/// One video, as the browse grid needs it.
///
/// **The file is the record**; this is what reading it produced. `id` is derived
/// from the source and the path rather than stored anywhere: a swing has no
/// identity of its own, which is the cost of the no-index decision and is why a
/// file renamed outside naelvol reads as a new swing.
public struct Swing: Identifiable, Hashable, Sendable {
    public var sourceID: String
    public var url: URL
    public var relativePath: String
    public var fileSize: Int64
    public var modified: Date
    public var created: Date?
    public var duration: Double?
    public var dimensions: CGSize?
    public var frameRate: Double?
    public var meta: SwingMeta
    /// Nil until the thumbnail has been generated; a path, not an image, so a
    /// listing of five hundred swings is not five hundred decoded bitmaps.
    public var thumbnailPath: String?

    public var id: String { "\(sourceID)/\(relativePath)" }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(sourceID: String, url: URL, relativePath: String,
                fileSize: Int64, modified: Date, created: Date? = nil,
                duration: Double? = nil, dimensions: CGSize? = nil,
                frameRate: Double? = nil, meta: SwingMeta = SwingMeta(),
                thumbnailPath: String? = nil) {
        self.sourceID = sourceID
        self.url = url
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modified = modified
        self.created = created
        self.duration = duration
        self.dimensions = dimensions
        self.frameRate = frameRate
        self.meta = meta
        self.thumbnailPath = thumbnailPath
    }

    /// What the grid puts under the thumbnail. Duration first, because it is the
    /// one thing every swing has.
    public var caption: String {
        var parts: [String] = []
        if let duration { parts.append(Swing.durationText(duration)) }
        let c = meta.context.caption
        if !c.isEmpty { parts.append(c) } else { parts.append(name) }
        return parts.joined(separator: "  ")
    }

    /// `1:04.2` — subseconds included, because a swing is measured in tenths and a
    /// clip of one is a few seconds long.
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let m = Int(seconds) / 60, s = seconds - Double(m * 60)
        return m > 0 ? String(format: "%d:%04.1f", m, s) : String(format: "%.1fs", s)
    }
}
