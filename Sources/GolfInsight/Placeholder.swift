// GolfInsight — play suggestion from your own accumulated history.
//
// Not generic advice. The unit is: "on this hole, from this position, at this
// elevation delta, here is what you have actually done before." Needs several
// rounds before it says anything — cold start is honest silence.
//
// TODO(phase-6): per-club dispersion, elevation-adjusted playing distance,
// per-hole outcome history, suggestion ranking with a stated confidence.

import Foundation
import GolfSessionFormat
import GolfStore
