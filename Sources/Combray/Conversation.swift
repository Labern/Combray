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

