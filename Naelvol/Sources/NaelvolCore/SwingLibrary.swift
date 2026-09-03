import Foundation
import Combine

/// The library: which folders are listed, what is in them, and what the grid is
/// currently filtered to.
///
/// Scanning is two passes on purpose. The **first** is a directory listing and a
/// cache lookup — cheap, synchronous, and enough to draw the grid. The **second**
/// opens only the files the cache did not answer for, one at a time, publishing as
/// it goes, so a folder of four hundred videos fills in rather than blocking on the
/// four hundredth.
@MainActor
public final class SwingLibrary: ObservableObject {
    @Published public private(set) var sources: [SwingSource]
    @Published public private(set) var swings: [Swing] = []
    @Published public private(set) var scanning = false
    /// Files that could not be read at all, this scan. Reported in the UI as a
    /// count; never rendered as broken cells.
    @Published public private(set) var unreadable = 0
    @Published public var filter = SwingFilter()
    @Published public var sort: SwingSort = .newest

    public var visible: [Swing] { sort.sorted(swings.filter(filter.matches)) }

    /// Every tag on every swing, for the filter bar's suggestions.
    public var knownTags: [String] {
        var seen = Set<String>()
        for swing in swings { for tag in swing.meta.context.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    private let resolver: SwingSourceResolver
    private let cache: SwingCache
    private let defaults: UserDefaults
    private let defaultsKey = "naelvol.sources"
    private var scanTask: Task<Void, Never>?

    public init(appRoot: URL, cacheDirectory: URL, defaults: UserDefaults = .standard) {
        self.resolver = SwingSourceResolver(appRoot: appRoot)
        self.cache = SwingCache(directory: cacheDirectory)
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([SwingSource].self, from: data), !stored.isEmpty {
            sources = stored
        } else {
            sources = [SwingSource(id: SwingSource.appSourceID, name: "Naelgol", kind: .app)]
        }
        // The app's own source is not removable and not optional: a capture has to
        // land somewhere, and a library with no writable source is a capture
        // button that cannot work.
        if !sources.contains(where: { $0.kind == .app }) {
            sources.insert(SwingSource(id: SwingSource.appSourceID, name: "Naelgol", kind: .app), at: 0)
        }
    }

    public var appRoot: URL { resolver.appRoot }

    // MARK: - Sources

    public func addFolder(at url: URL, named name: String? = nil, recurse: Bool = true) throws {
        let bookmark = try SwingSourceResolver.bookmark(for: url)
        let source = SwingSource(name: name ?? url.lastPathComponent, kind: .bookmarked,
                                 bookmark: bookmark, recurse: recurse)
        sources.append(source)
        persistSources()
        refresh()
    }

    /// Re-pick a folder whose bookmark went stale. **The id is kept**, so every
    /// cached thumbnail and probe for that folder survives the repair.
    public func repair(_ source: SwingSource, with url: URL) throws {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].bookmark = try SwingSourceResolver.bookmark(for: url)
        sources[index].needsPermission = false
        persistSources()
        refresh()
    }

    public func remove(_ source: SwingSource) {
        guard source.kind != .app else { return }
        sources.removeAll { $0.id == source.id }
        swings.removeAll { $0.sourceID == source.id }
        persistSources()
    }

    public func rename(_ source: SwingSource, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].name = name
        persistSources()
    }

    public func source(id: String) -> SwingSource? { sources.first { $0.id == id } }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) { defaults.set(data, forKey: defaultsKey) }
    }

    // MARK: - Scanning

    public func refresh() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    public func scan() async {
        scanning = true
        unreadable = 0
        defer { scanning = false }

        var listed: [Swing] = []
        var pending: [(SwingSourceResolver.Entry, String)] = []
        var keys = Set<String>()

        for (index, source) in sources.enumerated() {
            let result = resolver.scan(source)
            if case SwingSourceError.staleBookmark? = result.error {
                sources[index].needsPermission = true
            } else if result.error != nil, source.kind == .bookmarked {
                sources[index].needsPermission = true
            } else if sources[index].needsPermission {
                sources[index].needsPermission = false
            }
            unreadable += result.failed
            for entry in result.entries {
                keys.insert(SwingCache.key(sourceID: source.id, relativePath: entry.relativePath))
                if let cached = cache.swing(for: entry, sourceID: source.id) {
                    listed.append(cached)
                } else {
                    // Drawn immediately with what the filesystem already said, so
                    // the grid has a cell to fill in rather than a gap that
                    // appears later and moves everything.
                    listed.append(Swing(sourceID: source.id, url: entry.url,
                                        relativePath: entry.relativePath, fileSize: entry.size,
                                        modified: entry.modified, created: entry.created))
                    pending.append((entry, source.id))
                }
            }
        }
        swings = listed
        cache.prune(keeping: keys)

        for (entry, sourceID) in pending {
            if Task.isCancelled { break }
            await probe(entry, sourceID: sourceID)
        }
        cache.save()
    }

    /// Open one file, read its record, make its thumbnail, publish it.
    private func probe(_ entry: SwingSourceResolver.Entry, sourceID: String) async {
        guard let source = source(id: sourceID) else { return }
        let resolved = try? resolver.resolve(source)
        defer { if let resolved { resolver.release(resolved) } }

        guard let probe = try? await SwingMetadata.probe(url: entry.url) else {
            unreadable += 1
            return
        }
        var swing = Swing(sourceID: sourceID, url: entry.url, relativePath: entry.relativePath,
                          fileSize: entry.size, modified: entry.modified,
                          created: probe.created ?? entry.created,
                          duration: probe.duration, dimensions: probe.dimensions,
                          frameRate: probe.frameRate, meta: probe.meta)
        let thumb = cache.thumbnailURL(for: swing)
        if FileManager.default.fileExists(atPath: thumb.path) {
            swing.thumbnailPath = thumb.path
        } else if await SwingThumbnail.generate(for: entry.url, to: thumb) {
            swing.thumbnailPath = thumb.path
        }
        cache.store(swing)
        if let index = swings.firstIndex(where: { $0.id == swing.id }) {
            swings[index] = swing
        } else {
            swings.append(swing)
        }
    }

    /// Re-read one file after it was written to. Cheaper than a whole scan and it
    /// is what an edit, a trim and a capture all need.
    public func reload(_ swing: Swing) async {
        cache.forget(sourceID: swing.sourceID, relativePath: swing.relativePath)
        let thumb = cache.thumbnailURL(for: swing)
        try? FileManager.default.removeItem(at: thumb)
        guard let values = try? swing.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else {
            swings.removeAll { $0.id == swing.id }
            return
        }
        await probe(SwingSourceResolver.Entry(url: swing.url, relativePath: swing.relativePath,
                                              size: Int64(size), modified: modified,
                                              created: values.creationDate),
                    sourceID: swing.sourceID)
        cache.save()
    }

    // MARK: - Writing

    /// Rewrite a swing's record.
    ///
    /// **Refused on a read-only source, out loud.** The files in a bookmarked
    /// folder belong to whatever put them there, and the escape hatch is
    /// `copyToApp` — a copy the user asks for, never one that happens silently.
    public func update(_ swing: Swing, context: SwingContext) async throws {
        guard source(id: swing.sourceID)?.isWritable == true else { throw SwingSourceError.readOnly }
        var meta = swing.meta
        meta.context = context
        meta.isForeign = false
        meta.version = SwingMeta.currentVersion
        try await SwingMetadata.write(meta, to: swing.url)
        await reload(swing)
    }

    /// Copy a foreign swing into naelvol's own directory so it can be edited.
    @discardableResult
    public func copyToApp(_ swing: Swing, context: SwingContext? = nil) async throws -> URL {
        let destination = try uniqueURL(extension: swing.url.pathExtension)
        let source = self.source(id: swing.sourceID)
        let resolved = source.flatMap { try? resolver.resolve($0) }
        defer { if let resolved { resolver.release(resolved) } }
        try FileManager.default.copyItem(at: swing.url, to: destination)
        if let context {
            var meta = swing.meta
            meta.context = context
            meta.isForeign = false
            try await SwingMetadata.write(meta, to: destination)
        }
        await scan()
        return destination
    }

    /// Bring a file in from Photos or Files. The context is stamped on the copy,
    /// never on the original.
    @discardableResult
    public func importFile(at url: URL, context: SwingContext? = nil) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = try uniqueURL(extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        if let context, !context.isEmpty {
            let existing = (try? await SwingMetadata.probe(url: destination))?.meta ?? SwingMeta()
            var meta = existing
            meta.context = context
            meta.isForeign = false
            try? await SwingMetadata.write(meta, to: destination)
        }
        await scan()
        return destination
    }

    public func delete(_ swing: Swing) throws {
        guard source(id: swing.sourceID)?.isWritable == true else { throw SwingSourceError.readOnly }
        try FileManager.default.removeItem(at: swing.url)
        cache.forget(sourceID: swing.sourceID, relativePath: swing.relativePath)
        swings.removeAll { $0.id == swing.id }
        cache.save()
    }

    /// `swing-0007.mov`, the next free number. vipl's naming, kept, because the
    /// two apps' files end up in the same folder often enough to matter.
    public func uniqueURL(extension ext: String = "mov") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: appRoot.path)) ?? [])
        var n = 1
        while true {
            let base = String(format: "swing-%04d", n)
            let candidates = swingFileExtensions.map { "\(base).\($0)" } + ["\(base).\(ext)"]
            if !candidates.contains(where: { name in
                existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            }) {
                return appRoot.appendingPathComponent("\(base).\(ext)")
            }
            n += 1
        }
    }
}
