import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Helpers

/// Page-image cache. SwiftUI re-evaluates the detail view on every state tick (playback runs at
/// several Hz), and decoding a multi-megabyte JPEG on the main thread on EVERY pass made the whole
/// UI sloppy — clicks queued behind image decodes. One decode per file, then it's free.
@MainActor private let pageImageCache = NSCache<NSString, NSImage>()

@MainActor
func loadImage(_ url: URL) -> Image? {
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        .map { String($0.timeIntervalSince1970) } ?? ""
    let key = (url.path + "|" + mtime) as NSString
    if let hit = pageImageCache.object(forKey: key) { return Image(nsImage: hit) }
    guard let img = NSImage(contentsOf: url) else { return nil }
    pageImageCache.setObject(img, forKey: key)
    return Image(nsImage: img)
}

/// A page image you can pinch to zoom, drag to pan when zoomed, and double-click to reset.
struct ZoomableImage: View {
    let image: Image
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value.magnification, 1), 6)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { withAnimation(.spring) { offset = .zero; lastOffset = .zero } }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring) {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    else { scale = 2.5; lastScale = 2.5 }
                }
            }
            .contentShape(Rectangle())
            .clipped()
    }
}

