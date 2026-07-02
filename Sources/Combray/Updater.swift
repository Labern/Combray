import Foundation
import AppKit
import Combine
import CombrayCore

/// Watches the GitHub repo for a newer release and installs it — like the Claude Desktop updater.
///
/// Install strategy (robust across how Combray was installed):
/// - It downloads BOTH the signed `Combray.zip` (app bundle) and `Combray.pkg`.
/// - If `/Applications/Combray.app` is **user-owned** (drag-installed), it swaps the bundle in place
///   with no prompt.
/// - If it's **root-owned** (installed via the `.pkg` or Homebrew — the common case), an in-place
///   swap can't touch root files, so it runs the `.pkg` through the privileged installer with a
///   single admin-password prompt. (This is why the old in-place-only updater silently failed for
///   pkg installs.)
/// - It only ever touches the **app bundle** — never the user's letters — so no data can be lost.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle                          // nothing to do (current, or still checking)
        case downloading(version: String)  // a newer release is being fetched in the background
        case ready(version: String)        // staged and ready — click to restart, or it applies on quit
        case installing(version: String)   // privileged install running — the password prompt is up
    }

    /// Shown briefly after the app has just been updated (auto OR manual) — "Updated to Vx.y.z".
    struct JustUpdated: Equatable { let version: String; var summary: String? }

    @Published private(set) var state: State = .idle
    @Published private(set) var releaseSummary: String?   // "what's new" line from the release notes
    @Published var bubbleHidden = false     // user dismissed the "update available" bubble this run
    @Published var justUpdated: JustUpdated?              // non-nil → show the "Updated!" bubble
    @Published var installError: String?    // a privileged install failed/was cancelled — shown in the bubble

    private let repo = "Labern/Combray"
    private var timer: Timer?
    private var stagedApp: URL?             // unzipped Combray.app waiting to be installed
    private var stagedPkg: URL?             // Combray.pkg, for the privileged (root-owned) install path
    private var swapLaunched = false        // the detached install script has been kicked off

    init() {}
    /// Build an updater pinned to a fixed state — used only to render preview screenshots.
    init(previewState: State, summary: String? = nil) { state = previewState; releaseSummary = summary }

    // MARK: lifecycle

    /// Begin checking: once now, then every 20 minutes. Also arms the apply-on-quit hook.
    /// No-op for un-installed dev builds (`swift run`) so they never nag or try to self-swap.
    func start() {
        guard installedAppURL != nil else { return }
        detectJustUpdated()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applyStagedUpdateOnQuit() } }

        timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
        Task { await check() }
    }

    /// The currently-running app version, read from the bundle (the `Vx.y.z` shown in the footer).
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// The installed bundle to replace, or nil when running un-bundled (`swift run`) — which disables updates.
    var installedAppURL: URL? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }

    // MARK: "Updated!" note

    private let lastVersionKey = "Combray.lastLaunchedVersion"

    /// On launch, compare the stored last-run version with the running one; if it went UP, the app was
    /// just updated (by either path) — fetch that version's notes and show the "Updated!" bubble.
    private func detectJustUpdated() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastVersionKey)
        defaults.set(currentVersion, forKey: lastVersionKey)
        guard let previous, AppUpdate.isNewer(currentVersion, than: previous) else { return }
        let version = currentVersion
        Task {
            var summary: String?
            if let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let release = try? GitHubRelease.decode(data) {
                summary = release.whatsNew
            }
            justUpdated = JustUpdated(version: version, summary: summary)
            try? await Task.sleep(nanoseconds: 20_000_000_000)        // auto-hide after 20s
            if justUpdated?.version == version { justUpdated = nil }
        }
    }

    func dismissUpdatedNote() { justUpdated = nil }

    // MARK: check → download

    /// Ask GitHub for the latest release; if it's newer, start fetching it. Stays silent on any error.
    func check() async {
        guard installedAppURL != nil else { return }
        if case .downloading = state { return }   // already fetching
        if case .ready = state { return }          // already staged
        if case .installing = state { return }     // mid-install
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let release = try? GitHubRelease.decode(data),
              AppUpdate.isNewer(release.version, than: currentVersion) else { return }
        startDownload(release)
    }

    private func startDownload(_ release: GitHubRelease) {
        // Need both assets: the .zip for the seamless swap, the .pkg for the privileged install.
        guard let zipURL = release.assetURL(suffix: ".zip"),
              let pkgURL = release.assetURL(suffix: ".pkg") else { return }
        let version = release.version
        let dir = updatesDir.appendingPathComponent(version, isDirectory: true)
        releaseSummary = release.whatsNew
        state = .downloading(version: version)
        Task {
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: dir)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let zipDst = dir.appendingPathComponent("Combray.zip")
                let pkgDst = dir.appendingPathComponent("Combray.pkg")
                let (zipTmp, _) = try await URLSession.shared.download(from: zipURL)
                try fm.moveItem(at: zipTmp, to: zipDst)           // move out of the temp dir before the next await
                let (pkgTmp, _) = try await URLSession.shared.download(from: pkgURL)
                try fm.moveItem(at: pkgTmp, to: pkgDst)
                let app = try await Task.detached { try Updater.unzip(zipAt: zipDst, into: dir) }.value
                stagedApp = app
                stagedPkg = pkgDst
                state = .ready(version: version)
            } catch {
                state = .idle   // fail quietly; the 20-minute timer will try again
            }
        }
    }

    // MARK: install

    /// Apply the staged update now and relaunch (the bubble's action).
    ///
    /// User-owned installs: the seamless detached swap, then quit. Root-owned (pkg/Homebrew)
    /// installs: run the privileged installer **while the app is still open**, so the macOS
    /// password prompt is visibly tied to this click — the old flow prompted AFTER the app had
    /// quit, and a password dialog appearing out of nowhere got missed or cancelled, the old
    /// version reopened, and the bubble came back forever. On failure the bubble now says so
    /// and the click can simply be retried.
    func installNow() {
        guard case .ready(let version) = state, let app = stagedApp, let pkg = stagedPkg,
              let dest = installedAppURL else { return }
        installError = nil
        let fm = FileManager.default
        let writable = fm.isWritableFile(atPath: dest.path)
            && fm.isWritableFile(atPath: dest.appendingPathComponent("Contents").path)
        if writable {
            launchInstall(appSrc: app, pkg: pkg, dest: dest, relaunch: true, allowPrompt: false)
            NSApp.terminate(nil)
            return
        }
        state = .installing(version: version)
        let pkgPath = pkg.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok = Updater.runPrivilegedInstaller(pkgPath: pkgPath)
            await MainActor.run { self?.privilegedInstallFinished(ok: ok, version: version) }
        }
    }

    /// After the in-app privileged install: relaunch into the new version, or surface the failure
    /// so the user can click again (retries were previously dead — the one-shot script guard ate them).
    private func privilegedInstallFinished(ok: Bool, version: String) {
        if ok, let dest = installedAppURL {
            spawnRelaunch(dest: dest)
            NSApp.terminate(nil)
        } else {
            state = .ready(version: version)
            installError = "That didn’t finish — click again and enter your Mac password when asked."
        }
    }

    /// `installer -pkg` via osascript so macOS shows its standard admin-password prompt,
    /// synchronously, while the app is frontmost. Returns true when the install completed.
    nonisolated private static func runPrivilegedInstaller(pkgPath: String) -> Bool {
        let escaped = pkgPath.replacingOccurrences(of: "'", with: "'\\''")
        let apple = "do shell script \"/usr/sbin/installer -pkg '\(escaped)' -target /\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", apple]) == 0
    }

    /// Tiny detached helper: wait for this process to exit, then open the (now updated) app.
    private func spawnRelaunch(dest: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let destQ = "'" + dest.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "nohup /bin/bash -c 'for i in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; sleep 0.3; /usr/bin/open \(destQ)' >/dev/null 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
    }

    func hideBubble() { bubbleHidden = true }

    /// On normal quit, if an update is staged and the user didn't click, apply it silently (no relaunch)
    /// so the next launch is the new version. Never prompts — a password dialog popping up on an
    /// unattended quit would be hostile; a root-owned install just waits for the next explicit click.
    private func applyStagedUpdateOnQuit() {
        guard case .ready = state, let app = stagedApp, let pkg = stagedPkg, let dest = installedAppURL else { return }
        launchInstall(appSrc: app, pkg: pkg, dest: dest, relaunch: false, allowPrompt: false)
    }

    /// Write and launch a detached script that waits for this app to exit, then installs the update:
    /// an in-place bundle swap when the app's files are writable, else (if allowed) the privileged
    /// `.pkg` installer. Re-signs (macOS 26), strips quarantine, and optionally relaunches.
    private func launchInstall(appSrc: URL, pkg: URL, dest: URL, relaunch: Bool, allowPrompt: Bool) {
        guard !swapLaunched else { return }
        swapLaunched = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        PID="$1"; APPSRC="$2"; PKG="$3"; DEST="$4"; RELAUNCH="$5"; ALLOWPROMPT="$6"
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        sleep 0.3
        /usr/bin/xattr -dr com.apple.quarantine "$APPSRC" 2>/dev/null
        if [ -w "$DEST" ] && [ -w "$DEST/Contents" ]; then
          rm -rf "$DEST" && /usr/bin/ditto "$APPSRC" "$DEST"
          /usr/bin/codesign --force --deep --sign - "$DEST" 2>/dev/null
        elif [ "$ALLOWPROMPT" = "1" ]; then
          /usr/bin/osascript -e "do shell script \\"/usr/sbin/installer -pkg '$PKG' -target /\\" with administrator privileges" 2>/dev/null
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        if [ "$RELAUNCH" = "1" ]; then /usr/bin/open "$DEST"; fi
        """
        try? FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let scriptURL = updatesDir.appendingPathComponent("install.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "nohup /bin/bash \(q(scriptURL.path)) \(pid) \(q(appSrc.path)) \(q(pkg.path)) \(q(dest.path)) "
                + "\(relaunch ? "1" : "0") \(allowPrompt ? "1" : "0") >/tmp/combray-update.log 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
    }

    // MARK: staging (off the main actor — only Foundation + ditto)

    private var updatesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Combray/Updates", isDirectory: true)
    }

    /// Unzip the downloaded archive in place and return the `Combray.app` inside.
    nonisolated private static func unzip(zipAt zip: URL, into dir: URL) throws -> URL {
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else {
            throw NSError(domain: "Combray.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "unzip failed"])
        }
        let app = dir.appendingPathComponent("Combray.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw NSError(domain: "Combray.Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "no app in archive"])
        }
        return app
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
