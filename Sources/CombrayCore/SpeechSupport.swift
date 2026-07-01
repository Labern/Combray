import Foundation

/// Pure helpers for the read-aloud feature (no AVFoundation) — kept here so they're unit-testable.
public enum SpeechSupport {

    /// True when the writer's sex guess reads female. **Checks "female" before "male"** — "female"
    /// contains "male" as a substring, so naive matching would misread it; otherwise default to male.
    public static func wantsFemale(_ gender: String?) -> Bool {
        let g = (gender ?? "").lowercased()
        return g.contains("female") || g.contains("woman") || g.contains("girl") || g.contains("lady")
    }

    /// Rough spoken length: word count at `wpm` (words per minute).
    public static func estimateDuration(_ text: String, wpm: Double) -> TimeInterval {
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        return wpm > 0 ? Double(words) / wpm * 60 : 0
    }

    /// The start index (UTF-16) of the word containing/just-before `loc`, so a skip lands on a word.
    public static func wordStart(in text: String, at loc: Int) -> Int {
        let ns = text as NSString
        var i = max(0, min(loc, ns.length))
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 32 || c == 10 || c == 9 { break }   // space / newline / tab
            i -= 1
        }
        return i
    }

    /// `m:ss` clock string (e.g. 1:21).
    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded())); return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Rank a candidate voice so we play the *most natural* one installed instead of the tinny
    /// compact default. Quality dominates (premium > enhanced > default), then a British accent
    /// (the user is in the UK), then a small nudge for the voices that actually sound human.
    /// `qualityTier`: 2 = premium, 1 = enhanced, 0 = default. Pure so it's unit-testable.
    public static func voiceRank(qualityTier: Int, language: String, name: String) -> Int {
        var s = qualityTier * 100
        if language == "en-GB" { s += 30 }
        else if language == "en-IE" || language == "en-AU" { s += 8 }
        let natural: Set<String> = ["daniel", "kate", "serena", "oliver", "stephanie", "jamie",
                                    "ava", "tom", "zoe", "evan", "nathan", "samantha", "allison", "susan"]
        if natural.contains(name.lowercased()) { s += 5 }
        return s
    }
}
