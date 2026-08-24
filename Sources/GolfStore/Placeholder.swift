// GolfStore — persistence for rounds, holes, shots, players, courses.
// SwiftData at the iOS 17 floor; the schema is the same shape the reconstruction
// emits, so a reconstructed round saves without translation.
//
// This is what turns one round into a record: past holes, past rounds, and the
// per-player shot history GolfInsight learns from.
//
// TODO(phase-5): model definitions, migration policy, import from round.json.

import Foundation
import GolfSessionFormat
