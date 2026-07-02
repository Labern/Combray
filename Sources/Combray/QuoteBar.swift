import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Quote bar (cycling app tips)

/// Short how-to tips that rotate along the footer — a new one each time, cycling through all of them.
enum AppTips {
    static let all = [
        "Drag a photo of a letter anywhere onto the window to start a new entry.",
        "Photograph pages with your iPhone — scan the QR code and they fly to your Mac.",
        "Hover any button for a moment to see exactly what it does.",
        "Use “Find a specific letter” to search by theme, period, writer, or a pair of people.",
        "Ask Claude about a transcription — it can propose a fix you apply in one click.",
        "Edit a transcription and Combray refreshes the summary and meta to match.",
        "Letters are reflowed into a beautiful read; screenshots keep their exact layout.",
        "Right-click a page image to replace it with a clearer photo, or delete it.",
        "Add more pages to a letter with the ＋ button under the last image.",
        "Click “View full size” to read a transcription big and centred.",
        "Drag the divider between the image and the text to resize either side.",
        "Pin up to three important letters to the top of the sidebar (right-click a letter).",
        "Browse by People to see everyone someone corresponded with.",
        "Browse by Years to read your archive as a timeline.",
        "Tell Combray about yourself in Settings so it can spot letters you wrote.",
        "Export any letter to Word (.docx) in the same beautiful font you read on screen.",
        "Share a letter straight to a Gmail draft with one click.",
        "Switch between Light and Dark mode with the moon/sun in the toolbar.",
        "Back up every letter to iCloud Drive from the bottom-left.",
        "The folders on disk are the real archive — Combray can always rebuild from them.",
        "Stuck? Tap the headset to ask Labern, or the lightbulb to request a feature."
    ]
}

struct QuoteBar: View {
    @EnvironmentObject var c: ArchiveController
    @State private var index = Int.random(in: 0..<AppTips.all.count)
    private let timer = Timer.publish(every: 18, on: .main, in: .common).autoconnect()

    /// App version from the bundle Info.plist (three-part), shown in the footer. Falls back when the
    /// app is run un-bundled (e.g. `swift run`).
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.15.0"
    }

    var body: some View {
        ZStack {
            Label(AppTips.all[index], systemImage: "lightbulb")
                .font(.system(size: 15))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 230)
                .id(index)
                .transition(.opacity)
                .onReceive(timer) { _ in
                    withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % AppTips.all.count }
                }

            HStack {
                // bottom-left: iCloud backup
                Button { c.backupToICloud() } label: {
                    HStack(spacing: 6) {
                        if c.iCloudBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        Text(c.iCloudStatus ?? "Back up to iCloud")
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(TapStyle(scale: 0.93))
                .foregroundStyle(c.iCloudAvailable ? Theme.accentDeep : Theme.faint)
                .disabled(c.iCloudBusy)
                .help(c.iCloudAvailable ? "Copy every letter folder to iCloud Drive" : "iCloud Drive isn’t set up on this Mac")
                .frame(maxWidth: 260, alignment: .leading)

                Spacer()

                // bottom-right: version + credit
                HStack(spacing: 22) {
                    Text("V\(Self.appVersion)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.faint.opacity(0.65))
                    Button {
                        if let u = URL(string: "https://github.com/Labern/Combray") { NSWorkspace.shared.open(u) }
                    } label: {
                        Text("Made by Labern 🐿️").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(TapStyle(scale: 0.9))
                    .foregroundStyle(Theme.faint)
                    .help("Made by Labern — open the source on GitHub")
                }
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 24)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }
}

/// A rounded speech bubble with a small tail on the right edge (pointing at Proust).
struct SpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 9
        let radius: CGFloat = 13
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - tail, height: rect.height)
        var p = Path(roundedRect: body, cornerRadius: radius)
        let midY = rect.midY
        p.move(to: CGPoint(x: body.maxX - 3, y: midY - tail))
        p.addLine(to: CGPoint(x: rect.maxX, y: midY))
        p.addLine(to: CGPoint(x: body.maxX - 3, y: midY + tail))
        p.closeSubpath()
        return p
    }
}

