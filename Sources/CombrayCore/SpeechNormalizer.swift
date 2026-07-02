import Foundation

/// Turns a transcription into a *speakable* rendition, the way an English person would say it:
/// dates as dates ("6-8-66" → "the sixth of August, nineteen sixty-six"), times as times
/// ("3.30pm" → "half past three in the afternoon"), and old money as old money
/// ("£3 4s 6d" → "three pounds, four shillings and sixpence"; "2/6d" → "two and six").
///
/// Every rewrite is a range-tracked substitution — never a blind text edit — so the on-screen
/// word highlight and tap-to-seek stay aligned: "6-8-66" glows while the whole date is spoken.
/// Deterministic rules handle the unambiguous cases; a per-letter Claude pass (cached in
/// letter.json) supplies context judgements like whether "3/6" is money or the 3rd of June,
/// merged in via `extra`.
public enum SpeechNormalizer {

    public struct Substitution: Equatable, Sendable {
        public let range: NSRange          // in the original text
        public let spoken: String
        public init(range: NSRange, spoken: String) { self.range = range; self.spoken = spoken }
    }

    /// The speakable text plus the bidirectional range map back to the original.
    public struct SpokenText: Sendable {
        public let original: String
        public let text: String
        /// Ordered, covering segments: (range in spoken text, range in original, wasSubstituted).
        let segments: [(spoken: NSRange, original: NSRange, isSub: Bool)]

        /// The original-text range to highlight while `spokenRange` is being spoken.
        /// Inside a substitution, that's the WHOLE original token (the date glows while the
        /// expansion is read); in untouched text it's the same words, offset-translated.
        public func originalRange(forSpokenRange r: NSRange) -> NSRange? {
            guard let seg = segments.last(where: { $0.spoken.location <= r.location }) else { return nil }
            if seg.isSub { return seg.original }
            let offset = r.location - seg.spoken.location
            let start = seg.original.location + offset
            let maxLen = max(0, seg.original.location + seg.original.length - start)
            return NSRange(location: start, length: min(r.length, maxLen))
        }
    }

    // MARK: - Public entry points

    /// Deterministic substitutions for `text` (dates, times, £sd money, misc) — unambiguous only.
    public static func substitutions(for text: String) -> [Substitution] {
        let ns = text as NSString
        var claimed: [NSRange] = []
        var subs: [Substitution] = []

        func claim(_ range: NSRange, _ spoken: String) {
            guard !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            claimed.append(range)
            subs.append(Substitution(range: range, spoken: spoken))
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: [.caseInsensitive]) else { return [] }
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        }
        func int(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }

        // 1 · Full £sd — "£3 4s. 6d." / "£3-4-6" / "£3/4/6"
        for m in matches(#"£\s*(\d{1,4})[\s\-/]+(\d{1,2})(?:s\.?)?[\s\-/]+(\d{1,2})(?:d\.?)?"#) {
            guard let p = int(m, 1), let s = int(m, 2), let d = int(m, 3), s <= 19, d <= 11 else { continue }
            claim(m.range, "\(pounds(p)), \(shillings(s)) and \(penceWord(d))")
        }
        // 1b · "£3 4s." (no pence)
        for m in matches(#"£\s*(\d{1,4})\s+(\d{1,2})s\.?\b"#) {
            guard let p = int(m, 1), let s = int(m, 2), s <= 19 else { continue }
            claim(m.range, "\(pounds(p)) \(shillings(s))")
        }
        // 2 · "4s 6d" → four shillings and sixpence
        for m in matches(#"\b(\d{1,2})s\.?\s+(\d{1,2})d\.?\b"#) {
            guard let s = int(m, 1), let d = int(m, 2), s <= 19, d <= 11 else { continue }
            claim(m.range, "\(shillings(s)) and \(penceWord(d))")
        }
        // 3 · "2/6d" → two and six · "10/-" → ten shillings
        for m in matches(#"\b(\d{1,2})/(\d{1,2})d\b"#) {
            guard let s = int(m, 1), let d = int(m, 2), s <= 19, d <= 11 else { continue }
            claim(m.range, "\(spell(s)) and \(spell(d))")
        }
        for m in matches(#"\b(\d{1,2})/-"#) {
            guard let s = int(m, 1), s <= 19 else { continue }
            claim(m.range, shillings(s))
        }
        // 4 · guineas
        for m in matches(#"\b(\d{1,4})\s*(?:guineas?|gns\.?|gn\.?)\b"#) {
            guard let g = int(m, 1) else { continue }
            claim(m.range, g == 1 ? "one guinea" : "\(spell(g)) guineas")
        }
        // 4b · lone pence — "a 2d stamp" → "a tuppence stamp"
        for m in matches(#"\b(\d{1,2})d\.?\b"#) {
            guard let d = int(m, 1), d <= 11 else { continue }
            claim(m.range, penceWord(d))
        }
        // 5 · numeric dates — "6-8-66", "6/8/1966", "6.8.66" (UK: day first; 2-digit year → 1900s)
        for m in matches(#"\b(\d{1,2})[-/.](\d{1,2})[-/.]((?:18|19|20)\d{2}|\d{2})\b"#) {
            guard var day = int(m, 1), var month = int(m, 2), var year = int(m, 3) else { continue }
            if month > 12, day <= 12 { swap(&day, &month) }     // forgive transposed forms
            guard (1...31).contains(day), (1...12).contains(month) else { continue }
            if year < 100 { year += 1900 }
            claim(m.range, "the \(ordinal(day)) of \(monthName(month)), \(spellYear(year))")
        }
        // 6 · "6th August(, 1966)" and "August 6th(, 1966)" — voice the year properly
        let monthsAlt = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
        for m in matches(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(\#(monthsAlt))\.?(?:\s*,?\s*((?:18|19|20)\d{2}))?\b"#) {
            guard let day = int(m, 1), (1...31).contains(day),
                  let month = monthIndex(ns.substring(with: m.range(at: 2))) else { continue }
            var spoken = "the \(ordinal(day)) of \(monthName(month))"
            if let y = int(m, 3) { spoken += ", \(spellYear(y))" }
            claim(m.range, spoken)
        }
        for m in matches(#"\b(\#(monthsAlt))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*((?:18|19|20)\d{2}))?\b"#) {
            guard let month = monthIndex(ns.substring(with: m.range(at: 1))),
                  let day = int(m, 2), (1...31).contains(day) else { continue }
            var spoken = "the \(ordinal(day)) of \(monthName(month))"
            if let y = int(m, 3) { spoken += ", \(spellYear(y))" }
            claim(m.range, spoken)
        }
        // 7 · times — "3.30", "3:30 pm" → the English way ("half past three in the afternoon")
        for m in matches(#"\b(\d{1,2})[.:](\d{2})\s*([ap])\.?m\.?\b"#) {
            guard let h = int(m, 1), let mm = int(m, 2), (1...12).contains(h), mm <= 59 else { continue }
            let isPM = ns.substring(with: m.range(at: 3)).lowercased() == "p"
            claim(m.range, timePhrase(hour: h, minute: mm, pm: isPM))
        }
        for m in matches(#"\b(\d{1,2})[.:](\d{2})\b"#) {
            guard let h = int(m, 1), let mm = int(m, 2), (1...12).contains(h), mm <= 59 else { continue }
            claim(m.range, timePhrase(hour: h, minute: mm, pm: nil))
        }
        // 8 · standalone years — espeak reads "1966" as a number, not a year
        for m in matches(#"\b((?:18|19|20)\d{2})\b"#) {
            guard let y = int(m, 1) else { continue }
            claim(m.range, spellYear(y))
        }
        // 9 · misc: "&" → and · "No. 12" → number 12
        for m in matches(#"\s&\s"#) { claim(m.range, " and ") }
        for m in matches(#"\bNo\.\s?(?=\d)"#) { claim(m.range, "number ") }

        return subs.sorted { $0.range.location < $1.range.location }
    }

    /// Build the speakable rendition: deterministic rules + `extra` context substitutions
    /// (Claude's judgement calls, given as exact original substrings → spoken forms).
    public static func spokenText(for text: String,
                                  extra: [(original: String, spoken: String)] = []) -> SpokenText {
        let ns = text as NSString
        var subs = substitutions(for: text)
        var claimed = subs.map(\.range)
        for e in extra {
            let needle = e.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let found = ns.range(of: needle, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if !claimed.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    claimed.append(found)
                    subs.append(Substitution(range: found, spoken: e.spoken))
                }
                let nextStart = found.location + found.length
                search = NSRange(location: nextStart, length: ns.length - nextStart)
            }
        }
        subs.sort { $0.range.location < $1.range.location }

        var spoken = ""
        var segments: [(spoken: NSRange, original: NSRange, isSub: Bool)] = []
        var cursor = 0
        func appendGap(upTo end: Int) {
            guard end > cursor else { return }
            let orig = NSRange(location: cursor, length: end - cursor)
            let piece = ns.substring(with: orig)
            segments.append((NSRange(location: (spoken as NSString).length,
                                     length: (piece as NSString).length), orig, false))
            spoken += piece
        }
        for sub in subs {
            appendGap(upTo: sub.range.location)
            segments.append((NSRange(location: (spoken as NSString).length,
                                     length: (sub.spoken as NSString).length), sub.range, true))
            spoken += sub.spoken
            cursor = sub.range.location + sub.range.length
        }
        appendGap(upTo: ns.length)
        return SpokenText(original: text, text: spoken, segments: segments)
    }

    // MARK: - The English voicings

    /// "half past three", "a quarter to four", "ten past six in the evening", "three o'clock".
    static func timePhrase(hour: Int, minute: Int, pm: Bool?) -> String {
        let nextHour = hour == 12 ? 1 : hour + 1
        let core: String
        switch minute {
        case 0:  core = "\(spell(hour)) o'clock"
        case 15: core = "a quarter past \(spell(hour))"
        case 30: core = "half past \(spell(hour))"
        case 45: core = "a quarter to \(spell(nextHour))"
        case 5, 10, 20, 25: core = "\(spell(minute)) past \(spell(hour))"
        case 35, 40, 50, 55: core = "\(spell(60 - minute)) to \(spell(nextHour))"
        default: core = minute < 10 ? "\(spell(hour)) oh \(spell(minute))"
                                    : "\(spell(hour)) \(spell(minute))"
        }
        guard let pm else { return core }
        if pm { return core + (hour == 12 || hour < 6 ? " in the afternoon" : " in the evening") }
        return core + " in the morning"
    }

    static func pounds(_ n: Int) -> String { n == 1 ? "one pound" : "\(spell(n)) pounds" }
    static func shillings(_ n: Int) -> String { n == 1 ? "one shilling" : "\(spell(n)) shillings" }

    /// Pence, as said: a penny, tuppence, thruppence, sixpence, elevenpence…
    static func penceWord(_ n: Int) -> String {
        switch n {
        case 1: return "a penny"
        case 2: return "tuppence"
        case 3: return "thruppence"
        case 6: return "sixpence"
        default: return "\(spell(n))pence"
        }
    }

    static func monthName(_ m: Int) -> String {
        ["January", "February", "March", "April", "May", "June", "July",
         "August", "September", "October", "November", "December"][m - 1]
    }
    static func monthIndex(_ s: String) -> Int? {
        let l = s.lowercased()
        let names = ["january", "february", "march", "april", "may", "june", "july",
                     "august", "september", "october", "november", "december"]
        if let i = names.firstIndex(where: { $0 == l || $0.hasPrefix(l) }) { return i + 1 }
        return nil
    }

    // MARK: - Numbers, as said aloud

    static let onesWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                            "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                            "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tensWords = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
                            "eighty", "ninety"]

    /// 0…9999 in words, English style ("three hundred and forty-five").
    static func spell(_ n: Int) -> String {
        precondition(n >= 0)
        switch n {
        case 0..<20: return onesWords[n]
        case 20..<100:
            let t = tensWords[n / 10]
            return n % 10 == 0 ? t : "\(t)-\(onesWords[n % 10])"
        case 100..<1000:
            let h = "\(onesWords[n / 100]) hundred"
            return n % 100 == 0 ? h : "\(h) and \(spell(n % 100))"
        default:
            let th = "\(spell(n / 1000)) thousand"
            let rest = n % 1000
            if rest == 0 { return th }
            return rest < 100 ? "\(th) and \(spell(rest))" : "\(th), \(spell(rest))"
        }
    }

    /// Years, as said: 1966 → "nineteen sixty-six", 1905 → "nineteen oh five",
    /// 1900 → "nineteen hundred", 2005 → "two thousand and five".
    static func spellYear(_ y: Int) -> String {
        guard (1000...9999).contains(y) else { return spell(max(0, y)) }
        if y >= 2000, y < 2100 { return spell(y) }             // "two thousand and five"
        let century = y / 100
        let rest = y % 100
        if rest == 0 { return "\(spell(century)) hundred" }
        if rest < 10 { return "\(spell(century)) oh \(onesWords[rest])" }
        return "\(spell(century)) \(spell(rest))"
    }

    /// 1 → "first" … 31 → "thirty-first".
    static func ordinal(_ n: Int) -> String {
        let irregular = [1: "first", 2: "second", 3: "third", 5: "fifth", 8: "eighth",
                         9: "ninth", 12: "twelfth"]
        if let o = irregular[n] { return o }
        if n < 20 { return onesWords[n] + "th" }
        if n % 10 == 0 { return String(tensWords[n / 10].dropLast()) + "ieth" }
        return "\(tensWords[n / 10])-\(ordinal(n % 10))"
    }
}
