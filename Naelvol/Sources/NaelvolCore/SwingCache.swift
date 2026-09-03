import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What a listing needs, remembered so a grid of five hundred swings does not open
/// five hundred assets.
///
/// **Derived, never authoritative.** The file is the record; this holds only what
/// reading one produced, and deleting the whole directory costs a slow first scan
/// and nothing else. The key is the file's identity *and* its size and
/// modification date, so a file edited by any other app — vipl, Finder, another
/// naelvol — falls out of the cache instead of being served stale.
public final class SwingCache: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        var sourceID: String
        var relativePath: String
        var size: Int64
        var modified: Date
        var created: Date?
        var duration: Double?
        var width: Double?
        var height: Double?
        var frameRate: Double?
        var meta: SwingMeta
        var isForeign: Bool
        var thumbnail: String?
    }

    private let directory: URL
    private let indexURL: URL
    private var entries: [String: Entry]
    private let queue = DispatchQueue(label: "naelvol.cache")
    private var dirty = false

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("thumbs"),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public static func key(sourceID: String, relativePath: String) -> String {
        "\(sourceID)/\(relativePath)"
    }

    /// The cached swing for a scanned file, or nil if anything about the file has
    /// changed since it was cached.
    public func swing(for entry: SwingSourceResolver.Entry, sourceID: String) -> Swing? {
        let key = Self.key(sourceID: sourceID, relativePath: entry.relativePath)
        var cached: Entry?
        queue.sync { cached = entries[key] }
        guard let c = cached, c.size == entry.size,
              abs(c.modified.timeIntervalSince(entry.modified)) < 1 else { return nil }
        var meta = c.meta
        meta.isForeign = c.isForeign
        var swing = Swing(sourceID: sourceID, url: entry.url, relativePath: entry.relativePath,
                          fileSize: entry.size, modified: entry.modified, created: c.created ?? entry.created,
                          duration: c.duration,
                          dimensions: (c.width).flatMap { w in (c.height).map { CGSize(width: w, height: $0) } },
                          frameRate: c.frameRate, meta: meta)
        if let name = c.thumbnail {
            let url = directory.appendingPathComponent("thumbs").appendingPathComponent(name)
            swing.thumbnailPath = FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        return swing
    }

    public func store(_ swing: Swing) {
        let key = Self.key(sourceID: swing.sourceID, relativePath: swing.relativePath)
        let entry = Entry(sourceID: swing.sourceID, relativePath: swing.relativePath,
                          size: swing.fileSize, modified: swing.modified, created: swing.created,
                          duration: swing.duration,
                          width: swing.dimensions.map { Double($0.width) },
                          height: swing.dimensions.map { Double($0.height) },
                          frameRate: swing.frameRate, meta: swing.meta, isForeign: swing.meta.isForeign,
                          thumbnail: swing.thumbnailPath.map { URL(fileURLWithPath: $0).lastPathComponent })
        queue.sync { entries[key] = entry; dirty = true }
    }

    public func forget(sourceID: String, relativePath: String) {
        let key = Self.key(sourceID: sourceID, relativePath: relativePath)
        queue.sync {
            if let name = entries[key]?.thumbnail {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("thumbs")
                    .appendingPathComponent(name))
            }
            entries[key] = nil
            dirty = true
        }
    }

    /// Drop rows for files that are no longer there. Called after a scan, so a
    /// deleted folder does not keep its thumbnails forever.
    public func prune(keeping keys: Set<String>) {
        queue.sync {
            let gone = entries.keys.filter { !keys.contains($0) }
            for key in gone {
                if let name = entries[key]?.thumbnail {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("thumbs")
                        .appendingPathComponent(name))
                }
                entries[key] = nil
            }
            if !gone.isEmpty { dirty = true }
        }
    }

    public func save() {
        var snapshot: [String: Entry] = [:]
        var needed = false
        queue.sync { snapshot = entries; needed = dirty; dirty = false }
        guard needed else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    public func thumbnailURL(for swing: Swing) -> URL {
        let name = Self.key(sourceID: swing.sourceID, relativePath: swing.relativePath)
            .replacingOccurrences(of: "/", with: "_") + ".jpg"
        return directory.appendingPathComponent("thumbs").appendingPathComponent(name)
    }
}

/// One frame, written as JPEG beside the cache index.
public enum SwingThumbnail {
    /// **A quarter second in, not frame zero.** The first frame of a capture is
    /// routinely the phone still moving to its stand, and a grid of grey blurs is
    /// a grid nobody can read.
    public static let sampleTime = 0.25

    public static func generate(for url: URL, to destination: URL, maxPixel: CGFloat = 480) async -> Bool {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A swing is seconds long, so a tolerance in frames is fine and a
        // zero tolerance makes the generator decode from the last sync sample.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let at = duration > sampleTime * 2 ? sampleTime : max(0, duration / 2)
        let time = CMTime(seconds: at, preferredTimescale: 600)

        guard let image = try? await generator.image(at: time).image else { return false }
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
