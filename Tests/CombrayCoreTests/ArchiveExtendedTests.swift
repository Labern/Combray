import XCTest
import Foundation
@testable import CombrayCore

// Additional exhaustive coverage (Stage D) — driven by docs/test-plan-stageD.txt.
// Self-contained helpers so this file doesn't depend on the originals' file-private ones.

private func arch() throws -> Archive { Archive(try AppDatabase.makeInMemory()) }
private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: - People de-duplication (the new mergeDuplicatePeople)

final class MergePeopleTests: XCTestCase {
    func testFoldsParentheticalDuplicateIntoSimplest() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "labern")
        _ = try a.findOrCreatePerson(named: "labern (user)")
        try a.mergeDuplicatePeople()
        let names = try a.people().map(\.displayName)
        XCTAssertEqual(names, ["labern"])           // one entity, the simplest name
    }

    func testCaseOnlyDuplicatesFold() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "Eleanor")
        _ = try a.findOrCreatePerson(named: "eleanor")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().count, 1)
    }

    func testReassignsLetterParticipantsToCanonical() throws {
        let a = try arch()
        let l1 = try a.save(Letter(number: 1))
        try a.setParticipants(letterId: l1.id, sender: "labern (user)", recipients: [])
        let l2 = try a.save(Letter(number: 2))
        try a.setParticipants(letterId: l2.id, sender: "labern", recipients: [])
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().count, 1)
        // Both letters now point at the single canonical "labern".
        XCTAssertEqual(try a.participants(forLetterId: l1.id).sender?.displayName, "labern")
        XCTAssertEqual(try a.participants(forLetterId: l2.id).sender?.displayName, "labern")
    }

    func testNoOpWhenNoDuplicates() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "Alice")
        _ = try a.findOrCreatePerson(named: "Bob")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(Set(try a.people().map(\.displayName)), ["Alice", "Bob"])
    }

    func testIsIdempotent() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "labern")
        _ = try a.findOrCreatePerson(named: "labern (user)")
        try a.mergeDuplicatePeople()
        try a.mergeDuplicatePeople()                // second pass changes nothing
        XCTAssertEqual(try a.people().count, 1)
    }

    func testDistinctPeopleAreNotMerged() throws {
        let a = try arch()
        _ = try a.findOrCreatePerson(named: "labern")
        _ = try a.findOrCreatePerson(named: "Eleanor Brun")
        try a.mergeDuplicatePeople()
        XCTAssertEqual(try a.people().count, 2)
    }
}

// MARK: - Archive ordering / boundary gaps

final class ArchiveOrderingTests: XCTestCase {
    func testNextLetterNumberUsesMaxNotCount() throws {
        let a = try arch()
        _ = try a.save(Letter(number: 5))           // a single letter numbered 5
        XCTAssertEqual(try a.nextLetterNumber(), 6)  // MAX+1, not COUNT+1 (=2)
    }

    func testAllLettersNilYearSortsLast() throws {
        let a = try arch()
        let withYear = try a.save(Letter(number: 1, dateYear: 1990))
        let noYear = try a.save(Letter(number: 2, dateYear: nil))
        let ids = try a.allLetters().map(\.id)
        XCTAssertEqual(ids.first, withYear.id)
        XCTAssertEqual(ids.last, noYear.id)          // NULLS LAST
    }

    func testYearsAreDistinctAndDescending() throws {
        let a = try arch()
        _ = try a.save(Letter(number: 1, dateYear: 1962))
        _ = try a.save(Letter(number: 2, dateYear: 1962))
        _ = try a.save(Letter(number: 3, dateYear: 1970))
        _ = try a.save(Letter(number: 4, dateYear: nil))
        XCTAssertEqual(try a.years(), [1970, 1962])  // deduped, DESC, nil excluded — no .sorted()
    }

    func testPagesReturnedInPageIndexOrder() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1))
        try a.setPages([
            Page(letterId: l.id, pageIndex: 2, imagePath: "Letters/1/c.jpg"),
            Page(letterId: l.id, pageIndex: 0, imagePath: "Letters/1/a.jpg"),
            Page(letterId: l.id, pageIndex: 1, imagePath: "Letters/1/b.jpg"),
        ], forLetterId: l.id)
        XCTAssertEqual(try a.pages(forLetterId: l.id).map(\.pageIndex), [0, 1, 2])
    }

    func testSetPagesReplacesPreviousSet() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1))
        try a.setPages([Page(letterId: l.id, pageIndex: 0, imagePath: "x"),
                        Page(letterId: l.id, pageIndex: 1, imagePath: "y")], forLetterId: l.id)
        try a.setPages([Page(letterId: l.id, pageIndex: 0, imagePath: "z")], forLetterId: l.id)
        XCTAssertEqual(try a.pages(forLetterId: l.id).count, 1)
    }
}

// MARK: - Cascade + lifecycle gaps

final class ArchiveLifecycleTests: XCTestCase {
    func testDeleteLetterCascadesEverything() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1, transcription: "the quick brown fox"))
        try a.setPages([Page(letterId: l.id, pageIndex: 0, imagePath: "p")], forLetterId: l.id)
        try a.setParticipants(letterId: l.id, sender: "Alice", recipients: ["Bob"])
        XCTAssertEqual(try a.search("fox").count, 1)

        try a.deleteLetter(id: l.id)

        XCTAssertNil(try a.letter(id: l.id))
        XCTAssertTrue(try a.pages(forLetterId: l.id).isEmpty)
        XCTAssertNil(try a.participants(forLetterId: l.id).sender)
        XCTAssertTrue(try a.search("fox").isEmpty)   // explicit FTS row deletion (not SQL-cascaded)
    }

    func testDeleteUnknownLetterIsNoOp() throws {
        let a = try arch()
        _ = try a.save(Letter(number: 1))
        XCTAssertNoThrow(try a.deleteLetter(id: "nope"))
        XCTAssertEqual(try a.allLetters().count, 1)
    }

    func testFindOrCreatePersonTrimsAndDeduplicates() throws {
        let a = try arch()
        let first = try a.findOrCreatePerson(named: "  Eleanor\n")
        XCTAssertEqual(first.displayName, "Eleanor")
        let again = try a.findOrCreatePerson(named: " Eleanor ")
        XCTAssertEqual(again.id, first.id)           // same entity, not a duplicate
        XCTAssertEqual(try a.people().count, 1)
    }

    func testSetParticipantsReplacesPrevious() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1))
        try a.setParticipants(letterId: l.id, sender: "Alice", recipients: ["Bob"])
        try a.setParticipants(letterId: l.id, sender: "Carol", recipients: [])
        let p = try a.participants(forLetterId: l.id)
        XCTAssertEqual(p.sender?.displayName, "Carol")
        XCTAssertTrue(p.recipients.isEmpty)
    }

    func testSearchReindexesWhenParticipantsChange() throws {
        let a = try arch()
        let l = try a.save(Letter(number: 1, transcription: "body"))
        try a.setParticipants(letterId: l.id, sender: "Alpha", recipients: [])
        XCTAssertEqual(try a.search("Alpha").first?.letterId, l.id)
        try a.setParticipants(letterId: l.id, sender: "Beta", recipients: [])
        XCTAssertTrue(try a.search("Alpha").isEmpty)   // old name no longer indexed
        XCTAssertEqual(try a.search("Beta").first?.letterId, l.id)
    }
}
