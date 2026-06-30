import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Root

enum SidebarMode: String, CaseIterable, Identifiable {
    case letters = "Letters"
    case people = "People"
    case years = "Years"
    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var c: ArchiveController
    @State private var mode: SidebarMode = .letters
    @AppStorage("darkMode") private var darkMode = false
    @State private var showFeatureRequest = false
    @State private var showHelpDesk = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(mode: $mode)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            } detail: {
                DetailContainer()
            }
            .overlay(alignment: .bottom) { statusBar }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if c.isTranscribing {
                        TranscribeSpinner()
                    } else if c.transcribedFlash {
                        Label("Transcribed!", systemImage: "checkmark.circle.fill")
                            .font(Theme.small).foregroundStyle(Theme.accent)
                            .transition(.opacity.combined(with: .scale))
                    }
                    Button { showHelpDesk.toggle() } label: {
                        Image(systemName: "headset")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    .help("Ask Labern a question over WhatsApp.")
                    .popover(isPresented: $showHelpDesk, arrowEdge: .bottom) {
                        WhatsAppPopover(title: "Got a question about how it works?",
                                        blurb: "Ask anything about Combray — adding letters, transcribing, searching, and so on. This opens WhatsApp to send your question to Labern.",
                                        placeholder: "Type your question…",
                                        actionLabel: "Ask Labern",
                                        actionIcon: "paperplane.fill",
                                        send: { openWhatsApp("Combray question -- " + $0); showHelpDesk = false },
                                        cancel: { showHelpDesk = false })
                    }

                    Button { showFeatureRequest.toggle() } label: {
                        Label("Request feature", systemImage: "lightbulb")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Suggest a feature — sent to Labern over WhatsApp.")
                    .popover(isPresented: $showFeatureRequest, arrowEdge: .bottom) {
                        WhatsAppPopover(title: "Request a feature",
                                        blurb: "What would you like Combray to do? This opens WhatsApp to send your idea to Labern.",
                                        placeholder: "Describe the feature…",
                                        actionLabel: "Request feature",
                                        actionIcon: "paperplane.fill",
                                        send: { openWhatsApp("Combray feature request -- " + $0); showFeatureRequest = false },
                                        cancel: { showFeatureRequest = false })
                    }

                    Button { withAnimation(.easeInOut(duration: 0.25)) { darkMode.toggle() } } label: {
                        Image(systemName: darkMode ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentDeep)
                    }
                    .tip(darkMode ? "Switch to Light mode." : "Switch to Dark mode.")
                }
            }

            QuoteBar()
        }
        .background(Theme.bg)
        .preferredColorScheme(darkMode ? .dark : .light)
        .overlay {
            if let letter = c.fullSizeLetter {
                FullTranscriptionView(letter: letter).environmentObject(c)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: c.fullSizeLetter)
        .onAppear { installMadeleineDockIcon() }
        .sheet(isPresented: $c.showAddChoice) { AddLetterSheet().environmentObject(c) }
        .sheet(isPresented: $c.showReplaceChoice) { ReplaceChoiceSheet().environmentObject(c) }
        .sheet(isPresented: $c.showAddPageChoice) { AddPageChoiceSheet().environmentObject(c) }
        .sheet(isPresented: $c.showFindLetter) { FindLetterSheet().environmentObject(c) }
        .sheet(isPresented: $c.showCapture) { CaptureSheet().environmentObject(c) }
        .sheet(isPresented: $c.showSignIn) { SignInSheet().environmentObject(c) }
        .sheet(isPresented: $c.showSettings) { SettingsSheet().environmentObject(c) }
        .alert("Delete this letter?", isPresented: Binding(
            get: { c.pendingDeleteLetter != nil },
            set: { if !$0 { c.pendingDeleteLetter = nil } }
        ), presenting: c.pendingDeleteLetter) { letter in
            Button("Delete", role: .destructive) { c.deleteLetter(letter); c.pendingDeleteLetter = nil }
            Button("Cancel", role: .cancel) { c.pendingDeleteLetter = nil }
        } message: { _ in Text("Are you sure? This moves the letter and its images to the Trash.") }
        .alert("Delete this image?", isPresented: Binding(
            get: { c.pendingDeletePage != nil },
            set: { if !$0 { c.pendingDeletePage = nil } }
        ), presenting: c.pendingDeletePage) { page in
            Button("Delete", role: .destructive) { c.deletePage(page); c.pendingDeletePage = nil }
            Button("Cancel", role: .cancel) { c.pendingDeletePage = nil }
        } message: { _ in Text("Are you sure? This removes this page image. The other pages stay.") }
    }

    private func openHelpDesk() { openWhatsApp("Combray question -- ") }

    /// Opens the WhatsApp Mac app straight to a chat with Labern (the person this app is for),
    /// pre-filled with `text`. UK 07476 897931 → international 447476897931. Falls back to wa.me.
    private func openWhatsApp(_ text: String) {
        let phone = "447476897931"
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let app = URL(string: "whatsapp://send?phone=\(phone)&text=\(q)"),
           NSWorkspace.shared.open(app) { return }
        if let web = URL(string: "https://wa.me/\(phone)?text=\(q)") {
            NSWorkspace.shared.open(web)   // fallback if the WhatsApp app isn't installed
        }
    }

    @ViewBuilder private var statusBar: some View {
        if let busy = c.busy {
            HStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(busy).font(Theme.big)
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
        } else if c.transcribedFlash {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                Text("Transcribed!").font(Theme.big)
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let err = c.errorText {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(err).font(Theme.body).lineLimit(2)
                Button("Dismiss") { c.errorText = nil }.font(Theme.big)
            }
            .padding(.horizontal, 26).padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 24).frame(maxWidth: 620)
        }
    }
}

/// A gold ring that spins continuously while a transcription is running.
struct TranscribeSpinner: View {
    @State private var spin = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accent)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: spin)
            Text("Transcribing…").font(Theme.small).foregroundStyle(Theme.faint)
        }
        .onAppear { spin = true }
        .transition(.opacity.combined(with: .scale))
    }
}

/// A small pop-down from a toolbar button: a heading, a text field, and a send button that hands the
/// typed text to `send` (which composes a WhatsApp message to Labern). Used by HelpDesk and Request
/// feature.
struct WhatsAppPopover: View {
    let title: String
    let blurb: String
    let placeholder: String
    let actionLabel: String
    let actionIcon: String
    let send: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.title)
            Text(blurb).font(Theme.small).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.body).lineLimit(3...8)
                .focused($focused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            HStack {
                Button { cancel() } label: { Text("Cancel") }
                    .buttonStyle(BigButtonStyle(filled: false, compact: true))
                Spacer()
                Button { send(trimmed) } label: { Label(actionLabel, systemImage: actionIcon) }
                    .buttonStyle(BigButtonStyle(compact: true))
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
    }
}

