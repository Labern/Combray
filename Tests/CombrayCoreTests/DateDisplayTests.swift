import XCTest
@testable import CombrayCore

final class DateDisplayTests: XCTestCase {
    func testFullDateInEnglishWithOrdinal() {
        XCTAssertEqual(DateDisplay.pretty("1963-11-01"), "1st November, 1963")
    }
    func testMonthAndYear() {
        XCTAssertEqual(DateDisplay.pretty("1963-11"), "November 1963")
    }
    func testYearOnly() {
        XCTAssertEqual(DateDisplay.pretty("1963"), "1963")
    }
    func testOrdinalSuffixes() {
        XCTAssertEqual(DateDisplay.pretty("2000-01-02"), "2nd January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-01-03"), "3rd January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-01-04"), "4th January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-01-11"), "11th January, 2000")  // teens are "th"
        XCTAssertEqual(DateDisplay.pretty("2000-01-12"), "12th January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-01-13"), "13th January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-01-21"), "21st January, 2000")
        XCTAssertEqual(DateDisplay.pretty("2000-12-31"), "31st December, 2000")
    }
    func testEveryMonthNameSpelledCorrectly() {
        let expected = ["January","February","March","April","May","June",
                        "July","August","September","October","November","December"]
        for (i, name) in expected.enumerated() {
            let mm = String(format: "%02d", i + 1)
            XCTAssertEqual(DateDisplay.pretty("1963-\(mm)"), "\(name) 1963")
        }
    }
    func testNilAndEmptyAreNil() {
        XCTAssertNil(DateDisplay.pretty(nil))
        XCTAssertNil(DateDisplay.pretty("   "))
    }
    func testNonIsoReturnedUnchanged() {
        XCTAssertEqual(DateDisplay.pretty("spring 1963"), "spring 1963")
    }
}
