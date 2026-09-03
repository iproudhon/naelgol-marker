#if os(iOS)
import AVFoundation
import CoreMotion
import Foundation
import NaelvolCore

/// Writes one recording: video, audio and a per-frame gravity track.
///
/// `AVAssetWriter` rather than `AVCaptureMovieFileOutput` for one reason — a
/// **timed metadata track** — and one consequence: the sample buffers come through
/// the app, so the live pose overlay and the hand trigger read the same frames
/// that are being written rather than a second preview stream.
public final class SwingRecorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var metadataInput: AVAssetWriterInput?
    private var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    private var started = false

    public private(set) var url: URL?
    public private(set) var startTime: CMTime = .zero
    public private(set) var latestTime: CMTime = .zero
    public private(set) var isRecording = false

    public var duration: CMTime { isRecording ? latestTime - startTime : .zero }

    public init() {}

    /// - Parameter meta: the swing's record, **stamped at the start of the
    ///   recording, not applied afterwards**. A capture from the hole view knows
    ///   its course and hole at the moment the button is pressed; making that a
    ///   later metadata edit means a rewrite of the whole file and a window in
    ///   which the swing is anonymous.
    public func start(url: URL, videoSettings: [String: Any]?, transform: CGAffineTransform,
                      audioSettings: [String: Any]?, meta: SwingMeta) throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = transform
        if writer.canAdd(video) { writer.add(video) }

        var audio: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); audio = input }
        }

        // The metadata input needs a format hint, and the only way to get one is
        // to build a sample group and ask it.
        let hint = AVMutableMetadataItem()
        hint.identifier = SwingRecorder.gravityIdentifier
        hint.value = "0 0 0" as NSString
        let group = AVTimedMetadataGroup(items: [hint], timeRange: CMTimeRange(start: .zero, duration: .zero))
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                               sourceFormatHint: group.copyFormatDescription())
        metadataInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        if writer.canAdd(metadataInput) { writer.add(metadataInput) }

        writer.metadata = SwingMetadata.items(for: meta) + [creationDateItem()]
        guard writer.startWriting() else { throw writer.error ?? SwingRecorderError.cannotStart }

        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.metadataInput = metadataInput
        self.metadataAdaptor = adaptor
        self.url = url
        self.started = false
        self.isRecording = true
    }

    public func append(_ sampleBuffer: CMSampleBuffer, for mediaType: AVMediaType,
                       gravity: CMAcceleration? = nil) {
        guard isRecording, let writer, writer.status == .writing else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // **The session starts on the first sample, whatever kind it is.** Starting
        // it at `start(url:)` stamps a zero that no buffer matches, and every
        // frame then lands after a gap of however long the camera took to warm up.
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        latestTime = time

        switch mediaType {
        case .video:
            guard videoInput?.isReadyForMoreMediaData == true else { return }
            videoInput?.append(sampleBuffer)
            if let gravity, metadataInput?.isReadyForMoreMediaData == true {
                let item = AVMutableMetadataItem()
                item.identifier = SwingRecorder.gravityIdentifier
                item.value = GravitySource.string(gravity) as NSString
                // A zero-duration range at the frame's own time: gravity is a
                // reading, not an interval.
                let group = AVTimedMetadataGroup(items: [item],
                                                 timeRange: CMTimeRange(start: time, duration: .zero))
                metadataAdaptor?.append(group)
            }
        case .audio:
            guard audioInput?.isReadyForMoreMediaData == true else { return }
            audioInput?.append(sampleBuffer)
        default:
            break
        }
    }

    /// Finish the file. **Awaited, and the writer is released before it returns** —
    /// a movie whose writer is still alive is a file that may not open at all,
    /// and the browse grid opens it the instant this comes back.
    @discardableResult
    public func stop() async -> URL? {
        guard isRecording, let writer else { return nil }
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        metadataInput?.markAsFinished()
        await writer.finishWriting()
        let finished = writer.status == .completed ? url : nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.metadataInput = nil
        self.metadataAdaptor = nil
        self.url = nil
        self.started = false
        return finished
    }

    private func creationDateItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        item.value = ISO8601DateFormatter().string(from: Date()) as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// The key lives in `NaelvolCore` beside the reader, so a recording written
    /// here and levelled there cannot disagree about what it is called.
    public static let gravityKey = GravityTrack.key
    public static let gravityIdentifier = GravityTrack.identifier
}

public enum SwingRecorderError: Error {
    case cannotStart
    case blocked(String)
    case noCamera
}
#endif
