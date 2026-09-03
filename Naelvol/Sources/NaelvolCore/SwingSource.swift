import Foundation

/// A folder naelvol lists swings from.
///
/// Two kinds, and the difference is who owns the files. `.app` is naelvol's own
/// directory inside the host app's container — writable, always present, and where
/// a capture lands. `.bookmarked` is a folder the user picked in a document picker;
/// naelvol holds a security-scoped bookmark to it and treats it as **read-only**,
/// because the files belong to whatever put them there.
public struct SwingSource: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case app, bookmarked }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Nil for `.app`. Security-scoped on macOS; a plain bookmark on iOS, where
    /// scope comes from the picker's grant.
    public var bookmark: Data?
    /// A folder the user picked may hold a tree; naelvol's own never does.
    public var recurse: Bool
    /// Set when the bookmark resolved stale. **A first-class state, not an error
    /// toast**: the row says so and re-picking the folder repairs it in place,
    /// keeping the id so cached metadata survives.
    public var needsPermission: Bool

    public init(id: String = UUID().uuidString, name: String, kind: Kind,
                bookmark: Data? = nil, recurse: Bool = false,
                needsPermission: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bookmark = bookmark
        self.recurse = recurse
        self.needsPermission = needsPermission
    }

    public var isWritable: Bool { kind == .app }

    public static let appSourceID = "naelvol.app"
}

/// The video extensions naelvol lists. `.moz` is deliberately absent: point cloud
/// capture is not ported, and listing a file nothing here can open is worse than
/// not listing it.
public let swingFileExtensions: Set<String> = ["mov", "mp4", "m4v"]

/// Resolving a source to a directory, and reading files out of it.
///
/// **Every read of a bookmarked folder is wrapped in
/// `startAccessingSecurityScopedResource()` balanced with `defer`.** Without the
/// scope the read fails with an error that reads like a corrupt file; without the
/// balance it leaks a sandbox extension. Same rule the round importer follows.
public struct SwingSourceResolver: Sendable {
    /// The host app's own swing directory. Injected rather than computed so the
    /// scan is testable against a temporary directory.
    public let appRoot: URL

    public init(appRoot: URL) { self.appRoot = appRoot }

    public struct Resolved {
        public let url: URL
        public let isStale: Bool
        public let scoped: Bool
    }

    public func resolve(_ source: SwingSource) throws -> Resolved {
        switch source.kind {
        case .app:
            try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
            return Resolved(url: appRoot, isStale: false, scoped: false)
        case .bookmarked:
            guard let bookmark = source.bookmark else { throw SwingSourceError.noBookmark }
            var stale = false
            #if os(macOS)
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let url = try URL(resolvingBookmarkData: bookmark, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            let scoped = url.startAccessingSecurityScopedResource()
            return Resolved(url: url, isStale: stale, scoped: scoped)
        }
    }

    public func release(_ resolved: Resolved) {
        if resolved.scoped { resolved.url.stopAccessingSecurityScopedResource() }
    }

    /// Make a bookmark for a folder the user just picked.
    public static func bookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Every video file in a source, with the file attributes a cache key needs.
    ///
    /// Errors are **counted, never thrown**: one unreadable file in a folder of
    /// four hundred must not empty the grid.
    public func scan(_ source: SwingSource) -> ScanResult {
        let resolved: Resolved
        do { resolved = try resolve(source) } catch { return ScanResult(entries: [], failed: 0, error: error) }
        defer { release(resolved) }

        let fm = FileManager.default
        var entries: [Entry] = []
        var failed = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey]

        let urls: [URL]
        if source.recurse {
            let e = fm.enumerator(at: resolved.url, includingPropertiesForKeys: keys,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            urls = (e?.allObjects as? [URL]) ?? []
        } else {
            urls = (try? fm.contentsOfDirectory(at: resolved.url, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        }
        for url in urls {
            guard swingFileExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true,
                  let size = values.fileSize, let modified = values.contentModificationDate else {
                failed += 1
                continue
            }
            // A zero-byte file is a recording in flight or an iCloud placeholder
            // that has not come down. Skipped and counted — the same rule as an
            // `.m4a` still being written, which cannot be opened at all.
            guard size > 0 else { failed += 1; continue }
            entries.append(Entry(url: url,
                                 relativePath: relativePath(of: url, under: resolved.url),
                                 size: Int64(size), modified: modified, created: values.creationDate))
        }
        return ScanResult(entries: entries, failed: failed, error: resolved.isStale ? SwingSourceError.staleBookmark : nil)
    }

    func relativePath(of url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if path.hasPrefix(base) {
            return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    public struct Entry: Sendable {
        public let url: URL
        public let relativePath: String
        public let size: Int64
        public let modified: Date
        public let created: Date?
    }

    public struct ScanResult: Sendable {
        public let entries: [Entry]
        /// Files that could not be read at all. Reported, never rendered as a
        /// broken cell.
        public let failed: Int
        public let error: Error?
    }
}

public enum SwingSourceError: Error {
    case noBookmark
    case staleBookmark
    case readOnly
}
