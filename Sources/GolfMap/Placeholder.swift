// GolfMap — the round on a map, with elevation.
//
// Elevation is the differentiator: a hole that plays 8 m uphill plays roughly a
// club longer, and GNSS altitude (±10–20 m) cannot resolve that. Barometric
// relative altitude can (~0.3–1 m). Renders the shot track, per-hole elevation
// profile, and tee->green delta.
//
// TODO(phase-6): MapKit overlays, elevation profile view, replay scrubber.

import Foundation
import GolfSessionFormat
import GolfStore
