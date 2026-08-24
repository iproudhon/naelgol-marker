// GolfCaptureMotion — CMMotionActivity, CMPedometer, CMAltimeter.
//
// iOS-only: CMMotionActivityManager and CMPedometer have no macOS counterpart.
// Split out for exactly that reason — see docs/PLAN.md §3.
//
// Altitude: prefer CMAltimeter relative updates (~0.3–1 m) over CLLocation.altitude
// (±10–20 m). Guard on isRelativeAltitudeAvailable / isAbsoluteAltitudeAvailable;
// devices without a barometer fall back to GNSS altitude with a quality flag.
//
// TODO(phase-1): MotionRecorder, AltitudeRecorder.

import Foundation
