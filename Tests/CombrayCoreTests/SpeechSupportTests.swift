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

    /// A plain compact voice is preferred over a super-compact one of the same accent (less robotic).
    func testVoiceRankAvoidsSuperCompact() {
        let compactGB = SpeechSupport.voiceRank(qualityTier: 0, language: "en-GB", name: "Daniel", superCompact: false)
        let superGB = SpeechSupport.voiceRank(qualityTier: 0, language: "en-GB", name: "Daniel", superCompact: true)
        XCTAssertGreaterThan(compactGB, superGB)
    }

    /// Only default-quality voices installed → flagged robotic (drives the "install a natural voice" hint).
    func testVoiceIsRoboticOnlyForDefaultQuality() {
        XCTAssertTrue(SpeechSupport.voiceIsRobotic(qualityTier: 0))
        XCTAssertFalse(SpeechSupport.voiceIsRobotic(qualityTier: 1))   // enhanced
        XCTAssertFalse(SpeechSupport.voiceIsRobotic(qualityTier: 2))   // premium
    }

    /// Chunk ranges tile the whole string in order — every character in exactly one chunk.
    func testChunkRangesTileTheString() {
        let text = String(repeating: "One sentence here. Another follows on! A third, question? ", count: 20)
        let ranges = SpeechSupport.chunkRanges(text: text)
        XCTAssertGreaterThan(ranges.count, 1)
        var pos = 0
        for r in ranges {
            XCTAssertEqual(r.location, pos, "chunks must be contiguous")
            pos += r.length
        }
        XCTAssertEqual(pos, (text as NSString).length, "chunks must cover the full text")
    }

    /// The first chunk is small (fast start); later chunks may be bigger (efficient).
    func testFirstChunkIsSmall() {
        let text = String(repeating: "A short sentence goes right here. ", count: 40)
        let ranges = SpeechSupport.chunkRanges(text: text, firstMax: 140, restMax: 480)
        XCTAssertLessThanOrEqual(ranges[0].length, 170)      // ~firstMax, sentence-rounded
        XCTAssertTrue(ranges.dropFirst().contains { $0.length > 170 })
    }

    /// A single monster sentence is hard-split on word boundaries rather than left whole.
    func testLongSentenceIsHardSplit() {
        let text = String(repeating: "word ", count: 300)     // 1500 chars, no sentence breaks
        let ranges = SpeechSupport.chunkRanges(text: text, firstMax: 140, restMax: 480)
        XCTAssertGreaterThan(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { $0.length <= 481 })
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.length }, (text as NSString).length)
    }

    /// Proportional word times start at zero, are monotonic, and stay within the duration.
    func testProportionalWordTimes() {
        let times = SpeechSupport.proportionalWordTimes(text: "the quick brown fox jumps", duration: 10)
        XCTAssertEqual(times.count, 5)
        XCTAssertEqual(times.first?.time ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0.time <= $1.time })
        XCTAssertLessThan(times.last!.time, 10)
    }
}
