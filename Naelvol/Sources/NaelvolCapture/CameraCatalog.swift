#if os(iOS)
import AVFoundation
import CoreMedia
import Foundation

/// A camera and one of its formats, as the picker offers them.
public struct CaptureOption: Identifiable, Hashable, Sendable {
    public var id: String { "\(deviceID)|\(width)x\(height)@\(Int(frameRate))" }
    public let deviceID: String
    public let deviceName: String
    public let position: AVCaptureDevice.Position
    public let width: Int32
    public let height: Int32
    public let frameRate: Double
    public let formatIndex: Int

    /// `Back Wide · 1920×1080 · 240 fps`. The frame rate is what the golfer is
    /// choosing between; the resolution is the price.
    public var label: String {
        "\(deviceName) · \(width)×\(height) · \(Int(frameRate)) fps"
    }

    public var isHighSpeed: Bool { frameRate >= 120 }
}

/// What this phone can film a swing at.
///
/// **Depth is not enumerated, and that is what unlocks the frame rate.** vipl
/// capped depth-capable candidates at 640 px and drove the *video* at the depth
/// format's rate, so high-speed capture and depth capture were mutually exclusive
/// modes. With `.moz` out of scope the constraint goes with it: every format is a
/// video format and the fastest one wins.
public enum CameraCatalog {
    public static func options() -> [CaptureOption] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                       position: .unspecified)
        var out: [CaptureOption] = []
        for device in session.devices {
            // **One entry per resolution, at that resolution's fastest rate.** A
            // modern phone reports dozens of formats per camera and all but a
            // handful differ in ways nobody filming a swing is choosing between.
            var best: [String: (Int, AVCaptureDevice.Format, Double)] = [:]
            for (index, format) in device.formats.enumerated() {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                guard rate > 0 else { continue }
                let key = "\(dims.width)x\(dims.height)"
                if let existing = best[key], existing.2 >= rate { continue }
                best[key] = (index, format, rate)
            }
            for (_, entry) in best {
                let dims = CMVideoFormatDescriptionGetDimensions(entry.1.formatDescription)
                out.append(CaptureOption(deviceID: device.uniqueID, deviceName: name(for: device),
                                         position: device.position,
                                         width: dims.width, height: dims.height,
                                         frameRate: entry.2, formatIndex: entry.0))
            }
        }
        // Fastest first, then largest: the reason to open this list is slow motion.
        return out.sorted {
            $0.frameRate != $1.frameRate ? $0.frameRate > $1.frameRate
                : $0.width * $0.height > $1.width * $1.height
        }
    }

    public static func device(id: String) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified).devices.first { $0.uniqueID == id }
    }

    static func name(for device: AVCaptureDevice) -> String {
        let side = device.position == .front ? "Front" : "Back"
        let lens: String
        switch device.deviceType {
        case .builtInUltraWideCamera: lens = "Ultra Wide"
        case .builtInTelephotoCamera: lens = "Telephoto"
        default: lens = "Wide"
        }
        return "\(side) \(lens)"
    }
}
#endif
