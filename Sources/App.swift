import AppKit
import SwiftUI

/// App entry point: main window, menu commands and Settings.
@main
struct PhotoMetaScrubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PhotoStore.shared

    var body: some Scene {
        Window("PhotoMetaScrub", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands { AppCommands(store: store) }

        Settings {
            SettingsView()
        }
    }
}

/// Receives files dropped on the Dock icon or opened from Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in PhotoStore.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu bar commands: Open, batch scrubbing, copying metadata and support.
struct AppCommands: Commands {
    @ObservedObject var store: PhotoStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { store.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandMenu("Scrub") {
            Button("Remove Location From All") { store.scrub(store.items, mode: .locationOnly) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.items.isEmpty || store.isWorking)
            Button("Scrub All") { store.scrub(store.items, mode: store.mode) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.items.isEmpty || store.isWorking)
            Divider()
            Button("Copy Metadata as Text") { store.copySelectedMetadata() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.selectedItem == nil)
            Divider()
            Button("Clear List") { store.clear() }
                .disabled(store.items.isEmpty || store.isWorking)
        }
        CommandGroup(after: .help) {
            Button("Support / Donate ❤️") { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) }
        }
    }
}
