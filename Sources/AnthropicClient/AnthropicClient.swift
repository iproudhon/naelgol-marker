import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal `POST /v1/messages` client. **Knows nothing about golf** — messages,
/// model config, content blocks, structured output. Reusable anywhere.
///
/// Raw HTTPS because there is no official Anthropic Swift SDK. Request shapes here
/// were checked against the live API documentation rather than written from
/// memory, per CLAUDE.md; the two that drift most are noted at `ModelConfig` and
/// `OutputConfig`.
public struct AnthropicClient: Sendable {

    public struct Config: Sendable {
        public var apiKey: String
        public var baseURL: URL
        public var version: String
        public var timeout: TimeInterval
        public init(apiKey: String,
                    baseURL: URL = URL(string: "https://api.anthropic.com")!,
                    version: String = "2023-06-01",
                    timeout: TimeInterval = 600) {
            self.apiKey = apiKey; self.baseURL = baseURL
            self.version = version; self.timeout = timeout
        }

        /// `ANTHROPIC_API_KEY` from the environment. Never committed, never a default.
        public static func fromEnvironment() -> Config? {
            guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
                  !key.isEmpty else { return nil }
            return Config(apiKey: key)
        }
    }

    public let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Model configuration

    /// Per-model knobs, as a value rather than an `if` — a model sweep exercises
    /// several on the same code path.
    ///
    /// **Thinking is the field that drifts.** On the current models a fixed
    /// `budget_tokens` is rejected with a 400; adaptive thinking replaced it.
    /// `effort` belongs *inside* `output_config`, not at the top level.
    public struct ModelConfig: Sendable {
        public enum Thinking: Sendable {
            case adaptive
            case disabled
            /// Pre-4.6 models only, where `budget_tokens` is still the mechanism.
            case budget(Int)
        }
        public var model: String
        public var maxTokens: Int
        public var thinking: Thinking
        /// "low" | "medium" | "high" | "xhigh" | "max". Nil leaves the default.
        public var effort: String?

        public init(model: String = "claude-opus-5", maxTokens: Int = 16_000,
                    thinking: Thinking = .adaptive, effort: String? = nil) {
            self.model = model; self.maxTokens = maxTokens
            self.thinking = thinking; self.effort = effort
        }
    }

    // MARK: - Content

    /// One block of user content. Documents and images are first-class because the
    /// input is often a photograph or a PDF rather than text.
    public enum Content: Sendable {
        case text(String)
        /// `mediaType` must be image/jpeg, image/png, image/gif or image/webp.
        case image(data: Data, mediaType: String)
        case pdf(Data)

        var json: [String: Any] {
            switch self {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let d, let m):
                return ["type": "image",
                        "source": ["type": "base64", "media_type": m,
                                   "data": d.base64EncodedString()]]
            case .pdf(let d):
                return ["type": "document",
                        "source": ["type": "base64", "media_type": "application/pdf",
                                   "data": d.base64EncodedString()]]
            }
        }
    }

    public struct Message: Sendable {
        public var role: String            // "user" | "assistant"
        public var content: [Content]
        public init(role: String = "user", content: [Content]) {
            self.role = role; self.content = content
        }
        public init(role: String = "user", text: String) {
            self.init(role: role, content: [.text(text)])
        }
    }

    // MARK: - Response

    public struct Response: Sendable {
        public var id: String
        public var model: String
        /// Concatenated text blocks. Thinking blocks are not included.
        public var text: String
        public var stopReason: String?
        public var inputTokens: Int
        public var outputTokens: Int
        /// The whole response body, for anything this struct does not surface —
        /// and for caching next to the output, which is what keeps a prompt edit
        /// from re-running an expensive call.
        public var rawBody: Data

        /// True when safety classifiers declined the request. HTTP is still 200,
        /// so this must be checked before `text` is trusted.
        public var isRefusal: Bool { stopReason == "refusal" }
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case malformed(String)
        case refused(String)

        public var description: String {
            switch self {
            case .http(let s, let b): return "Anthropic API returned \(s): \(b)"
            case .malformed(let m): return "unexpected response shape: \(m)"
            case .refused(let c): return "the model declined this request (\(c))"
            }
        }
    }

    // MARK: - Send

    /// - Parameter schema: a JSON Schema object. When present the response is
    ///   constrained to match it, so the text block is parseable JSON rather than
    ///   prose that happens to contain some. Passed straight through, which is why
    ///   it can come from a `--schema` file the user edits between runs.
    public func send(_ messages: [Message],
                     model: ModelConfig = ModelConfig(),
                     system: String? = nil,
                     schema: [String: Any]? = nil) async throws -> Response {

        var body: [String: Any] = [
            "model": model.model,
            "max_tokens": model.maxTokens,
            "messages": messages.map { ["role": $0.role, "content": $0.content.map(\.json)] },
        ]
        if let system { body["system"] = system }

        switch model.thinking {
        case .adaptive: body["thinking"] = ["type": "adaptive"]
        case .disabled: body["thinking"] = ["type": "disabled"]
        case .budget(let n): body["thinking"] = ["type": "enabled", "budget_tokens": n]
        }

        var output: [String: Any] = [:]
        if let effort = model.effort { output["effort"] = effort }
        if let schema { output["format"] = ["type": "json_schema", "schema": schema] }
        if !output.isEmpty { body["output_config"] = output }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(config.version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.http(status: status,
                               body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("body is not a JSON object")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let usage = obj["usage"] as? [String: Any] ?? [:]
        let stop = obj["stop_reason"] as? String

        let result = Response(id: obj["id"] as? String ?? "",
                              model: obj["model"] as? String ?? model.model,
                              text: text,
                              stopReason: stop,
                              inputTokens: usage["input_tokens"] as? Int ?? 0,
                              outputTokens: usage["output_tokens"] as? Int ?? 0,
                              rawBody: data)
        if result.isRefusal {
            let details = obj["stop_details"] as? [String: Any]
            throw Failure.refused(details?["category"] as? String ?? "no category given")
        }
        return result
    }

    /// Convenience: send and decode the text block as JSON. Use with `schema`,
    /// which is what makes the text parseable in the first place.
    public func sendJSON(_ messages: [Message],
                         model: ModelConfig = ModelConfig(),
                         system: String? = nil,
                         schema: [String: Any]) async throws -> (json: Data, response: Response) {
        let r = try await send(messages, model: model, system: system, schema: schema)
        guard let d = r.text.data(using: .utf8) else {
            throw Failure.malformed("response text is not UTF-8")
        }
        return (d, r)
    }
}
