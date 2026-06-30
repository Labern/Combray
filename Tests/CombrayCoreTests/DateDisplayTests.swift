import XCTest
@testable import CombrayCore

/// Pretty English date formatting from the partial ISO forms (`1963`, `1963-11`, `1963-11-01`).
final class DateDisplayTests: XCTestCase {
    /// A full date renders as "1st November, 1963" (day with ordinal, month name, year).
    func testFullDateInEnglishWithOrdinal() {
        XCTAssertEqual(DateDisplay.pretty("1963-11-01"), "1st November, 1963")
    }
    /// A year+month renders as "November 1963".
    func testMonthAndYear() {
        XCTAssertEqual(DateDisplay.pretty("1963-11"), "November 1963")
    }
    /// A bare year renders as the year.
    func testYearOnly() {
        XCTAssertEqual(DateDisplay.pretty("1963"), "1963")
    }
    /// Ordinal suffixes are correct, including the 11th–13th "th" exceptions and 21st/31st.
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
    /// All twelve month names are spelled correctly.
    func testEveryMonthNameSpelledCorrectly() {
        let expected = ["January","February","March","April","May","June",
                        "July","August","September","October","November","December"]
        for (i, name) in expected.enumerated() {
            let mm = String(format: "%02d", i + 1)
            XCTAssertEqual(DateDisplay.pretty("1963-\(mm)"), "\(name) 1963")
        }
    }
    /// nil and whitespace-only input render as nil (nothing to show).
    func testNilAndEmptyAreNil() {
        XCTAssertNil(DateDisplay.pretty(nil))
        XCTAssertNil(DateDisplay.pretty("   "))
    }
    /// A non-ISO string (e.g. "spring 1963") is passed through unchanged.
    func testNonIsoReturnedUnchanged() {
        XCTAssertEqual(DateDisplay.pretty("spring 1963"), "spring 1963")
    }

    // MARK: numericUK (DD/MM/YYYY for the reading view)

    /// A full date renders UK-numeric as DD/MM/YYYY with zero-padding.
    func testNumericUKFullDate() {
        XCTAssertEqual(DateDisplay.numericUK("1963-11-01"), "01/11/1963")
        XCTAssertEqual(DateDisplay.numericUK("2000-12-31"), "31/12/2000")
    }
    /// Year+month renders as MM/YYYY; year-only as the year.
    func testNumericUKPartialDates() {
        XCTAssertEqual(DateDisplay.numericUK("1963-11"), "11/1963")
        XCTAssertEqual(DateDisplay.numericUK("1963"), "1963")
    }
    /// nil/empty → nil; non-ISO passed through unchanged.
    func testNumericUKNilAndNonIso() {
        XCTAssertNil(DateDisplay.numericUK(nil))
        XCTAssertNil(DateDisplay.numericUK("  "))
        XCTAssertEqual(DateDisplay.numericUK("spring 1963"), "spring 1963")
    }
}
