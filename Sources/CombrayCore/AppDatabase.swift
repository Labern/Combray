import Foundation
import GRDB

/// Owns the SQLite database connection and schema for the Combray archive.
///
/// One portable `.sqlite` file holds everything (letters, people, pages, full-text index) so a
/// future read-only web service can serve the exact same data. Images themselves live on disk;
/// the `page` table stores their paths.
public final class AppDatabase: Sendable {
    /// The GRDB writer (a `DatabasePool` on disk, or a `DatabaseQueue` in memory for tests).
    public let dbWriter: any DatabaseWriter

    /// Creates the database and runs migrations.
    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// A read-only accessor for queries.
    public var reader: any DatabaseReader { dbWriter }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // During development, rebuild the schema from scratch when a migration changes.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("aka", .text)
                t.column("notes", .text)
            }

            try db.create(table: "relationship") { t in
                t.primaryKey("id", .text)
                t.column("personId", .text).notNull()
                    .indexed()
                    .references("person", onDelete: .cascade)
                t.column("relation", .text).notNull()
            }

            try db.create(table: "letter") { t in
                t.primaryKey("id", .text)
                t.column("number", .integer).notNull().defaults(to: 0).indexed()
                t.column("title", .text)
                t.column("dateValue", .text)
                t.column("dateYear", .integer).indexed()
                t.column("dateSource", .text).notNull()
                t.column("dateConfidence", .text)
                t.column("transcription", .text).notNull().defaults(to: "")
                t.column("aiTranscription", .text)
                t.column("notes", .text)
                t.column("summary", .text)
                t.column("metaLocation", .text)
                t.column("metaRelationship", .text)
                t.column("metaRelationshipState", .text)
                t.column("metaWriterGoals", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "page") { t in
                t.primaryKey("id", .text)
                t.column("letterId", .text).notNull()
                    .indexed()
                    .references("letter", onDelete: .cascade)
                t.column("pageIndex", .integer).notNull()
                t.column("imagePath", .text).notNull()
                t.column("thumbnailPath", .text)
                t.column("width", .integer)
                t.column("height", .integer)
            }

            try db.create(table: "letterPerson") { t in
                t.column("letterId", .text).notNull()
                    .references("letter", onDelete: .cascade)
                t.column("personId", .text).notNull()
                    .references("person", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.primaryKey(["letterId", "personId", "role"])
            }

            // Standalone full-text index. The repository keeps it in sync per-letter
            // (delete + insert by letterId) so denormalized sender/recipient names can
            // be indexed alongside the title and transcription body.
            try db.create(virtualTable: "letterSearch", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.column("letterId").notIndexed()
                t.column("title")
                t.column("body")
                t.column("names")
            }
        }

        return migrator
    }
}

// MARK: - Factories

public extension AppDatabase {
    /// Opens (or creates) the on-disk archive database at `url`.
    static func makeOnDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path)
        return try AppDatabase(pool)
    }

    /// An in-memory database for tests and previews.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }
}
