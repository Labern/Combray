import XCTest
@testable import CombrayCore

/// Canonical person resolution: normalization, relation folding ("Mother" → "Mum"), endearment
/// detection ("darling sweetness"), deterministic merges, and the persistent alias store.
final class PeopleResolverTests: XCTestCase {

    // MARK: normalize

    func testNormalizeFoldsCaseDiacriticsPunctuationAndParens() {
        XCTAssertEqual(PeopleResolver.normalize("  Eleanor  Whitfield "), "eleanor whitfield")
        XCTAssertEqual(PeopleResolver.normalize("Éléanor"), "eleanor")
        XCTAssertEqual(PeopleResolver.normalize("Eleanor (the elder)"), "eleanor")
        XCTAssertEqual(PeopleResolver.normalize("O'Brien, J."), "o brien j")
    }

    // MARK: relation folding — the user searches by the relation

    func testRelationVariantsFoldToCanonicalRelation() {
        XCTAssertEqual(PeopleResolver.relationCanonical("Mother"), "Mum")
        XCTAssertEqual(PeopleResolver.relationCanonical("mummy"), "Mum")
        XCTAssertEqual(PeopleResolver.relationCanonical("my dearest mother"), "Mum")
        XCTAssertEqual(PeopleResolver.relationCanonical("Father"), "Dad")
        XCTAssertEqual(PeopleResolver.relationCanonical("Granny"), "Grandma")
        XCTAssertEqual(PeopleResolver.relationCanonical("Auntie Vera"), "Aunt Vera")
        XCTAssertNil(PeopleResolver.relationCanonical("Mum"))          // already canonical
        XCTAssertNil(PeopleResolver.relationCanonical("Margaret"))     // not a relation
        XCTAssertNil(PeopleResolver.relationCanonical("Mother Superior Agnes"))  // not a bare relation
    }

    // MARK: endearments are never identities

    func testEndearmentsAreDetected() {
        XCTAssertTrue(PeopleResolver.isEndearment("sweetness"))
        XCTAssertTrue(PeopleResolver.isEndearment("darling sweetness"))
        XCTAssertTrue(PeopleResolver.isEndearment("My Love"))
        XCTAssertFalse(PeopleResolver.isEndearment("darling Margaret"))
        XCTAssertFalse(PeopleResolver.isEndearment("Mum"))
        XCTAssertFalse(PeopleResolver.isEndearment(""))
    }

    // MARK: deterministic merges

    func testCaseAndPunctuationVariantsMerge() {
        let m = PeopleResolver.deterministicMerges(names: ["eleanor whitfield", "Eleanor Whitfield"])
        XCTAssertEqual(m["eleanor whitfield"], "Eleanor Whitfield")
        XCTAssertNil(m["Eleanor Whitfield"])
    }

    func testRelationVariantsMergeToOnePerson() {
        let m = PeopleResolver.deterministicMerges(names: ["Mother", "Mum", "Mummy"])
        XCTAssertEqual(m["Mother"], "Mum")
        XCTAssertEqual(m["Mummy"], "Mum")
        XCTAssertNil(m["Mum"])
    }

    func testUnambiguousFirstNameFoldsIntoFullName() {
        let m = PeopleResolver.deterministicMerges(names: ["Eleanor", "Eleanor Whitfield", "Margaret"])
        XCTAssertEqual(m["Eleanor"], "Eleanor Whitfield")
        XCTAssertNil(m["Margaret"])
    }

    func testAmbiguousFirstNameIsLeftAlone() {
        let m = PeopleResolver.deterministicMerges(names: ["Anne", "Anne Boleyn", "Anne Whitfield"])
        XCTAssertNil(m["Anne"])          // two candidates — do not guess
    }

    func testOwnerNamesAreNotTouched() {
        let m = PeopleResolver.deterministicMerges(names: ["Labern", "labern", "me"], ownerName: "Labern")
        XCTAssertTrue(m.isEmpty)         // the archive's owner pass handles these
    }

    func testChainsResolveToTerminalCanonical() {
        // "Eleanor" folds into the fuller name even when that name is itself being re-cased.
        let m = PeopleResolver.deterministicMerges(names: ["Eleanor", "eleanor whitfield", "Eleanor Whitfield"])
        XCTAssertEqual(m["Eleanor"], "Eleanor Whitfield")
        XCTAssertEqual(m["eleanor whitfield"], "Eleanor Whitfield")
    }

    // MARK: alias store

    func testAliasStoreResolvesAndChasesChains() {
        var store = PeopleAliases()
        store.set(alias: "sweetness", canonical: "Mum")
        store.set(alias: "darling sweetness", canonical: "sweetness")   // chain → terminal
        XCTAssertEqual(store.canonical(for: "Sweetness"), "Mum")
        XCTAssertEqual(store.canonical(for: "darling  sweetness"), "Mum")
        XCTAssertNil(store.canonical(for: "Margaret"))
    }

    func testAliasStoreRefusesSelfReference() {
        var store = PeopleAliases()
        store.set(alias: "Mum", canonical: "mum")
        XCTAssertNil(store.canonical(for: "Mum"))
    }

    func testAliasStoreRoundTripsToDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = PeopleAliases()
        store.set(alias: "Mother", canonical: "Mum")
        store.save(toArchiveRoot: dir)
        let loaded = PeopleAliases.load(fromArchiveRoot: dir)
        XCTAssertEqual(loaded.canonical(for: "mother"), "Mum")
    }
}
