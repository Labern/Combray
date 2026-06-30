import XCTest
import Foundation
@testable import CombrayCore

// Core unit tests for the CombrayCore data layer. Every test runs against a fresh in-memory database
// or a unique temp directory, so nothing here touches the user's real archive or credentials.

// MARK: - Helpers

/// A fresh in-memory archive (no disk, no migrations to clean up).
private func makeArchive() throws -> Archive {
    Archive(try AppDatabase.makeInMemory())
}

/// A unique temp directory for file-touching tests (never the real archive).
private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("combray-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Plumbing

/// The build links GRDB/SQLite and the schema migrates cleanly — the foundation everything sits on.
final class PlumbingTests: XCTestCase {
    /// The library exposes a positive schema version (sanity that the module is wired up).
    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(Combray.schemaVersion, 0)
    }

    /// GRDB is linked and the bundled SQLite is a real 3.x engine.
    func testGRDBLinksAndSQLiteOpens() throws {
        XCTAssertTrue(try Combray.sqliteVersion().hasPrefix("3."))
    }

    /// An in-memory database opens, which means all migrations applied without error.
    func testInMemoryDatabaseOpens() throws {
        _ = try AppDatabase.makeInMemory()  // would throw if migrations failed
    }
}

// MARK: - Archive CRUD

/// Saving, fetching, deleting and ordering letters — the basic record lifecycle.
final class ArchiveCRUDTests: XCTestCase {
    /// A saved letter reads back with its fields intact and `pinned` defaulting to false.
    func testSaveAndFetchLetter() throws {
        let a = try makeArchive()
        var l = Letter(number: 1, title: "Hello", transcription: "Dear friend")
        l = try a.save(l)
        let back = try XCTUnwrap(try a.letter(id: l.id))
        XCTAssertEqual(back.title, "Hello")
        XCTAssertEqual(back.transcription, "Dear friend")
        XCTAssertEqual(back.number, 1)
        XCTAssertFalse(back.pinned)             // default
    }

    /// `nextLetterNumber()` returns one past the highest existing number (drives folder names).
    func testNextLetterNumberIncrements() throws {
        let a = try makeArchive()
        XCTAssertEqual(try a.nextLetterNumber(), 1)
        _ = try a.save(Letter(number: 1))
        _ = try a.save(Letter(number: 2))
        XCTAssertEqual(try a.nextLetterNumber(), 3)
    }

    /// Deleting a letter removes it from the index.
    func testDeleteLetter() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 1))
        try a.deleteLetter(id: l.id)
        XCTAssertNil(try a.letter(id: l.id))
    }

    /// The `pinned` flag is persisted across save/fetch.
    func testPinnedPersists() throws {
        let a = try makeArchive()
        var l = try a.save(Letter(number: 1))
        l.pinned = true
        _ = try a.save(l)
        XCTAssertTrue(try XCTUnwrap(try a.letter(id: l.id)).pinned)
    }

    /// `allLetters()` returns newest-year first.
    func testAllLettersOrdersByYearDescending() throws {
        let a = try makeArchive()
        _ = try a.save(Letter(number: 1, dateYear: 1960))
        _ = try a.save(Letter(number: 2, dateYear: 1990))
        _ = try a.save(Letter(number: 3, dateYear: 1975))
        XCTAssertEqual(try a.allLetters().map(\.dateYear), [1990, 1975, 1960])
    }
}

// MARK: - People, pages, participants

/// The many-to-many edges — who's on a letter, its pages, and the derived people/years lists.
final class ArchiveRelationsTests: XCTestCase {
    /// A letter's sender + recipients are stored and read back as people.
    func testParticipantsRoundTrip() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 1))
        try a.setParticipants(letterId: l.id, sender: "Eleanor Brun", recipients: ["Marcel", "Mum"])
        let parties = try a.participants(forLetterId: l.id)
        XCTAssertEqual(parties.sender?.displayName, "Eleanor Brun")
        XCTAssertEqual(Set(parties.recipients.map(\.displayName)), ["Marcel", "Mum"])
    }

    /// A letter's page rows are stored and read back by image path.
    func testPagesRoundTrip() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 3))
        let pages = [
            Page(letterId: l.id, pageIndex: 0, imagePath: "Letters/3/letter_3_page_1.jpg"),
            Page(letterId: l.id, pageIndex: 1, imagePath: "Letters/3/letter_3_page_2.jpg"),
        ]
        try a.setPages(pages, forLetterId: l.id)
        XCTAssertEqual(try a.pages(forLetterId: l.id).map(\.imagePath).sorted(),
                       ["Letters/3/letter_3_page_1.jpg", "Letters/3/letter_3_page_2.jpg"])
    }

    /// The distinct people across letters and the distinct years are both derived correctly.
    func testPeopleAndYears() throws {
        let a = try makeArchive()
        let l1 = try a.save(Letter(number: 1, dateYear: 1962))
        try a.setParticipants(letterId: l1.id, sender: "Alice", recipients: ["Bob"])
        let l2 = try a.save(Letter(number: 2, dateYear: 1970))
        try a.setParticipants(letterId: l2.id, sender: "Carol", recipients: [])
        XCTAssertEqual(Set(try a.people().map(\.displayName)), ["Alice", "Bob", "Carol"])
        XCTAssertEqual(try a.years().sorted(), [1962, 1970])
    }
}

// MARK: - Full-text search

/// The FTS5 index — finding letters by transcription body and by participant name.
final class SearchTests: XCTestCase {
    /// A word in the transcription matches only the letter that contains it.
    func testSearchFindsByTranscription() throws {
        let a = try makeArchive()
        let l1 = try a.save(Letter(number: 1, title: "A", transcription: "the quick brown fox"))
        _ = try a.save(Letter(number: 2, title: "B", transcription: "lazy sleeping dog"))
        let hits = try a.search("fox")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.letterId, l1.id)
    }

    /// A sender's name is indexed alongside the body, so searching the name finds the letter.
    func testSearchFindsBySenderName() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 1, transcription: "nothing notable"))
        try a.setParticipants(letterId: l.id, sender: "Persephone", recipients: [])
        XCTAssertEqual(try a.search("Persephone").first?.letterId, l.id)
    }

    /// A term that appears nowhere returns no hits.
    func testSearchEmptyForNoMatch() throws {
        let a = try makeArchive()
        _ = try a.save(Letter(number: 1, transcription: "hello world"))
        XCTAssertTrue(try a.search("zzzznomatch").isEmpty)
    }
}

// MARK: - applyTranscription

/// Applying a model result to a letter — fields, date parsing, people, and the composed title.
final class ApplyTranscriptionTests: XCTestCase {
    private func decode(_ json: String) throws -> TranscriptionResult {
        try JSONDecoder().decode(TranscriptionResult.self, from: Data(json.utf8))
    }

    /// A full result populates text, summary, date (+ parsed year/source), meta, quotes and people.
    func testAppliesAllFields() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 1))
        let r = try decode("""
        {"transcription":"Dear Marcel, ...","title":"Letter to Marcel from Eleanor",
         "document_type":"letter","summary":"A warm note.","sender":"Eleanor","recipients":["Marcel"],
         "date":{"value":"1962-03","source":"written","confidence":"high"},
         "people_mentioned":["Odette"],"notable_quotes":["one bite of the madeleine"],
         "uncertain_spans":[],
         "meta":{"location":"Combray","relationship":"mother and son",
                 "relationship_state":"tender","writer_goals":"to reassure"}}
        """)
        let updated = try a.applyTranscription(r, toLetterId: l.id)
        XCTAssertEqual(updated.title, "Letter to Marcel from Eleanor")
        XCTAssertEqual(updated.summary, "A warm note.")
        XCTAssertEqual(updated.dateValue, "1962-03")
        XCTAssertEqual(updated.dateYear, 1962)
        XCTAssertEqual(updated.dateSource, .written)
        XCTAssertEqual(updated.metaLocation, "Combray")
        XCTAssertEqual(updated.metaWriterGoals, "to reassure")
        XCTAssertEqual(updated.notableQuotes, "one bite of the madeleine")
        let parties = try a.participants(forLetterId: l.id)
        XCTAssertEqual(parties.sender?.displayName, "Eleanor")
        XCTAssertEqual(parties.recipients.first?.displayName, "Marcel")
    }

    /// When the model returns no title, one is composed from the type + sender/recipient.
    func testComposesTitleWhenModelGivesNone() throws {
        let a = try makeArchive()
        let l = try a.save(Letter(number: 1))
        let r = try decode("""
        {"transcription":"hi","title":"","document_type":"letter","summary":"",
         "sender":"Alice","recipients":["Bob"],
         "date":{"value":"","source":"unknown","confidence":"low"},
         "people_mentioned":[],"notable_quotes":[],"uncertain_spans":[],
         "meta":{"location":"","relationship":"","relationship_state":"","writer_goals":""}}
        """)
        XCTAssertEqual(try a.applyTranscription(r, toLetterId: l.id).title, "Letter to Bob from Alice")
    }
}

// MARK: - composedTitle (document-type aware)

/// The fallback title builder — correspondence reads "Type to X from Y"; other docs use the summary.
final class ComposedTitleTests: XCTestCase {
    /// A letter composes "Letter to Bob from Alice".
    func testLetter() {
        XCTAssertEqual(
            Archive.composedTitle(documentType: "letter", sender: "Alice", recipients: ["Bob"], summary: ""),
            "Letter to Bob from Alice")
    }

    /// A postcard is still correspondence, so it keeps the to/from framing.
    func testPostcardIsCorrespondence() {
        XCTAssertEqual(
            Archive.composedTitle(documentType: "postcard", sender: "Alice", recipients: ["Bob"], summary: ""),
            "Postcard to Bob from Alice")
    }

    /// A non-correspondence type (a list) reads "Type — summary" instead of to/from.
    func testNonCorrespondenceUsesSummary() {
        XCTAssertEqual(
            Archive.composedTitle(documentType: "list", sender: "", recipients: [], summary: "weekly groceries"),
            "List — weekly groceries")
    }

    /// A non-correspondence type with no summary falls back to just the capitalised kind.
    func testNonCorrespondenceNoSummaryFallsBackToKind() {
        XCTAssertEqual(
            Archive.composedTitle(documentType: "receipt", sender: "", recipients: [], summary: ""),
            "Receipt")
    }

    /// A blank document type defaults to "Letter".
    func testDefaultsToLetterWhenTypeBlank() {
        XCTAssertEqual(
            Archive.composedTitle(documentType: "", sender: "Alice", recipients: [], summary: ""),
            "Letter from Alice")
    }
}

// MARK: - Date parsing

/// Extracting a 4-digit year from the partial date forms the model returns.
final class DateParsingTests: XCTestCase {
    /// Full and partial ISO dates yield the year; junk and 2-digit years yield nil.
    func testYearExtraction() {
        XCTAssertEqual(Archive.year(from: "1962"), 1962)
        XCTAssertEqual(Archive.year(from: "1962-03"), 1962)
        XCTAssertEqual(Archive.year(from: "1962-03-04"), 1962)
        XCTAssertNil(Archive.year(from: ""))
        XCTAssertNil(Archive.year(from: "spring"))
        XCTAssertNil(Archive.year(from: "62"))
    }
}

// MARK: - Backup (folder = source of truth)

/// Writing/scanning `letter.json` (+ `transcription.txt`) and rebuilding the index from folders.
final class BackupTests: XCTestCase {
    /// A record written to disk scans back with its fields (incl. pinned + quotes) intact.
    func testWriteAndScanRoundTrip() throws {
        let dir = tempDir()
        let file = LetterFile(
            number: 5, id: "abc", title: "Postcard from Venice",
            date: .init(value: "1962", source: "written", confidence: "high"),
            from: "Eleanor", to: ["Marcel"], summary: "Greetings",
            meta: .init(location: "Venice", relationship: nil, relationshipState: nil, writerGoals: nil),
            transcription: "Wish you were here", aiTranscription: nil,
            pages: ["letter_5_page_1.jpg"], notableQuotes: ["wish you were here"],
            pinned: true, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        try Backup.write(file, lettersDir: dir)

        let folder = dir.appendingPathComponent("5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("letter.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcription.txt").path))

        let scanned = Backup.scan(lettersDir: dir)
        XCTAssertEqual(scanned.count, 1)
        let s = try XCTUnwrap(scanned.first)
        XCTAssertEqual(s.number, 5)
        XCTAssertEqual(s.title, "Postcard from Venice")
        XCTAssertEqual(s.pinned, true)
        XCTAssertEqual(s.notableQuotes, ["wish you were here"])
    }

    /// Backward-compat: a letter.json from before `pinned`/`notableQuotes` existed still decodes (→ nil).
    func testOldRecordWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"number":1,"id":"x","date":{"source":"unknown"},"to":[],"meta":{},
         "transcription":"hi","pages":[],
         "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(LetterFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.number, 1)
        XCTAssertNil(file.pinned)
        XCTAssertNil(file.notableQuotes)
        XCTAssertNil(file.title)
    }

    /// Importing folder records rebuilds the DB rows (letter, pages, participants) — the cache recovery path.
    func testImportFromFilesRebuildsIndex() throws {
        let a = try makeArchive()
        let file = LetterFile(
            number: 1, id: "id1", title: "T",
            date: .init(value: "1970", source: "inferred", confidence: "medium"),
            from: "A", to: ["B"], summary: "s",
            meta: .init(location: nil, relationship: nil, relationshipState: nil, writerGoals: nil),
            transcription: "body", aiTranscription: nil, pages: ["letter_1_page_1.jpg"],
            notableQuotes: nil, pinned: true, createdAt: Date(), updatedAt: Date())
        try a.importFromFiles([file])
        let back = try XCTUnwrap(try a.letter(id: "id1"))
        XCTAssertEqual(back.title, "T")
        XCTAssertTrue(back.pinned)
        XCTAssertEqual(try a.pages(forLetterId: "id1").count, 1)
        XCTAssertEqual(try a.participants(forLetterId: "id1").sender?.displayName, "A")
    }
}

// MARK: - TranscriptionResult lenient decoding

/// The model's JSON decodes leniently — a full object reads fully, a partial one fills defaults.
final class TranscriptionResultTests: XCTestCase {
    /// Every field of a complete result decodes into the struct.
    func testDecodesFullObject() throws {
        let r = try JSONDecoder().decode(TranscriptionResult.self, from: Data("""
        {"transcription":"t","title":"ti","document_type":"postcard","summary":"su",
         "sender":"se","recipients":["r1","r2"],
         "date":{"value":"1999","source":"written","confidence":"high"},
         "people_mentioned":["p"],"notable_quotes":["q"],"uncertain_spans":[{"text":"x","reason":"y"}],
         "meta":{"location":"l","relationship":"rel","relationship_state":"st","writer_goals":"g"}}
        """.utf8))
        XCTAssertEqual(r.title, "ti")
        XCTAssertEqual(r.document_type, "postcard")
        XCTAssertEqual(r.recipients, ["r1", "r2"])
        XCTAssertEqual(r.date.value, "1999")
        XCTAssertEqual(r.notable_quotes, ["q"])
        XCTAssertEqual(r.meta.writer_goals, "g")
    }

    /// A near-empty result doesn't throw; missing fields fall back to defaults.
    func testDecodesPartialObjectWithDefaults() throws {
        let r = try JSONDecoder().decode(TranscriptionResult.self, from: Data("""
        {"transcription":"just text"}
        """.utf8))
        XCTAssertEqual(r.transcription, "just text")
        XCTAssertEqual(r.title, "")
        XCTAssertEqual(r.document_type, "")
        XCTAssertTrue(r.recipients.isEmpty)
        XCTAssertTrue(r.notable_quotes.isEmpty)
    }
}

// MARK: - Anthropic request schema (regression guard)

/// Guards the structured-output schema so output fields can't silently go missing again.
final class SchemaTests: XCTestCase {
    /// Every output field is in `required` (once, dropping these left meta/summary empty) and present in properties.
    func testSchemaRequiresAllOutputFields() {
        let schema = AnthropicClient.schema
        let required = (schema["required"] as? [String]) ?? []
        // These were once dropped by `additionalProperties:false`, leaving meta/summary empty.
        for key in ["transcription", "title", "document_type", "summary", "date",
                    "people_mentioned", "notable_quotes", "uncertain_spans", "meta"] {
            XCTAssertTrue(required.contains(key), "schema.required is missing \(key)")
        }
        let props = (schema["properties"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(props["document_type"])
        XCTAssertNotNil(props["meta"])
    }
}

// MARK: - ImageStore

/// Where images live on disk and how they're named/copied (ungated Application Support, lossless).
final class ImageStoreTests: XCTestCase {
    /// The archive root is under Application Support, never the TCC-gated Documents folder.
    func testDefaultRootIsApplicationSupport() {
        let root = ImageStore.defaultRoot().path
        XCTAssertTrue(root.contains("Application Support/Combray"), "got \(root)")
        XCTAssertFalse(root.contains("/Documents/"), "must not live in Documents")
    }

    /// The images live under a capitalised `Letters/` directory.
    func testLettersDirIsCapitalised() {
        XCTAssertEqual(ImageStore(root: tempDir()).lettersDir.lastPathComponent, "Letters")
    }

    /// Importing copies the original bytes verbatim to a logical `Letters/<n>/letter_<n>_page_<k>.<ext>` path.
    func testImportImageCopiesAndNames() throws {
        let store = ImageStore(root: tempDir())
        let src = tempDir().appendingPathComponent("scan.JPG")
        try Data("not-really-a-jpeg".utf8).write(to: src)

        let page = try store.importImage(from: src, letterId: "L", letterNumber: 7, index: 0)
        XCTAssertEqual(page.imagePath, "Letters/7/letter_7_page_1.jpg")
        XCTAssertEqual(page.letterId, "L")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: page).path))
        XCTAssertEqual(try Data(contentsOf: store.url(for: page)), Data("not-really-a-jpeg".utf8))
    }
}

// MARK: - Credentials (in-memory only — does NOT touch the real credentials file)

/// Stored credential expiry + Codable round-trip (constructed in memory, never the real file).
final class CredentialTests: XCTestCase {
    /// OAuth tokens expire on their expiry date; API keys never report expired.
    func testOAuthExpiry() {
        let live = StoredCredential(kind: .oauth, accessToken: "a",
                                    expiresAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(live.isExpired)
        let stale = StoredCredential(kind: .oauth, accessToken: "a",
                                     expiresAt: Date().addingTimeInterval(-10))
        XCTAssertTrue(stale.isExpired)
        XCTAssertFalse(StoredCredential(kind: .apiKey, apiKey: "k").isExpired)
    }

    /// A credential survives an encode/decode round-trip with its tokens intact.
    func testCodableRoundTrip() throws {
        let cred = StoredCredential(kind: .oauth, accessToken: "tok", refreshToken: "ref",
                                    expiresAt: Date(timeIntervalSince1970: 1000))
        let back = try JSONDecoder().decode(StoredCredential.self,
                                            from: try JSONEncoder().encode(cred))
        XCTAssertEqual(back.kind, .oauth)
        XCTAssertEqual(back.accessToken, "tok")
        XCTAssertEqual(back.refreshToken, "ref")
    }
}
