import SwiftUI
import AppKit
import CombrayCore

/// Design tokens. White, simple, BIG, legible. One warm madeleine-gold accent.
/// Swap this file to re-theme everything.
enum Theme {
    /// A token that resolves per appearance — `light` RGB in Light mode, `dark` RGB in Dark mode.
    /// Every colour flows through here, so Dark Mode is a single swap (no per-view edits).
    static func dynNS(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static func dyn(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: dynNS(light: light, dark: dark))
    }

    /// The ink colour as a (dark-mode-aware) `NSColor`, for AppKit views like the justified text view.
    static let inkNS = dynNS(light: (0.12, 0.11, 0.10), dark: (0.928, 0.908, 0.860))

    static let bg        = dyn(light: (1.00, 1.00, 1.00),    dark: (0.086, 0.080, 0.067))  // paper / near-black
    static let surface   = dyn(light: (0.975, 0.965, 0.945), dark: (0.145, 0.132, 0.110))  // faint warm panel
    static let ink       = dyn(light: (0.12, 0.11, 0.10),    dark: (0.928, 0.908, 0.860))  // text
    static let faint     = dyn(light: (0.42, 0.40, 0.37),    dark: (0.640, 0.610, 0.555))  // muted text
    static let line      = dyn(light: (0.89, 0.87, 0.83),    dark: (0.235, 0.215, 0.180))  // hairlines
    static let accent    = dyn(light: (0.84, 0.68, 0.24),    dark: (0.905, 0.745, 0.305))  // gold
    static let accentDeep = dyn(light: (0.62, 0.49, 0.13),   dark: (0.955, 0.815, 0.430))  // deep antique gold

    // Roomy spacing.
    static let gap: CGFloat = 20
    static let pad: CGFloat = 28
    static let radius: CGFloat = 18

    // BIG type scale. Serif for headings (literary), sans for body.
    // Optima (a beautiful humanist sans) everywhere; Didot (elegant French serif) for "Combray".
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// The beautiful book serif used to read transcribed letters & written documents.
    /// Hoefler Text ships with macOS; falls back gracefully to the system serif.
    static func letterFace(_ size: CGFloat) -> Font {
        .custom("Hoefler Text", size: size)
    }
    static let wordmark = serif(56, .bold)
    static let wordmarkSmall = serif(27, .bold)
    static let hero = sans(46, .bold)
    static let title = sans(31, .semibold)
    static let section = sans(23, .semibold)
    static let big = sans(22, .semibold)
    static let body = sans(19)
    static let small = sans(18)
    static let label = sans(18, .semibold)
}

/// Big, unmissable buttons. There are no small tap targets in this app.
struct BigButtonStyle: ButtonStyle {
    var filled: Bool = true
    var fullWidth: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(compact ? 18 : 24, .semibold))
            .lineLimit(1)                         // never wrap → buttons in a row stay equal height
            .minimumScaleFactor(0.6)              // shrink to fit so a row stays horizontal, not truncated
            .padding(.vertical, compact ? 13 : 20)
            .padding(.horizontal, compact ? 16 : 30)
            .frame(minHeight: compact ? 50 : 68)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(filled ? Color.white : Theme.accentDeep)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(filled ? Theme.accent : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(filled ? Color.clear : Theme.accent, lineWidth: 2)
            )
            .shadow(color: filled ? Theme.accent.opacity(configuration.isPressed ? 0.16 : 0.30) : .clear,
                    radius: configuration.isPressed ? 5 : 10, y: configuration.isPressed ? 2 : 4)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// A plain (chrome-free) button that still reacts visibly to every press — a quick spring
/// scale + dim. Drop-in for `.plain` so no tap in the app goes unacknowledged.
struct TapStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

extension View {
    func card() -> some View {
        self
            .padding(Theme.pad)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
    }

    /// A hover tooltip with a larger, readable font — the native `.help()` font can't be enlarged.
    /// Appears after a brief hover and dismisses when the pointer leaves.
    func tip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}

struct HoverTip: ViewModifier {
    let text: String
    @State private var show = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    let work = DispatchWorkItem { show = true }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
                } else {
                    show = false
                }
            }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
    }
}

// MARK: - Madeleine

/// A drawn madeleine — the shell-shaped cake of involuntary memory. Used as the hero mark
/// and rendered into the Dock icon.
struct MadeleineMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // Draw the whole mark scaled-in slightly so the bold outline is NEVER clipped by the
            // Canvas edge — identical look to the Dock icon, just never cut off.
            let inset: CGFloat = 0.90
            ctx.translateBy(x: w * (1 - inset) / 2, y: h * (1 - inset) / 2)
            ctx.scaleBy(x: inset, y: inset)

            let cx = w * 0.5
            let baseY = h * 0.86
            let baseHalf = w * 0.10
            let apex = CGPoint(x: cx, y: baseY)
            let ribs = 6
            let spread = CGFloat.pi * 0.44
            let radius = h * 0.76
            let widthScale: CGFloat = 0.68

            func tip(_ i: Int) -> CGPoint {
                let t = CGFloat(i) / CGFloat(ribs)
                let a = (t - 0.5) * 2 * spread
                return CGPoint(x: apex.x + sin(a) * radius * widthScale,
                               y: apex.y - cos(a) * radius)
            }

            let baseL = CGPoint(x: cx - baseHalf, y: baseY)
            let baseR = CGPoint(x: cx + baseHalf, y: baseY)

            // Plump shell: rounded base, curved sides, scalloped wide top.
            var shell = Path()
            shell.move(to: baseL)
            shell.addQuadCurve(to: tip(0),
                control: CGPoint(x: tip(0).x - w * 0.04, y: (baseL.y + tip(0).y) / 2))
            for i in 1...ribs {
                let a = tip(i - 1), b = tip(i)
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let dx = mid.x - apex.x, dy = mid.y - apex.y
                let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
                let bulge = h * 0.06
                let ctrl = CGPoint(x: mid.x + dx / len * bulge, y: mid.y + dy / len * bulge)
                shell.addQuadCurve(to: b, control: ctrl)
            }
            shell.addQuadCurve(to: baseR,
                control: CGPoint(x: tip(ribs).x + w * 0.04, y: (baseR.y + tip(ribs).y) / 2))
            shell.addQuadCurve(to: baseL, control: CGPoint(x: cx, y: baseY + h * 0.07))
            shell.closeSubpath()

            // Flat cartoon golden fill.
            ctx.fill(shell, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.99, green: 0.85, blue: 0.47),
                    Color(red: 0.90, green: 0.68, blue: 0.30)
                ]),
                startPoint: CGPoint(x: cx, y: h * 0.10),
                endPoint: CGPoint(x: cx, y: baseY)))

            // Bold cartoon ridges.
            let ribColor = Color(red: 0.50, green: 0.32, blue: 0.12).opacity(0.55)
            for i in 1..<ribs {
                let t = CGFloat(i) / CGFloat(ribs)
                let a = (t - 0.5) * 2 * spread
                let end = CGPoint(x: apex.x + sin(a) * radius * widthScale * 0.82,
                                  y: apex.y - cos(a) * radius * 0.84)
                var p = Path()
                p.move(to: CGPoint(x: apex.x, y: apex.y - h * 0.06))
                p.addLine(to: end)
                ctx.stroke(p, with: .color(ribColor), lineWidth: max(2, w * 0.02))
            }

            // Soft white highlight near the top.
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.37, y: h * 0.19, width: w * 0.17, height: h * 0.09)),
                     with: .color(.white.opacity(0.5)))

            // Bold cartoon outline.
            ctx.stroke(shell, with: .color(Color(red: 0.42, green: 0.27, blue: 0.10)),
                       lineWidth: max(3, w * 0.045))
        }
        .aspectRatio(0.95, contentMode: .fit)
    }
}

/// The in-app logo: just the madeleine (no plate), scaled slightly in so its outline is never
/// clipped. The off-white plate is used only for the app/Dock icon.
struct MadeleineIcon: View {
    var body: some View {
        MadeleineMark()
    }
}

/// A small cartoon Marcel Proust — pale face, full side-parted dark hair, dark eyes, full
/// mustache, white collar with a dark cravat over a dark coat.
struct ProustMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let outline = Color(red: 0.18, green: 0.15, blue: 0.14)

            // Coat
            let coat = Path(roundedRect: CGRect(x: w * 0.12, y: h * 0.82, width: w * 0.76, height: h * 0.30),
                            cornerRadius: w * 0.14)
            ctx.fill(coat, with: .color(Color(red: 0.16, green: 0.15, blue: 0.18)))
            // White collar V
            var collar = Path()
            collar.move(to: CGPoint(x: w * 0.38, y: h * 0.82))
            collar.addLine(to: CGPoint(x: w * 0.50, y: h * 0.97))
            collar.addLine(to: CGPoint(x: w * 0.62, y: h * 0.82))
            ctx.fill(collar, with: .color(Color(red: 0.96, green: 0.95, blue: 0.93)))
            // Dark cravat knot
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.455, y: h * 0.85, width: w * 0.09, height: h * 0.07)),
                     with: .color(Color(red: 0.30, green: 0.10, blue: 0.12)))

            // Pale face
            let face = Path(ellipseIn: CGRect(x: w * 0.30, y: h * 0.26, width: w * 0.40, height: h * 0.52))
            ctx.fill(face, with: .color(Color(red: 0.97, green: 0.91, blue: 0.85)))
            ctx.stroke(face, with: .color(outline.opacity(0.28)), lineWidth: max(1, w * 0.006))

            // Full side-parted hair
            var hair = Path()
            hair.move(to: CGPoint(x: w * 0.28, y: h * 0.54))
            hair.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.16), control: CGPoint(x: w * 0.24, y: h * 0.22))
            hair.addQuadCurve(to: CGPoint(x: w * 0.72, y: h * 0.54), control: CGPoint(x: w * 0.78, y: h * 0.22))
            hair.addQuadCurve(to: CGPoint(x: w * 0.65, y: h * 0.36), control: CGPoint(x: w * 0.72, y: h * 0.42))
            hair.addQuadCurve(to: CGPoint(x: w * 0.44, y: h * 0.31), control: CGPoint(x: w * 0.55, y: h * 0.25))
            hair.addQuadCurve(to: CGPoint(x: w * 0.35, y: h * 0.36), control: CGPoint(x: w * 0.37, y: h * 0.31))
            hair.addQuadCurve(to: CGPoint(x: w * 0.28, y: h * 0.54), control: CGPoint(x: w * 0.28, y: h * 0.44))
            ctx.fill(hair, with: .color(Color(red: 0.13, green: 0.10, blue: 0.09)))

            // Eyebrows
            for (bx, dir) in [(w * 0.41, CGFloat(1)), (w * 0.59, CGFloat(-1))] {
                var b = Path()
                b.move(to: CGPoint(x: bx - w * 0.045 * dir, y: h * 0.47))
                b.addQuadCurve(to: CGPoint(x: bx + w * 0.045 * dir, y: h * 0.47), control: CGPoint(x: bx, y: h * 0.44))
                ctx.stroke(b, with: .color(outline), lineWidth: max(1.5, w * 0.012))
            }
            // Eyes
            for ex in [w * 0.41, w * 0.59] {
                ctx.fill(Path(ellipseIn: CGRect(x: ex - w * 0.028, y: h * 0.50, width: w * 0.056, height: h * 0.05)),
                         with: .color(outline))
            }
            // Full mustache
            var mus = Path()
            mus.move(to: CGPoint(x: w * 0.50, y: h * 0.66))
            mus.addQuadCurve(to: CGPoint(x: w * 0.32, y: h * 0.63), control: CGPoint(x: w * 0.40, y: h * 0.73))
            mus.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.68), control: CGPoint(x: w * 0.41, y: h * 0.69))
            mus.addQuadCurve(to: CGPoint(x: w * 0.68, y: h * 0.63), control: CGPoint(x: w * 0.59, y: h * 0.69))
            mus.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.66), control: CGPoint(x: w * 0.60, y: h * 0.73))
            ctx.fill(mus, with: .color(Color(red: 0.12, green: 0.09, blue: 0.08)))
        }
        .aspectRatio(0.82, contentMode: .fit)
    }
}

/// Proust cropped into a small circular avatar.
struct ProustAvatar: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.94, green: 0.91, blue: 0.87))
            ProustMark().scaleEffect(1.5).offset(y: 5)
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
    }
}

/// Renders the madeleine into an NSImage and sets it as the app/Dock icon.
@MainActor
func installMadeleineDockIcon() {
    let side: CGFloat = 512
    let inset = side * 0.10              // transparent margin, so it matches other macOS app icons
    let plate = side - inset * 2
    let icon = ZStack {
        RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
            .fill(Color(red: 0.99, green: 0.975, blue: 0.94))
        MadeleineMark().padding(plate * 0.15)
    }
    .frame(width: plate, height: plate)
    .frame(width: side, height: side)

    let renderer = ImageRenderer(content: icon)
    renderer.isOpaque = false
    renderer.scale = 2
    if let image = renderer.nsImage {
        NSApplication.shared.applicationIconImage = image
    }
}

/// Renders the madeleine mark (on the off-white icon background) to a PNG — used to preview the
/// art via `Combray --render <path>` so it can be inspected and iterated on.
@MainActor
func renderMadeleinePNG(to path: String) {
    let controller = ArchiveController()
    let ui = HStack(spacing: 0) {
        SidebarView(mode: .constant(.letters)).frame(width: 340)
        Divider()
        VStack(spacing: 0) {
            ExplainerView().frame(maxHeight: .infinity)
            QuoteBar()
        }
    }
    .frame(width: 1040, height: 700)
    .environmentObject(controller)

    let renderer = ImageRenderer(content: ui)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

/// Like `renderMadeleinePNG`, but with the "Restart to update" bubble shown bottom-left — used to
/// preview the auto-updater UI via `Combray --render-update <path>`.
@MainActor
func renderUpdatePreviewPNG(to path: String) {
    let controller = ArchiveController()
    let ui = ZStack(alignment: .bottomLeading) {
        HStack(spacing: 0) {
            SidebarView(mode: .constant(.letters)).frame(width: 340)
            Divider()
            VStack(spacing: 0) {
                ExplainerView().frame(maxHeight: .infinity)
                QuoteBar()
            }
        }
        UpdateBubble(updater: Updater(
            previewState: .ready(version: "0.12.0"),
            summary: "Adds an in-app auto-updater — Combray now spots new versions on GitHub and updates itself."))
            .padding(.leading, 18)
            .padding(.bottom, 70)
    }
    .frame(width: 1040, height: 700)
    .environmentObject(controller)

    let renderer = ImageRenderer(content: ui)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

/// Renders the reflowed letter view (the real `TranscriptionText`) for a representative letter — used
/// to eyeball transcription formatting via `Combray --render-letter <path>`.
@MainActor
func renderLetterPreviewPNG(to path: String) {
    // Multiple paragraphs (blank-line separated), each with the page's physical line breaks → should
    // flow into justified paragraphs with clear spacing between sections.
    let sample = """
    calm and peaceful and quiet, and there is a bright moon
    so we can see where we are. I trust that by the morning
    we will have received some news. We are in constant touch
    with Raido and also Singapore which is the Area station Ships.

    I havent the faintest idea now what will happen to us, or so
    the book says. It will take us a week or ten days in Dock if
    the Dock is in Hong Kong, and we certainly cant undertake a
    voyage of some thousands of miles across the Pacific in our
    present state so it is this Charter will also have to be cancelled.

    I am hoping for the best. You will I am sure be glad to know
    that we have been in touch with our old Second Engineer Yoo
    Yung Moon. He came to Singapore and told me that he had not
    been paid in spite of Two telegrams to the Agents at Manilla.
    """
    // Render the *same* justified attributed text the app's JustifiedText draws (ImageRenderer can't
    // snapshot an NSView, so draw it directly with AppKit).
    let serif: CGFloat = 21
    let width: CGFloat = 680, pad: CGFloat = 40
    let font = NSFont(name: "Hoefler Text", size: serif) ?? .systemFont(ofSize: serif)
    let style = NSMutableParagraphStyle()
    style.alignment = .justified
    style.lineSpacing = serif * 0.43
    style.paragraphSpacing = 24
    let body = TextReflow.paragraphs(sample).joined(separator: "\n\n")
    let attr = NSAttributedString(string: body, attributes: [
        .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])

    let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    let textH = ceil(attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                       options: opts).height)
    let canvasW = width + pad * 2, canvasH = textH + pad * 2 + 36
    let img = NSImage(size: NSSize(width: canvasW, height: canvasH))
    img.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()
    ("Transcription" as NSString).draw(at: NSPoint(x: pad, y: canvasH - 30),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.gray])
    attr.draw(with: NSRect(x: pad, y: pad, width: width, height: textH), options: opts)
    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
