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

    /// Short lines (an address block) keep their own line breaks rather than being merged.
    func testShortLinesKeepTheirBreaks() {
        // An address block: every line is short, so none are joined.
        let input = "12 Rue de la Paix\nParis\nFrance"
        let blocks = TextReflow.paragraphs(input)
        XCTAssertEqual(blocks, ["12 Rue de la Paix\nParis\nFrance"])
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

    /// Trailing whitespace on each line is trimmed.
    func testTrailingWhitespacePerLineIsTrimmed() {
        let input = "Short one   \nShort two   "
        XCTAssertEqual(TextReflow.paragraphs(input), ["Short one\nShort two"])
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
