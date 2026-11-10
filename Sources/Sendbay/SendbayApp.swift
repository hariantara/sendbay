import AppKit
import SwiftUI

@main
struct SendbayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DeviceStore

    init() {
        let mock = CommandLine.arguments.contains("--mock-device")
        _store = State(initialValue: DeviceStore(
            connector: mock ? MockConnector() : USBConnector(),
            watchesUSB: !mock
        ))
        // Needed when launched as a bare executable (swift run) rather than a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Sendbay", id: "main") {
            ContentView()
                .environment(store)
                .task { store.start() }
        }
        .defaultSize(width: 960, height: 600)
        .commands { SendbayCommands(store: store) }

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            Image(systemName: store.isConnected ? "smartphone" : "cable.connector")
        }

        Settings {
            SettingsView().environment(store)
        }
    }
}

struct SendbayCommands: Commands {
    let store: DeviceStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Hidden Files", isOn: Binding(get: { store.showHidden }, set: { store.showHidden = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r")
                .disabled(store.phase != .connected)
        }
        CommandGroup(after: .newItem) {
            Button("Import Photos & Videos") { store.importPhotos() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store.phase != .connected)
        }
    }
}
