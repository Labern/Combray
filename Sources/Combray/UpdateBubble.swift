import SwiftUI

/// The bottom-left "Update available" card — Combray's take on the Claude Desktop update bubble.
/// A big, **fixed-size** rounded panel so it's always fully visible and never gets clipped or squeezed:
/// a bold headline + version, a one-line "what's new" sentence from the release notes, and a clear
/// "Restart to update" call-to-action.
struct UpdateBubble: View {
    @ObservedObject var updater: Updater

    /// Fixed footprint — the card is always exactly this size, whatever the state or text.
    private let cardWidth: CGFloat = 440
    private let cardHeight: CGFloat = 168

    var body: some View {
        Group {
            if let info = updater.justUpdated {
                updatedCard(info)                       // just-updated → "Updated!" note (priority)
            } else if !updater.bubbleHidden {
                switch updater.state {
                case .downloading(let v): card(version: v, downloading: true)
                case .ready(let v):       card(version: v, downloading: false)
                case .installing(let v):  installingCard(v)
                case .idle:               EmptyView()
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updater.state)
        .animation(.easeInOut(duration: 0.2), value: updater.bubbleHidden)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updater.justUpdated)
    }

    /// The post-update confirmation: "Updated to Vx.y.z" + what changed. Dismiss with X (or it
    /// auto-hides after 20s).
    @ViewBuilder
    private func updatedCard(_ info: Updater.JustUpdated) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Theme.accentDeep)
                Text("Updated!").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                Text("V\(info.version)").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accentDeep)
                Spacer(minLength: 6)
                Button { updater.dismissUpdatedNote() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(TapStyle(scale: 0.8))
                .foregroundStyle(Theme.faint)
            }
            Text(info.summary ?? "Combray has been updated to the latest version.")
                .font(.system(size: 15)).foregroundStyle(Theme.faint)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18).padding(.horizontal, 22)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, lineWidth: 2.5))
                .shadow(color: Theme.accent.opacity(0.32), radius: 22, y: 7)
        )
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// Shown while the privileged installer runs (root-owned installs): the macOS password
    /// prompt belongs to this moment — the card says so, and isn't clickable.
    @ViewBuilder
    private func installingCard(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                ProgressView().controlSize(.small).tint(Theme.accentDeep)
                Text("Installing update").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                Text("V\(version)").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accentDeep)
                Spacer(minLength: 6)
            }
            Text("Enter your Mac password if asked — Combray will restart itself when it’s done.")
                .font(.system(size: 15)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18).padding(.horizontal, 22)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, lineWidth: 2.5))
                .shadow(color: Theme.accent.opacity(0.32), radius: 22, y: 7)
        )
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private func card(version: String, downloading: Bool) -> some View {
        let inner = VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                if downloading {
                    ProgressView().controlSize(.small).tint(Theme.accentDeep)
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Theme.accentDeep)
                }
                Text(downloading ? "Downloading update" : "Update available")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                Text("V\(version)")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accentDeep)
                Spacer(minLength: 6)
                Button { updater.hideBubble() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(TapStyle(scale: 0.8))
                .foregroundStyle(Theme.faint)
            }

            // A failed/cancelled privileged install takes over the summary line so the user
            // knows exactly what happened and that clicking again is the fix.
            Text(updater.installError
                    ?? updater.releaseSummary
                    ?? "A newer version of Combray is ready to install.")
                .font(.system(size: 15, weight: updater.installError == nil ? .regular : .semibold))
                .foregroundStyle(updater.installError == nil ? Theme.faint : Theme.accentDeep)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            if downloading {
                Text("Downloading in the background…")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.faint)
            } else {
                HStack(spacing: 8) {
                    Text("Restart to update").font(.system(size: 16, weight: .bold))
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Theme.accentDeep)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 22)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, lineWidth: 2.5))
                .shadow(color: Theme.accent.opacity(0.32), radius: 22, y: 7)
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
