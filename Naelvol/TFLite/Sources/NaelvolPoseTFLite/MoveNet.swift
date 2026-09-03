import Foundation
import CoreVideo
import CoreGraphics
import TensorFlowLite
import NaelvolPose
import os

/// MoveNet, on TensorFlow Lite.
///
/// **The same `.tflite` files vipl runs**, deliberately: there is no official
/// CoreML MoveNet, `coremltools` has no TFLite frontend, and a conversion of the
/// TF Hub SavedModel would have to be proven keypoint-for-keypoint before it could
/// replace this. Running the file itself is zero model risk; the cost is packaging,
/// which is why this target lives in its own package.
///
/// One instance runs one frame at a time (`isProcessing`), because the interpreter
/// is not reentrant. A second caller is refused with `.modelBusy` rather than
/// queued: the live path wants the *latest* frame, and a queue of stale frames is
/// an overlay that lags the golfer.
public final class MoveNet: PoseEstimating, @unchecked Sendable {
    private let interpreter: Interpreter
    private var inputTensor: Tensor
    private var outputTensor: Tensor

    private let imageMean: Float = 0
    private let imageStd: Float = 1
    private var crop = MoveNetCrop()
    private var cropRegion: RectF?
    private var isProcessing = false

    public let model: PoseModel
    public let delegateKind: PoseDelegateKind

    /// - Parameters:
    ///   - url: the `.tflite` file. **Located by the host**, never resolved from
    ///     `Bundle.main` the way vipl does — a library that can only find its
    ///     model inside its own bundle cannot be handed a newer one.
    ///   - delegateKind: Core ML first, Metal second, CPU last. Core ML is what
    ///     puts MoveNet on the ANE; the caller can force one for a comparison.
    public init(url: URL, model: PoseModel = .thunder,
                delegateKind: PoseDelegateKind = .coreML, threadCount: Int = 4) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PoseEstimationError.modelMissing(url.lastPathComponent)
        }
        self.model = model

        var options = Interpreter.Options()
        options.threadCount = threadCount

        // **A delegate that will not initialise returns nil rather than
        // throwing**, so the fallback is a working interpreter on the CPU and not
        // a pose feature that is simply absent on some device.
        var delegates: [Delegate] = []
        var resolved = delegateKind
        switch delegateKind {
        case .coreML:
            if let d = CoreMLDelegate() { delegates.append(d) } else {
                delegates.append(MetalDelegate())
                resolved = .metal
            }
        case .metal:
            delegates.append(MetalDelegate())
        case .cpu:
            break
        }
        self.delegateKind = resolved

        interpreter = try Interpreter(modelPath: url.path, options: options,
                                      delegates: delegates.isEmpty ? nil : delegates)
        try interpreter.allocateTensors()
        inputTensor = try interpreter.input(at: 0)
        outputTensor = try interpreter.output(at: 0)
    }

    public func reset() { cropRegion = nil }

    public func estimateSinglePose(on pixelBuffer: CVPixelBuffer) throws -> (Person, Times) {
        guard !isProcessing else { throw PoseEstimationError.modelBusy }
        isProcessing = true
        defer { isProcessing = false }

        let preStart = Date()
        guard let data = preprocess(pixelBuffer) else { throw PoseEstimationError.preprocessingFailed }
        let preTime = Date().timeIntervalSince(preStart)

        let inferenceStart = Date()
        do {
            try interpreter.copy(data, toInputAt: 0)
            try interpreter.invoke()
            outputTensor = try interpreter.output(at: 0)
        } catch {
            os_log("naelvol: interpreter failed: %{public}@", type: .error, String(describing: error))
            throw PoseEstimationError.inferenceFailed
        }
        let inferenceTime = Date().timeIntervalSince(inferenceStart)

        let postStart = Date()
        guard let person = postprocess(imageSize: pixelBuffer.size, modelOutput: outputTensor) else {
            throw PoseEstimationError.postProcessingFailed
        }
        let postTime = Date().timeIntervalSince(postStart)

        return (person, Times(preprocessing: preTime, inference: inferenceTime, postprocessing: postTime))
    }

    private func preprocess(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let dimensions = inputTensor.shape.dimensions
        guard dimensions.count >= 3 else { return nil }
        let inputWidth = CGFloat(dimensions[1]), inputHeight = CGFloat(dimensions[2])
        let imageWidth = pixelBuffer.size.width, imageHeight = pixelBuffer.size.height

        let region = cropRegion ?? crop.initialRegion(imageWidth: imageWidth, imageHeight: imageHeight)
        cropRegion = region

        guard let thumbnail = pixelBuffer.cropAndResize(
            fromRect: region.scaled(width: imageWidth, height: imageHeight),
            toSize: CGSize(width: inputWidth, height: inputHeight)) else { return nil }

        return thumbnail.rgbData(isModelQuantized: inputTensor.dataType == .uInt8,
                                 imageMean: imageMean, imageStd: imageStd)
    }

    private func postprocess(imageSize: CGSize, modelOutput: Tensor) -> Person? {
        let imageWidth = imageSize.width, imageHeight = imageSize.height
        let region = cropRegion ?? crop.initialRegion(imageWidth: imageWidth, imageHeight: imageHeight)
        let minX = region.left * imageWidth, minY = region.top * imageHeight

        let output = modelOutput.data.toArray(type: Float32.self)
        let dimensions = modelOutput.shape.dimensions
        guard dimensions.count >= 3 else { return nil }
        let numKeyPoints = min(dimensions[2], BodyPart.allCases.count)
        guard output.count >= numKeyPoints * 3 else { return nil }

        let inputWidth = CGFloat(inputTensor.shape.dimensions[1])
        let inputHeight = CGFloat(inputTensor.shape.dimensions[2])
        let widthRatio = region.width * imageWidth / inputWidth
        let heightRatio = region.height * imageHeight / inputHeight

        // The model reports `(y, x, score)` **in that order** and normalised to
        // its own input, so the y term reads index 0 and the x term index 1.
        // Swapping them yields a skeleton that looks like a person lying down.
        var keyPoints: [KeyPoint] = []
        var total: Float = 0
        for index in 0..<numKeyPoints {
            let x = (CGFloat(output[index * 3 + 1]) * inputWidth) * widthRatio + minX
            let y = (CGFloat(output[index * 3 + 0]) * inputHeight) * heightRatio + minY
            let score = output[index * 3 + 2]
            total += score
            keyPoints.append(KeyPoint(bodyPart: BodyPart.allCases[index],
                                      coordinate: CGPoint(x: x, y: y), score: score))
        }

        cropRegion = crop.nextRegion(keyPoints: keyPoints, imageWidth: imageWidth, imageHeight: imageHeight)
        return Person(keyPoints: keyPoints, score: total / Float(numKeyPoints))
    }
}

/// Loading and holding the two models.
///
/// **An LRU of two, not one slot**, for the reason `WhisperEngine` needed the same
/// fix: the live overlay and a whole-video pass use *different* models, and a
/// single slot makes each evict the other on every switch — which only shows up
/// once the two models actually differ, the configuration the feature exists for.
public actor MoveNetStore {
    private var loaded: [PoseModel: MoveNet] = [:]
    private var order: [PoseModel] = []
    private var loading: [PoseModel: Task<Void, Never>] = [:]
    private let locator: PoseModelLocator
    private let capacity = 2

    public init(locator: PoseModelLocator) { self.locator = locator }

    public func model(_ model: PoseModel, delegateKind: PoseDelegateKind = .coreML) async throws -> MoveNet {
        if let existing = loaded[model] { touch(model); return existing }
        // **Loads are deduplicated in flight.** An actor suspends at every
        // `await`, so two callers that both miss the cache would otherwise both
        // build an interpreter over the same file.
        if let task = loading[model] {
            await task.value
            if let existing = loaded[model] { touch(model); return existing }
        }
        guard let url = locator.url(for: model) else {
            throw PoseEstimationError.modelMissing(model.fileName)
        }
        let net = try MoveNet(url: url, model: model, delegateKind: delegateKind)
        loaded[model] = net
        touch(model)
        evictIfNeeded()
        return net
    }

    public func preload(_ models: [PoseModel], delegateKind: PoseDelegateKind = .coreML) async {
        for model in models { _ = try? await self.model(model, delegateKind: delegateKind) }
    }

    public func isAvailable(_ model: PoseModel) -> Bool { locator.isAvailable(model) }

    private func touch(_ model: PoseModel) {
        order.removeAll { $0 == model }
        order.append(model)
    }

    private func evictIfNeeded() {
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            loaded[oldest] = nil
        }
    }
}
