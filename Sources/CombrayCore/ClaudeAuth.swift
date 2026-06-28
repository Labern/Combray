import Foundation
import CryptoKit
import Security

/// "Sign in with Claude" — Anthropic's OAuth 2.0 + PKCE flow (the same one Claude Code uses).
/// The user approves in the browser, copies the code shown on the callback page, and pastes it back.
public enum ClaudeAuth {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    public static let consoleRedirect = "https://console.anthropic.com/oauth/code/callback"
    public static func loopbackRedirect(port: UInt16) -> String { "http://localhost:\(port)/callback" }
    static let scope = "org:create_api_key user:profile user:inference"

    public struct PKCE: Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String
    }

    public struct Tokens: Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
    }

    public static func makePKCE() -> PKCE {
        let verifier = randomBase64URL(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = randomBase64URL(24)
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    public static func authorizeURL(_ pkce: PKCE, redirectURI: String = consoleRedirect) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return comps.url!
    }

    /// Exchanges the pasted code (which may be in `code#state` form) for tokens.
    public static func exchange(code raw: String, pkce: PKCE,
                                redirectURI: String = consoleRedirect) async throws -> Tokens {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let code = String(parts.first ?? "")
        let state = parts.count > 1 ? String(parts[1]) : pkce.state
        return try await post([
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
    }

    public static func refresh(_ refreshToken: String) async throws -> Tokens {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private static func post(_ body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "ClaudeAuth", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Sign-in failed (\(status)). \(String(data: data, encoding: .utf8) ?? "")"
            ])
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            throw NSError(domain: "ClaudeAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No access token in the response."])
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        return Tokens(accessToken: access,
                      refreshToken: json["refresh_token"] as? String,
                      expiresAt: Date().addingTimeInterval(expiresIn))
    }

    static func randomBase64URL(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
