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
    /// compact default. Quality dominates (premium > enhanced > default), then avoid super-compact
    /// (the most robotic tier), then a British accent (the user is in the UK), then a small nudge for
    /// the voices that actually sound human. `qualityTier`: 2 = premium, 1 = enhanced, 0 = default.
    /// Pure so it's unit-testable.
    public static func voiceRank(qualityTier: Int, language: String, name: String,
                                 superCompact: Bool = false) -> Int {
        var s = qualityTier * 100
        if superCompact { s -= 15 }                 // the most robotic tier — pick a plain compact over it
        if language == "en-GB" { s += 30 }
        else if language == "en-IE" || language == "en-AU" { s += 8 }
        let natural: Set<String> = ["daniel", "kate", "serena", "oliver", "stephanie", "jamie",
                                    "ava", "tom", "zoe", "evan", "nathan", "samantha", "allison", "susan"]
        if natural.contains(name.lowercased()) { s += 5 }
        return s
    }

    /// True when the best voice we could pick is still only *default* quality (compact / super-compact)
    /// — i.e. there is no natural (enhanced/premium) voice installed, so it will sound robotic until
    /// the user downloads one. Drives the in-app "install a natural voice" hint.
    public static func voiceIsRobotic(qualityTier: Int) -> Bool { qualityTier <= 0 }

    /// Splits `text` into chunk ranges for streamed neural rendering: a SMALL first chunk (so
    /// playback starts within a few seconds) then larger ones (efficient), breaking on sentence
    /// boundaries, hard-splitting on a word boundary only when a single sentence exceeds the cap.
    /// The ranges tile the whole string in order (every character belongs to exactly one chunk).
    public static func chunkRanges(text: String, firstMax: Int = 140, restMax: Int = 480) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        // Sentence pieces (including trailing whitespace); cover any gaps so the tiles are complete.
        var pieces: [NSRange] = []
        var covered = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            if range.location > covered {
                pieces.append(NSRange(location: covered, length: range.location - covered))
            }
            pieces.append(range)
            covered = range.location + range.length
        }
        if covered < ns.length { pieces.append(NSRange(location: covered, length: ns.length - covered)) }

        // Hard-split any piece longer than the cap on word boundaries.
        func split(_ r: NSRange, max: Int) -> [NSRange] {
            guard r.length > max else { return [r] }
            var out: [NSRange] = []
            var start = r.location
            let end = r.location + r.length
            while end - start > max {
                var cut = start + max
                while cut > start, ns.character(at: cut - 1) != 32 { cut -= 1 }   // back to a space
                if cut == start { cut = start + max }                              // no space — hard cut
                out.append(NSRange(location: start, length: cut - start))
                start = cut
            }
            out.append(NSRange(location: start, length: end - start))
            return out
        }

        // Greedy packing: first chunk small, the rest larger.
        var chunks: [NSRange] = []
        var current: NSRange? = nil
        func capNow() -> Int { chunks.isEmpty ? firstMax : restMax }
        for piece in pieces {
            for part in split(piece, max: restMax) {
                if let c = current {
                    if c.length + part.length <= capNow() {
                        current = NSRange(location: c.location, length: c.length + part.length)
                    } else {
                        chunks.append(c)
                        current = part
                    }
                } else if part.length >= capNow() {
                    chunks.append(part)
                } else {
                    current = part
                }
            }
        }
        if let c = current { chunks.append(c) }
        return chunks
    }

    /// Word-highlight timings for audio rendered WITHOUT per-word callbacks (the neural voice):
    /// each word's start time is estimated proportionally to its character position — close enough
    /// for a reading highlight, and it never drifts past the end.
    public static func proportionalWordTimes(text: String, duration: TimeInterval)
        -> [(time: TimeInterval, range: NSRange)] {
        let ns = text as NSString
        guard ns.length > 0, duration > 0 else { return [] }
        var out: [(TimeInterval, NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            out.append((duration * Double(range.location) / Double(ns.length), range))
        }
        return out
    }
}
