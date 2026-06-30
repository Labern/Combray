import Foundation

/// Auto-update logic that doesn't touch the network or the UI — kept here so it's unit-testable.
/// The app layer (`Updater`) does the fetching, downloading and bundle-swap; this file just decides
/// *whether* a release is newer and *which* asset to download.
public enum AppUpdate {

    /// `true` when `latest` is a strictly newer version than `current`.
    /// Numeric, component-wise comparison so `0.10.0 > 0.9.0` and `0.12.0 > 0.11.1` (not lexical).
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        compare(latest, current) == .orderedDescending
    }

    /// Compare two dotted version strings (a leading `v` and differing component counts are fine).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = components(a), pb = components(b)
        for i in 0 ..< max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Split "v0.12.1" → [0, 12, 1]; each component takes its leading digits ("1-beta" → 1).
    static func components(_ s: String) -> [Int] {
        let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .drop { $0 == "v" }
        return body.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

/// The slice of GitHub's `releases/latest` JSON the updater needs.
public struct GitHubRelease: Decodable {
    public let tagName: String
    public let htmlURL: String
    public let assets: [Asset]

    public struct Asset: Decodable {
        public let name: String
        public let downloadURL: String
        enum CodingKeys: String, CodingKey { case name; case downloadURL = "browser_download_url" }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    /// The version stripped of the leading `v` (e.g. `v0.12.0` → `0.12.0`).
    public var version: String { String(tagName.drop { $0 == "v" }) }

    /// Download URL of the first asset whose name ends with `suffix` (case-insensitive), e.g. ".zip".
    public func assetURL(suffix: String) -> URL? {
        assets.first { $0.name.lowercased().hasSuffix(suffix.lowercased()) }
            .flatMap { URL(string: $0.downloadURL) }
    }

    /// Decode a release from raw `releases/latest` JSON.
    public static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
