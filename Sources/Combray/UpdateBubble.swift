import SwiftUI

/// The bottom-left "Update available" card — Combray's take on the Claude Desktop update bubble.
/// A deliberately big, rectangular panel: a bold headline + version, a one-line "what's new" sentence
/// pulled from the release notes, and a clear "Restart to update" call-to-action.
struct UpdateBubble: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            if !updater.bubbleHidden {
                switch updater.state {
                case .downloading(let v): card(version: v, downloading: true)
                case .ready(let v):       card(version: v, downloading: false)
                case .idle:               EmptyView()
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updater.state)
        .animation(.easeInOut(duration: 0.2), value: updater.bubbleHidden)
    }

    @ViewBuilder
    private func card(version: String, downloading: Bool) -> some View {
        let inner = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if downloading {
                    ProgressView().controlSize(.small).tint(Theme.accentDeep)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accentDeep)
                }
                Text(downloading ? "Downloading update" : "Update available")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                Text("V\(version)")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accentDeep)
                Spacer(minLength: 6)
                Button { updater.hideBubble() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(TapStyle(scale: 0.8))
                .foregroundStyle(Theme.faint)
            }

            if let s = updater.releaseSummary, !s.isEmpty {
                Text(s)
                    .font(.system(size: 14)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            if !downloading {
                HStack(spacing: 7) {
                    Text("Restart to update").font(.system(size: 15, weight: .bold))
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Theme.accentDeep)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 20)
        .frame(width: 380, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accent, lineWidth: 2))
                .shadow(color: Theme.accent.opacity(0.30), radius: 18, y: 6)
        )

        if downloading {
            inner.transition(.move(edge: .leading).combined(with: .opacity))
        } else {
            Button { updater.installNow() } label: { inner }
                .buttonStyle(TapStyle(scale: 0.98))
                .help("Restart Combray to finish updating. Your letters are untouched.")
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}
