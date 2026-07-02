import SwiftUI
import AppKit

/// A selectable, **justified** multi-paragraph text view. SwiftUI's `Text` only does
/// leading/center/trailing, so the letter (reflow) view drops to an `NSTextView` for true
/// justification. Paragraphs are separated by blank lines in `text`; `paragraphSpacing` is the gap
/// between them.
///
/// The wrap width is driven **explicitly** from the SwiftUI-measured width (a `GeometryReader`)
/// and hard-set on the text container — letting the `NSTextView` size itself made it fall back to
/// its single-line width and spill off the pane. Height self-reports back through a binding.
///
/// Performance matters here: SwiftUI re-runs `updateNSView` on every state tick (several Hz during
/// read-aloud), and a full justified re-layout of a long letter each time saturated the main thread
/// — buttons went sloppy, playback control lagged. The Coordinator caches what was last applied so
/// a pass that changes nothing costs nothing, and a highlight move only repaints two word ranges.
struct JustifiedText: View {
    let text: String
    var font: NSFont
    var color: NSColor
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var highlight: NSRange? = nil          // the word being read aloud, highlighted live

    @State private var measuredHeight: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Rep(text: text, font: font, color: color, lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing, highlight: highlight,
                width: geo.size.width, height: $measuredHeight)
        }
        .frame(height: measuredHeight)
    }

    private struct Rep: NSViewRepresentable {
        let text: String
        let font: NSFont
        let color: NSColor
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let highlight: NSRange?
        let width: CGFloat
        @Binding var height: CGFloat

        /// What's currently applied to the NSTextView — so unchanged passes are free.
        final class Coordinator {
            var text = ""
            var width: CGFloat = 0
            var highlight: NSRange?
            var height: CGFloat = 0
        }
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSTextView {
            let tv = NSTextView()
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = .zero
            tv.textContainer?.lineFragmentPadding = 0
            tv.textContainer?.widthTracksTextView = false   // WE set the width — don't track the frame
            tv.isHorizontallyResizable = false
            tv.isVerticallyResizable = true
            return tv
        }

        func updateNSView(_ tv: NSTextView, context: Context) {
            guard width > 0,
                  let tc = tv.textContainer, let lm = tv.layoutManager, let storage = tv.textStorage
            else { return }
            let coord = context.coordinator

            let textChanged = coord.text != text
            let widthChanged = abs(coord.width - width) > 0.5

            if textChanged {
                storage.setAttributedString(attributed())
                coord.text = text
                coord.highlight = nil               // attributes were reset with the text
            }

            if textChanged || widthChanged {        // the only cases that need a full re-layout
                coord.width = width
                tc.size = CGSize(width: width, height: .greatestFiniteMagnitude)
                lm.ensureLayout(for: tc)
                let needed = ceil(lm.usedRect(for: tc).height)
                tv.frame = CGRect(x: 0, y: 0, width: width, height: needed)
                if abs(needed - coord.height) > 0.5 {
                    coord.height = needed
                    DispatchQueue.main.async { self.height = needed }
                }
            }

            if coord.highlight != highlight {       // repaint just the two affected word ranges
                let len = storage.length
                if let old = coord.highlight, old.location >= 0, old.location + old.length <= len {
                    storage.removeAttribute(.backgroundColor, range: old)
                }
                if let h = highlight, h.location >= 0, h.location + h.length <= len {
                    storage.addAttribute(.backgroundColor,
                                         value: Theme.accentNS.withAlphaComponent(0.35), range: h)
                    // Keep the spoken word on screen: scroll the surrounding SwiftUI scroll view
                    // (an NSScrollView underneath) so the reader never has to chase the voice.
                    let glyphs = lm.glyphRange(forCharacterRange: h, actualCharacterRange: nil)
                    var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                    rect = rect.insetBy(dx: 0, dy: -90)          // breathing room above & below
                    tv.scrollToVisible(rect)
                }
                coord.highlight = highlight
            }
        }

        private func attributed() -> NSAttributedString {
            let p = NSMutableParagraphStyle()
            p.alignment = .justified
            p.lineSpacing = lineSpacing
            p.paragraphSpacing = paragraphSpacing
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: p,
            ])
        }
    }
}
