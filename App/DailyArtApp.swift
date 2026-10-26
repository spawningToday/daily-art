import SwiftUI

@main
struct DailyArtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
        } label: {
            Image(systemName: "photo.artframe")
                .accessibilityLabel("Daily Art")
        }
        .menuBarExtraStyle(.window)

        Window("Artwork History", id: "history") {
            HistoryView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start immediately so the wallpaper updates even if the menu is never opened.
        Task { await model.start() }
    }
}
