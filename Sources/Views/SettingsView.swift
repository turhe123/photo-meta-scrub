import AppKit
import SwiftUI

/// Preferences: default mode, output naming/location, replace-originals, map options and support.
struct SettingsView: View {
    @AppStorage(Prefs.defaultMode) private var defaultMode = ScrubMode.everything.rawValue
    @AppStorage(Prefs.suffix) private var suffix = "-clean"
    @AppStorage(Prefs.outputFolder) private var outputFolder = ""
    @AppStorage(Prefs.replaceOriginals) private var replaceOriginals = false
    @AppStorage(Prefs.showMap) private var showMap = true
    @AppStorage(Prefs.lookUpAddress) private var lookUpAddress = false
    @AppStorage(Prefs.resetModificationDate) private var resetModificationDate = false
    @State private var confirmReplace = false

    var body: some View {
        Form {
            Section("Scrubbing") {
                Picker("Default scrub mode", selection: $defaultMode) {
                    ForEach(ScrubMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Reset file modification date to now", isOn: $resetModificationDate)
            }
            Section("Output") {
                TextField("Copy suffix", text: $suffix)
                LabeledContent("Output folder") {
                    HStack {
                        Text(outputFolder.isEmpty ? "Ask every time" : (outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        if !outputFolder.isEmpty { Button("Clear") { outputFolder = "" } }
                    }
                }
                Toggle("Replace originals (backup to Trash)", isOn: Binding(
                    get: { replaceOriginals },
                    set: { if $0 { confirmReplace = true } else { replaceOriginals = false } }
                ))
            }
            Section("Map") {
                Toggle("Show map for photos with GPS", isOn: $showMap)
                Toggle("Look up address (sends coordinates to Apple)", isOn: $lookUpAddress)
            }
            Section {
                Button("Support / Donate ❤️") {
                    NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Replace originals?", isPresented: $confirmReplace) {
            Button("Enable", role: .destructive) { replaceOriginals = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrubbing will overwrite your original files. You’ll still be asked to confirm each batch, and originals are moved to the Trash first.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }
}
