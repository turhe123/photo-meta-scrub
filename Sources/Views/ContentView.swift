import SwiftUI
import UniformTypeIdentifiers

/// Main window: file sidebar, metadata detail and the scrub bar, with drag-and-drop everywhere.
struct ContentView: View {
    @EnvironmentObject private var store: PhotoStore
    @State private var isTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if let item = store.selectedItem {
                    DetailView(item: item)
                } else {
                    emptyState
                }
            }
            .safeAreaInset(edge: .bottom) { ScrubBar() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { store.presentOpenPanel() } label: { Label("Open", systemImage: "plus") }
            }
            ToolbarItem {
                Button { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!) } label: {
                    Text("Support / Donate ❤️")
                }
            }
        }
        .alert(item: $store.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
        .confirmationDialog("Replace original files?", isPresented: Binding(
            get: { store.pendingReplace != nil },
            set: { if !$0 { store.pendingReplace = nil } }
        )) {
            Button("Replace \(store.pendingReplace?.urls.count ?? 0) File(s)", role: .destructive) { store.confirmReplace() }
            Button("Cancel", role: .cancel) { store.pendingReplace = nil }
        } message: {
            Text("The originals will be moved to the Trash as a backup and replaced with cleaned versions.")
        }
    }

    private var sidebar: some View {
        List(selection: $store.selection) {
            ForEach(store.items) { item in
                HStack(spacing: 10) {
                    Group {
                        if let thumb = item.thumbnail {
                            Image(nsImage: thumb).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if item.hasGPS {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(.red).help("Contains location data")
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("Remove from List") { store.remove(item.id) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let note = store.skippedNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Drop photos to see what they reveal").font(.title2.weight(.semibold))
            Text("JPEG, HEIC, PNG and TIFF · everything stays on your Mac").foregroundStyle(.secondary)
            Button("Choose Photos…") { store.presentOpenPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar: scrub mode picker, custom group toggles, progress and scrub buttons.
struct ScrubBar: View {
    @EnvironmentObject private var store: PhotoStore
    @State private var showCustom = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $store.mode) {
                ForEach(ScrubMode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if store.mode == .custom {
                Button("Groups…") { showCustom.toggle() }
                    .popover(isPresented: $showCustom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Remove these groups:").font(.headline)
                            ForEach(MetadataGroup.removable) { group in
                                Toggle(group.rawValue, isOn: Binding(
                                    get: { store.customGroups.contains(group) },
                                    set: { store.setCustom(group, $0) }
                                ))
                            }
                        }
                        .padding()
                    }
            }
            Spacer()
            if store.isWorking {
                ProgressView(value: store.progress).frame(width: 140)
            }
            Button("Scrub All") { store.scrub(store.items, mode: store.mode) }
                .disabled(store.items.isEmpty || store.isWorking)
            Button("Scrub") { store.scrubSelected() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedItem == nil || store.isWorking)
        }
        .padding(10)
        .background(.bar)
    }
}
