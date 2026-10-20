import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// UserDefaults keys shared by @AppStorage views and the store.
enum Prefs {
    static let defaultMode = "defaultScrubMode"
    static let suffix = "outputSuffix"
    static let outputFolder = "outputFolder"
    static let replaceOriginals = "replaceOriginals"
    static let showMap = "showMap"
    static let lookUpAddress = "lookUpAddress"
    static let resetModificationDate = "resetModificationDate"
    static let customGroups = "customGroups"
}

/// A user-facing alert message.
struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// A scrub job waiting for the user to confirm replacing originals.
struct PendingReplace {
    let urls: [URL]
    let gpsCount: Int
    let removing: Set<MetadataGroup>
}

/// Owns the loaded photos, selection and the batch scrubbing workflow.
@MainActor
final class PhotoStore: ObservableObject {
    static let shared = PhotoStore()

    @Published var items: [PhotoItem] = []
    @Published var selection: PhotoItem.ID?
    @Published var skippedNote: String?
    @Published var mode: ScrubMode
    @Published var customGroups: Set<MetadataGroup>
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var alert: AlertInfo?
    @Published var pendingReplace: PendingReplace?

    private let defaults = UserDefaults.standard

    init() {
        mode = ScrubMode(rawValue: defaults.string(forKey: Prefs.defaultMode) ?? "") ?? .everything
        let saved = (defaults.string(forKey: Prefs.customGroups) ?? "GPS").split(separator: ",")
        customGroups = Set(saved.compactMap { MetadataGroup(rawValue: String($0)) })
    }

    var selectedItem: PhotoItem? { items.first { $0.id == selection } }

    func setCustom(_ group: MetadataGroup, _ on: Bool) {
        if on { customGroups.insert(group) } else { customGroups.remove(group) }
        defaults.set(customGroups.map(\.rawValue).joined(separator: ","), forKey: Prefs.customGroups)
    }

    // MARK: Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MetadataReader.supportedTypes + [.folder]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Adds files (folders are expanded one level deep); unsupported files are noted and skipped.
    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                files += (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)) ?? []
            } else {
                files.append(url)
            }
        }
        let known = Set(items.map(\.url))
        let candidates = files.filter { !known.contains($0) }
        Task.detached(priority: .userInitiated) {
            var loaded: [PhotoItem] = []
            var skipped: [String] = []
            for url in candidates {
                if MetadataReader.isSupported(url), let item = MetadataReader.load(url) {
                    loaded.append(item)
                } else {
                    skipped.append(url.lastPathComponent)
                }
            }
            await self.finishLoading(loaded, skipped: skipped)
        }
    }

    private func finishLoading(_ loaded: [PhotoItem], skipped: [String]) {
        items += loaded
        if selection == nil { selection = loaded.first?.id }
        skippedNote = skipped.isEmpty ? nil
            : "Skipped \(skipped.count) unsupported file(s): \(skipped.prefix(5).joined(separator: ", "))"
                + (skipped.count > 5 ? "…" : "")
    }

    func remove(_ id: PhotoItem.ID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    func clear() {
        items = []
        selection = nil
        skippedNote = nil
    }

    func copySelectedMetadata() {
        guard let item = selectedItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.asText, forType: .string)
    }

    // MARK: Scrubbing

    func scrubSelected() {
        if let item = selectedItem { scrub([item], mode: mode) }
    }

    /// Entry point for all scrub commands; asks for confirmation or an output folder as needed.
    func scrub(_ targets: [PhotoItem], mode: ScrubMode) {
        guard !targets.isEmpty, !isWorking else { return }
        let removing = mode.groupsToRemove(custom: customGroups)
        guard !removing.isEmpty else {
            alert = AlertInfo(title: "Nothing to remove", message: "Choose at least one group in Custom mode.")
            return
        }
        let urls = targets.map(\.url)
        let gpsCount = targets.filter(\.hasGPS).count
        if defaults.bool(forKey: Prefs.replaceOriginals) {
            pendingReplace = PendingReplace(urls: urls, gpsCount: gpsCount, removing: removing)
            return
        }
        guard let folder = resolveOutputFolder() else { return }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            alert = AlertInfo(title: "Folder is read-only",
                              message: "PhotoMetaScrub can’t write to “\(folder.lastPathComponent)”. Choose another output folder in Settings.")
            return
        }
        let suffix = defaults.string(forKey: Prefs.suffix) ?? "-clean"
        run(urls, gpsCount: gpsCount, removing: removing, destination: .folder(folder, suffix: suffix))
    }

    func confirmReplace() {
        guard let job = pendingReplace else { return }
        pendingReplace = nil
        run(job.urls, gpsCount: job.gpsCount, removing: job.removing, destination: .replaceOriginals)
    }

    private func resolveOutputFolder() -> URL? {
        if let path = defaults.string(forKey: Prefs.outputFolder), !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the cleaned copies."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func run(_ urls: [URL], gpsCount: Int, removing: Set<MetadataGroup>, destination: ScrubDestination) {
        isWorking = true
        progress = 0
        let resetDate = defaults.bool(forKey: Prefs.resetModificationDate)
        Task.detached(priority: .userInitiated) {
            var succeeded = 0
            var reencoded: [String] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                do {
                    if try Scrubber.process(url, removing: removing, to: destination, resetModificationDate: resetDate) {
                        reencoded.append(url.lastPathComponent)
                    }
                    succeeded += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                let fraction = Double(index + 1) / Double(urls.count)
                await MainActor.run { self.progress = fraction }
            }
            var lines = ["Cleaned \(succeeded) of \(urls.count) file(s).",
                         "\(gpsCount) file(s) contained location data."]
            if !reencoded.isEmpty {
                lines.append("\nRe-encoded at maximum quality (lossless copy not supported): "
                             + reencoded.joined(separator: ", "))
            }
            if case .replaceOriginals = destination, succeeded > 0 {
                lines.append("\nOriginals were moved to the Trash as a backup.")
            }
            if !failures.isEmpty { lines.append("\nFailed:\n" + failures.joined(separator: "\n")) }
            let summary = AlertInfo(title: failures.isEmpty ? "Scrub complete" : "Scrub finished with errors",
                                    message: lines.joined(separator: "\n"))
            await self.finishRun(summary, reload: { if case .replaceOriginals = destination { urls } else { [] } }())
        }
    }

    private func finishRun(_ summary: AlertInfo, reload: [URL]) {
        isWorking = false
        alert = summary
        guard !reload.isEmpty else { return }
        let selectedURL = selectedItem?.url
        items.removeAll { reload.contains($0.url) }
        Task.detached(priority: .userInitiated) {
            let fresh = reload.compactMap(MetadataReader.load)
            await MainActor.run {
                self.items += fresh
                if let url = selectedURL { self.selection = self.items.first { $0.url == url }?.id ?? self.selection }
            }
        }
    }
}
