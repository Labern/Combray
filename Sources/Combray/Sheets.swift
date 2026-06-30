import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Add a letter

struct AddLetterSheet: View {
    @EnvironmentObject var c: ArchiveController
    var body: some View {
        VStack(spacing: 18) {
            Text("Add a Letter").font(Theme.title)
            Text("Photograph the pages with your iPhone, or choose image files already on this Mac.")
                .font(Theme.body).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button {
                c.showAddChoice = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    c.startCapture()
                }
            } label: {
                Label("Take photos with iPhone", systemImage: "iphone")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))
            Button {
                c.showAddChoice = false
                c.pickAndImport()
            } label: {
                Label("Choose photos from this Mac", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
            Button { c.showAddChoice = false } label: { Text("Cancel") }
                .buttonStyle(BigButtonStyle(filled: false))
        }
        .padding(34).frame(minWidth: 460, minHeight: 380)
    }
}

// MARK: - Replace a page (iPhone · Mac · drag)

/// Shown when the user clicks "Replace" on a page: swap in a better photo by taking a fresh one with
/// the iPhone, choosing a file, or dragging one in. All three route to the same `replaceTarget` page.
struct ReplaceChoiceSheet: View {
    @EnvironmentObject var c: ArchiveController
    @State private var dropping = false
    var body: some View {
        VStack(spacing: 18) {
            Text("Replace this page").font(Theme.title)
            Text("Swap in a better-quality photo — take a fresh one with your iPhone, choose a file, or drag one in.")
                .font(Theme.body).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { c.beginReplaceCapture() } label: {
                Label("Take a photo with iPhone", systemImage: "iphone")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))
            Button { c.replaceTargetWithPicker() } label: {
                Label("Choose a photo from this Mac", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(dropping ? Theme.accent.opacity(0.10) : Color.clear)
                RoundedRectangle(cornerRadius: 14)
                    .stroke(dropping ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 2, dash: [8]))
                Label("…or drag a photo here", systemImage: "arrow.down.doc")
                    .font(Theme.body).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity).frame(height: 96)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadDroppedURLs(providers) { urls in if !urls.isEmpty { c.replaceTargetPage(with: urls) } }
                return true
            }

            Button { c.cancelReplace() } label: { Text("Cancel") }
                .buttonStyle(BigButtonStyle(filled: false))
        }
        .padding(34).frame(minWidth: 480, minHeight: 470)
    }
}

// MARK: - Sign in with Claude

struct SignInSheet: View {
    @EnvironmentObject var c: ArchiveController
    var body: some View {
        VStack(spacing: 18) {
            Text("Sign in with Claude").font(Theme.title)
            Text("A Claude sign-in page opened in your browser. Approve access there — Combray signs you in automatically, no codes to copy.")
                .font(Theme.body).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            ProgressView().controlSize(.large)
            Text("Waiting for you to approve in the browser…")
                .font(Theme.small).foregroundStyle(Theme.faint)
            Button { c.startSignIn() } label: { Label("Open the page again", systemImage: "safari") }
                .buttonStyle(BigButtonStyle(filled: false))
            Button { c.cancelSignIn() } label: { Text("Cancel") }
                .buttonStyle(BigButtonStyle(filled: false))
        }
        .padding(34).frame(minWidth: 460, minHeight: 400)
    }
}

// MARK: - iPhone capture

struct CaptureSheet: View {
    @EnvironmentObject var c: ArchiveController
    var body: some View {
        VStack(spacing: 20) {
            Text("Add from iPhone").font(Theme.title)

            if c.captureSent {
                // 3 · the phone has uploaded — confirm, then the sheet auto-closes after 3s.
                Image(systemName: "checkmark.circle.fill").font(.system(size: 66)).foregroundStyle(Theme.accent)
                Text("Images sent!").font(Theme.title)
                Text("Adding them to your archive…").font(Theme.body).foregroundStyle(Theme.faint)
            } else if c.captureConnected {
                // 2 · the phone has opened the page — waiting for the photos.
                ProgressView().controlSize(.large)
                Text("Waiting for images on iPhone…").font(Theme.big)
                Text("Take the photos on your phone, then tap \u{201C}Send to Mac\u{201D}.")
                    .font(Theme.body).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            } else {
                // 1 · show the QR / address for the phone to open.
                Text("On your iPhone, point the Camera at this code (or open the address in Safari). Your phone must be on the same Wi‑Fi as this Mac.")
                    .font(Theme.body).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
                if let url = c.captureURL {
                    if let qr = qrImage(from: url) {
                        qr.interpolation(.none).resizable()
                            .frame(width: 230, height: 230)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    }
                    Text(url).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.large)
                    Text("Starting the connection…").font(Theme.body).foregroundStyle(Theme.faint)
                }
            }

            Button { c.stopCapture() } label: { Text(c.captureSent ? "Close" : "Cancel") }
                .buttonStyle(BigButtonStyle())
        }
        .padding(36)
        .frame(minWidth: 480, minHeight: 540)
        .animation(.easeInOut(duration: 0.25), value: c.captureConnected)
        .animation(.easeInOut(duration: 0.25), value: c.captureSent)
    }
}

// MARK: - Add a page (iPhone · Mac · drag)

/// Shown when the user taps "Add page": add another page to the current letter via the iPhone,
/// a file on this Mac, or by dragging one in.
struct AddPageChoiceSheet: View {
    @EnvironmentObject var c: ArchiveController
    @State private var dropping = false
    var body: some View {
        VStack(spacing: 18) {
            Text("Add a page").font(Theme.title)
            Text("Add another page to this letter — photograph it with your iPhone, choose a file, or drag one in.")
                .font(Theme.body).foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { c.beginAddPageCapture() } label: {
                Label("Take a photo with iPhone", systemImage: "iphone")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))
            Button { c.addPagesWithPickerFromChooser() } label: {
                Label("Choose a photo from this Mac", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(dropping ? Theme.accent.opacity(0.10) : Color.clear)
                RoundedRectangle(cornerRadius: 14)
                    .stroke(dropping ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 2, dash: [8]))
                Label("…or drag a photo here", systemImage: "arrow.down.doc")
                    .font(Theme.body).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity).frame(height: 96)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadDroppedURLs(providers) { urls in if !urls.isEmpty { c.addPagesFromChooser(urls) } }
                return true
            }

            Button { c.cancelAddPage() } label: { Text("Cancel") }
                .buttonStyle(BigButtonStyle(filled: false))
        }
        .padding(34).frame(minWidth: 480, minHeight: 470)
    }
}

func qrImage(from string: String) -> Image? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return Image(nsImage: image)
}

/// Pulls image file URLs out of a drag-and-drop.
func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, exts.contains(url.pathExtension.lowercased()) { urls.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
