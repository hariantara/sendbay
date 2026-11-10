import AppKit
import MTPKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(DeviceStore.self) private var store
    @State private var selection = Set<UInt32>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ObjectInfo.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var renaming: ObjectInfo?
    @State private var renameText = ""
    @State private var pendingDelete: [ObjectInfo] = []

    private var rows: [ObjectInfo] {
        let filtered = search.isEmpty
            ? store.visibleItems
            : store.visibleItems.filter { $0.name.localizedCaseInsensitiveContains(search) }
        // Folders always first, like Finder.
        let folders = filtered.filter(\.isFolder).sorted(using: sortOrder)
        let files = filtered.filter { !$0.isFolder }.sorted(using: sortOrder)
        return folders + files
    }

    private var selectedItems: [ObjectInfo] {
        store.visibleItems.filter { selection.contains($0.handle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            table
        }
        .navigationTitle(store.path.last?.name ?? store.storages.first { $0.id == store.selectedStorageID }?.displayName ?? "Sendbay")
        .searchable(text: $search, placement: .toolbar, prompt: "Search this folder")
        .toolbar { toolbar }
        .onChange(of: store.path) { selection.removeAll(); search = "" }
        .onChange(of: store.selectedStorageID) { selection.removeAll(); search = "" }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { store.createFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let item = renaming { store.rename(item, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)” from the phone?" : "Delete \(pendingDelete.count) items from the phone?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                store.delete(pendingDelete)
                selection.removeAll()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var table: some View {
        Table(of: ObjectInfo.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    Image(nsImage: FileIcon.image(for: item))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(item.isHidden ? 0.55 : 1)
                }
            }
            .width(min: 220, ideal: 380)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : Format.bytes(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.modified.map { Format.date.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Kind") { item in
                Text(FileIcon.kind(for: item)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
        } rows: {
            ForEach(rows) { item in
                TableRow(item).itemProvider { store.itemProvider(for: item) }
            }
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            contextMenu(for: store.visibleItems.filter { ids.contains($0.handle) })
        } primaryAction: { ids in
            if ids.count == 1, let item = store.visibleItems.first(where: { ids.contains($0.handle) }) {
                store.open(item)
            }
        }
        .onKeyPress(.space) {
            guard let item = selectedItems.first, !item.isFolder else { return .ignored }
            store.preview(item)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.upload(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                    .allowsHitTesting(false)
            } else if store.isLoading && store.items.isEmpty {
                ProgressView()
            } else if rows.isEmpty {
                Text(search.isEmpty ? "This folder is empty.\nDrop files here to copy them to your phone." : "No matches")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("fileTable")
    }

    @ViewBuilder
    private func contextMenu(for items: [ObjectInfo]) -> some View {
        if items.count == 1, let item = items.first {
            Button(item.isFolder ? "Open" : "Open on Mac") { store.open(item) }
            if !item.isFolder {
                Button("Quick Look") { store.preview(item) }
            }
            Divider()
        }
        if !items.isEmpty {
            Button("Copy to Mac…") { chooseDownloadFolder(for: items) }
            if items.count == 1, let item = items.first {
                Button("Rename…") {
                    renameText = item.name
                    renaming = item
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = items }
        } else {
            Button("New Folder…") { promptNewFolder() }
            Button("Copy from Mac…") { chooseUpload() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { store.goUp() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(store.path.isEmpty)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing folder (⌘↑)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { promptNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder (⇧⌘N)")
            Button { chooseUpload() } label: { Label("Copy from Mac", systemImage: "square.and.arrow.up") }
                .help("Copy files from your Mac to this folder")
                .accessibilityIdentifier("uploadButton")
            Button { chooseDownloadFolder(for: selectedItems) } label: { Label("Copy to Mac", systemImage: "square.and.arrow.down") }
                .disabled(selection.isEmpty)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Copy selected items to your Mac (⇧⌘S)")
            Button { pendingDelete = selectedItems } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete from phone (⌘⌫)")
            TransfersButton()
        }
    }

    private func promptNewFolder() {
        newFolderName = "New Folder"
        showingNewFolder = true
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        if panel.runModal() == .OK { store.upload(panel.urls) }
    }

    private func chooseDownloadFolder(for items: [ObjectInfo]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { store.download(items, to: url) }
    }
}

struct PathBar: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(store.storages.first { $0.id == store.selectedStorageID }?.displayName ?? "Phone", index: -1)
                ForEach(Array(store.path.enumerated()), id: \.element.handle) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    crumb(folder.name, index: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .accessibilityIdentifier("pathBar")
    }

    private func crumb(_ title: String, index: Int) -> some View {
        let isCurrent = index == store.path.count - 1
        return Button(title) { store.goTo(pathIndex: index) }
            .buttonStyle(.plain)
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? .primary : .secondary)
    }
}

extension ObjectInfo {
    var sortDate: Date { modified ?? .distantPast }
}

/// Finder icons and kind strings by file extension, cached.
@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for item: ObjectInfo) -> NSImage {
        let key = item.isFolder ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let image = NSWorkspace.shared.icon(for: type(of: item))
        cache[key] = image
        return image
    }

    static func kind(for item: ObjectInfo) -> String {
        type(of: item).localizedDescription ?? "Document"
    }

    private static func type(of item: ObjectInfo) -> UTType {
        if item.isFolder { return .folder }
        return UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
    }
}
