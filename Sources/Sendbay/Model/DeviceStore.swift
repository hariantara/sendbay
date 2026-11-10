import AppKit
import Foundation
import MTPKit
import Observation
import OSLog
import SendbayUSB
import UniformTypeIdentifiers

/// Inspect with: log stream --predicate 'subsystem == "com.hariantara.sendbay"'
let log = Logger(subsystem: "com.hariantara.sendbay", category: "device")

@MainActor @Observable
final class DeviceStore {
    enum Phase: Equatable {
        case searching
        case noDevice
        /// Phone is plugged in but in "Charging only" USB mode.
        case needsFileTransfer(String)
        case connecting
        case needsUnlock
        case connected
        case failed(String)
    }

    private(set) var phase: Phase = .searching {
        didSet { if phase != oldValue { log.notice("phase: \(String(describing: self.phase), privacy: .public)") } }
    }
    private(set) var deviceName = ""
    private(set) var storages: [StorageInfo] = []
    private(set) var selectedStorageID: UInt32?
    /// Folders from the storage root down to the current folder.
    private(set) var path: [ObjectInfo] = []
    private(set) var items: [ObjectInfo] = []
    private(set) var isLoading = false

    var alertMessage: String?
    var banner: Banner?
    var previewURL: URL?

    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    var importFolder: URL {
        didSet { UserDefaults.standard.set(importFolder.path, forKey: "importFolder") }
    }

    let transfers = TransferCenter()

    struct Banner: Equatable {
        var text: String
        var revealURL: URL?
    }

    private let connector: DeviceConnector
    private let watchesUSB: Bool
    private var connection: DeviceConnection?
    private var scanTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var monitor: USBDeviceMonitor?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(connector: DeviceConnector, watchesUSB: Bool) {
        self.connector = connector
        self.watchesUSB = watchesUSB
        let defaults = UserDefaults.standard
        showHidden = defaults.bool(forKey: "showHidden")
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        importFolder = defaults.string(forKey: "importFolder").map(URL.init(fileURLWithPath:))
            ?? pictures.appendingPathComponent("Sendbay", isDirectory: true)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        if watchesUSB {
            let monitor = USBDeviceMonitor { [weak self] in
                Task { @MainActor in self?.usbDevicesChanged() }
            }
            monitor.start()
            self.monitor = monitor
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            log.notice("system going to sleep; closing session")
            Task { @MainActor in self?.disconnect() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })

        scan()
    }

    var isConnected: Bool { phase == .connected || phase == .needsUnlock }

    /// After wake the USB bus re-enumerates and the camera daemons race us for
    /// the phone, so drop any stale session and reconnect with backoff.
    func didWake() {
        log.notice("system woke; reconnecting")
        disconnect()
        scan(delays: [0.5, 1, 2, 4, 8])
    }

    func retry() {
        disconnect()
        scan(delays: [0, 1, 2])
    }

    private func usbDevicesChanged() {
        if let connection {
            // Something changed; make sure our phone is still there.
            Task {
                do { _ = try await connection.run { try $0.storageIDs() } } catch { handle(error) }
            }
        } else {
            // A freshly plugged phone takes a moment to expose its MTP interface.
            scan(delays: [0.3, 1, 2])
        }
    }

    private func scan(delays: [Double] = [0]) {
        scanTask?.cancel()
        scanTask = Task {
            for delay in delays {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled || connection != nil { return }
                if await connect() { return }
            }
        }
    }

    private func connect() async -> Bool {
        if phase != .connected { phase = .connecting }
        do {
            let connection = try await DeviceConnection.open(using: connector)
            if Task.isCancelled { connection.close(); return false }
            self.connection = connection
            deviceName = connection.name
            log.notice("connected to \(connection.name, privacy: .public)")
            await loadStorages()
            return true
        } catch let error as MTPError where error == .noDevice {
            phase = .noDevice
        } catch MTPError.notInFileTransferMode(let name) {
            phase = .needsFileTransfer(name)
        } catch {
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
        return false
    }

    func disconnect() {
        scanTask?.cancel()
        unlockTask?.cancel()
        connection?.close()
        connection = nil
        storages = []
        items = []
        path = []
        if phase == .connected || phase == .needsUnlock { phase = .searching }
    }

    private func connectionLost() {
        disconnect()
        phase = .searching
        scan(delays: [0.5, 1.5, 3])
    }

    private func handle(_ error: Error) {
        log.error("operation failed: \(String(describing: error), privacy: .public)")
        if let mtp = error as? MTPError {
            if mtp == .cancelled { return }
            if mtp.isConnectionLost { connectionLost(); return }
        }
        alertMessage = error.localizedDescription
    }

    // MARK: Browsing

    /// Android only lists storage once the phone is unlocked and the user has
    /// allowed file access, so poll until it appears.
    private func loadStorages() async {
        guard let connection else { return }
        do {
            let list = try await connection.run { try $0.storages() }
            storages = list
            if list.isEmpty {
                phase = .needsUnlock
                unlockTask?.cancel()
                unlockTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { await loadStorages() }
                }
                return
            }
            phase = .connected
            if selectedStorageID == nil || !list.contains(where: { $0.id == selectedStorageID }) {
                selectedStorageID = list[0].id
                path = []
            }
            await reload()
        } catch {
            handle(error)
        }
    }

    var currentParent: UInt32 { path.last?.handle ?? rootParent }

    var visibleItems: [ObjectInfo] {
        items.filter { showHidden || !$0.isHidden }
    }

    func reload() async {
        guard let connection, let storage = selectedStorageID else { return }
        let parent = currentParent
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await connection.run { try $0.list(storage: storage, parent: parent) }
            // Ignore results for a folder the user already navigated away from.
            if storage == selectedStorageID && parent == currentParent { items = list }
        } catch {
            handle(error)
        }
    }

    func refresh() {
        Task {
            if let id = selectedStorageID, let connection,
               let info = try? await connection.run({ try $0.storageInfo(id) }),
               let index = storages.firstIndex(where: { $0.id == id }) {
                storages[index] = info
            }
            await reload()
        }
    }

    func selectStorage(_ id: UInt32?) {
        guard let id, id != selectedStorageID else { return }
        selectedStorageID = id
        path = []
        items = []
        Task { await reload() }
    }

    func open(_ object: ObjectInfo) {
        if object.isFolder {
            path.append(object)
            items = []
            Task { await reload() }
        } else {
            Task { await openFile(object) }
        }
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        Task { await reload() }
    }

    /// `index` -1 is the storage root.
    func goTo(pathIndex index: Int) {
        guard index < path.count - 1 else { return }
        path = index < 0 ? [] : Array(path.prefix(index + 1))
        Task { await reload() }
    }

    // MARK: Changes

    func createFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let connection, let storage = selectedStorageID else { return }
        let parent = currentParent
        Task {
            do {
                _ = try await connection.run { try $0.createFolder(storage: storage, parent: parent, name: name) }
                await reload()
            } catch { handle(error) }
        }
    }

    func rename(_ object: ObjectInfo, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != object.name, let connection else { return }
        Task {
            do {
                try await connection.run { try $0.rename(object.handle, to: name) }
                await reload()
            } catch { handle(error) }
        }
    }

    func delete(_ objects: [ObjectInfo]) {
        guard let connection, !objects.isEmpty else { return }
        Task {
            do {
                try await connection.run { session in
                    for object in objects { try session.delete(object.handle) }
                }
            } catch { handle(error) }
            await reload()
            refresh()
        }
    }

    // MARK: Downloads

    /// Copies phone items (files or whole folders) into a Mac folder.
    func download(_ objects: [ObjectInfo], to folder: URL) {
        Task {
            do {
                let n = try await downloadItems(objects, into: folder)
                banner = Banner(text: "Copied \(n) \(n == 1 ? "item" : "items") to \(folder.lastPathComponent)", revealURL: folder)
            } catch { handle(error) }
        }
    }

    /// Returns the number of files written.
    @discardableResult
    func downloadItems(_ objects: [ObjectInfo], into folder: URL, title: String? = nil) async throws -> Int {
        guard let connection else { throw MTPError.disconnected }
        let plan = try await connection.run { session in
            try Self.expand(objects, into: folder, session: session)
        }
        return try await runDownloads(plan, title: title ?? Self.title(for: objects))
    }

    private func runDownloads(_ plan: [(object: ObjectInfo, url: URL)], title: String) async throws -> Int {
        guard let connection else { throw MTPError.disconnected }
        let total = plan.reduce(UInt64(0)) { $0 + ($1.object.isFolder ? 0 : $1.object.size) }
        let transfer = transfers.start(title, kind: .download, total: total)
        let progress = BatchProgress(transfer)
        let token = transfer.token
        do {
            let count = try await connection.run { session in
                try Self.writeFiles(plan, session: session, cancel: token,
                                    onBytes: { progress.report(fileDone: $0) },
                                    onFileDone: { progress.finishFile(size: $0) })
            }
            transfer.done = transfer.total
            transfer.state = .done
            return count
        } catch {
            transfer.state = (error as? MTPError) == .cancelled ? .cancelled : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Writes phone files to their Mac destinations. Runs on the MTP queue and
    /// never touches the main actor, so it is safe to use from drag providers.
    nonisolated static func writeFiles(
        _ plan: [(object: ObjectInfo, url: URL)],
        session: MTPSession,
        cancel token: CancelToken,
        onBytes: @escaping (UInt64) -> Void,
        onFileDone: (UInt64) -> Void
    ) throws -> Int {
        var files = 0
        let fm = FileManager.default
        for (object, url) in plan {
            if token.isCancelled { throw MTPError.cancelled }
            if object.isFolder {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try session.download(object, to: { try handle.write(contentsOf: $0) }, cancel: token,
                                     progress: { done, _ in onBytes(done) })
                if let modified = object.modified {
                    try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                }
            } catch {
                try? fm.removeItem(at: url)
                throw error
            }
            onFileDone(object.size)
            files += 1
        }
        return files
    }

    /// Flattens folders into (object, destination) pairs, parents first.
    nonisolated static func expand(_ objects: [ObjectInfo], into folder: URL, session: MTPSession) throws -> [(object: ObjectInfo, url: URL)] {
        var out: [(ObjectInfo, URL)] = []
        func visit(_ object: ObjectInfo, _ parentURL: URL) throws {
            let url = parentURL.appendingPathComponent(object.name, isDirectory: object.isFolder)
            out.append((object, url))
            if object.isFolder {
                for child in try session.list(storage: object.storageID, parent: object.handle) {
                    try visit(child, url)
                }
            }
        }
        for object in objects { try visit(object, folder) }
        return out
    }

    private static func title(for objects: [ObjectInfo]) -> String {
        objects.count == 1 ? objects[0].name : "\(objects.count) items"
    }

    /// Downloads into a fresh temporary folder, for drag-out and Quick Look.
    func exportToTemporary(_ object: ObjectInfo) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sendbay-\(UUID().uuidString)", isDirectory: true)
        try await downloadItems([object], into: folder)
        return folder.appendingPathComponent(object.name, isDirectory: object.isFolder)
    }

    func preview(_ object: ObjectInfo) {
        guard !object.isFolder else { return }
        Task {
            do { previewURL = try await exportToTemporary(object) } catch { handle(error) }
        }
    }

    private func openFile(_ object: ObjectInfo) async {
        do { NSWorkspace.shared.open(try await exportToTemporary(object)) } catch { handle(error) }
    }

    /// Drag-out support: Finder receives the file once it has been copied.
    ///
    /// AppKit may resolve these promises synchronously on the main thread
    /// (it does so for every outstanding promise when the app quits), so the
    /// handler must never wait on the main actor, or the app deadlocks.
    func itemProvider(for object: ObjectInfo) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = object.name
        let type: UTType = object.isFolder
            ? .folder
            : UTType(filenameExtension: (object.name as NSString).pathExtension) ?? .data
        let connection = self.connection
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: Int64(clamping: max(object.size, 1)))
            guard let connection, !AppLifecycle.isTerminating else {
                completion(nil, false, CocoaError(.userCancelled))
                return progress
            }
            let token = CancelToken()
            progress.cancellationHandler = { token.cancel() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Sendbay-\(UUID().uuidString)", isDirectory: true)
            Task.detached {
                do {
                    try await connection.run { session in
                        let plan = try Self.expand([object], into: folder, session: session)
                        progress.totalUnitCount = Int64(clamping: max(1, plan.reduce(UInt64(0)) { $0 + ($1.object.isFolder ? 0 : $1.object.size) }))
                        var finished: UInt64 = 0
                        _ = try Self.writeFiles(plan, session: session, cancel: token,
                                                onBytes: { progress.completedUnitCount = Int64(clamping: finished + $0) },
                                                onFileDone: { finished += $0 })
                    }
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(folder.appendingPathComponent(object.name, isDirectory: object.isFolder), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    // MARK: Uploads

    /// Copies Mac files/folders into the current phone folder. Name clashes
    /// get a numbered name instead of replacing what is on the phone.
    func upload(_ urls: [URL]) {
        guard let connection, let storage = selectedStorageID, !urls.isEmpty else { return }
        let parent = currentParent
        let existing = Set(items.map(\.name))
        Task {
            let plan = Self.uploadPlan(urls, existingNames: existing)
            let total = plan.reduce(UInt64(0)) { $0 + $1.size }
            let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
            let transfer = transfers.start(title, kind: .upload, total: total)
            let progress = BatchProgress(transfer)
            let token = transfer.token
            do {
                try await connection.run { session in
                    var handles: [String: UInt32] = [:]
                    for entry in plan {
                        if token.isCancelled { throw MTPError.cancelled }
                        let target = entry.parent.flatMap { handles[$0] } ?? parent
                        if entry.isFolder {
                            handles[entry.url.standardizedFileURL.path] = try session.createFolder(storage: storage, parent: target, name: entry.name)
                            continue
                        }
                        let file = try FileHandle(forReadingFrom: entry.url)
                        defer { try? file.close() }
                        try session.upload(
                            storage: storage, parent: target, name: entry.name, size: entry.size, modified: entry.modified,
                            source: { try file.read(upToCount: $0) ?? Data() },
                            cancel: token,
                            progress: { done, _ in progress.report(fileDone: done) })
                        progress.finishFile(size: entry.size)
                    }
                }
                transfer.done = transfer.total
                transfer.state = .done
            } catch {
                transfer.state = (error as? MTPError) == .cancelled ? .cancelled : .failed(error.localizedDescription)
                handle(error)
            }
            await reload()
            refresh()
        }
    }

    struct UploadEntry {
        var url: URL
        /// Standardized path of the Mac folder this entry sits in (nil = top level).
        var parent: String?
        var name: String
        var isFolder: Bool
        var size: UInt64
        var modified: Date?
    }

    nonisolated static func uploadPlan(_ urls: [URL], existingNames: Set<String>) -> [UploadEntry] {
        let fm = FileManager.default
        var taken = existingNames
        var out: [UploadEntry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]

        func entry(_ url: URL, parent: String?, name: String) -> UploadEntry? {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return UploadEntry(url: url, parent: parent, name: name, isFolder: values.isDirectory ?? false,
                               size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }

        for url in urls {
            let name = uniqueName(url.lastPathComponent, taken: taken)
            taken.insert(name)
            guard let top = entry(url, parent: nil, name: name) else { continue }
            out.append(top)
            guard top.isFolder,
                  let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let child as URL in walker {
                if let e = entry(child, parent: child.deletingLastPathComponent().standardizedFileURL.path, name: child.lastPathComponent) {
                    out.append(e)
                }
            }
        }
        return out
    }

    nonisolated static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: Photo import

    func importPhotos() {
        guard let connection else { return }
        let folder = importFolder
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let media = try await connection.run { session in
                    try PhotoImport.findMedia(in: session, storages: try session.storageIDs())
                }
                let plan = PhotoImport.plan(media, into: folder)
                guard !plan.isEmpty else {
                    banner = Banner(text: "No new photos or videos to import", revealURL: nil)
                    return
                }
                let n = try await runDownloads(plan.map { ($0.object, $0.destination) },
                                               title: "Importing \(plan.count) photos & videos")
                banner = Banner(text: "Imported \(n) new \(n == 1 ? "item" : "items")", revealURL: folder)
            } catch { handle(error) }
        }
    }
}
