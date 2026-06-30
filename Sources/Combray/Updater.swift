import Foundation
import AppKit
import Combine
import CombrayCore

/// Watches the GitHub repo for a newer release and, when one appears, downloads it in the background
/// and swaps `/Applications/Combray.app` in place — like the Claude Desktop updater.
///
/// Seamlessness & safety:
/// - Source of truth is the latest GitHub **release tag** (see `AppUpdate` / `GitHubRelease`).
/// - It downloads the `Combray.zip` asset (a signed app bundle) and swaps the bundle directly, so
///   there's no admin-password prompt (a `.pkg` install would need one).
/// - It only ever touches the **app bundle** — never the user's letters — so no data can be lost.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle                          // nothing to do (current, or still checking)
        case downloading(version: String)  // a newer release is being fetched in the background
        case ready(version: String)        // staged and ready — click to restart, or it applies on quit
    }

    @Published private(set) var state: State = .idle
    @Published var bubbleHidden = false     // user dismissed the bubble this run (update still applies on quit)

    private let repo = "Labern/Combray"
    private var timer: Timer?
    private var stagedApp: URL?             // unzipped Combray.app waiting to be installed
    private var swapLaunched = false        // the detached swap script has been kicked off

    init() {}
    /// Build an updater pinned to a fixed state — used only to render preview screenshots.
    init(previewState: State) { state = previewState }

    // MARK: lifecycle

    /// Begin checking: once now, then every 20 minutes. Also arms the apply-on-quit hook.
    /// No-op for un-installed dev builds (`swift run`) so they never nag or try to self-swap.
    func start() {
        guard installedAppURL != nil else { return }
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

    // MARK: check → download

    /// Ask GitHub for the latest release; if it's newer, start fetching it. Stays silent on any error.
    func check() async {
        guard installedAppURL != nil else { return }
        if case .downloading = state { return }   // already fetching
        if case .ready = state { return }          // already staged
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
        // Only releases that carry a Combray.zip can self-update; older .pkg-only releases stay silent.
        guard let assetURL = release.assetURL(suffix: ".zip") else { return }
        let version = release.version
        let dir = updatesDir
        state = .downloading(version: version)
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: assetURL)
                let app = try await Task.detached { try Updater.stage(zip: tmp, version: version, updatesDir: dir) }.value
                stagedApp = app
                state = .ready(version: version)
            } catch {
                state = .idle   // fail quietly; the 20-minute timer will try again
            }
        }
    }

    // MARK: install

    /// Apply the staged update now and relaunch (the bubble's action).
    func installNow() {
        guard case .ready = state, let newApp = stagedApp, let dest = installedAppURL else { return }
        launchSwap(newApp: newApp, dest: dest, relaunch: true)
        NSApp.terminate(nil)
    }

    func hideBubble() { bubbleHidden = true }

    /// On normal quit, if an update is staged and the user didn't click, apply it silently (no relaunch)
    /// so the next launch is the new version — the "auto-updates when closed and reopened" path.
    private func applyStagedUpdateOnQuit() {
        guard case .ready = state, let newApp = stagedApp, let dest = installedAppURL else { return }
        launchSwap(newApp: newApp, dest: dest, relaunch: false)
    }

    /// Write and launch a tiny detached script that waits for this app to exit, replaces the bundle,
    /// re-signs it (required on macOS 26), strips quarantine, and optionally relaunches.
    private func launchSwap(newApp: URL, dest: URL, relaunch: Bool) {
        guard !swapLaunched else { return }
        swapLaunched = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        PID="$1"; SRC="$2"; DEST="$3"; RELAUNCH="$4"
        for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        sleep 0.3
        /usr/bin/xattr -dr com.apple.quarantine "$SRC" 2>/dev/null
        rm -rf "$DEST"
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/codesign --force --deep --sign - "$DEST" 2>/dev/null
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        if [ "$RELAUNCH" = "1" ]; then /usr/bin/open "$DEST"; fi
        """
        try? FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let scriptURL = updatesDir.appendingPathComponent("swap.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "nohup /bin/bash \(q(scriptURL.path)) \(pid) \(q(newApp.path)) \(q(dest.path)) "
                + "\(relaunch ? "1" : "0") >/tmp/combray-update.log 2>&1 &"
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

    /// Unzip the downloaded asset into a clean per-version folder and return the `Combray.app` inside.
    nonisolated private static func stage(zip: URL, version: String, updatesDir: URL) throws -> URL {
        let fm = FileManager.default
        let dir = updatesDir.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appendingPathComponent("Combray.zip")
        try fm.moveItem(at: zip, to: archive)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path]) == 0 else {
            throw NSError(domain: "Combray.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "unzip failed"])
        }
        let app = dir.appendingPathComponent("Combray.app")
        guard fm.fileExists(atPath: app.path) else {
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
