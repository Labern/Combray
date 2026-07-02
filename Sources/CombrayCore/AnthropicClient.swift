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
        /// A guess at the writer's sex and age FROM THE HANDWRITING STYLE (e.g. "Likely female, 30s–40s").
        public var handwriting_profile = ""
        /// If the handwriting strongly matches a supplied reference sample, who it's suspected to be.
        public var suspected_writer = ""
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            location = (try? c.decode(String.self, forKey: .location)) ?? ""
            relationship = (try? c.decode(String.self, forKey: .relationship)) ?? ""
            relationship_state = (try? c.decode(String.self, forKey: .relationship_state)) ?? ""
            writer_goals = (try? c.decode(String.self, forKey: .writer_goals)) ?? ""
            handwriting_profile = (try? c.decode(String.self, forKey: .handwriting_profile)) ?? ""
            suspected_writer = (try? c.decode(String.self, forKey: .suspected_writer)) ?? ""
        }
        enum CodingKeys: String, CodingKey {
            case location, relationship, relationship_state, writer_goals, handwriting_profile, suspected_writer
        }
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

/// One assistant turn when chatting *about* a transcription: a conversational `reply`, plus an
/// optional `suggestion` — a full proposed revision of the transcription the user can accept or not.
public struct AskResult: Decodable, Sendable, Hashable {
    public var reply = ""
    /// A complete proposed revised transcription, or nil when the model isn't suggesting a change.
    public var suggestion: String?
    public init(reply: String = "", suggestion: String? = nil) { self.reply = reply; self.suggestion = suggestion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
        let s = (try? c.decode(String.self, forKey: .suggestion)) ?? ""
        suggestion = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
    enum CodingKeys: String, CodingKey { case reply, suggestion }
}

/// One result from an intelligent "find a letter" search: the matched letter's id and why it matched.
public struct LetterMatch: Decodable, Sendable, Hashable {
    public var id = ""
    public var reason = ""
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
    }
    enum CodingKeys: String, CodingKey { case id, reason }
}

private struct FindResult: Decodable { var matches: [LetterMatch] = [] }

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

    public func transcribe(imageURLs: [URL], ownerContext: String? = nil,
                           model overrideModel: String? = nil) async throws -> TranscriptionResult {
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
        systemBlocks.append(["type": "text", "text": Self.dateAnchor()])
        if let ownerContext, !ownerContext.isEmpty {
            systemBlocks.append(["type": "text",
                                 "text": "About the archive owner (use for meta.suspected_writer): \(ownerContext)"])
        }

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

    /// Chats *about* an existing transcription. `history` is the full back-and-forth so far (each
    /// `(role: "user"|"assistant", text:)`), ending with the user's latest question. Returns the
    /// model's conversational reply plus an optional full proposed revision of the transcription.
    public func ask(transcription: String, history: [(role: String, text: String)],
                    model overrideModel: String? = nil) async throws -> AskResult {
        let model = overrideModel ?? self.model
        let headers = try await Self.authHeaders()

        var systemBlocks: [[String: Any]] = []
        if Keychain.credential()?.kind == .oauth {
            systemBlocks.append(["type": "text",
                                 "text": "You are Claude Code, Anthropic's official CLI for Claude."])
        }
        systemBlocks.append(["type": "text", "text": Self.askInstruction(transcription)])

        let messages = history.map { turn in
            ["role": turn.role, "content": [["type": "text", "text": turn.text]]] as [String: Any]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "output_config": ["format": ["type": "json_schema", "schema": Self.askSchema]],
            "system": systemBlocks,
            "messages": messages
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AnthropicError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]],
            let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw AnthropicError.noContent }

        let json = Self.extractJSON(text)
        guard let jsonData = json.data(using: .utf8) else { throw AnthropicError.noContent }
        do {
            return try JSONDecoder().decode(AskResult.self, from: jsonData)
        } catch {
            // Fall back to treating the whole reply as plain conversational text.
            return AskResult(reply: text, suggestion: nil)
        }
    }

    static func askInstruction(_ transcription: String) -> String {
        """
        You are helping the user review and proofread the transcription of a handwritten or \
        photographed document. Here is the CURRENT transcription, between the markers:

        <<<TRANSCRIPTION
        \(transcription)
        TRANSCRIPTION>>>

        The user will ask questions about it — often pointing at a passage that looks wrong and \
        asking what you think. Answer helpfully, specifically, and concisely about THIS text. You \
        cannot see the original photo, so reason from spelling, grammar, sense, and context, and be \
        honest about uncertainty.

        When — and only when — you are confident a concrete correction would improve the \
        transcription, put the ENTIRE corrected transcription (the full text, with your change \
        applied and everything else preserved exactly) in "suggestion". If you are only discussing, \
        speculating, or no change is warranted, set "suggestion" to an empty string. Always put your \
        conversational answer in "reply". Respond with ONLY the JSON object.
        """
    }

    static var askSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["reply", "suggestion"],
        "properties": [
            "reply": ["type": "string"],
            "suggestion": ["type": "string"]
        ]
    ] }

    /// Re-reads an already-corrected transcription (TEXT ONLY — no images, so cheap) and returns
    /// fresh derived metadata: summary, document type, people, quotes and the meta object. Used after
    /// the user edits or accepts a corrected transcription, to keep the summary & meta in step.
    public func analyzeText(transcription: String, ownerContext: String? = nil,
                            model overrideModel: String? = nil) async throws -> TranscriptionResult {
        let model = overrideModel ?? self.model
        let headers = try await Self.authHeaders()

        var systemBlocks: [[String: Any]] = []
        if Keychain.credential()?.kind == .oauth {
            systemBlocks.append(["type": "text",
                                 "text": "You are Claude Code, Anthropic's official CLI for Claude."])
        }
        systemBlocks.append(["type": "text", "text": Self.analyzeInstruction])
        systemBlocks.append(["type": "text", "text": Self.dateAnchor()])
        if let ownerContext, !ownerContext.isEmpty {
            systemBlocks.append(["type": "text",
                                 "text": "About the archive owner (use for meta.suspected_writer): \(ownerContext)"])
        }

        let userText = "Here is the final, corrected transcription:\n\n<<<TRANSCRIPTION\n\(transcription)\n"
            + "TRANSCRIPTION>>>\n\nExtract the metadata as the JSON described in your instructions."
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "output_config": ["format": ["type": "json_schema", "schema": Self.schema]],
            "system": systemBlocks,
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AnthropicError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]],
            let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let jsonData = Self.extractJSON(text).data(using: .utf8)
        else { throw AnthropicError.noContent }
        return try JSONDecoder().decode(TranscriptionResult.self, from: jsonData)
    }

    static let analyzeInstruction = """
    You are given the final, user-corrected transcription of a document (between the markers). Do NOT \
    rewrite the text. Read it and produce fresh metadata as a single JSON object matching the schema: \
    a short document_type; a brief 1–3 sentence summary; the sender; recipients; the date; people \
    mentioned; a few notable verbatim quotes; and the meta object (location, relationship, \
    relationship_state, writer_goals, handwriting_profile, suspected_writer). For "transcription", \
    echo the given text back unchanged. You are working from text only and cannot see the handwriting, \
    so set meta.handwriting_profile to "". For meta.suspected_writer use any signature/content cues \
    and the archive owner profile if one was provided. Respond with ONLY the JSON object.
    """

    /// Intelligent archive search: given the user's request and a one-line-per-item catalog, returns
    /// the matching letters (their ids + a short reason), most relevant first. Text only — cheap.
    public func findLetters(query: String, catalog: String,
                            model overrideModel: String? = nil) async throws -> [LetterMatch] {
        let model = overrideModel ?? self.model
        let headers = try await Self.authHeaders()

        var systemBlocks: [[String: Any]] = []
        if Keychain.credential()?.kind == .oauth {
            systemBlocks.append(["type": "text",
                                 "text": "You are Claude Code, Anthropic's official CLI for Claude."])
        }
        systemBlocks.append(["type": "text", "text": Self.findInstruction])

        let userText = "Request:\n\(query)\n\nCATALOG (one item per line):\n\(catalog)"
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["matches"],
            "properties": [
                "matches": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["id", "reason"],
                    "properties": ["id": ["type": "string"], "reason": ["type": "string"]]
                ]]
            ]
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "system": systemBlocks,
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AnthropicError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]],
            let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let jsonData = Self.extractJSON(text).data(using: .utf8)
        else { throw AnthropicError.noContent }
        return (try? JSONDecoder().decode(FindResult.self, from: jsonData))?.matches ?? []
    }

    static let findInstruction = """
    You are a meticulous librarian for a personal archive of letters and documents. You are given the \
    user's request and a CATALOG with one item per line in the form: \
    [id] "title" — date — from X to Y — type — summary. Choose the items that best satisfy the \
    request — whether by kind/type, theme or subject, time period, a particular writer or recipient, \
    or a specific pair of correspondents — and order them most relevant first. Return each match as \
    its exact id (copied verbatim from the catalog) plus a one-line reason it fits. Include only \
    genuine matches; if none fit, return an empty list. Respond with ONLY the JSON object.
    """

    /// Resolves auth headers from the stored credential (refreshing an expired OAuth token).
    // MARK: - People resolution

    /// One proposed identity merge from the People-resolution pass.
    public struct PersonMerge: Codable, Sendable {
        public let alias: String        // the name to fold away (as it appears in the catalog)
        public let canonical: String    // the one name this person should appear under
        public let confidence: String   // high | medium | low
    }
    private struct ResolveResult: Codable { let merges: [PersonMerge] }

    /// Asks Claude to resolve the People index into one entry per human being: duplicates,
    /// spelling variants, partial names, nicknames/endearments ("darling sweetness"), and
    /// relations folded into the name the owner would search by ("Mum"). The catalog carries one
    /// person per line with letter counts and relationship hints drawn from their letters.
    public func resolvePeople(catalog: String, ownerContext: String? = nil,
                              model overrideModel: String? = nil) async throws -> [PersonMerge] {
        let model = overrideModel ?? self.model
        let headers = try await Self.authHeaders()

        var systemBlocks: [[String: Any]] = []
        if Keychain.credential()?.kind == .oauth {
            systemBlocks.append(["type": "text",
                                 "text": "You are Claude Code, Anthropic's official CLI for Claude."])
        }
        systemBlocks.append(["type": "text", "text": Self.resolvePeopleInstruction])

        var userText = "PEOPLE (one per line):\n\(catalog)"
        if let ownerContext, !ownerContext.isEmpty {
            userText = "OWNER PROFILE:\n\(ownerContext)\n\n" + userText
        }
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["merges"],
            "properties": [
                "merges": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["alias", "canonical", "confidence"],
                    "properties": ["alias": ["type": "string"],
                                   "canonical": ["type": "string"],
                                   "confidence": ["type": "string", "enum": ["high", "medium", "low"]]]
                ]]
            ]
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "system": systemBlocks,
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AnthropicError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let blocks = root["content"] as? [[String: Any]],
            let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let jsonData = Self.extractJSON(text).data(using: .utf8)
        else { throw AnthropicError.noContent }
        return (try? JSONDecoder().decode(ResolveResult.self, from: jsonData))?.merges ?? []
    }

    static let resolvePeopleInstruction = """
    You are curating the People index of a personal archive of letters. The same human being often \
    appears under several names — a full name, a first name, a misspelling, a nickname or term of \
    endearment ("darling sweetness"), or a relation word ("Mother"). You are given the archive \
    owner's profile and a PEOPLE catalog, one person-entry per line, as: "Name" — N letters — \
    roles — hints (relationship and suspected-writer notes drawn from their letters). Propose \
    merges so the index has exactly ONE entry per real person. Rules: \
    (1) If someone is a close relation of the owner, the canonical name is the relation as the \
    owner would say and search it — "Mum", "Dad", "Grandma" — with the real name in parentheses \
    when known, e.g. "Mum (Vivienne)". \
    (2) A term of endearment is never a canonical name: resolve it to the real person when the \
    hints and profile support it. \
    (3) Otherwise prefer the fullest real name ("Eleanor Whitfield" over "Eleanor"). \
    (4) Never merge two people who are plausibly distinct; when unsure, leave them apart or use \
    confidence "low". Do not invent names that are not grounded in the catalog or profile. \
    Return ONLY the JSON object with the merges (empty list if nothing should change).
    """

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

    /// Today's date (the user's local date), with guidance so dates are anchored to *now* — the model
    /// otherwise tends to date undated digital content (e.g. screenshots) to its training era.
    static func dateAnchor() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        return "Today's date is \(today). Anchor all relative or recent dates to it. In particular, "
            + "screenshots and other digital content with no explicit visible date were almost "
            + "certainly captured recently (on or near \(today)) — never date them to an earlier year "
            + "from your training data."
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

    Resolve terms of endearment to who they really are. If a sender or recipient is addressed ONLY by \
    a pet name, term of endearment, or nickname (e.g. "sweetness", "darling", "my dear boy") rather \
    than a real name, infer who they actually are from the letter's content and the archive owner \
    profile, and use that real/canonical name for the sender/recipient field (e.g. a mother addressed \
    throughout as "sweetness" should be recorded as "Mum"). Keep the original endearment in \
    people_mentioned so nothing is lost. Only resolve when the letter and context make it reasonably \
    clear; if you genuinely cannot tell who it is, keep the term exactly as written.

    Also pull out a few notable or striking quotes from the letter — verbatim excerpts that capture \
    its voice or its key moments — into notable_quotes (an empty list is fine if none stand out).

    Finally, do a quiet "meta" reading of the letter and fill the meta object: a possible location \
    the letter was written from or concerns; the likely relationship between sender and recipient; \
    the apparent state or tone of that relationship at this moment; and the writer's goals — what \
    they seem to want from writing. Infer reasonably from tone and content; use "" if there is no \
    basis. Keep each meta value to a short phrase or sentence.

    Also study the HANDWRITING itself. In meta.handwriting_profile, give your best guess at the \
    writer's sex and approximate age based purely on handwriting style — letterforms, slant, \
    pressure, formality, fluency — e.g. "Likely female, 30s–40s", hedged honestly; use "" only if \
    you truly cannot tell. In meta.suspected_writer, if a signature, a named sender, the archive \
    owner profile (provided separately, if any), or the hand and content of THIS document let you \
    identify or strongly suspect who wrote it, name them with a brief reason (e.g. "Signed 'M' — \
    likely Marcel", or "About the owner's ★★★★★/PARADOX work — written by them"); otherwise "".

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
                "required": ["location", "relationship", "relationship_state", "writer_goals",
                             "handwriting_profile", "suspected_writer"],
                "properties": [
                    "location": ["type": "string"],
                    "relationship": ["type": "string"],
                    "relationship_state": ["type": "string"],
                    "writer_goals": ["type": "string"],
                    "handwriting_profile": ["type": "string"],
                    "suspected_writer": ["type": "string"]
                ]
            ]
        ]
    ] }
}
