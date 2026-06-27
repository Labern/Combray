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
    case search = "Search"
    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var c: ArchiveController
    @State private var mode: SidebarMode = .letters

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(mode: $mode)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
            } detail: {
                DetailContainer()
            }
            .overlay(alignment: .bottom) { statusBar }

            QuoteBar()
        }
        .background(Theme.bg)
        .onAppear { installMadeleineDockIcon() }
        .sheet(isPresented: $c.showAddChoice) { AddLetterSheet().environmentObject(c) }
        .sheet(isPresented: $c.showCapture) { CaptureSheet().environmentObject(c) }
        .sheet(isPresented: $c.showSignIn) { SignInSheet().environmentObject(c) }
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

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var c: ArchiveController
    @Binding var mode: SidebarMode

    var body: some View {
        VStack(spacing: Theme.gap) {
            Button { c.goHome() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        MadeleineIcon().frame(width: 46, height: 46)
                        Text("Combray").font(Theme.wordmarkSmall)
                        Spacer()
                    }
                    Text("Upload letters, transcribe them, and store them.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
            }
            .buttonStyle(.plain)
            .help("Home")
            .padding([.horizontal, .top], Theme.gap)

            Button { c.showAddChoice = true } label: {
                Label("Add a Letter", systemImage: "plus.circle.fill")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))
            .padding(.horizontal, Theme.gap)

            list

            if mode == .search {
                TextField("Search all letters…", text: $c.searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.big)
                    .padding(.horizontal, Theme.gap)
                    .onChange(of: c.searchText) { _, _ in c.runSearch() }
            }

            ModeSelector(mode: $mode)
        }
        .background(Theme.bg)
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                switch mode {
                case .letters:
                    ForEach(c.letters) { letter in
                        LetterRow(letter: letter, selected: c.selectedLetterID == letter.id)
                            .onTapGesture { c.showLetter(letter.id) }
                    }
                case .people:
                    ForEach(c.people) { person in
                        PersonRow(person: person).onTapGesture { c.showPerson(person.id) }
                    }
                case .years:
                    ForEach(c.years, id: \.self) { year in
                        Text(String(year)).font(Theme.section)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        ForEach(c.letters.filter { $0.dateYear == year }) { letter in
                            LetterRow(letter: letter, selected: c.selectedLetterID == letter.id)
                                .onTapGesture { c.showLetter(letter.id) }
                        }
                    }
                case .search:
                    ForEach(c.hits, id: \.letterId) { hit in
                        SearchRow(hit: hit, letter: c.letters.first { $0.id == hit.letterId })
                            .onTapGesture { c.showLetter(hit.letterId) }
                    }
                }
            }
            .padding(.horizontal, Theme.gap)
            .padding(.bottom, Theme.gap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModeSelector: View {
    @Binding var mode: SidebarMode
    var body: some View {
        HStack(spacing: 6) {
            ForEach(SidebarMode.allCases) { m in
                Button { mode = m } label: {
                    Text(m.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == m ? Color.white : Theme.ink)
                .background(RoundedRectangle(cornerRadius: 9).fill(mode == m ? Theme.accent : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(mode == m ? Color.clear : Theme.line))
            }
        }
        .padding(.horizontal, Theme.gap)
        .padding(.bottom, Theme.gap)
    }
}

struct LetterRow: View {
    let letter: Letter
    var selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            MadeleineIcon().frame(width: 30, height: 30).opacity(0.9)
            VStack(alignment: .leading, spacing: 4) {
                Text(letter.title ?? "Untitled letter").font(Theme.big).lineLimit(1)
                Text(letter.dateValue ?? "—").font(Theme.small).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Theme.accent.opacity(0.15) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}

struct PersonRow: View {
    let person: Person
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text(person.displayName).font(Theme.big)
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct SearchRow: View {
    let hit: SearchHit
    let letter: Letter?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(letter?.title ?? "Untitled letter").font(Theme.big).lineLimit(1)
            Text(hit.snippet).font(Theme.small).foregroundStyle(Theme.faint).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

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
            Button { c.pickAndImport() } label: { Label("Choose photos from this Mac", systemImage: "photo.on.rectangle") }
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
    @State private var titleText = ""
    @State private var fromText = ""
    @State private var toText = ""
    @State private var dateText = ""
    @FocusState private var focus: MetaField?
    enum MetaField { case title, from, to, date }

    var body: some View {
        HSplitView {
            pages.frame(minWidth: 320)
            transcript.frame(minWidth: 440)
        }
        .onAppear(perform: syncFields)
        .onChange(of: letter.id) { _, _ in isEditing = false; syncFields() }
        .onChange(of: focus) { oldValue, _ in saveField(oldValue) }
        .sheet(isPresented: $showChat) { ChatSheet(letterID: letter.id).environmentObject(c) }
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
                ForEach(c.pages) { page in
                    if let image = loadImage(c.images.url(for: page)) {
                        ZoomableImage(image: image)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    }
                }
                if c.pages.isEmpty {
                    Text("No page images.").font(Theme.body).foregroundStyle(Theme.faint).padding(50)
                }
            }
            .padding(Theme.gap)
        }
        .background(Theme.surface)
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                TextField("Title", text: $titleText)
                    .font(Theme.title).textFieldStyle(.plain)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = nil }

                HStack(spacing: 26) {
                    metaField("From", text: $fromText, field: .from)
                    metaField("To", text: $toText, field: .to)
                    metaField("Date", text: $dateText, field: .date)
                }

                actions

                if let summary = letter.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary").font(Theme.label).foregroundStyle(Theme.faint)
                        Text(summary).font(Theme.body)
                    }.card()
                }

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
                    Button { draft = letter.transcription; isEditing = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(BigButtonStyle(filled: false))
                }

                MetaPanel(letter: letter)
            }
            .padding(Theme.pad)
        }
        .background(Theme.bg)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { Task { await c.transcribeSelected() } } label: {
                Label(letter.transcription.isEmpty ? "Transcribe" : "Re-transcribe", systemImage: "sparkles")
            }
            .buttonStyle(BigButtonStyle(fullWidth: true))

            HStack(spacing: 12) {
                if c.correspondence(forLetter: letter.id).count > 1 {
                    Button { showChat = true } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }.buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
                }
                Button { c.exportDOCX(letter) } label: { Label("Export", systemImage: "doc.richtext") }
                    .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
                Button { c.shareViaGmail(letter) } label: { Label("Share", systemImage: "paperplane") }
                    .buttonStyle(BigButtonStyle(filled: false, fullWidth: true))
            }
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
    var body: some View {
        DisclosureGroup {
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

// MARK: - Chat view

struct ChatSheet: View {
    @EnvironmentObject var c: ArchiveController
    let letterID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Correspondence").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(BigButtonStyle(filled: false))
            }.padding(Theme.pad)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let thread = c.correspondence(forLetter: letterID)
                    let focal = c.sender(ofLetter: letterID)?.id
                    ForEach(thread) { letter in
                        let s = c.sender(ofLetter: letter.id)
                        Bubble(letter: letter, senderName: s?.displayName ?? "Unknown", mine: s?.id == focal)
                    }
                }.padding(Theme.pad)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Theme.bg)
    }
}

struct Bubble: View {
    let letter: Letter
    let senderName: String
    let mine: Bool
    var body: some View {
        HStack {
            if mine { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(senderName).font(Theme.label)
                    Spacer()
                    Text(letter.dateValue ?? "").font(Theme.small).foregroundStyle(Theme.faint)
                }
                Text(letter.summary ?? String(letter.transcription.prefix(300))).font(Theme.body)
            }
            .padding(18)
            .frame(maxWidth: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(mine ? Theme.accent.opacity(0.16) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
            if !mine { Spacer(minLength: 80) }
        }
    }
}

// MARK: - Person detail (author view)

struct PersonDetailView: View {
    @EnvironmentObject var c: ArchiveController
    let person: Person

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 52)).foregroundStyle(Theme.accent)
                    Text(person.displayName).font(Theme.hero)
                }

                let correspondents = c.correspondents(of: person.id)
                if !correspondents.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wrote to / heard from").font(Theme.label).foregroundStyle(Theme.faint)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(correspondents) { p in
                                    Button { c.showPerson(p.id) } label: { Text(p.displayName).font(Theme.big) }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 18).padding(.vertical, 12)
                                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                                        .overlay(Capsule().stroke(Theme.accent.opacity(0.4)))
                                }
                            }
                        }
                    }.card()
                }

                Text("Letters, chronologically").font(Theme.section)
                ForEach(c.letters(forPerson: person.id)) { letter in
                    Button { c.showLetter(letter.id) } label: {
                        HStack(spacing: 12) {
                            MadeleineIcon().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(letter.title ?? "Untitled letter").font(Theme.big)
                                Text([letter.dateValue, letter.summary].compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.small).foregroundStyle(Theme.faint).lineLimit(2)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                }
            }
            .padding(Theme.pad)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var c: ArchiveController
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Connect Claude").font(Theme.title)
            Text("Combray uses Claude to read the handwriting. Sign in with your Claude account — or paste an API key. Either is stored only in your macOS Keychain, never in the app or the repo.")
                .font(Theme.body).foregroundStyle(Theme.faint)

            HStack(spacing: 14) {
                Button { c.startSignIn() } label: { Label("Sign in with Claude", systemImage: "person.crop.circle") }
                    .buttonStyle(BigButtonStyle())
                if c.hasAPIKey {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(Theme.big).foregroundStyle(.green)
                }
            }

            Divider().padding(.vertical, 4)
            Text("Or paste an API key").font(Theme.label).foregroundStyle(Theme.faint)
            HStack(spacing: 14) {
                SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder).font(Theme.big)
                Button { c.saveAPIKey(key); saved = true } label: { Label("Save", systemImage: "key.fill") }
                    .buttonStyle(BigButtonStyle(filled: false))
            }

            Divider().padding(.vertical, 8)
            Toggle(isOn: $c.autoTranscribe) {
                Text("Transcribe automatically when I add a letter").font(Theme.body)
            }
            .toggleStyle(.switch).controlSize(.large)
        }
        .padding(34)
        .frame(width: 600)
    }
}

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
    @State private var index = 0
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("\u{201C}\(ProustQuotes.all[index])\u{201D}  — Proust, In Search of Lost Time")
            .font(.system(size: 15)).italic()
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 11).padding(.horizontal, 24)
            .background(Theme.surface)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
            .id(index)
            .transition(.opacity)
            .onReceive(timer) { _ in
                withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % ProustQuotes.all.count }
            }
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

// MARK: - Helpers

func loadImage(_ url: URL) -> Image? {
    NSImage(contentsOf: url).map { Image(nsImage: $0) }
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

            Button { c.stopCapture() } label: { Text("Done") }.buttonStyle(BigButtonStyle())
        }
        .padding(36)
        .frame(minWidth: 480, minHeight: 540)
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
