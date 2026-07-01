import SwiftUI
import AppKit
import CombrayCore

/// Headless visual probes: host the REAL UI views (with period sample content) and dump the rendered
/// pixels to a PNG — used to (a) verify the transcription wraps within its pane, and (b) generate the
/// feature screenshots in the README. Invoked via `--render-scene <name> <out.png> [width]`.
/// Scenes: `read` (reading + read-aloud pane), `side` (side-by-side: letter photo + transcription),
/// `full` (the "View full size" reading card).
private let sampleLetter = """
My dearest, I am writing to you from the garden this warm afternoon, the light long and gold across the lawn, and I find my thoughts turning, as they so often do, to the summers we spent together by the sea when the children were small and the days seemed to stretch without end.

You asked in your last letter whether I had heard from your brother. I had a short note from him only last week; he is well, though busier than ever, and he sends his fondest love to you and to the little ones, whom he longs to see again before the year is out.

Write soon, and tell me everything. Yours ever, with all my heart.
"""

@MainActor
func renderScenePNG(scene: String, to path: String, width: CGFloat) {
    let speech = SpeechController()
    speech.configure(text: sampleLetter, gender: "female")

    let root: AnyView
    switch scene {
    case "side":  root = AnyView(SideBySideScene(speech: speech))
    case "full":  root = AnyView(FullReaderScene())
    default:      root = AnyView(ReadingScene(speech: speech))
    }

    let height: CGFloat = scene == "side" ? 720 : (scene == "full" ? 820 : 760)
    let content = root.frame(width: width, height: height).background(Color(white: 0.99))

    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)       // real light-mode reading ink
    host.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

/// The reading pane: "Transcription" header, the read-aloud bar, and the justified transcription.
private struct ReadingScene: View {
    @ObservedObject var speech: SpeechController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Transcription").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Label("View full size", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
                }
                PlaybackBar(controller: speech)
                TranscriptionText(transcription: sampleLetter, documentType: "letter", title: "A letter")
                    .frame(maxWidth: 680, alignment: .leading)
            }
            .padding(24)
        }
    }
}

/// The core side-by-side: the original letter photo on the left, the transcription on the right.
private struct SideBySideScene: View {
    @ObservedObject var speech: SpeechController
    var body: some View {
        HStack(spacing: 0) {
            HandwrittenLetter()
                .frame(width: 360)
                .background(Color(white: 0.97))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Letter to my dear friend, about a summer by the sea")
                        .font(.custom("Hoefler Text", size: 26).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 26) {
                        field("From", "Eleanor")
                        field("To", "Margaret")
                        field("Date", "14/06/1961")
                    }
                    HStack {
                        Text("Transcription").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Label("View full size", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
                    }
                    PlaybackBar(controller: speech)
                    TranscriptionText(transcription: sampleLetter, documentType: "letter", title: "A letter")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
            }
        }
    }
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.custom("Hoefler Text", size: 17))
        }
    }
}

/// The "View full size" centred reading card.
private struct FullReaderScene: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack { Spacer(); Label("Close", systemImage: "xmark").font(.system(size: 13, weight: .semibold)) }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Letter to my dear friend, about a summer by the sea")
                            .font(.custom("Hoefler Text", size: 30))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("14/06/1961").font(.system(size: 15)).foregroundStyle(.secondary)
                        TranscriptionText(transcription: sampleLetter, documentType: "letter", title: "A letter",
                                          serifSize: 23, paragraphSpacing: 20)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 48).padding(.vertical, 34)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.99)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(white: 0.85)))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: 720, maxHeight: 760)
            .padding(28)
        }
    }
}

/// A faux "original letter photo" — the sample rendered in a cursive hand on aged paper, so the
/// side-by-side screenshot reads authentically without shipping anyone's real letter.
private struct HandwrittenLetter: View {
    var body: some View {
        VStack {
            Text("My dearest,\n\nI am writing to you from the garden this warm afternoon, the light long and gold across the lawn, and I find my thoughts turning, as they so often do, to the summers we spent together by the sea.\n\nWrite soon, and tell me everything.\n\nYours ever,\nwith all my heart.")
                .font(.custom("Snell Roundhand", size: 21))
                .foregroundStyle(Color(red: 0.12, green: 0.11, blue: 0.16))
                .lineSpacing(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.98, green: 0.96, blue: 0.91)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.82), lineWidth: 1))
        }
        .padding(20)
    }
}
