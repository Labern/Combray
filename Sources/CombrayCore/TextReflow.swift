import Foundation

/// Turns a raw transcription — which faithfully preserves the *physical* line breaks of the page,
/// so prose wraps early and awkwardly — into a neatly-flowing read where paragraphs are paragraphs.
///
/// The rule is layout-preserving where it matters and only un-wraps where it helps:
///   • blank lines stay paragraph breaks (block separators);
///   • inside a block, a line that runs near the page width is treated as a *soft wrap* and joined
///     to the next with a space, so prose reflows to the view;
///   • a short line (a salutation, signature, address, list item, line of verse) keeps its break.
/// Because short lines are preserved, lists and poems survive unharmed; only long wrapped prose
/// is reflowed.
public enum TextReflow {

    /// The transcription split into display paragraphs, with intra-paragraph soft wraps un-wrapped.
    /// Each returned string is one paragraph (it may still contain `\n` for intentional short-line
    /// breaks). Render them in a stack with spacing between for the "letter view".
    public static func paragraphs(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        // A line is a "full" (soft-wrapped) line if it's long relative to the longest line present.
        let maxLen = lines.map(\.count).max() ?? 0
        let threshold = max(40, Int(Double(maxLen) * 0.6))

        var blocks: [String] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            var s = ""
            for (idx, line) in current.enumerated() {
                s += line
                if idx < current.count - 1 {
                    s += line.count >= threshold ? " " : "\n"   // soft wrap → space; intentional break → newline
                }
            }
            blocks.append(s)
            current.removeAll()
        }
        for line in lines {
            if line.isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return blocks
    }

    /// True when a document's exact whitespace/layout is meaningful and must be shown verbatim
    /// (computer screenshots, code, terminal output, …) rather than reflowed as prose. Everything
    /// else — letters and written documents — defaults to the neat reflowed view.
    public static func isLayoutSignificant(_ documentType: String?) -> Bool {
        guard let t = documentType?.lowercased() else { return false }
        let markers = ["screenshot", "screen shot", "screengrab", "screen grab", "screen capture",
                       "code", "terminal", "console", "spreadsheet"]
        return markers.contains { t.contains($0) }
    }
}
