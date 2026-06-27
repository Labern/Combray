import Foundation

/// The stored Anthropic credential — either a Claude OAuth token (from "Sign in with Claude") or a
/// pasted API key.
public struct StoredCredential: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case apiKey, oauth }
    public var kind: Kind
    public var apiKey: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(kind: Kind, apiKey: String? = nil, accessToken: String? = nil,
                refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.kind = kind
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let e = expiresAt else { return false }
        return Date() >= e.addingTimeInterval(-60)  // refresh a minute early
    }
}

/// Stores the credential as a private 0600 file in Application Support. (Not the macOS Keychain —
/// an unsigned/rebuilt dev app loses its Keychain ACL and would prompt for the login password on
/// every launch; a file in the user's own protected folder avoids that. Kept out of the
/// Finder-browsable archive so a backup of ~/Documents/Combray never contains the token.)
public enum Keychain {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Combray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    public static func credential() -> StoredCredential? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return StoredCredential(kind: .apiKey, apiKey: env)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    @discardableResult
    public static func save(_ credential: StoredCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    public static func setAPIKey(_ key: String) {
        save(StoredCredential(kind: .apiKey, apiKey: key))
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public static func hasCredential() -> Bool { credential() != nil }

    public static func apiKey() -> String? {
        let cred = credential()
        return cred?.kind == .apiKey ? cred?.apiKey : nil
    }
}
