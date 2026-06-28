import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import CombrayCore

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var c: ArchiveController
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            // MARK: Account
            Text("Claude account").font(Theme.title)
            HStack(spacing: 12) {
                Image(systemName: c.hasAPIKey ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .font(.title2).foregroundStyle(c.hasAPIKey ? .green : Theme.faint)
                Text(c.accountSummary).font(Theme.body)
                Spacer()
            }
            HStack(spacing: 14) {
                Button { c.startSignIn() } label: {
                    Label(c.hasAPIKey ? "Switch account" : "Sign in with Claude", systemImage: "person.crop.circle")
                }.buttonStyle(BigButtonStyle())
                if c.hasAPIKey {
                    Button { c.disconnect() } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }.buttonStyle(BigButtonStyle(filled: false))
                }
            }
            Text("Stored only in a private file on this Mac — never in the app or the repo.")
                .font(Theme.small).foregroundStyle(Theme.faint)

            DisclosureGroup {
                HStack(spacing: 14) {
                    SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder).font(Theme.big)
                    Button { c.saveAPIKey(key); saved = true } label: { Label("Save", systemImage: "key.fill") }
                        .buttonStyle(BigButtonStyle(filled: false))
                }.padding(.top, 8)
            } label: {
                Text("Use an API key instead").font(Theme.label).foregroundStyle(Theme.faint)
            }

            Divider().padding(.vertical, 4)

            // MARK: Model
            Text("Transcription model").font(Theme.label).foregroundStyle(Theme.faint)
            Picker("", selection: $c.transcriptionModel) {
                ForEach(TranscriptionModel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(c.transcriptionModel.detail).font(Theme.small).foregroundStyle(Theme.faint)

            Divider().padding(.vertical, 4)

            // MARK: Web viewer
            Text("View on the web").font(Theme.label).foregroundStyle(Theme.faint)
            HStack(spacing: 14) {
                Button { c.showOnWeb() } label: { Label("Show on web", systemImage: "safari") }
                    .buttonStyle(BigButtonStyle())
                if let url = c.webURL {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                        if let lan = c.webLanURL {
                            Text("On your Wi-Fi: \(lan)").font(Theme.small).foregroundStyle(Theme.faint).textSelection(.enabled)
                        }
                    }
                }
            }
            Text("Runs a private viewer on this Mac while Combray is open — your documents stay on your machine.")
                .font(Theme.small).foregroundStyle(Theme.faint)

            Divider().padding(.vertical, 4)

            Toggle(isOn: $c.autoTranscribe) {
                Text("Transcribe automatically when I add a letter").font(Theme.body)
            }
            .toggleStyle(.switch).controlSize(.large)
        }
        .padding(34)
        .frame(width: 600)
    }
}

/// Settings presented as a sheet from the sidebar cog (separate from the ⌘, Settings window).
struct SettingsSheet: View {
    @EnvironmentObject var c: ArchiveController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape.fill").font(Theme.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(BigButtonStyle(filled: false))
            }
            .padding(.horizontal, Theme.pad).padding(.vertical, 18)
            Divider()
            ScrollView { SettingsView().environmentObject(c) }
        }
        .frame(width: 660, height: 660)
        .background(Theme.bg)
    }
}

