import SwiftUI

@main
struct CombrayApp: App {
    @StateObject private var controller = ArchiveController()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            renderMadeleinePNG(to: args[i + 1])
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
