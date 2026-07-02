import Foundation

/// The durable, app-independent on-disk record of one letter, written alongside its page images so
/// the **folder is the source of truth**, not the database. Any future version of Combray — even a
/// fundamental rewrite — can read and write these files.
///
/// Layout: `~/Documents/Combray/Letters/<number>/`
///   - `letter_<n>_page_<y>.jpg` … the lossless page images (openable in Preview)
///   - `letter.json` … this record (sender, date, summary, meta, transcription, …)
///   - `transcription.txt` … the transcription as plain, human-readable text
public struct LetterFile: Codable, Sendable {
    public struct DateInfo: Codable, Sendable {
        public var value: String?
        public var source: String
        public var confidence: String?
    }
    public struct MetaInfo: Codable, Sendable {
        public var location: String?
        public var relationship: String?
        public var relationshipState: String?
        public var writerGoals: String?
        /// Handwriting-based guess at the writer's sex/age — optional/additive, absent in old records.
        public var handwriting: String?
        /// Suspected writer from handwriting match — optional/additive, absent in old records.
        public var suspectedWriter: String?
    }

    public var number: Int
    public var id: String
    public var title: String?
    public var date: DateInfo
    public var from: String?
    public var to: [String]
    public var summary: String?
    /// What the document is ("letter", "screenshot", …) — optional/additive; absent in old records.
    public var documentType: String?
    public var meta: MetaInfo
    public var transcription: String
    public var aiTranscription: String?
    public var pages: [String]      // page image filenames, in order
    public var notableQuotes: [String]?
    /// Read-aloud voicing substitutions — optional/additive; absent in old records.
    public var speechSubstitutions: [SpokenSub]?
    /// Questionable readings awaiting review — optional/additive; absent in old records.
    public var uncertainSpans: [UncertainItem]?
    public var pinned: Bool?        // pinned to the sidebar top (optional — absent in old records = false)
    public var createdAt: Date
    public var updatedAt: Date

    /// One "say this token as…" pair for read-aloud (dates, times, old money).
    public struct SpokenSub: Codable, Sendable, Equatable {
        public var original: String
        public var spoken: String
        public init(original: String, spoken: String) { self.original = original; self.spoken = spoken }
    }

    /// One questionable reading: the transcribed guess, why it's doubtful, and its review status
    /// ("open" | "approved" | "denied").
    public struct UncertainItem: Codable, Sendable, Equatable {
        public var text: String
        public var reason: String
        public var status: String
        public init(text: String, reason: String, status: String = "open") {
            self.text = text; self.reason = reason; self.status = status
        }
    }

    public static func decodeUncertain(_ json: String?) -> [UncertainItem]? {
        guard let data = json?.data(using: .utf8),
              let items = try? JSONDecoder().decode([UncertainItem].self, from: data), !items.isEmpty
        else { return nil }
        return items
    }
    public static func encodeUncertain(_ items: [UncertainItem]?) -> String? {
        guard let items, let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The DB stores substitutions as a JSON string column; letter.json stores them typed.
    public static func decodeSpeechSubs(_ json: String?) -> [SpokenSub]? {
        guard let data = json?.data(using: .utf8),
              let subs = try? JSONDecoder().decode([SpokenSub].self, from: data), !subs.isEmpty
        else { return nil }
        return subs
    }
    public static func encodeSpeechSubs(_ subs: [SpokenSub]?) -> String? {
        guard let subs, let data = try? JSONEncoder().encode(subs) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum Backup {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes `letter.json` + `transcription.txt` into `letters/<number>/`.
    public static func write(_ file: LetterFile, lettersDir: URL) throws {
        let dir = lettersDir.appendingPathComponent("\(file.number)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: dir.appendingPathComponent("letter.json"), options: .atomic)
        let text = [file.title, file.transcription].compactMap { $0 }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: dir.appendingPathComponent("transcription.txt"), options: .atomic)
    }

    /// Scans `letters/*/letter.json` and returns every record found — used to rebuild the index.
    public static func scan(lettersDir: URL) -> [LetterFile] {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: lettersDir, includingPropertiesForKeys: nil) else { return [] }
        return subdirs.compactMap { dir in
            let json = dir.appendingPathComponent("letter.json")
            guard let data = try? Data(contentsOf: json) else { return nil }
            return try? decoder.decode(LetterFile.self, from: data)
        }
    }
}
