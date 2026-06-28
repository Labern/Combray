import Foundation
import GRDB

/// Namespace + build metadata for the Combray letter archive.
///
/// Combray stores a personal collection of handwritten letters: each letter is one or
/// more photographed pages plus an AI-generated, user-editable transcription, organized by
/// people, relationships, and year, and searchable in full text.
public enum Combray {
    /// The on-disk schema version. Bump when adding a migration in `AppDatabase`.
    public static let schemaVersion = 1

    /// A quick smoke check that GRDB links and an in-memory SQLite database opens.
    /// Returns the SQLite library version string (e.g. "3.43.2").
    public static func sqliteVersion() throws -> String {
        let dbQueue = try DatabaseQueue()
        return try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
        }
    }
}
