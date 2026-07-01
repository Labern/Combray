import SwiftUI
import AppKit

/// A selectable, **justified** multi-paragraph text view. SwiftUI's `Text` only does
/// leading/center/trailing, so the letter (reflow) view drops to an `NSTextView` for true
/// justification. Paragraphs are separated by blank lines in `text`; `paragraphSpacing` is the gap
/// between them.
///
/// Crucially, the wrap width is driven **explicitly** from the SwiftUI-measured width (a
/// `GeometryReader`) and hard-set on the text container — letting the `NSTextView` size itself made
/// it fall back to its single-line width and spill off the side of the pane. Height self-reports back
/// through a binding so the surrounding scroll layout reserves the right space.
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

    /// The AppKit text view. `width` is the exact wrap width measured by the SwiftUI `GeometryReader`;
    /// `height` reports the laid-out height back up.
    private struct Rep: NSViewRepresentable {
        let text: String
        let font: NSFont
        let color: NSColor
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let highlight: NSRange?
        let width: CGFloat
        @Binding var height: CGFloat

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

            if tv.string != text { storage.setAttributedString(attributed()) }

            // Hard-constrain the wrap width to the SwiftUI-measured width.
            tc.size = CGSize(width: width, height: .greatestFiniteMagnitude)

            // Per-word read-aloud highlight (repaint only — cheap, keeps selection/scroll).
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            if let h = highlight, h.location >= 0, h.location + h.length <= storage.length {
                storage.addAttribute(.backgroundColor, value: Theme.accentNS.withAlphaComponent(0.35), range: h)
            }

            lm.ensureLayout(for: tc)
            let needed = ceil(lm.usedRect(for: tc).height)
            tv.frame = CGRect(x: 0, y: 0, width: width, height: needed)
            if abs(needed - height) > 0.5 {
                DispatchQueue.main.async { self.height = needed }
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
