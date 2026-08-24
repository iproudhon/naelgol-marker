// GolfCaptureCore — audio + location capture into a SessionFolder.
//
// Floor: iOS 17 / macOS 14 for the location path (CLBackgroundActivitySession,
// CLLocationUpdate.liveUpdates) — gate with @available(iOS 17, macOS 14, *).
// AVAudioEngine and CoreLocation are cross-platform, so this target stays
// macOS-testable: you can develop the pipeline without a device in the loop.
//
// TODO(phase-1): AudioRecorder, LocationRecorder, MarkRecorder, RoundSession.

import Foundation
