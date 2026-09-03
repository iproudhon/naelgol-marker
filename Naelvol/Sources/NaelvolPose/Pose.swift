import Foundation
import CoreGraphics
import CoreVideo

/// The 17 keypoints MoveNet reports, in the order it reports them.
///
/// **The order is the wire format**, not a preference: the model's output is a
/// flat array and `position` indexes into it. Reordering this enum silently
/// relabels every joint.
public enum BodyPart: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

    public var position: Int { BodyPart.allCases.firstIndex(of: self) ?? 0 }

    public var isFace: Bool {
        switch self {
        case .nose, .leftEye, .rightEye, .leftEar, .rightEar: return true
        default: return false
        }
    }

    public var isLeft: Bool {
        switch self {
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle: return true
        default: return false
        }
    }
}

public struct KeyPoint: Hashable, Sendable {
    public var bodyPart: BodyPart
    public var coordinate: CGPoint
    public var score: Float

    public init(bodyPart: BodyPart = .nose, coordinate: CGPoint = .zero, score: Float = 0) {
        self.bodyPart = bodyPart
        self.coordinate = coordinate
        self.score = score
    }
}

/// One detection, in the coordinate space of the frame it was run on.
public struct Person: Hashable, Sendable {
    public var keyPoints: [KeyPoint]
    public var score: Float

    public init(keyPoints: [KeyPoint], score: Float) {
        self.keyPoints = keyPoints
        self.score = score
    }
}

/// Where one frame's time went. Kept because the live overlay's throttle is a
/// parameter that has to be set against a measurement, not guessed once.
public struct Times: Hashable, Sendable {
    public var preprocessing: TimeInterval
    public var inference: TimeInterval
    public var postprocessing: TimeInterval
    public var total: TimeInterval { preprocessing + inference + postprocessing }

    public init(preprocessing: TimeInterval = 0, inference: TimeInterval = 0, postprocessing: TimeInterval = 0) {
        self.preprocessing = preprocessing
        self.inference = inference
        self.postprocessing = postprocessing
    }
}

/// The seam between naelvol and an inference engine.
///
/// **The engine is not in this package.** `NaelvolPoseTFLite` conforms with
/// MoveNet, and it is a separate *package* because its xcframeworks have no macOS
/// slice; everything on this side of the protocol — the keypoint model, the crop
/// tracker, the validity rules, the collection — builds and tests on a Mac.
public protocol PoseEstimating: AnyObject {
    func estimateSinglePose(on pixelBuffer: CVPixelBuffer) throws -> (Person, Times)
}

public enum PoseEstimationError: Error {
    case modelBusy
    case preprocessingFailed
    case inferenceFailed
    case postProcessingFailed
    case modelMissing(String)
}

/// Which MoveNet build to run.
///
/// Two, with opposite constraints, exactly like the two Whisper models: lightning
/// is what a live preview can afford, thunder is what a recorded swing deserves
/// when somebody is looking at one frame.
public enum PoseModel: String, CaseIterable, Sendable {
    case lightning, thunder

    public var fileName: String {
        switch self {
        case .lightning: return "movenet_lightning"
        case .thunder: return "movenet_thunder"
        }
    }

    public var label: String {
        switch self {
        case .lightning: return "Lightning"
        case .thunder: return "Thunder"
        }
    }
}

/// Which accelerator the interpreter is given.
public enum PoseDelegateKind: String, CaseIterable, Sendable {
    case coreML, metal, cpu

    public var label: String {
        switch self {
        case .coreML: return "Core ML"
        case .metal: return "Metal"
        case .cpu: return "CPU"
        }
    }
}

/// **Models are located, not bundled.** Neither pose target declares `resources:`:
/// a resource declaration generates `Bundle.module`, and a library that can only
/// find its model inside its own bundle cannot be handed a newer one without a
/// rebuild. The host says where the `.tflite` files are; this is the only thing
/// that knows how they are named.
public struct PoseModelLocator: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func url(for model: PoseModel) -> URL? {
        let url = folder.appendingPathComponent("\(model.fileName).tflite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isAvailable(_ model: PoseModel) -> Bool { url(for: model) != nil }
}
