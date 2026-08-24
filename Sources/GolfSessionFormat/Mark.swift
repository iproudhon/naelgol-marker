import Foundation

/// GROUND TRUTH. Deliberately in its own file and its own type so that it is
/// structurally impossible for the evidence-bundle builder to read it.
/// Nothing in GolfReconstruction may import or reference this type.
/// See docs/PLAN.md §4 and docs/poc-plan-round-reconstruction.md §2e.
public struct Mark: Codable, Sendable {
    public var t: Millis
    public var player: String
    public var lat: Double, lon: Double
    public var hole: Int?
    public var note: String?
}

public struct Scorecard: Codable, Sendable {
    /// player -> hole -> strokes
    public var strokes: [String: [Int: Int]]
}
