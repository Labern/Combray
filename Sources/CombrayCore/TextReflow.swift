import Foundation

/// Turns a raw transcription — which faithfully preserves the *physical* line breaks of the page,
/// so prose wraps early and awkwardly — into a neatly-flowing read where paragraphs are paragraphs.
///
/// The rule is deliberately simple, so prose never gets "poetic" mid-sentence breaks:
///   • a blank line is a paragraph break (block separator);
///   • every line inside a block is joined into one flowing paragraph — the page's physical wraps
///     are dropped and SwiftUI re-wraps to the view width.
/// A transcription with no blank lines therefore becomes a single flowing block of text — which is
/// correct: paragraphs come from blank-line breaks in the source, never from guessing line lengths.
public enum TextReflow {

    /// The transcription split into display paragraphs. Each returned string is one flowing paragraph
    /// with no internal `\n`. Render them in a stack with spacing between for the "letter view".
    public static func paragraphs(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        var blocks: [String] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            blocks.append(current.joined(separator: " "))   // join EVERY line in the block → one paragraph
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
                       "code", "terminal", "console", "command line", "cli", "shell", "log",
                       "spreadsheet"]
        return markers.contains { t.contains($0) }
    }

    /// Display-time check that also handles **legacy records** with no `documentType` (written before
    /// it was captured): falls back to strong screenshot words in the title and to the code/terminal
    /// *shape* of the content. Used for rendering and export so old screenshots still show monospaced.
    public static func isLayoutSignificant(documentType: String?, title: String?, transcription: String) -> Bool {
        if let dt = documentType?.trimmingCharacters(in: .whitespaces), !dt.isEmpty {
            return isLayoutSignificant(dt)                              // authoritative when present
        }
        let t = (title ?? "").lowercased()
        let strongTitleWords = ["screenshot", "screen shot", "screengrab", "screen grab", "screen capture"]
        if strongTitleWords.contains(where: t.contains) { return true }
        return looksLikeCodeOrTerminal(transcription)
    }

    /// Conservative heuristic: does this text look like code or terminal output (heavy indentation or
    /// code/CLI punctuation), as opposed to prose? Only used when no document type is recorded.
    static func looksLikeCodeOrTerminal(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4 else { return false }
        var indented = 0, codey = 0
        for line in lines {
            if line.hasPrefix("  ") || line.hasPrefix("\t") { indented += 1 }
            if line.hasPrefix("$ ") || line.hasPrefix("> ") || line.contains(" => ")
                || line.contains("();") || line.contains("://") || line.contains("{")
                || line.contains("()") { codey += 1 }
        }
        let n = Double(lines.count)
        return Double(indented) / n > 0.30 || Double(codey) / n > 0.35
    }
}
