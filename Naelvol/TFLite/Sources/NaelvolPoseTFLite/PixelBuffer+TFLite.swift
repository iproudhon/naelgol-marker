import Accelerate
import CoreVideo
import CoreGraphics
import Foundation

// Crop, resize and channel conversion for the interpreter's input. Ported from
// Google's TFLite pose sample by way of vipl, with its behaviour intact: this is
// the code that decides what pixels the model actually sees, so a "tidier"
// rewrite changes the keypoints.
extension CVPixelBuffer {
    var size: CGSize {
        CGSize(width: CVPixelBufferGetWidth(self), height: CVPixelBufferGetHeight(self))
    }

    /// Crop `source` (in pixels) and scale it to `size`.
    ///
    /// **The crop is the whole point of MoveNet's tracking**: the model gets a
    /// square around the golfer rather than the whole frame, so a 192-pixel input
    /// is spent on a body instead of on a car park.
    func cropAndResize(fromRect source: CGRect, toSize size: CGSize) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(self)
        guard format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(self)
        let channels = 4

        // Clamped to the buffer: a crop region derived from the previous frame's
        // keypoints can name a rectangle that runs off this frame, and reading
        // past the last row is a crash rather than a bad skeleton.
        let x = max(0, min(Int(source.minX), CVPixelBufferGetWidth(self) - 1))
        let y = max(0, min(Int(source.minY), CVPixelBufferGetHeight(self) - 1))
        let width = max(1, min(Int(source.width), CVPixelBufferGetWidth(self) - x))
        let height = max(1, min(Int(source.height), CVPixelBufferGetHeight(self) - y))

        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(self)?
            .advanced(by: y * rowBytes + x * channels) else { return nil }

        var cropped = vImage_Buffer(data: base, height: UInt(height), width: UInt(width), rowBytes: rowBytes)
        let outRowBytes = Int(size.width) * channels
        guard let outAddress = malloc(Int(size.height) * outRowBytes) else { return nil }
        var resized = vImage_Buffer(data: outAddress, height: UInt(size.height),
                                    width: UInt(size.width), rowBytes: outRowBytes)

        guard vImageScale_ARGB8888(&cropped, &resized, nil, vImage_Flags(0)) == kvImageNoError else {
            free(outAddress)
            return nil
        }

        let release: CVPixelBufferReleaseBytesCallback = { _, pointer in
            if let pointer { free(UnsafeMutableRawPointer(mutating: pointer)) }
        }
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, Int(size.width), Int(size.height), format,
                                                  outAddress, outRowBytes, release, nil, nil, &result)
        guard status == kCVReturnSuccess else {
            free(outAddress)
            return nil
        }
        return result
    }

    /// BGRA → planar RGB, as floats unless the model is quantized.
    func rgbData(isModelQuantized: Bool, imageMean: Float, imageStd: Float) -> Data? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(self) else { return nil }

        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        var sourceBuffer = vImage_Buffer(data: source, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width),
                                         rowBytes: CVPixelBufferGetBytesPerRow(self))
        let outRowBytes = 3 * width
        guard let destination = malloc(height * outRowBytes) else { return nil }
        defer { free(destination) }
        var destinationBuffer = vImage_Buffer(data: destination, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: outRowBytes)

        switch CVPixelBufferGetPixelFormatType(self) {
        case kCVPixelFormatType_32BGRA:
            vImageConvert_BGRA8888toRGB888(&sourceBuffer, &destinationBuffer, UInt32(kvImageNoFlags))
        case kCVPixelFormatType_32ARGB:
            vImageConvert_ARGB8888toRGB888(&sourceBuffer, &destinationBuffer, UInt32(kvImageNoFlags))
        default:
            return nil
        }

        let bytes = Data(bytes: destinationBuffer.data, count: destinationBuffer.rowBytes * height)
        if isModelQuantized { return bytes }
        let floats = [UInt8](bytes).map { (Float($0) - imageMean) / imageStd }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Data {
    func toArray<T>(type: T.Type) -> [T] where T: AdditiveArithmetic {
        var array = [T](repeating: T.zero, count: count / MemoryLayout<T>.stride)
        _ = array.withUnsafeMutableBytes { copyBytes(to: $0) }
        return array
    }
}
