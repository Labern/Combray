import XCTest
import Foundation
@testable import CombrayCore

// Coverage for logic added in the v0.11 cycle: stronger people de-dup, text-only metadata refresh,
// the legacy "looks like a screenshot" fallback, and the new additive fields' round-trip.

private func arch() throws -> Archive { Archive(try AppDatabase.makeInMemory()) }
private func result(_ json: String) -> TranscriptionResult {
    try! JSONDecoder().decode(TranscriptionResult.self, from: Data(json.utf8))
}

// MARK: - People de-dup (new behaviours)

final class MergePeopleV011Tests: XCTestCase {
    func testJunkNamesAreDeleted() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: ",")
        _ = try a.findOrCreatePerson(named: "Alice")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().map(\.displayName), ["Alice"])
    }

    func testOwnerAliasesFoldToOwnerName() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "self")
        _ = try a.findOrCreatePerson(named: "labern")
        try a.mergeDuplicatePeople(ownerName: "Labern")
        XCTAssertEqual(try a.people().map(\.displayName), ["Labern"])   // one entity, shown as the owner name
    }

    func testParentheticalPrefixVariantsMerge() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "Claude (CLI agent)")
        _ = try a.findOrCreatePerson(named: "Claude Code (CLI agents)")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().count, 1)
    }

    func testLeadingNameWithoutParensIsNotMerged() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "Anne")
        _ = try a.findOrCreatePerson(named: "Anne Marie")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().count, 2)   // distinct people who merely share a first name
    }
}

// MARK: - Text-only metadata refresh (applyMetadata)

final class ApplyMetadataTests: XCTestCase {
    func testRefreshesDerivedFieldsButKeepsTheRest() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1))
        _ = try a.applyTranscription(result("""
        {"transcription":"orig text","title":"Orig","document_type":"letter","summary":"old summary",
         "sender":"Marcel","recipients":["Eleanor"],
         "date":{"value":"1990","source":"written","confidence":"high"},
         "meta":{"location":"Paris","handwriting_profile":"Likely female, 30s"}}
        """), toLetterId: l.id)

        try a.applyMetadata(result("""
        {"transcription":"IGNORED","summary":"new summary","document_type":"screenshot",
         "date":{"value":"2020","source":"inferred","confidence":"low"},
         "meta":{"location":"London","suspected_writer":"Bob","handwriting_profile":""}}
        """), toLetterId: l.id)

        let u = try a.letter(id: l.id)!
        // refreshed from the new text-only reading
        XCTAssertEqual(u.summary, "new summary")
        XCTAssertEqual(u.metaLocation, "London")
        XCTAssertEqual(u.metaSuspectedWriter, "Bob")
        // left untouched
        XCTAssertEqual(u.transcription, "orig text")
        XCTAssertEqual(u.title, "Orig")
        XCTAssertEqual(u.dateValue, "1990")
        XCTAssertEqual(u.documentType, "letter")                 // not flipped to "screenshot"
        XCTAssertEqual(u.metaHandwriting, "Likely female, 30s")  // text-only can't see handwriting
        XCTAssertEqual(try a.participants(forLetterId: l.id).sender?.displayName, "Marcel")
    }
}

// MARK: - Layout-significance fallback (legacy records without documentType)

final class LayoutSignificanceFallbackTests: XCTestCase {
    func testTitleScreenshotWordTriggersVerbatimWhenNoDocType() {
        XCTAssertTrue(TextReflow.isLayoutSignificant(
            documentType: nil, title: "Screenshot of two Claude Code sessions", transcription: "anything"))
    }

    func testCodeShapedContentTriggersVerbatimWhenNoDocType() {
        let code = "func main() {\n    let x = compute()\n    print(x)\n    return\n}"
        XCTAssertTrue(TextReflow.isLayoutSignificant(documentType: nil, title: "Notes", transcription: code))
    }

    func testProseLetterStaysReflowed() {
        let prose = "Dear Anne,\n\nIt was lovely to hear from you after all these long months apart.\n\nYours, M."
        XCTAssertFalse(TextReflow.isLayoutSignificant(documentType: nil, title: "A long letter", transcription: prose))
    }

    func testExplicitDocTypeIsAuthoritativeOverTitle() {
        // documentType "letter" wins even if the title mentions a screenshot.
        XCTAssertFalse(TextReflow.isLayoutSignificant(
            documentType: "letter", title: "Screenshot mock-up", transcription: "Dear friend, …"))
    }
}

// MARK: - Additive fields round-trip (folders are the source of truth)

final class AdditiveFieldsRoundTripTests: XCTestCase {
    func testDocumentTypeAndHandwritingSurviveBackupAndRebuild() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1))
        _ = try a.applyTranscription(result("""
        {"transcription":"hi","title":"A note","document_type":"postcard","summary":"s",
         "date":{"value":"1963"},
         "meta":{"handwriting_profile":"Likely male, 50s","suspected_writer":"Eleanor"}}
        """), toLetterId: l.id)

        // letter.json shape carries the new fields…
        let file = try a.backupFile(forLetterId: l.id)!
        XCTAssertEqual(file.documentType, "postcard")
        XCTAssertEqual(file.meta.handwriting, "Likely male, 50s")
        XCTAssertEqual(file.meta.suspectedWriter, "Eleanor")

        // …and a fresh archive rebuilt from that file restores them.
        let rebuilt = try arch()
        try rebuilt.importFromFiles([file])
        let imported = try rebuilt.letter(id: l.id)!
        XCTAssertEqual(imported.documentType, "postcard")
        XCTAssertEqual(imported.metaHandwriting, "Likely male, 50s")
        XCTAssertEqual(imported.metaSuspectedWriter, "Eleanor")
    }

    func testOldRecordWithoutNewFieldsDecodesWithNilDefaults() throws {
        // A letter.json written by an older version (no documentType / handwriting / suspectedWriter).
        let oldJSON = """
        {"number":1,"id":"L1","title":"Old","date":{"source":"unknown"},"to":[],
         "meta":{},"transcription":"body","pages":[],
         "createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z"}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(LetterFile.self, from: Data(oldJSON.utf8))
        XCTAssertNil(file.documentType)
        XCTAssertNil(file.meta.handwriting)

        let a = try arch()
        try a.importFromFiles([file])
        let l = try a.letter(id: "L1")!
        XCTAssertNil(l.documentType)               // defaults to nil → the reflowed view, no crash
        XCTAssertEqual(l.transcription, "body")     // existing data preserved
    }
}
