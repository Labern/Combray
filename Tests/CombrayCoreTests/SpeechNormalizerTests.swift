import XCTest
@testable import CombrayCore

/// The speakable rendition: dates as dates, times as times (the English way), old money as old
/// money — with the range map that keeps the on-screen highlight aligned.
final class SpeechNormalizerTests: XCTestCase {

    private func spoken(_ s: String) -> String { SpeechNormalizer.spokenText(for: s).text }

    // MARK: dates

    func testNumericDateReadsAsUKDate() {
        XCTAssertEqual(spoken("We arrive 6-8-66 by sea."),
                       "We arrive the sixth of August, nineteen sixty-six by sea.")
        XCTAssertEqual(spoken("on 21/12/1959"), "on the twenty-first of December, nineteen fifty-nine")
        XCTAssertEqual(spoken("dated 3.4.05"), "dated the third of April, nineteen oh five")
    }

    func testWrittenDateGetsVoicedYear() {
        XCTAssertEqual(spoken("on 6th August, 1966"),
                       "on the sixth of August, nineteen sixty-six")
        XCTAssertEqual(spoken("by Aug 6 1966"), "by the sixth of August, nineteen sixty-six")
    }

    func testStandaloneYearIsSpoken() {
        XCTAssertEqual(spoken("back in 1959 it rained"), "back in nineteen fifty-nine it rained")
        XCTAssertEqual(spoken("the year 1900"), "the year nineteen hundred")
    }

    // MARK: times — the English way

    func testTimesReadTheEnglishWay() {
        XCTAssertEqual(spoken("at 3.30"), "at half past three")
        XCTAssertEqual(spoken("at 3:15 pm"), "at a quarter past three in the afternoon")
        XCTAssertEqual(spoken("at 7.45 pm"), "at a quarter to eight in the evening")
        XCTAssertEqual(spoken("the 9.05 am train"), "the five past nine in the morning train")
        XCTAssertEqual(spoken("by 6.00"), "by six o'clock")
        XCTAssertEqual(spoken("at 4.50"), "at ten to five")
    }

    // MARK: old money

    func testFullPoundsShillingsPence() {
        XCTAssertEqual(spoken("cost £3 4s. 6d."),
                       "cost three pounds, four shillings and sixpence")
        XCTAssertEqual(spoken("cost £3-4-6"), "cost three pounds, four shillings and sixpence")
    }

    func testShillingsAndPenceForms() {
        XCTAssertEqual(spoken("it was 2/6d each"), "it was two and six each")
        XCTAssertEqual(spoken("only 10/- the pair"), "only ten shillings the pair")
        XCTAssertEqual(spoken("about 4s 6d"), "about four shillings and sixpence")
        XCTAssertEqual(spoken("a 2d stamp"), "a tuppence stamp")
        XCTAssertEqual(spoken("30 gns at auction"), "thirty guineas at auction")
    }

    // MARK: misc

    func testAmpersandAndNumero() {
        XCTAssertEqual(spoken("Smith & Sons at No. 12"), "Smith and Sons at number 12")
    }

    // MARK: the range map — highlight stays honest

    func testHighlightMapsExpansionBackToOriginalToken() {
        let text = "We sail 6-8-66 for Colombo."
        let st = SpeechNormalizer.spokenText(for: text)
        // find "August" inside the spoken text — it should map back to the whole "6-8-66"
        let augustAt = (st.text as NSString).range(of: "August")
        let original = st.originalRange(forSpokenRange: augustAt)
        XCTAssertEqual(original, (text as NSString).range(of: "6-8-66"))
        // untouched words map straight through
        let sailSpoken = (st.text as NSString).range(of: "sail")
        XCTAssertEqual(st.originalRange(forSpokenRange: sailSpoken), (text as NSString).range(of: "sail"))
    }

    func testExtraSubstitutionsMergeWithoutOverlap() {
        let text = "The fare was 3/6 that day."
        let st = SpeechNormalizer.spokenText(for: text, extra: [("3/6", "three and six")])
        XCTAssertEqual(st.text, "The fare was three and six that day.")
        let spokenSix = (st.text as NSString).range(of: "three and six")
        XCTAssertEqual(st.originalRange(forSpokenRange: spokenSix), (text as NSString).range(of: "3/6"))
    }

    // MARK: number spelling

    func testNumberAndYearSpelling() {
        XCTAssertEqual(SpeechNormalizer.spell(345), "three hundred and forty-five")
        XCTAssertEqual(SpeechNormalizer.spellYear(1966), "nineteen sixty-six")
        XCTAssertEqual(SpeechNormalizer.spellYear(2005), "two thousand and five")
        XCTAssertEqual(SpeechNormalizer.ordinal(21), "twenty-first")
        XCTAssertEqual(SpeechNormalizer.ordinal(12), "twelfth")
        XCTAssertEqual(SpeechNormalizer.ordinal(30), "thirtieth")
    }
}
