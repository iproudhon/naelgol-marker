import Foundation
import Compression

/// The wire form: what goes on the clipboard, and what comes back off it.
///
/// **Two forms, and the reader accepts either.** A round with no terrain is a few
/// tens of kilobytes of readable JSON and should stay readable — it is diffable,
/// greppable, and a person can see what they are about to import. A round carrying
/// a course and a DEM is 850 KB to 1 MB, nearly all of it one base64 elevation
/// string no human will ever read, and pasting that into a text box is unpleasant
/// on a phone. So the exporter emits plain JSON below `compressAbove` and a
/// compressed block above it.
///
/// Measured on the two real courses (zlib + base64, whole bundle):
///
/// | course | plain | compressed |
/// |---|---|---|
/// | Corica Park South — 10 m of relief | ~850 KB | ~150 KB |
/// | Coyote Creek Tournament — 177 m | ~1.0 MB | ~410 KB |
///
/// The hilly course compresses far worse, which is the whole reason the threshold
/// is on the **serialized size** rather than on "has terrain": relief is entropy,
/// and a flat course's grid is mostly the same number over and over.
public enum BundleText {

    /// First token of the compressed form. Chosen to be greppable and obviously
    /// not JSON, so sniffing the two apart is one character.
    public static let marker = "MARKER-ROUND"

    /// Above this many bytes of JSON, the text form is compressed.
    ///
    /// 100 KB is about where a paste stops being something a person can scroll
    /// through and starts being an opaque wall — which is the point at which
    /// keeping it readable buys nothing and costs six hundred kilobytes.
    public static let compressAbove = 100_000

    /// Base64 is wrapped, because this format's whole job is to survive being
    /// pasted. Chat clients, mail and issue trackers all mangle a single
    /// multi-hundred-kilobyte line; 76 is the MIME convention and is safe
    /// everywhere. The reader strips **all** whitespace, so a client that re-wraps
    /// at some other width costs nothing.
    public static let lineWidth = 76

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notABundle
        case unsupportedVersion(Int)
        case badHeader(String)
        case badBase64
        case corrupt
        case malformedJSON(String)

        /// **A sentence, not an `NSError`.** The same rule the Overpass client
        /// follows: the person reading this pasted something into a box and needs
        /// to know which thing to try instead.
        public var description: String {
            switch self {
            case .notABundle:
                return "That does not look like an exported round. Paste the whole export, "
                     + "starting with either '\(marker)' or '{'."
            case .unsupportedVersion(let v):
                return "That round was exported by a newer version of Marker (format \(v)). "
                     + "Update the app and try again."
            case .badHeader(let line):
                return "The export's first line is not readable: \(line)"
            case .badBase64:
                return "The export is incomplete or was altered in transit — its data is not "
                     + "valid base64. Copy the whole thing and paste it again."
            case .corrupt:
                return "The export is damaged and could not be unpacked. Copy the whole thing "
                     + "and paste it again."
            case .malformedJSON(let why):
                return "The export could not be read: \(why)"
            }
        }
    }

    // MARK: - Writing

    /// - Parameter compressed: nil picks by size, which is the normal case. Pass a
    ///   value only to force one form — a test, or `--plain` on the CLI.
    public static func encode(_ bundle: RoundBundle, compressed: Bool? = nil) throws -> String {
        let json = try encoder.encode(bundle)
        let wantsCompression = compressed ?? (json.count > compressAbove)
        guard wantsCompression, let deflated = Deflate.compress(json) else {
            // Falls through to plain when compression was not asked for, and also
            // when it did not fit — `compression_encode_buffer` returns 0 rather
            // than growing, and a bundle that will not deflate is still a bundle.
            return String(decoding: json, as: UTF8.self)
        }
        var out = "\(marker) v\(bundle.version) zlib \(json.count)\n"
        // A comment line, so a blob on a clipboard still says what it is. Ignored
        // by the reader — see `decode`.
        out += "# \(bundle.summary)\n"
        out += wrap(deflated.base64EncodedString())
        return out
    }

    /// The bundle as readable JSON, whichever form the text was in. This is what
    /// keeps the compact form from ever becoming un-inspectable.
    public static func json(_ text: String) throws -> String {
        let bundle = try decode(text)
        let data = try encoder.encode(bundle)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reading

    public static func decode(_ text: String) throws -> RoundBundle {
        // **`split(separator: "\n")` is wrong here, and silently.** A `String` is a
        // sequence of grapheme clusters and `"\r\n"` is ONE of them, so a document
        // that picked up Windows line endings on its way through a chat client
        // contains no `"\n"` character at all and splits into a single line — which
        // then fails as an unreadable header, for a file that is perfectly fine.
        // Measured by pasting a CRLF copy of a real export. `isNewline` is true for
        // the `\r\n` cluster and for every lone variant.
        var lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Blank and comment lines are skipped anywhere, not only at the top: a
        // paste often picks up a stray blank line, and the comment is ours.
        lines = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let first = lines.first else { throw Failure.notABundle }

        if first.hasPrefix("{") {
            return try bundle(fromJSON: Data(lines.joined(separator: "\n").utf8))
        }
        guard first.hasPrefix(marker) else { throw Failure.notABundle }

        // `MARKER-ROUND v1 zlib 872341`
        let fields = first.split(separator: " ").map(String.init)
        guard fields.count >= 4,
              fields[1].hasPrefix("v"), let v = Int(fields[1].dropFirst()),
              fields[2] == "zlib", let size = Int(fields[3]), size > 0
        else { throw Failure.badHeader(first) }
        guard v <= RoundBundle.currentVersion else { throw Failure.unsupportedVersion(v) }

        // Every remaining character that is not whitespace. A pasted block may have
        // been re-wrapped, indented, or given CRLF line endings by whatever carried
        // it, and none of that is a reason to refuse it.
        let payload = lines.dropFirst().joined()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let deflated = Data(base64Encoded: payload,
                                  options: [.ignoreUnknownCharacters])
        else { throw Failure.badBase64 }
        guard let json = Deflate.decompress(deflated, size: size) else { throw Failure.corrupt }
        // **Anything wrong past this point is damage, not a malformed document.**
        // Nobody hand-writes the compressed form, so "that is not valid JSON" would
        // be an accurate sentence pointing at the wrong thing to fix. It also
        // catches the one failure the size check cannot: a header claiming FEWER
        // bytes than the payload really inflates to fills the destination exactly,
        // returns the promised length, and hands back a truncated document.
        do { return try bundle(fromJSON: json) }
        catch let e as Failure where e == .notABundle { throw Failure.corrupt }
        catch is Failure { throw Failure.corrupt }
    }

    private static func bundle(fromJSON data: Data) throws -> RoundBundle {
        // **What it is, before whether it parses.** Decoding straight into
        // `RoundBundle` reports the first missing field of some *other* JSON
        // document — "a required field is missing (exported)" for a file that was
        // never one of ours — which sends the reader looking for a field instead of
        // for the right file. Two optional strings answer the identity question
        // first, and cannot themselves fail on a foreign document.
        struct Envelope: Decodable { var format: String?; var version: Int? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == RoundBundle.formatName
        else { throw Failure.notABundle }
        if let v = envelope.version, v > RoundBundle.currentVersion {
            throw Failure.unsupportedVersion(v)
        }

        let b: RoundBundle
        do { b = try JSONDecoder().decode(RoundBundle.self, from: data) }
        catch let e as DecodingError { throw Failure.malformedJSON(describe(e)) }
        catch { throw Failure.notABundle }
        guard b.version <= RoundBundle.currentVersion else {
            throw Failure.unsupportedVersion(b.version)
        }
        return b
    }

    // MARK: - Plumbing

    /// Sorted keys because a clipboard is diffed and eyeballed and a dictionary's
    /// order is not stable between runs; `withoutEscapingSlashes` so a course name
    /// with a slash in it stays readable. Pretty-printed only in the plain form,
    /// which is the one anybody reads — the compressed one is bytes either way, and
    /// indenting a megabyte before deflating it is work for nothing.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func wrap(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: lineWidth, limitedBy: s.endIndex) ?? s.endIndex
            out += s[i..<j]
            out += "\n"
            i = j
        }
        return out
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, _):     return "a required field is missing (\(k.stringValue))"
        case .typeMismatch(_, let c):    return "a field has the wrong type at "
                                              + c.codingPath.map(\.stringValue).joined(separator: ".")
        case .valueNotFound(_, let c):   return "a field is null at "
                                              + c.codingPath.map(\.stringValue).joined(separator: ".")
        case .dataCorrupted(let c):      return c.debugDescription
        @unknown default:                return "unrecognised structure"
        }
    }
}

// MARK: - Deflate

/// Raw DEFLATE through Apple's `Compression` framework — on the platform floor
/// (iOS 9 / macOS 10.11) and therefore not a new dependency.
///
/// The decompressed size is carried in the header rather than discovered, because
/// `compression_decode_buffer` needs a destination big enough up front. That also
/// makes it a checksum of sorts: a payload that inflates to a different length than
/// the header claims is damaged, and saying so beats handing a truncated JSON
/// document to a decoder.
enum Deflate {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Deliberately generous. `compression_encode_buffer` returns 0 rather than
        // growing its destination, and incompressible input can exceed its own
        // length; the caller then falls back to plain text.
        let cap = data.count + 4_096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }

    static func decompress(_ data: Data, size: Int) -> Data? {
        guard size > 0, !data.isEmpty else { return nil }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst, size, base, data.count, nil, COMPRESSION_ZLIB)
        }
        // Anything but the exact promised length is damage, not a short read.
        return n == size ? Data(bytes: dst, count: n) : nil
    }
}
