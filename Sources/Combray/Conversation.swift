import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

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

// MARK: - Ask about the transcription (AI chat)

/// A single chat window for querying the selected letter's transcription. The user asks questions
/// ("this part looks wrong — what do you think?"); Claude replies and, when warranted, proposes a
/// full revised transcription the user can Apply or keep.
struct AskSheet: View {
    @EnvironmentObject var c: ArchiveController
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [AskTurn] = []
    @State private var input = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    struct AskTurn: Identifiable {
        let id = UUID()
        let role: String            // "user" | "assistant"
        var text: String
        var suggestion: String?
        var applied = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask about the transcription").font(Theme.title)
                    Text("Point at anything that looks wrong — Claude can suggest a fix.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(BigButtonStyle(filled: false))
            }.padding(Theme.pad)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty { emptyState }
                        ForEach(turns) { turn in askBubble(turn).id(turn.id) }
                        if sending {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Claude is reading…").font(Theme.small).foregroundStyle(Theme.faint)
                            }.id("typing")
                        }
                    }
                    .padding(Theme.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo(turns.last?.id, anchor: .bottom) } }
                .onChange(of: sending) { _, s in if s { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } } }
            }

            Divider()
            inputBar
        }
        .frame(minWidth: 640, minHeight: 580)
        .background(Theme.bg)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For example:").font(Theme.label).foregroundStyle(Theme.faint)
            ForEach(["The third line looks wrong — what do you think it says?",
                     "Does the closing make sense as transcribed?",
                     "Fix any obvious misreadings you can spot."], id: \.self) { ex in
                Button { input = ex; focused = true } label: {
                    Text("\u{201C}\(ex)\u{201D}").font(Theme.body).foregroundStyle(Theme.accentDeep)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TapStyle(scale: 0.99))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    @ViewBuilder private func askBubble(_ turn: AskTurn) -> some View {
        let mine = turn.role == "user"
        HStack {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 12) {
                Text(turn.text).font(Theme.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let suggestion = turn.suggestion { suggestionCard(turn, suggestion) }
            }
            .padding(16).frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(mine ? Theme.accent.opacity(0.16) : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            if !mine { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder private func suggestionCard(_ turn: AskTurn, _ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Proposed correction", systemImage: "wand.and.stars")
                .font(Theme.label).foregroundStyle(Theme.accentDeep)
            Text(suggestion).font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            if turn.applied {
                Label("Applied to the transcription", systemImage: "checkmark.circle.fill")
                    .font(Theme.small).foregroundStyle(Theme.accentDeep)
            } else {
                HStack(spacing: 10) {
                    Button { apply(turn, suggestion) } label: { Label("Apply", systemImage: "checkmark") }
                        .buttonStyle(BigButtonStyle(compact: true))
                    Button { dismissSuggestion(turn) } label: { Text("Keep as is") }
                        .buttonStyle(BigButtonStyle(filled: false, compact: true))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.35)))
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Ask a question about this transcription…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.body).lineLimit(1...5)
                .focused($focused).onSubmit(send)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundStyle(canSend ? Theme.accent : Theme.faint)
            }
            .buttonStyle(TapStyle()).disabled(!canSend)
        }
        .padding(Theme.pad)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        turns.append(AskTurn(role: "user", text: q, suggestion: nil))
        input = ""
        sending = true
        let history = turns.map { (role: $0.role, text: $0.text) }
        Task {
            let result = await c.askAboutTranscription(history)
            await MainActor.run {
                sending = false
                if let result {
                    turns.append(AskTurn(role: "assistant", text: result.reply, suggestion: result.suggestion))
                }
            }
        }
    }

    private func apply(_ turn: AskTurn, _ suggestion: String) {
        c.saveTranscription(suggestion)
        if let i = turns.firstIndex(where: { $0.id == turn.id }) { turns[i].applied = true }
    }

    private func dismissSuggestion(_ turn: AskTurn) {
        if let i = turns.firstIndex(where: { $0.id == turn.id }) { turns[i].suggestion = nil }
    }
}

// MARK: - Find a specific letter (AI search)

/// An intelligent search window: the user describes what they're after (kind, theme, period, writer,
/// or a pair) and Claude returns the matching letters as clickable links.
struct FindLetterSheet: View {
    @EnvironmentObject var c: ArchiveController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searching = false
    @State private var didSearch = false
    @State private var results: [Match] = []
    @FocusState private var focused: Bool

    struct Match: Identifiable { let id: String; let title: String; let reason: String }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find a specific letter").font(Theme.title)
                    Text("Describe what you're after — a kind, theme, period, writer, or a pair of people.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(BigButtonStyle(filled: false))
            }.padding(Theme.pad)
            Divider()

            HStack(spacing: 12) {
                TextField("e.g. \u{201C}angry letters from the 1960s\u{201D}, \u{201C}anything between Marcel and Eleanor\u{201D}…",
                          text: $query, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.body).lineLimit(1...4)
                    .focused($focused).onSubmit(run)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                Button(action: run) { Label("Find", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(BigButtonStyle(compact: true)).disabled(!canSearch)
            }.padding(Theme.pad)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if searching {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Searching the archive…").font(Theme.small).foregroundStyle(Theme.faint)
                        }
                    } else if didSearch && results.isEmpty {
                        Text("No matches. Try describing it a different way.")
                            .font(Theme.body).foregroundStyle(Theme.faint)
                    }
                    ForEach(results) { m in
                        Button { c.showLetter(m.id); dismiss() } label: {
                            HStack(spacing: 12) {
                                MadeleineIcon().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(m.title).font(Theme.big)
                                    Text(m.reason).font(Theme.small).foregroundStyle(Theme.faint).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.faint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TapStyle(scale: 0.985))
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    }
                }
                .padding(Theme.pad).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 660, minHeight: 600)
        .background(Theme.bg)
        .onAppear { focused = true }
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !searching
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        searching = true; didSearch = true
        Task {
            let found = await c.findLetters(q)
            await MainActor.run {
                results = found.map { Match(id: $0.letter.id, title: $0.letter.title ?? "Untitled letter", reason: $0.reason) }
                searching = false
            }
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
                                        .buttonStyle(TapStyle(scale: 0.91))
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
                    .buttonStyle(TapStyle(scale: 0.985))
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                }
            }
            .padding(Theme.pad)
        }
    }
}

