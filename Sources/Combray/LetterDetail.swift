import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Detail container

struct DetailContainer: View {
    @EnvironmentObject var c: ArchiveController
    var body: some View {
        Group {
            if let letter = c.selectedLetter {
                LetterDetailView(letter: letter)
            } else if let pid = c.focusedPersonID, let person = c.people.first(where: { $0.id == pid }) {
                PersonDetailView(person: person)
            } else {
                ExplainerView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - Explainer (right pane, default)

struct ExplainerView: View {
    @EnvironmentObject var c: ArchiveController
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            MadeleineIcon().frame(width: 150, height: 120)
            VStack(spacing: 10) {
                Text("Combray").font(Theme.wordmark)
                Text("One bite of the madeleine brings it all back.")
                    .font(Theme.sans(20)).italic().foregroundStyle(Theme.faint)
            }
            Button { c.startCapture() } label: { Label("Take photos with iPhone", systemImage: "iphone") }
                .buttonStyle(BigButtonStyle())
                .padding(.top, 4)
            Button { c.pickAndImport() } label: {
                Label("Choose photos from this Mac", systemImage: "photo.on.rectangle")
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(BigButtonStyle(filled: false))
            Text("or drag photos of a letter here")
                .font(Theme.small).foregroundStyle(Theme.faint)
            if !c.hasAPIKey {
                Button { c.startSignIn() } label: {
                    Label("Sign in with Claude", systemImage: "person.crop.circle")
                }
                .buttonStyle(BigButtonStyle(filled: false))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? Theme.accent.opacity(0.06) : Theme.bg)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(28)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            loadDroppedURLs(providers) { urls in if !urls.isEmpty { c.importLetter(from: urls) } }
            return true
        }
    }
}

// MARK: - Letter detail (side-by-side)

struct LetterDetailView: View {
    @EnvironmentObject var c: ArchiveController
    let letter: Letter
    @State private var draft: String = ""
    @State private var isEditing = false
    @State private var showChat = false
    @State private var showAsk = false
    @State private var copied = false
    @State private var titleText = ""
    @State private var fromText = ""
    @State private var toText = ""
    @State private var dateText = ""
    @State private var paneWidth: CGFloat = 0
    @State private var droppingPage = false
    @FocusState private var focus: MetaField?
    enum MetaField { case title, from, to, date }

    /// When the transcription pane is narrow, rows of fields/buttons stack vertically (responsive).
    private var stacked: Bool { paneWidth > 0 && paneWidth < 560 }
    /// Keep the action buttons HORIZONTAL; only stack them when the pane is genuinely tiny.
    /// (Labels shrink-to-fit via BigButtonStyle's minimumScaleFactor so the row stays clean.)
    private var actionsStacked: Bool { paneWidth > 0 && paneWidth < 340 }

    var body: some View {
        HSplitView {
            pages.frame(minWidth: 220)
            transcript.frame(minWidth: 300)
        }
        .onAppear(perform: syncFields)
        .onChange(of: letter.id) { _, _ in isEditing = false; syncFields() }
        .onChange(of: focus) { oldValue, _ in saveField(oldValue) }
        .onChange(of: letter.updatedAt) { _, _ in if focus == nil { syncFields() } }
        .sheet(isPresented: $showChat) { ChatSheet(letterID: letter.id).environmentObject(c) }
        .sheet(isPresented: $showAsk) { AskSheet().environmentObject(c) }
    }

    private func syncFields() {
        titleText = letter.title ?? ""
        fromText = c.sender?.displayName ?? ""
        toText = c.recipients.map(\.displayName).joined(separator: ", ")
        dateText = letter.dateValue ?? ""
    }

    /// Saves whichever field just lost focus (on Enter or tap-away).
    private func saveField(_ field: MetaField?) {
        switch field {
        case .title:
            var l = letter
            l.title = titleText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : titleText
            if l.title != letter.title { c.update(l) }
        case .from:
            c.updateParticipants(sender: fromText, recipients: c.recipients.map(\.displayName))
        case .to:
            c.updateParticipants(sender: c.sender?.displayName,
                                 recipients: toText.split(separator: ",").map(String.init))
        case .date:
            c.updateDate(dateText)
        case nil:
            break
        }
    }

    private func metaField(_ label: String, text: Binding<String>, field: MetaField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.label).foregroundStyle(Theme.faint)
            TextField(label, text: text)
                .font(Theme.body).textFieldStyle(.plain)
                .focused($focus, equals: field)
                .onSubmit { focus = nil }
        }
    }

    private var pages: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                ForEach(Array(c.pages.enumerated()), id: \.element.id) { idx, page in
                    if let image = loadImage(c.images.url(for: page)) {
                        VStack(spacing: 8) {
                            ZoomableImage(image: image)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                                .contextMenu {
                                    Button { c.beginReplace(page) } label: {
                                        Label("Replace image…", systemImage: "photo.on.rectangle")
                                    }
                                    Button(role: .destructive) { c.pendingDeletePage = page } label: {
                                        Label("Delete image", systemImage: "trash")
                                    }
                                }
                            pageControls(page, number: idx + 1)
                        }
                    }
                }
                if c.pages.isEmpty {
                    Text("No page images yet — add the first below.")
                        .font(Theme.body).foregroundStyle(Theme.faint).padding(.vertical, 30)
                }
                addPageButton
            }
            .padding(Theme.gap)
        }
        .background(Theme.surface)
    }

    /// Subtle per-page strip beneath each image: which page it is, plus visible Replace / Remove.
    private func pageControls(_ page: Page, number: Int) -> some View {
        HStack(spacing: 16) {
            Text("Page \(number)").foregroundStyle(Theme.faint)
            Spacer()
            Button { c.beginReplace(page) } label: {
                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(TapStyle())
            .foregroundStyle(Theme.accentDeep)
            .help("Swap in a better-quality photo of this page")
            Button { c.pendingDeletePage = page } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(TapStyle())
            .foregroundStyle(.red)
            .help("Remove this page from the letter")
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 4)
    }

    /// The dashed "＋ Add page" button under the last page — appends new photos to this letter.
    /// Also accepts dropped image files for the same effect.
    private var addPageButton: some View {
        Button { c.addPagesWithPicker() } label: {
            Label(c.pages.isEmpty ? "Add a page" : "Add page", systemImage: "plus")
                .font(Theme.label)
                .foregroundStyle(Theme.accentDeep)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        }
        .buttonStyle(TapStyle(scale: 0.98))
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(droppingPage ? Theme.accent.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(droppingPage ? Theme.accent : Theme.line,
                    style: StrokeStyle(lineWidth: 2, dash: [8])))
        .onDrop(of: [.fileURL], isTargeted: $droppingPage) { providers in
            loadDroppedURLs(providers) { urls in if !urls.isEmpty { c.addPages(from: urls) } }
            return true
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                TextField("Title", text: $titleText, axis: .vertical)
                    .font(.system(size: 26, weight: .semibold)).textFieldStyle(.plain)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = nil }

                let fieldsLayout = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                fieldsLayout {
                    metaField("From", text: $fromText, field: .from)
                    metaField("To", text: $toText, field: .to)
                    metaField("Date", text: $dateText, field: .date)
                }

                actions

                Text("Transcription").font(Theme.label).foregroundStyle(Theme.faint)
                if isEditing {
                    TextEditor(text: $draft)
                        .font(.system(size: 18))
                        .frame(minHeight: 360)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    HStack(spacing: 12) {
                        Button { isEditing = false } label: { Text("Cancel") }
                            .buttonStyle(BigButtonStyle(filled: false))
                        Button { c.saveTranscription(draft); isEditing = false } label: {
                            Label("Save", systemImage: "checkmark")
                        }
                        .buttonStyle(BigButtonStyle())
                    }
                } else if letter.transcription.isEmpty {
                    Text("Not transcribed yet — press Transcribe above.")
                        .font(Theme.body).foregroundStyle(Theme.faint).italic()
                } else {
                    Text(letter.transcription)
                        .font(.system(size: 19))
                        .lineSpacing(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Button { showAsk = true } label: {
                            Label("Ask about the transcription", systemImage: "text.bubble")
                        }
                        .buttonStyle(BigButtonStyle())
                        Button { draft = letter.transcription; isEditing = true } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(BigButtonStyle(filled: false))
                    }
                }

                if let summary = letter.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary").font(Theme.label).foregroundStyle(Theme.faint)
                        Text(summary).font(Theme.body)
                    }.card()
                }

                if let quotes = letter.notableQuotes?
                    .split(separator: "\n").map(String.init).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }), !quotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notable quotes").font(Theme.label).foregroundStyle(Theme.faint)
                        ForEach(quotes, id: \.self) { q in
                            Text("\u{201C}\(q)\u{201D}").font(Theme.body).italic()
                        }
                    }.card()
                }

                MetaPanel(letter: letter)
            }
            .padding(Theme.pad)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { paneWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in paneWidth = w }
            })
        }
        .background(Theme.bg)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { Task { await c.transcribeSelected() } } label: {
                Label(letter.transcription.isEmpty ? "Transcribe" : "Re-transcribe", systemImage: "sparkles")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))

            let actionsLayout = actionsStacked
                ? AnyLayout(VStackLayout(spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            actionsLayout {
                if c.correspondence(forLetter: letter.id).count > 1 {
                    Button { showChat = true } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }.buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
                }
                Button { copyTranscript() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
                .disabled(letter.transcription.isEmpty)
                Button { c.exportDOCX(letter) } label: { Label("Export", systemImage: "doc.richtext") }
                    .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
                Button { c.shareViaGmail(letter) } label: { Label("Share", systemImage: "paperplane") }
                    .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
            }

            if copied {
                Label("Copied to clipboard — paste wherever!", systemImage: "checkmark.circle.fill")
                    .font(Theme.label)
                    .foregroundStyle(Theme.accentDeep)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent, lineWidth: 1.5))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: copied)
    }

    /// Copies the full transcription to the clipboard and flashes a confirmation.
    private func copyTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(letter.transcription, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            copied = false
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.label).foregroundStyle(Theme.faint)
            Text(value).font(Theme.body)
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { letter.title ?? "" },
            set: { var l = letter; l.title = $0.isEmpty ? nil : $0; c.update(l) }
        )
    }
}

struct MetaPanel: View {
    let letter: Letter
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                metaRow("Possible location", letter.metaLocation)
                metaRow("Likely relationship", letter.metaRelationship)
                metaRow("State of the relationship", letter.metaRelationshipState)
                metaRow("Writer's goals", letter.metaWriterGoals)
            }
            .padding(.top, 10)
        } label: {
            Text("Meta — what the letter quietly reveals").font(Theme.big).foregroundStyle(Theme.faint)
        }
        .card()
    }
    @ViewBuilder private func metaRow(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.label).foregroundStyle(Theme.faint)
            Text(value ?? "—").font(Theme.body)
        }
    }
}

