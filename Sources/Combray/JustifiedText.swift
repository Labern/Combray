import SwiftUI
import AppKit

/// A selectable, **justified** multi-paragraph text view — SwiftUI's `Text` only does
/// leading/center/trailing, so the letter (reflow) view drops down to an `NSTextView` for true
/// justification. Paragraphs are separated by blank lines in `text`; `paragraphSpacing` is the gap
/// between them so they read as distinct sections.
struct JustifiedText: NSViewRepresentable {
    let text: String
    var font: NSFont
    var color: NSColor
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.textStorage?.setAttributedString(attributed())
    }

    /// Report the height the text needs at the proposed width, so the SwiftUI layout reserves the
    /// right space (no clipping, no overlap).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(lm.usedRect(for: container).height))
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
