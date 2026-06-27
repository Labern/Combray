import XCTest
@testable import CombrayCore

final class CombrayCoreTests: XCTestCase {
    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(Combray.schemaVersion, 0)
    }

    func testGRDBLinksAndSQLiteOpens() throws {
        let version = try Combray.sqliteVersion()
        // Expect something like "3.x.y"
        XCTAssertTrue(version.hasPrefix("3."), "Unexpected SQLite version: \(version)")
    }
}
