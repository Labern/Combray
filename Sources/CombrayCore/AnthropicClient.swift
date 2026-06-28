import Foundation
import AppKit

/// What the model returns for one letter: the transcription plus extracted metadata.
/// Decoded leniently — any missing/mismatched field falls back to a default, so a partial or
/// loosely-shaped model response still produces a usable result.
public struct TranscriptionResult: Decodable, Sendable, Hashable {
    public struct DateField: Decodable, Sendable, Hashable {
        public var value = ""
        public var source = "unknown"
        public var confidence = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? c.decode(String.self, forKey: .value)) ?? ""
            source = (try? c.decode(String.self, forKey: .source)) ?? "unknown"
            confidence = (try? c.decode(String.self, forKey: .confidence)) ?? ""
        }
        enum CodingKeys: String, CodingKey { case value, source, confidence }
    }
    public struct UncertainSpan: Decodable, Sendable, Hashable {
        public var text = ""
        public var reason = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        }
        enum CodingKeys: String, CodingKey { case text, reason }
    }
    public struct Meta: Decodable, Sendable, Hashable {
        public var location = ""
        public var relationship = ""
        public var relationship_state = ""
        public var writer_goals = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            location = (try? c.decode(String.self, forKey: .location)) ?? ""
            relationship = (try? c.decode(String.self, forKey: .relationship)) ?? ""
            relationship_state = (try? c.decode(String.self, forKey: .relationship_state)) ?? ""
            writer_goals = (try? c.decode(String.self, forKey: .writer_goals)) ?? ""
        }
        enum CodingKeys: String, CodingKey { case location, relationship, relationship_state, writer_goals }
    }

    public var transcription = ""
    public var title = ""
    /// What the document is — "letter", "postcard", "note", "list", … Used to name it correctly.
    public var document_type = ""
    public var summary = ""
    public var sender = ""
    public var recipients: [String] = []
    public var date = DateField()
    public var people_mentioned: [String] = []
    public var uncertain_spans: [UncertainSpan] = []
    public var notable_quotes: [String] = []
    public var meta = Meta()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcription = (try? c.decode(String.self, forKey: .transcription)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        document_type = (try? c.decode(String.self, forKey: .document_type)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        sender = (try? c.decode(String.self, forKey: .sender)) ?? ""
        recipients = (try? c.decode([String].self, forKey: .recipients)) ?? []
        if let df = try? c.decode(DateField.self, forKey: .date) {
            date = df
        } else if let s = try? c.decode(String.self, forKey: .date) {
            date = DateField(); date.value = s
        }
        people_mentioned = (try? c.decode([String].self, forKey: .people_mentioned)) ?? []
        uncertain_spans = (try? c.decode([UncertainSpan].self, forKey: .uncertain_spans)) ?? []
        notable_quotes = (try? c.decode([String].self, forKey: .notable_quotes)) ?? []
        meta = (try? c.decode(Meta.self, forKey: .meta)) ?? Meta()
    }
    enum CodingKeys: String, CodingKey {
        case transcription, title, document_type, summary, sender, recipients, date
        case people_mentioned, uncertain_spans, notable_quotes, meta
    }
}

public enum AnthropicError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case noContent
    case badImage(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No Anthropic API key set. Add one in Settings."
        case let .http(code, body): return "Anthropic API error \(code): \(body)"
        case .noContent: return "The model returned no content."
        case let .badImage(p): return "Couldn't read image: \(p)"
        }
    }
}

/// Calls the Anthropic Messages API (no Swift SDK) to transcribe handwritten letter photos and
/// extract structured fields in a single vision request.
public struct AnthropicClient: Sendable {
    public var model: String
    public init(model: String = "claude-opus-4-8") {
        self.model = model
    }

    public func transcribe(imageURLs: [URL], model overrideModel: String? = nil) async throws -> TranscriptionResult {
        let model = overrideModel ?? self.model
        let headers = try await Self.authHeaders()

        // Build image content blocks (re-encode anything — incl. HEIC — to JPEG).
        var content: [[String: Any]] = []
        for url in imageURLs {
            let jpeg = try Self.jpegData(from: url)
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpeg.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text",
                        "text": "Transcribe this handwritten letter and return the JSON described in your instructions."])

        // The transcription guidance lives in the system prompt for weight. Claude Pro/Max OAuth
        // tokens additionally require the FIRST system block to identify as Claude Code, or the
        // Messages API rejects the request (often a 429) — but on its own that persona makes the
        // model transcribe like a coding assistant, so the real instruction follows it.
        var systemBlocks: [[String: Any]] = []
        if Keychain.credential()?.kind == .oauth {
            systemBlocks.append(["type": "text",
                                 "text": "You are Claude Code, Anthropic's official CLI for Claude."])
        }
        systemBlocks.append(["type": "text", "text": Self.instruction])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
            "system": systemBlocks,
            "messages": [["role": "user", "content": content]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AnthropicError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        // Response: { content: [ { type: "text", text: "<json matching schema>" }, ... ] }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]],
            let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw AnthropicError.noContent }

        let json = Self.extractJSON(text)
        guard let jsonData = json.data(using: .utf8) else { throw AnthropicError.noContent }
        do {
            return try JSONDecoder().decode(TranscriptionResult.self, from: jsonData)
        } catch {
            throw AnthropicError.http(200, "Couldn't read the transcription. The model returned:\n\(text.prefix(600))")
        }
    }

    /// Resolves auth headers from the stored credential (refreshing an expired OAuth token).
    static func authHeaders() async throws -> [String: String] {
        guard var cred = Keychain.credential() else { throw AnthropicError.missingAPIKey }
        switch cred.kind {
        case .apiKey:
            guard let key = cred.apiKey, !key.isEmpty else { throw AnthropicError.missingAPIKey }
            return ["x-api-key": key]
        case .oauth:
            if cred.isExpired, let refresh = cred.refreshToken {
                let tokens = try await ClaudeAuth.refresh(refresh)
                cred.accessToken = tokens.accessToken
                cred.refreshToken = tokens.refreshToken ?? refresh
                cred.expiresAt = tokens.expiresAt
                Keychain.save(cred)
            }
            guard let token = cred.accessToken, !token.isEmpty else { throw AnthropicError.missingAPIKey }
            return ["authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]
        }
    }

    // MARK: - Helpers

    /// Pulls the JSON object out of the model's text (handles ```json fences or surrounding prose).
    static func extractJSON(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if let fence = t.range(of: "```", options: .backwards) { t = String(t[..<fence.lowerBound]) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end {
            return String(t[start...end])
        }
        return t
    }

    static func jpegData(from url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw AnthropicError.badImage(url.lastPathComponent) }
        return jpeg
    }

    static let instruction = """
    These are photographs of the pages of a single handwritten letter, in order. The handwriting \
    may be difficult or nearly illegible — read it as carefully as you can, using context to decode \
    hard words.

    Transcribe the letter faithfully and completely: preserve paragraphs, line breaks, and the \
    original layout and spacing as closely as plain text allows. Keep original spelling and \
    punctuation, and reproduce every mark exactly — stars (★ ☆), boxes, underlines, arrows, and \
    other symbols. Do NOT summarize, correct, or tidy anything. For a word you genuinely cannot \
    read, write [illegible] and add it to uncertain_spans with a short reason.

    Then work out what this document actually IS — don't assume it's a letter. It could be a postcard, \
    note, list, card, telegram, recipe, invitation, diary entry, receipt, poem, a screenshot, a \
    printed page, anything. Put a short lowercase noun for it in document_type ("letter", "postcard", \
    "note", "list", "screenshot", …). \
    Now WRITE THE TITLE as a short, specific description of what this is — the same understanding that \
    goes into your summary, compressed into a name. Say what it is, and the key who/from/to/about. \
    Only use the "Letter to [recipient] from [sender]" form when it genuinely is a letter. For \
    anything else, describe it: e.g. "Postcard from Venice to Eleanor", "Shopping list for a dinner \
    party", "Recipe for plum cake", "Screenshot of a Claude Code coding session", "Birthday card to \
    Mum", "Note about the garden gate". Keep it under ~10 words, no trailing period, specific not \
    generic. \
    Also extract: a brief 1–3 sentence summary of what it is about; the sender (or author/who it's \
    from — "" if not applicable); the recipient(s); the date (use a date written on it if present with \
    source "written", otherwise infer from the contents with source "inferred", else source \
    "unknown") with a confidence; and any people mentioned. Use the partial date form you can support: \
    "1962", "1962-03", or "1962-03-04".

    Also pull out a few notable or striking quotes from the letter — verbatim excerpts that capture \
    its voice or its key moments — into notable_quotes (an empty list is fine if none stand out).

    Finally, do a quiet "meta" reading of the letter and fill the meta object: a possible location \
    the letter was written from or concerns; the likely relationship between sender and recipient; \
    the apparent state or tone of that relationship at this moment; and the writer's goals — what \
    they seem to want from writing. Infer reasonably from tone and content; use "" if there is no \
    basis. Keep each meta value to a short phrase or sentence.

    Respond with ONLY a single JSON object containing these fields and nothing else — no markdown, \
    no commentary.
    """

    static var schema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["transcription", "title", "document_type", "summary", "sender", "recipients", "date",
                     "people_mentioned", "notable_quotes", "uncertain_spans", "meta"],
        "properties": [
            "transcription": ["type": "string"],
            "title": ["type": "string"],
            "document_type": ["type": "string"],
            "summary": ["type": "string"],
            "sender": ["type": "string"],
            "recipients": ["type": "array", "items": ["type": "string"]],
            "date": [
                "type": "object",
                "additionalProperties": false,
                "required": ["value", "source", "confidence"],
                "properties": [
                    "value": ["type": "string"],
                    "source": ["type": "string", "enum": ["written", "inferred", "unknown"]],
                    "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                ]
            ],
            "people_mentioned": ["type": "array", "items": ["type": "string"]],
            "notable_quotes": ["type": "array", "items": ["type": "string"]],
            "uncertain_spans": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["text", "reason"],
                    "properties": [
                        "text": ["type": "string"],
                        "reason": ["type": "string"]
                    ]
                ]
            ],
            "meta": [
                "type": "object",
                "additionalProperties": false,
                "required": ["location", "relationship", "relationship_state", "writer_goals"],
                "properties": [
                    "location": ["type": "string"],
                    "relationship": ["type": "string"],
                    "relationship_state": ["type": "string"],
                    "writer_goals": ["type": "string"]
                ]
            ]
        ]
    ] }
}
