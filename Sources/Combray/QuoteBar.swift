import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Quote bar (cycling Proust)

enum ProustQuotes {
    static let all = [
        "The only real voyage of discovery consists not in seeking new landscapes, but in having new eyes.",
        "We do not receive wisdom, we must discover it for ourselves after a journey that no one can take for us.",
        "Remembrance of things past is not necessarily the remembrance of things as they were.",
        "Let us be grateful to people who make us happy; they are the charming gardeners who make our souls blossom.",
        "A change in the weather is sufficient to recreate the world and ourselves.",
        "Time, which changes people, does not alter the image we have retained of them.",
        "Love is space and time measured by the heart.",
        "We are healed of a suffering only by experiencing it to the full."
    ]
}

struct QuoteBar: View {
    @EnvironmentObject var c: ArchiveController
    @State private var index = 0
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Text("\u{201C}\(ProustQuotes.all[index])\u{201D}  — Proust, In Search of Lost Time")
                .font(.system(size: 15)).italic()
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 230)
                .id(index)
                .transition(.opacity)
                .onReceive(timer) { _ in
                    withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % ProustQuotes.all.count }
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

                // bottom-right: credit
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

