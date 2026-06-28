import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var c: ArchiveController
    @Binding var mode: SidebarMode
    @State private var sidebarWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: Theme.gap) {
            Button { c.goHome() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        MadeleineIcon().frame(width: 46, height: 46)
                        Text("Combray").font(Theme.wordmarkSmall)
                        Spacer()
                    }
                    Text("Upload letters and documents, transcribe them, and store them.")
                        .font(Theme.small).foregroundStyle(Theme.faint)
                }
            }
            .buttonStyle(TapStyle(scale: 0.96))
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

            sidebarFooter
        }
        .background(Theme.bg)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { sidebarWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in sidebarWidth = w }
        })
    }

    /// Bottom strip: a Settings cog (bottom-left) + how many letters (or "Showing X of Y" in search).
    private var sidebarFooter: some View {
        HStack {
            Button { c.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(Theme.small)
            }
            .buttonStyle(TapStyle(scale: 0.92))
            .foregroundStyle(Theme.faint)
            .help("Settings — account, transcription model, options")

            Spacer()

            Text(countLabel)
                .font(Theme.small).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, Theme.gap)
        .padding(.bottom, 16)
    }

    private var countLabel: String {
        let total = c.letters.count
        switch mode {
        case .letters:
            return "\(total) letter\(total == 1 ? "" : "s")"
        case .search:
            if c.searchText.trimmingCharacters(in: .whitespaces).isEmpty { return "\(total) letters" }
            return "Showing \(c.hits.count) of \(total) letters"
        case .people:
            let p = c.people.count
            return "\(p) \(p == 1 ? "person" : "people") · \(total) letters"
        case .years:
            let y = c.years.count
            return "\(total) letter\(total == 1 ? "" : "s") · \(y) year\(y == 1 ? "" : "s")"
        }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                switch mode {
                case .letters:
                    let pinned = c.letters.filter(\.pinned)
                    let rest = c.letters.filter { !$0.pinned }
                    ForEach(pinned) { letterRowItem($0) }
                    if !pinned.isEmpty && !rest.isEmpty {
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(rest) { letterRowItem($0) }
                case .people:
                    ForEach(c.people) { person in
                        PersonRow(person: person).onTapGesture { c.showPerson(person.id) }
                    }
                case .years:
                    ForEach(c.years, id: \.self) { year in
                        Text(String(year)).font(Theme.section)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        ForEach(c.letters.filter { $0.dateYear == year }) { letterRowItem($0) }
                    }
                case .search:
                    ForEach(c.hits, id: \.letterId) { hit in
                        let letter = c.letters.first { $0.id == hit.letterId }
                        if let letter {
                            SidebarRow(letter: letter, onOpen: { c.showLetter(hit.letterId) }) {
                                SearchRow(hit: hit, letter: letter)
                            }
                        } else {
                            SearchRow(hit: hit, letter: nil)
                                .onTapGesture { c.showLetter(hit.letterId) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gap)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tappable letter row with the big right-click action popover attached.
    @ViewBuilder private func letterRowItem(_ letter: Letter) -> some View {
        let parts = c.participantsByLetter[letter.id]
        SidebarRow(letter: letter, onOpen: { c.showLetter(letter.id) }) {
            LetterRow(letter: letter, selected: c.selectedLetterID == letter.id,
                      titleSize: titleFontSize, from: parts?.from, to: parts?.to)
        }
    }

    /// Letter-title font shrinks as the sidebar is narrowed (dragged left).
    private var titleFontSize: CGFloat { min(17, max(13, sidebarWidth * 0.047)) }
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
                .buttonStyle(TapStyle(scale: 0.93))
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
    var titleSize: CGFloat = 17
    var from: String? = nil
    var to: String? = nil

    /// "FROM → TO  |  DATE" when both a sender and recipient exist; otherwise just the (pretty) date.
    private var subtitle: String {
        let date = DateDisplay.pretty(letter.dateValue)
        let f = from?.trimmingCharacters(in: .whitespaces)
        let t = to?.trimmingCharacters(in: .whitespaces)
        if let f, !f.isEmpty, let t, !t.isEmpty {
            return date.map { "\(f) → \(t)  |  \($0)" } ?? "\(f) → \(t)"
        }
        return date ?? "—"
    }

    var body: some View {
        HStack(spacing: 12) {
            if letter.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(45))
                    .help("Pinned")
            }
            MadeleineIcon().frame(width: 30, height: 30).opacity(0.9)
            VStack(alignment: .leading, spacing: 4) {
                Text(letter.title ?? "Untitled letter")
                    .font(.system(size: titleSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: max(11, titleSize - 3)))
                    .foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(
            selected ? Theme.accent.opacity(0.15) : (letter.pinned ? Theme.accent.opacity(0.08) : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            selected ? Theme.accent : (letter.pinned ? Theme.accent.opacity(0.55) : Theme.line),
            lineWidth: selected ? 2 : 1))
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

