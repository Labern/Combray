import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Big right-click menu

/// A transparent overlay that turns left-clicks into "open" and right-clicks into "show menu".
/// We need AppKit here because SwiftUI has no right-click gesture; the menu itself is a normal
/// SwiftUI popover (`LetterActionsMenu`), so it can be as big and as styled as we like.
struct RowClickCatcher: NSViewRepresentable {
    var onLeftClick: () -> Void
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = Catcher()
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? Catcher else { return }
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
    }

    final class Catcher: NSView {
        var onLeftClick: () -> Void = {}
        var onRightClick: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onLeftClick() }
        override func rightMouseDown(with event: NSEvent) { onRightClick() }
    }
}

/// A row in the sidebar (letter or search hit) with a big right-click action popover.
struct SidebarRow<Content: View>: View {
    @EnvironmentObject var c: ArchiveController
    let letter: Letter
    let onOpen: () -> Void
    @ViewBuilder var content: Content
    @State private var showMenu = false

    var body: some View {
        content
            .overlay(RowClickCatcher(onLeftClick: onOpen, onRightClick: { showMenu = true }))
            .popover(isPresented: $showMenu, arrowEdge: .trailing) {
                LetterActionsMenu(letter: letter) { showMenu = false }
                    .environmentObject(c)
            }
    }
}

/// The big, legible right-click menu — real SwiftUI buttons, large font (per the app's BIG-type ethos).
struct LetterActionsMenu: View {
    @EnvironmentObject var c: ArchiveController
    let letter: Letter
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item(letter.pinned ? "Unpin" : "Pin to top", letter.pinned ? "pin.slash" : "pin") {
                c.togglePin(letter)
            }
            item(letter.transcription.isEmpty ? "Transcribe" : "Re-transcribe", "sparkles") {
                c.showLetter(letter.id); Task { await c.transcribe(letterId: letter.id) }
            }
            item("Copy transcription", "doc.on.doc", disabled: letter.transcription.isEmpty) {
                c.copyTranscription(letter)
            }
            item("Export as .docx", "doc.richtext") { c.exportDOCX(letter) }
            item("Reveal in Finder", "folder") { c.revealInFinder(letter) }
            Divider().padding(.vertical, 5)
            item("Delete letter", "trash", destructive: true) { c.pendingDeleteLetter = letter }
        }
        .padding(8)
        .frame(width: 320)
    }

    @ViewBuilder
    private func item(_ title: String, _ icon: String,
                      destructive: Bool = false, disabled: Bool = false,
                      _ action: @escaping () -> Void) -> some View {
        Button { action(); close() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 26)
                Text(title).font(.system(size: 20, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuItemStyle(destructive: destructive))
        .disabled(disabled)
    }
}

/// Hover/press highlight for the big menu rows.
struct MenuItemStyle: ButtonStyle {
    var destructive = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.red : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill((hovering || configuration.isPressed) ? Theme.accent.opacity(0.16) : Color.clear))
            .onHover { hovering = $0 }
    }
}

