import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        if let active = store.transfers.active.first {
            Text("\(active.title) — \(Int(active.fraction * 100))%")
        }
        Divider()
        Button("Open Sendbay") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Import Photos & Videos") { store.importPhotos() }
            .disabled(store.phase != .connected)
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Sendbay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch store.phase {
        case .connected: "\(store.deviceName) connected"
        case .needsUnlock: "\(store.deviceName): unlock your phone"
        case .connecting: "Connecting…"
        case .searching: "Looking for your phone…"
        case .noDevice: "No phone connected"
        case .needsFileTransfer(let name): "\(name): set USB to File transfer"
        case .failed: "Couldn't connect"
        }
    }
}

struct SettingsView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Show hidden files", isOn: $store.showHidden)
            LabeledContent("Import photos to") {
                HStack {
                    Text(store.importFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.importFolder
        if panel.runModal() == .OK, let url = panel.url { store.importFolder = url }
    }
}
