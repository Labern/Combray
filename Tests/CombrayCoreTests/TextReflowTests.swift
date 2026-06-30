import XCTest
@testable import CombrayCore

/// The transcription reflow + layout-significance gate: turning page-wrapped text into flowing
/// paragraphs, and deciding when to keep exact whitespace (screenshots/code) instead.
final class TextReflowTests: XCTestCase {

    // MARK: paragraphs(_:)

    /// Lines wrapped only by the page width are joined back into one flowing paragraph.
    func testSoftWrappedLongLinesAreJoined() {
        let input = "The quick brown fox jumps over the lazy dog again and\n"
                  + "again across the meadow toward the river at dawn."
        let blocks = TextReflow.paragraphs(input)
        XCTAssertEqual(blocks.count, 1)                          // one flowing paragraph
        XCTAssertFalse(blocks[0].contains("\n"))                 // the hard wrap is gone
        XCTAssertTrue(blocks[0].contains("again and again"))     // joined with a single space
    }

    /// A blank line is a paragraph boundary, yielding separate blocks.
    func testBlankLinesSeparateParagraphs() {
        let input = "First paragraph, long enough to be treated as real prose here.\n\n"
                  + "Second paragraph, also long enough to count as flowing prose."
        let blocks = TextReflow.paragraphs(input)
        XCTAssertEqual(blocks.count, 2)
    }

    /// Every line inside a block is joined — even short ones — so prose never keeps "poetic" breaks.
    func testEveryLineInABlockIsJoined() {
        // Short lines are joined too (no clever address/verse preservation): one flowing block.
        let input = "12 Rue de la Paix\nParis\nFrance"
        XCTAssertEqual(TextReflow.paragraphs(input), ["12 Rue de la Paix Paris France"])
    }

    /// REGRESSION: a real letter whose every physical line was kept as a break must flow into ONE
    /// paragraph with no internal newlines — the "strange poetic formatting" bug.
    func testHardWrappedLetterFlowsIntoOneParagraph() {
        let input = """
        4 Monday. well I had a house full yesterday as the
        baby Lawrence was not his bright self, very quiet & cross
        says. Wendy was not up to
        the mark with throat getting worse
        Gavin home
        """
        let blocks = TextReflow.paragraphs(input)
        XCTAssertEqual(blocks.count, 1)                          // no blank lines → one block
        XCTAssertFalse(blocks[0].contains("\n"))                 // NO mid-paragraph breaks
        XCTAssertTrue(blocks[0].contains("not up to the mark"))  // short lines joined through
    }

    /// Paragraphs come from blank lines, even when the lines within are short.
    func testParagraphsComeFromBlankLinesNotLineLength() {
        let input = "Dear Anne\nhow are you?\n\nYours\nMarcel"
        XCTAssertEqual(TextReflow.paragraphs(input), ["Dear Anne how are you?", "Yours Marcel"])
    }

    /// Several consecutive blank lines collapse to a single paragraph break.
    func testCollapsesRunsOfBlankLines() {
        let input = "Para one is quite long and clearly a real sentence of prose.\n\n\n\n"
                  + "Para two is also quite long and clearly a real sentence too."
        XCTAssertEqual(TextReflow.paragraphs(input).count, 2)
    }

    /// Empty or whitespace-only input produces no paragraphs.
    func testEmptyAndWhitespaceProduceNoParagraphs() {
        XCTAssertEqual(TextReflow.paragraphs(""), [])
        XCTAssertEqual(TextReflow.paragraphs("   \n  \n"), [])
    }

    /// Trailing whitespace on each line is trimmed, and the lines join into one paragraph.
    func testTrailingWhitespacePerLineIsTrimmed() {
        let input = "Short one   \nShort two   "
        XCTAssertEqual(TextReflow.paragraphs(input), ["Short one Short two"])
    }

    // MARK: isLayoutSignificant(_:)

    /// Screenshot/code document types are flagged layout-significant (shown verbatim/monospaced).
    func testScreenshotsAndCodeArePreservedVerbatim() {
        XCTAssertTrue(TextReflow.isLayoutSignificant("screenshot"))
        XCTAssertTrue(TextReflow.isLayoutSignificant("Screenshot of a Claude Code coding session"))
        XCTAssertTrue(TextReflow.isLayoutSignificant("code"))
        XCTAssertTrue(TextReflow.isLayoutSignificant("terminal"))
    }

    /// Letters and written documents are NOT layout-significant (they get the reflowed view); nil defaults to reflow.
    func testLettersAndWrittenDocumentsAreReflowed() {
        XCTAssertFalse(TextReflow.isLayoutSignificant("letter"))
        XCTAssertFalse(TextReflow.isLayoutSignificant("postcard"))
        XCTAssertFalse(TextReflow.isLayoutSignificant("note"))
        XCTAssertFalse(TextReflow.isLayoutSignificant(nil))      // unknown → neat letter view (the default)
    }
}
