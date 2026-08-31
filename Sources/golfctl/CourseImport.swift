import Foundation
import GolfSessionFormat
import GolfCourse
import AnthropicClient

/// `golfctl course import` — a published scorecard becomes `Courses/<id>.json`.
///
/// **One path, four inputs.** A URL, a PDF, a photograph and pasted text all
/// converge on the same prompt and schema. That is a measured decision, not a
/// convenience: crawling 244 Korean course websites yielded a card 17.6% of the
/// time, and the misses were JS splash pages, EUC-KR, framesets and `/Mobile`
/// forks rather than missing data (docs/research-scorecard-import.md §2). A parser
/// per site is a treadmill with a hit-rate cliff; extraction handles all of them.
///
/// The card gives par, handicap and yardage. It never gives coordinates — those
/// come from a track, a survey, or the editor.
enum CourseImport {

    // MARK: - Input

    enum Input {
        case text(String, origin: String)
        case pdf(Data, origin: String)
        case image(Data, mediaType: String, origin: String)

        var origin: String {
            switch self {
            case .text(_, let o), .pdf(_, let o), .image(_, _, let o): return o
            }
        }

        var content: AnthropicClient.Content {
            switch self {
            case .text(let s, _): return .text(s)
            case .pdf(let d, _): return .pdf(d)
            case .image(let d, let m, _): return .image(data: d, mediaType: m)
            }
        }
    }

    static func input(fromFile path: String) throws -> Input {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf(data, origin: url.lastPathComponent)
        case "jpg", "jpeg":
            return .image(data, mediaType: "image/jpeg", origin: url.lastPathComponent)
        case "png":
            return .image(data, mediaType: "image/png", origin: url.lastPathComponent)
        case "gif":
            return .image(data, mediaType: "image/gif", origin: url.lastPathComponent)
        case "webp":
            return .image(data, mediaType: "image/webp", origin: url.lastPathComponent)
        default:
            guard let s = String(data: data, encoding: .utf8) else {
                throw Err("\(path): not UTF-8 text, and not a PDF or an image format Claude reads")
            }
            return .text(s, origin: url.lastPathComponent)
        }
    }

    // MARK: - Fetching a page

    /// Fetch a course page and reduce it to text.
    ///
    /// Follows one JS `location.href` / `location.replace`, `<meta refresh>` or
    /// frameset hop, because that single rule is the difference between "no card
    /// on this site" and a complete card: 스카이뷰CC's homepage is a video splash
    /// whose only content is `location.href = '/Mobile'`, and ten more sites in the
    /// sample behaved the same way. It is deliberately *one* hop — anything deeper
    /// is a crawler, and a crawler is not what this is.
    static func fetch(_ urlString: String, hops: Int = 2) async throws -> Input {
        var current = urlString
        var lastText = ""
        for _ in 0..<max(1, hops) {
            guard let url = URL(string: current) else { throw Err("not a URL: \(current)") }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            // Some course sites serve a bare frameset or block unknown clients.
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                             + "AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36",
                             forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let effective = (response as? HTTPURLResponse)?.url ?? url
            let html = decode(data)
            lastText = CardText.strip(html)

            if let next = redirectTarget(in: html, relativeTo: effective), lastText.count < 1500 {
                current = next.absoluteString
                continue
            }
            return .text(lastText, origin: effective.absoluteString)
        }
        return .text(lastText, origin: current)
    }

    /// Korean course sites are still often EUC-KR. Guess from the meta tag rather
    /// than mangling every second page into replacement characters.
    private static func decode(_ data: Data) -> String {
        let ascii = String(decoding: data.prefix(3000), as: UTF8.self)
        if ascii.range(of: "charset=[\"']?(euc-kr|ks_c_5601-1987|cp949)",
                       options: [.regularExpression, .caseInsensitive]) != nil {
            let euc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
            if let s = String(data: data, encoding: String.Encoding(rawValue: euc)) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func redirectTarget(in html: String, relativeTo base: URL) -> URL? {
        let patterns = [
            "location\\.(?:href|replace)\\s*(?:=|\\()\\s*['\"]([^'\"]+)",
            "http-equiv=[\"']refresh[\"'][^>]*url=([^\"'>\\s]+)",
            "<frame[^>]+src=[\"']([^\"']+)",
        ]
        for p in patterns {
            guard let m = html.range(of: p, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let fragment = String(html[m])
            guard let q = fragment.range(of: "['\"=]([^'\"=]+)$", options: .regularExpression)
            else { continue }
            let raw = String(fragment[q]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"="))
            if let u = URL(string: raw, relativeTo: base) { return u.absoluteURL }
        }
        return nil
    }

    // MARK: - Extraction

    static func extract(_ input: Input, courseName: String?,
                        promptPath: String, schemaPath: String,
                        model: AnthropicClient.ModelConfig,
                        client: AnthropicClient) async throws -> (CourseCard, Data) {
        let prompt = try String(contentsOfFile: promptPath, encoding: .utf8)
        let schemaData = try Data(contentsOf: URL(fileURLWithPath: schemaPath))
        guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        else { throw Err("\(schemaPath) is not a JSON object") }

        var blocks: [AnthropicClient.Content] = [input.content]
        var ask = "Extract the scorecard above."
        if let courseName { ask += " The course is \(courseName)." }
        ask += " Source: \(input.origin)."
        blocks.append(.text(ask))

        let (json, response) = try await client.sendJSON(
            [AnthropicClient.Message(role: "user", content: blocks)],
            model: model, system: prompt, schema: schema)
        let card = try JSONDecoder().decode(CourseCard.self, from: json)
        return (card, response.rawBody)
    }

    /// Now `Course.slug` — the app's course finder needs the same ids.
    static func slug(_ name: String) -> String { Course.slug(name) }
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
