import SwiftUI

/// The little bottom-left "Update available" pill — Combray's take on the Claude Desktop update bubble.
/// Appears only while an update is downloading or staged; clicking the staged pill restarts into it.
struct UpdateBubble: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            if !updater.bubbleHidden {
                switch updater.state {
                case .downloading(let v):
                    pill(text: "Downloading update — V\(v)", spinner: true, dismissable: false, action: nil)
                case .ready(let v):
                    pill(text: "Restart to update — V\(v)", spinner: false, dismissable: true) { updater.installNow() }
                case .idle:
                    EmptyView()
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updater.state)
        .animation(.easeInOut(duration: 0.2), value: updater.bubbleHidden)
    }

    @ViewBuilder
    private func pill(text: String, spinner: Bool, dismissable: Bool, action: (() -> Void)?) -> some View {
        let content = HStack(spacing: 9) {
            if spinner {
                ProgressView().controlSize(.small).tint(Theme.accentDeep)
            } else {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 15, weight: .semibold))
            }
            Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if dismissable {
                Button { updater.hideBubble() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(TapStyle(scale: 0.8))
                .foregroundStyle(Theme.faint)
                .padding(.leading, 2)
            }
        }
        .foregroundStyle(Theme.accentDeep)
        .padding(.vertical, 9).padding(.horizontal, 14)
        .background(
            Capsule().fill(Theme.surface)
                .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
                .shadow(color: Theme.accent.opacity(0.25), radius: 12, y: 4)
        )

        if let action {
            Button(action: action) { content }
                .buttonStyle(TapStyle(scale: 0.96))
                .help("Restart Combray to finish updating. Your letters are untouched.")
                .transition(.move(edge: .leading).combined(with: .opacity))
        } else {
            content.transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}
