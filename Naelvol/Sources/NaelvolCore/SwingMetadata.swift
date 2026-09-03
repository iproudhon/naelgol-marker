import Foundation
import AVFoundation
import CoreGraphics

/// Reading and writing the record a swing video carries inside itself.
///
/// **There is no index file, by decision.** The video *is* the record, so this
/// type is the whole persistence layer: what it cannot read does not exist, and
/// what it writes is what survives the file being AirDropped to somebody else.
public enum SwingMetadata {
    /// naelvol's own key. A custom `mdta` identifier, deliberately **not**
    /// `quickTimeMetadataKeyDescription`: that field is vipl's cell caption and
    /// its tag search, and JSON in it turns every swing into a row of braces in
    /// the app whose folder this feature exists to browse.
    public static let payloadKey = "com.naelgol.naelvol.swing"
    public static let payloadIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(payloadKey)")

    // MARK: - Reading

    /// Everything the browse grid needs from one file.
    ///
    /// Loaded with the async `load(_:)` accessors rather than the synchronous
    /// properties: on a bookmarked folder the file may be an iCloud placeholder,
    /// and the synchronous path blocks whatever thread asks.
    public static func probe(url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        var probe = Probe(meta: parse(metadata))

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { probe.duration = seconds }
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let size = try? await track.load(.naturalSize) {
                let t = (try? await track.load(.preferredTransform)) ?? .identity
                probe.dimensions = size.applying(t).absolute
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                probe.frameRate = Double(rate)
            }
        }
        probe.created = creationDate(metadata)
        return probe
    }

    public struct Probe: Sendable {
        public var meta: SwingMeta
        public var duration: Double?
        public var dimensions: CGSize?
        public var frameRate: Double?
        public var created: Date?
        public init(meta: SwingMeta) { self.meta = meta }
    }

    /// Turn a file's metadata items into a `SwingMeta`.
    ///
    /// Two sources, and **naelvol's own key wins when both are present** — the
    /// description is a rendering of it, and either app may have rewritten the
    /// description by hand since.
    public static func parse(_ items: [AVMetadataItem]) -> SwingMeta {
        var meta: SwingMeta
        if let payload = string(items, identifier: payloadIdentifier) ?? string(items, key: payloadKey),
           let data = payload.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SwingMeta.self, from: data) {
            meta = decoded
        } else {
            // **A file with no payload is not an error — it is somebody else's
            // file**, most likely vipl's, whose description is free text used as
            // a tag search. Split it into tags and keep it whole as the note, so
            // nothing a person typed is thrown away.
            var context = SwingContext()
            if let description = string(items, key: AVMetadataKey.quickTimeMetadataKeyDescription.rawValue)
                ?? string(items, key: AVMetadataKey.commonKeyDescription.rawValue) {
                context.tags = tags(from: description)
                context.note = description
            }
            meta = SwingMeta(context: context, isForeign: true)
        }
        if meta.location == nil { meta.location = location(items) }
        return meta
    }

    /// vipl's convention: whitespace- or comma-separated words, matched as
    /// substrings. Kept identical so a search that worked there works here.
    public static func tags(from description: String) -> [String] {
        description
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Writing

    /// The items a writer stamps onto a new recording, or an exporter carries
    /// onto a copy. Both keys, always: the payload is the record and the
    /// description is how another app renders it.
    public static func items(for meta: SwingMeta, location: SwingLocation? = nil) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        var payload = meta
        payload.location = location ?? meta.location
        if let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) {
            let item = AVMutableMetadataItem()
            item.identifier = payloadIdentifier
            item.value = json as NSString
            // `und` rather than the current locale: this payload is machine-read
            // and a locale-tagged item is filtered out of a differently-localised
            // read on the way back.
            item.extendedLanguageTag = "und"
            out.append(item)
        }
        let caption = payload.context.caption
        if !caption.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = AVMetadataKey.quickTimeMetadataKeyDescription as NSString
            item.value = caption as NSString
            item.extendedLanguageTag = "und"
            out.append(item)
        }
        if let l = payload.location {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709 as NSString
            item.value = iso6709(l) as NSString
            item.extendedLanguageTag = "und"
            out.append(item)
        }
        return out
    }

    /// Rewrite a file's metadata in place.
    ///
    /// **A metadata edit is a whole-file rewrite** — QuickTime metadata is not
    /// patchable through AVFoundation — so this is passthrough export to a temp
    /// file and a replace. Two things it must do and vipl's version does not:
    /// **await the export** (vipl calls its completion handler synchronously
    /// after `exportAsynchronously`, so every caller is told "failed" while the
    /// export is still running), and **preserve the file's creation and
    /// modification dates**, which are what the grid sorts on.
    public static func write(_ meta: SwingMeta, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SwingMetadataError.exportUnavailable
        }
        var items = try await asset.load(.metadata)
        // Drop every item we are about to write, by identifier *and* by key: an
        // item read back from a file may carry either depending on how it was
        // written, and a duplicate key means the reader picks one at random.
        let ours: Set<String> = [payloadKey,
                                 AVMetadataKey.quickTimeMetadataKeyDescription.rawValue,
                                 AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue]
        items = items.filter { item in
            if item.identifier == payloadIdentifier { return false }
            if let key = item.key as? String, ours.contains(key) { return false }
            return true
        }
        export.metadata = items + self.items(for: meta)
        export.outputFileType = .mov

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("naelvol-meta-\(UUID().uuidString).mov")
        export.outputURL = tmp
        await export.export()
        if let error = export.error {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw SwingMetadataError.exportFailed(export.status)
        }
        try replace(url, with: tmp)
    }

    /// Swap `tmp` in for `url`, keeping the original's timestamps. The grid sorts
    /// on creation date, so a metadata edit that restamped it would reorder the
    /// library every time somebody fixed a tag.
    public static func replace(_ url: URL, with tmp: URL) throws {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        var keep: [FileAttributeKey: Any] = [:]
        if let created = attrs?[.creationDate] as? Date { keep[.creationDate] = created }
        if let modified = attrs?[.modificationDate] as? Date { keep[.modificationDate] = modified }
        if !keep.isEmpty { try? fm.setAttributes(keep, ofItemAtPath: url.path) }
    }

    // MARK: - Pieces

    static func string(_ items: [AVMetadataItem], identifier: AVMetadataIdentifier) -> String? {
        AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            .compactMap { $0.stringValue }.first
    }

    static func string(_ items: [AVMetadataItem], key: String) -> String? {
        for item in items {
            let itemKey = (item.key as? String) ?? (item.key as? NSString).map(String.init)
            if itemKey == key, let value = item.stringValue { return value }
        }
        return nil
    }

    static func creationDate(_ items: [AVMetadataItem]) -> Date? {
        for item in items {
            guard let key = (item.key as? String) ?? (item.key as? NSString).map(String.init) else { continue }
            guard key == AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue
                    || key == AVMetadataKey.commonKeyCreationDate.rawValue else { continue }
            if let date = item.dateValue { return date }
            if let text = item.stringValue, let date = ISO8601DateFormatter().date(from: text) { return date }
        }
        return nil
    }

    static func location(_ items: [AVMetadataItem]) -> SwingLocation? {
        guard let text = string(items, key: AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue)
                ?? string(items, key: AVMetadataKey.commonKeyLocation.rawValue) else { return nil }
        return parseISO6709(text)
    }

    /// `+37.4056-121.9481+016.000/` — sign-prefixed fixed-point fields, in order.
    public static func parseISO6709(_ text: String) -> SwingLocation? {
        var numbers: [Double] = []
        var current = ""
        for ch in text {
            if ch == "+" || ch == "-" {
                if let value = Double(current) { numbers.append(value) }
                current = String(ch)
            } else if ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                if let value = Double(current) { numbers.append(value) }
                current = ""
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2 else { return nil }
        return SwingLocation(latitude: numbers[0], longitude: numbers[1],
                             altitude: numbers.count > 2 ? numbers[2] : nil)
    }

    public static func iso6709(_ l: SwingLocation) -> String {
        String(format: "%+08.4lf%+09.4lf%+.0lf/", l.latitude, l.longitude, l.altitude ?? 0)
    }
}

public enum SwingMetadataError: Error {
    case exportUnavailable
    case exportFailed(AVAssetExportSession.Status)
}

extension CGSize {
    /// A transformed size can come back negative — a rotation flips a dimension —
    /// and a negative height renders as a zero-height cell rather than as an error.
    var absolute: CGSize { CGSize(width: abs(width), height: abs(height)) }
}
