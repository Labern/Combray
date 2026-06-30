import SwiftUI

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
