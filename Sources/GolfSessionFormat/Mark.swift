import Foundation

// GROUND TRUTH — every type in this file.
//
// Nothing in GolfReconstruction may import or reference anything here. The
// firewall is a CONVENTION, not a compiler guarantee: GolfReconstruction depends
// on GolfSessionFormat, which is this module. Splitting these into their own
// target that only GolfEval depends on was raised 2026-08-24 and deferred.
// See CLAUDE.md "Known gaps", docs/PLAN.md §4, docs/poc-plan-round-reconstruction.md §2e.

/// A timestamped observation recorded by hand during a round, for eval only.
///
/// Position is optional and the timestamp is not: the phone may have no fix yet
/// when the button is tapped, and a mark with a time but no coordinate is still
/// worth far more than a mark that was never recorded. Never drop one for want
/// of a fix.
public struct Mark: Codable, Sendable {
    public var t: Millis
    public var player: String
    public var lat: Double?, lon: Double?
    /// Horizontal accuracy of the fix this mark borrowed, and how old it was in
    /// milliseconds — a mark anchored to a 90-second-old fix is a weaker claim.
    public var hAcc: Double?
    public var fixAgeMs: Millis?
    public var hole: Int?
    public var note: String?
    public init(t: Millis, player: String, lat: Double? = nil, lon: Double? = nil,
                hAcc: Double? = nil, fixAgeMs: Millis? = nil,
                hole: Int? = nil, note: String? = nil) {
        self.t = t; self.player = player; self.lat = lat; self.lon = lon
        self.hAcc = hAcc; self.fixAgeMs = fixAgeMs
        self.hole = hole; self.note = note
    }
}

public struct Scorecard: Codable, Sendable, Equatable {
    /// player -> hole -> strokes
    public var strokes: [String: [Int: Int]]
    public init(strokes: [String: [Int: Int]]) { self.strokes = strokes }
}


/// A user's amendment to a reconstructed round. GROUND TRUTH — see the file header.
///
/// Corrections are the reason the far-field capture rate stopped being a gate
/// (PLAN §3): the reconstruction is a draft, and this is how it gets fixed. They
/// are append-only and never rewritten, because the *sequence* of corrections is
/// the labeled error set GolfEval consumes — collapsing them to a final state
/// would throw away exactly what makes them valuable.
public struct Correction: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Reconstruction missed a shot entirely — the expensive error.
        case addShot
        /// Reconstruction invented a shot that never happened.
        case deleteShot
        /// Right shot, wrong player. The metric the product lives on.
        case reattribute
        case editClub
        case editScore
        case editLie
        case editLocation
        /// Free text the user typed; no structured claim.
        case note
    }

    /// When the correction was made (not when the shot happened).
    public var t: Millis
    public var kind: Kind
    /// Identifies the shot in round.json being amended. nil for `.addShot`.
    public var shotID: String?
    public var hole: Int?
    /// When the shot itself happened, for `.addShot` or a timing fix.
    public var shotT: Millis?
    public var player: String?
    public var club: String?
    public var strokes: Int?
    public var lie: String?
    public var lat: Double?, lon: Double?
    public var note: String?

    public init(t: Millis, kind: Kind, shotID: String? = nil, hole: Int? = nil,
                shotT: Millis? = nil, player: String? = nil, club: String? = nil,
                strokes: Int? = nil, lie: String? = nil,
                lat: Double? = nil, lon: Double? = nil, note: String? = nil) {
        self.t = t; self.kind = kind; self.shotID = shotID; self.hole = hole
        self.shotT = shotT; self.player = player; self.club = club
        self.strokes = strokes; self.lie = lie
        self.lat = lat; self.lon = lon; self.note = note
    }
}
