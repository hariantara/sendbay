import Foundation
import MTPKit
import Observation

@MainActor @Observable
final class Transfer: Identifiable {
    enum Kind { case download, upload }
    enum State: Equatable {
        case running
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let title: String
    let kind: Kind
    var total: UInt64
    var done: UInt64 = 0
    var state: State = .running
    let token = CancelToken()

    init(title: String, kind: Kind, total: UInt64) {
        self.title = title
        self.kind = kind
        self.total = total
    }

    var fraction: Double { total == 0 ? (state == .running ? 0 : 1) : min(1, Double(done) / Double(total)) }
    var isActive: Bool { state == .running }

    func cancel() { token.cancel() }
}

@MainActor @Observable
final class TransferCenter {
    private(set) var items: [Transfer] = []

    func start(_ title: String, kind: Transfer.Kind, total: UInt64) -> Transfer {
        let transfer = Transfer(title: title, kind: kind, total: total)
        items.insert(transfer, at: 0)
        return transfer
    }

    func clearFinished() { items.removeAll { !$0.isActive } }

    var active: [Transfer] { items.filter(\.isActive) }

    var overallFraction: Double {
        let active = self.active
        let total = active.reduce(UInt64(0)) { $0 + $1.total }
        guard total > 0 else { return 0 }
        return Double(active.reduce(UInt64(0)) { $0 + $1.done }) / Double(total)
    }
}

/// Converts per-chunk progress (reported on the MTP queue) into throttled
/// main-actor updates, accumulating across the files of a batch.
final class BatchProgress: @unchecked Sendable {
    private let transfer: Transfer
    private let lock = NSLock()
    private var completed: UInt64 = 0
    private var lastUpdate = Date.distantPast

    init(_ transfer: Transfer) { self.transfer = transfer }

    func report(fileDone: UInt64) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.1 else { lock.unlock(); return }
        lastUpdate = now
        let value = completed + fileDone
        lock.unlock()
        Task { @MainActor in self.transfer.done = value }
    }

    func finishFile(size: UInt64) {
        lock.lock()
        completed += size
        let value = completed
        lock.unlock()
        Task { @MainActor in self.transfer.done = value }
    }
}
