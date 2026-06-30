import Foundation

/// Renders a partial ISO date ("1963", "1963-11", "1963-11-01") in English:
/// "1963", "November 1963", "1st November, 1963". Returns the input unchanged if it isn't ISO-ish.
public enum DateDisplay {
    public static func pretty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        let parts = v.split(separator: "-").map(String.init)
        guard let year = parts.first, year.count == 4, Int(year) != nil else { return v }
        let months = ["January","February","March","April","May","June","July","August",
                      "September","October","November","December"]
        if parts.count == 1 { return year }
        guard parts.count >= 2, let m = Int(parts[1]), (1...12).contains(m) else { return year }
        let monthName = months[m - 1]
        if parts.count == 2 { return "\(monthName) \(year)" }
        guard let d = Int(parts[2]), (1...31).contains(d) else { return "\(monthName) \(year)" }
        return "\(ordinal(d)) \(monthName), \(year)"
    }

    /// UK numeric presentation of a partial ISO date: full → "01/11/1963", year+month → "11/1963",
    /// year → "1963". Non-ISO input is returned unchanged. Used in the reading/transcription view.
    public static func numericUK(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        let parts = v.split(separator: "-").map(String.init)
        guard let year = parts.first, year.count == 4, Int(year) != nil else { return v }
        if parts.count == 1 { return year }
        guard let m = Int(parts[1]), (1...12).contains(m) else { return year }
        let mm = String(format: "%02d", m)
        if parts.count == 2 { return "\(mm)/\(year)" }
        guard let d = Int(parts[2]), (1...31).contains(d) else { return "\(mm)/\(year)" }
        return "\(String(format: "%02d", d))/\(mm)/\(year)"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        if (11...13).contains(n % 100) { suffix = "th" }
        else { switch n % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" } }
        return "\(n)\(suffix)"
    }
}
