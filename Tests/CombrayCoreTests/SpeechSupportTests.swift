import XCTest
@testable import CombrayCore

/// The read-aloud helpers: voice-gender parsing (the "female contains male" trap), duration estimate,
/// word-boundary snapping for skip, and the m:ss clock.
final class SpeechSupportTests: XCTestCase {

    /// A female sex guess is detected as female — NOT misread as male because "female" contains "male".
    func testFemaleGuessIsFemaleNotMale() {
        XCTAssertTrue(SpeechSupport.wantsFemale("Likely female, 30s"))
        XCTAssertTrue(SpeechSupport.wantsFemale("a woman's hand"))
        XCTAssertTrue(SpeechSupport.wantsFemale("FEMALE"))
    }

    /// Male / unknown / empty default to the male voice (wantsFemale == false).
    func testMaleAndUnknownDefaultMale() {
        XCTAssertFalse(SpeechSupport.wantsFemale("Likely male, 50s"))
        XCTAssertFalse(SpeechSupport.wantsFemale("masculine hand"))
        XCTAssertFalse(SpeechSupport.wantsFemale(nil))
        XCTAssertFalse(SpeechSupport.wantsFemale(""))
    }

    /// Duration scales with word count at the given rate (165 wpm → ~one minute for 165 words).
    func testDurationEstimate() {
        let oneMinute = String(repeating: "word ", count: 165)
        XCTAssertEqual(SpeechSupport.estimateDuration(oneMinute, wpm: 165), 60, accuracy: 0.5)
        XCTAssertEqual(SpeechSupport.estimateDuration("", wpm: 165), 0)
    }

    /// Skipping snaps back to the start of the current word, not mid-word.
    func testWordStartSnapsToWordBoundary() {
        let s = "the quick brown fox"   // indices: t=0 … "brown" starts at 10
        XCTAssertEqual(SpeechSupport.wordStart(in: s, at: 13), 10)   // inside "brown" → start of "brown"
        XCTAssertEqual(SpeechSupport.wordStart(in: s, at: 10), 10)   // already at a boundary
        XCTAssertEqual(SpeechSupport.wordStart(in: s, at: 0), 0)
    }

    /// The clock renders seconds as m:ss with a zero-padded seconds field.
    func testClockFormat() {
        XCTAssertEqual(SpeechSupport.clock(81), "1:21")
        XCTAssertEqual(SpeechSupport.clock(150), "2:30")
        XCTAssertEqual(SpeechSupport.clock(5), "0:05")
        XCTAssertEqual(SpeechSupport.clock(0), "0:00")
    }

    /// Voice ranking: quality beats accent, and a UK accent beats a US one at equal quality — so we
    /// never play the tinny compact default when a better voice is installed.
    func testVoiceRankPrefersQualityThenUKAccent() {
        let premiumUS = SpeechSupport.voiceRank(qualityTier: 2, language: "en-US", name: "Zoe")
        let enhancedGB = SpeechSupport.voiceRank(qualityTier: 1, language: "en-GB", name: "Daniel")
        let defaultGB = SpeechSupport.voiceRank(qualityTier: 0, language: "en-GB", name: "Kate")
        let defaultUS = SpeechSupport.voiceRank(qualityTier: 0, language: "en-US", name: "Fred")
        XCTAssertGreaterThan(premiumUS, enhancedGB)     // quality dominates accent
        XCTAssertGreaterThan(enhancedGB, defaultGB)     // enhanced beats default
        XCTAssertGreaterThan(defaultGB, defaultUS)      // at equal quality, UK accent wins
    }
}
