import MTPKit
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                if store.phase == .connected {
                    BrowserView()
                } else {
                    StatusView()
                }
            }
            .overlay(alignment: .bottom) { BannerView() }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { if !$0 { store.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .quickLookPreview($store.previewURL)
    }
}

struct SidebarView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        List(selection: Binding(get: { store.selectedStorageID }, set: { store.selectStorage($0) })) {
            if store.storages.isEmpty {
                Text(store.isConnected ? store.deviceName : "No phone connected")
                    .foregroundStyle(.secondary)
            } else {
                Section(store.deviceName) {
                    ForEach(store.storages) { storage in
                        StorageRow(storage: storage).tag(storage.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if store.phase == .connected {
                Button {
                    store.importPhotos()
                } label: {
                    Label("Import Photos & Videos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(12)
                .accessibilityIdentifier("importPhotosButton")
            }
        }
    }
}

struct StorageRow: View {
    let storage: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(storage.displayName, systemImage: storage.displayName.localizedCaseInsensitiveContains("sd") ? "sdcard" : "internaldrive")
            if storage.capacity > 0 {
                ProgressView(value: Double(storage.capacity - min(storage.freeSpace, storage.capacity)), total: Double(storage.capacity))
                    .controlSize(.small)
                Text("\(Format.bytes(storage.freeSpace)) free of \(Format.bytes(storage.capacity))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .frame(maxWidth: 420)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("statusView")
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .searching, .connecting:
            ProgressView().controlSize(.large)
            Text(store.phase == .connecting ? "Connecting…" : "Looking for your phone…")
                .font(.title3.weight(.medium))
        case .noDevice:
            icon("cable.connector")
            Text("Connect your Android phone").font(.title3.weight(.semibold))
            Text("Plug it in with a USB cable, then pull down the notification shade and set USB to **File transfer**.")
                .foregroundStyle(.secondary)
            Button("Try Again") { store.retry() }
        case .needsFileTransfer(let name):
            icon("bolt.horizontal.circle")
            Text("\(name) is only charging").font(.title3.weight(.semibold))
            Text("On your phone, pull down the notifications, tap **Charging this device via USB**, then choose **File transfer**.")
                .foregroundStyle(.secondary)
            Text("Android resets this every time you plug in. To make it stick, set **Developer options → Default USB configuration → File transfer**.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Try Again") { store.retry() }
        case .needsUnlock:
            icon("lock.open")
            Text("Unlock your phone").font(.title3.weight(.semibold))
            Text("Android hides its files until the phone is unlocked. If asked, allow access to phone data.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            icon("exclamationmark.triangle")
            Text("Couldn't connect").font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            Button("Try Again") { store.retry() }
                .buttonStyle(.borderedProminent)
        case .connected:
            EmptyView()
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(.secondary)
    }
}

struct BannerView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        if let banner = store.banner {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(banner.text)
                if let url = banner.revealURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
                Button {
                    store.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner) {
                try? await Task.sleep(for: .seconds(6))
                if store.banner == banner { store.banner = nil }
            }
            .accessibilityIdentifier("banner")
        }
    }
}

enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
