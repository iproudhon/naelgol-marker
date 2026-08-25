import Foundation

/// Append-only JSONL: one JSON object per line, newline-terminated.
///
/// Chosen over a single JSON array because a round can end by battery death or
/// a crash, and an append-only file is still readable when that happens — the
/// worst case is one torn final line, which `JSONLReader` skips.
public final class JSONLWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var closed = false

    public init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        encoder = JSONEncoder()
        // Single line per record is the whole format; sorted keys keep diffs stable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw JSONLError.writerClosed }
        try handle.write(contentsOf: data)
    }

    /// Force buffered bytes to disk. Call at hole boundaries — a 4.5-hour round
    /// should not have its whole GPS track sitting in a buffer.
    public func sync() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        try handle.synchronize()
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try handle.synchronize()
        try handle.close()
    }

    deinit { try? close() }
}

public enum JSONLError: Error {
    case writerClosed
    case notAFile(URL)
}

/// Streams a JSONL file line by line without loading it whole. A 4.5-hour
/// motion stream is small but not guaranteed small, and the reader also runs on
/// the Mac over many sessions at once.
public struct JSONLReader<T: Decodable>: Sequence {
    public let url: URL
    /// Lines that fail to decode are skipped and counted here rather than
    /// aborting the read — a truncated last line must not lose the round.
    public final class Stats: @unchecked Sendable {
        public private(set) var decoded = 0
        public private(set) var skipped = 0
        func countDecoded() { decoded += 1 }
        func countSkipped() { skipped += 1 }
        public init() {}
    }
    public let stats: Stats

    public init(url: URL, stats: Stats = Stats()) {
        self.url = url
        self.stats = stats
    }

    public func makeIterator() -> Iterator { Iterator(url: url, stats: stats) }

    public struct Iterator: IteratorProtocol {
        private var handle: FileHandle?
        private var buffer = Data()
        private var atEOF = false
        private let decoder = JSONDecoder()
        private let stats: Stats
        private static var chunkSize: Int { 64 * 1024 }

        init(url: URL, stats: Stats) {
            self.handle = try? FileHandle(forReadingFrom: url)
            self.stats = stats
        }

        public mutating func next() -> T? {
            while true {
                guard let line = nextLine() else {
                    try? handle?.close()
                    handle = nil
                    return nil
                }
                if line.isEmpty { continue }
                if let value = try? decoder.decode(T.self, from: line) {
                    stats.countDecoded()
                    return value
                }
                stats.countSkipped()
            }
        }

        private mutating func nextLine() -> Data? {
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = buffer[buffer.index(after: nl)...]
                    return Data(line)
                }
                if atEOF {
                    // Trailing bytes with no newline: an interrupted write.
                    guard !buffer.isEmpty else { return nil }
                    let line = buffer
                    buffer = Data()
                    return line
                }
                let chunk = (try? handle?.read(upToCount: Self.chunkSize)) ?? nil
                if let chunk, !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    atEOF = true
                }
            }
        }
    }
}
