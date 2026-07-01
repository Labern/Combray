import SwiftUI
import AppKit

/// A headless visual probe: host the REAL `JustifiedText` in a narrow pane (mirroring the transcript
/// column) and dump the rendered pixels to a PNG, so we can actually SEE whether the transcription
/// wraps within the pane instead of spilling off the side. Invoked via `--render-justified <out.png>`.
@MainActor
func renderJustifiedProbePNG(to path: String, width: CGFloat = 520) {
    let sample = """
    My dearest, I am writing to you from the garden this warm afternoon, the light long and gold across the lawn, and I find my thoughts turning, as they so often do, to the summers we spent together by the sea when the children were small and the days seemed to stretch without end.

    You asked in your last letter whether I had heard from your brother. I had a short note from him only last week; he is well, though busier than ever, and he sends his fondest love to you and to the little ones, whom he longs to see again before the year is out.

    Write soon, and tell me everything. Yours ever, with all my heart.
    """

    let speech = SpeechController()
    speech.configure(text: sample, gender: "female")   // exercises the real timer + voice-hint layout

    let content = ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transcription").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Label("View full size", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
            }
            PlaybackBar(controller: speech)
            TranscriptionText(transcription: sample, documentType: "letter", title: "A letter")
                .frame(maxWidth: 680, alignment: .leading)
        }
        .padding(24)
    }
    .frame(width: width, height: 720)
    .background(Color(white: 0.99))

    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 720)

    let window = NSWindow(contentRect: host.frame,
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)

    // Give SwiftUI + the hosted NSTextView a beat to lay out, then snapshot the real pixels.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
