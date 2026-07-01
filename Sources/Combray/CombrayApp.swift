import SwiftUI
import AppKit

@main
struct CombrayApp: App {
    @StateObject private var controller = ArchiveController()
    @StateObject private var updater = Updater()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            renderMadeleinePNG(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-update"), i + 1 < args.count {
            renderUpdatePreviewPNG(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-letter"), i + 1 < args.count {
            renderLetterPreviewPNG(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-scene"), i + 2 < args.count {
            let scene = args[i + 1]
            let out = args[i + 2]
            let w = (i + 3 < args.count ? Double(args[i + 3]) : nil).map { CGFloat($0) } ?? 560
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            renderScenePNG(scene: scene, to: out, width: w)      // schedules snapshot + exit(0)
            app.run()                                            // manual loop; never returns
        }
        if args.contains("--serve") {
            runCaptureServerHeadless()
        }
        if args.contains("--web") {
            runWebServerHeadless()
        }
    }

    var body: some Scene {
        WindowGroup("Combray") {
            RootView()
                .environmentObject(controller)
                .environmentObject(updater)
                .tint(Theme.accent)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}
