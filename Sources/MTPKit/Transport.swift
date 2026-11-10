import Foundation

/// A bulk-pipe connection to an MTP device. Each `write` / `read` is one USB
/// bulk transfer: a transfer that is not a multiple of `maxPacketSize` ends
/// with a short packet, which terminates a PTP data phase on the device side.
public protocol MTPTransport: AnyObject {
    var maxPacketSize: Int { get }
    func write(_ data: Data, timeout: TimeInterval) throws
    /// Returns as soon as a short (or zero-length) packet arrives or
    /// `maxLength` bytes have been read.
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data
    /// Still Image class "Cancel Request" for an in-flight transaction.
    func cancel(transactionID: UInt32) throws
    func close()
}

/// Cooperative cancellation flag shared between UI and the transfer loop.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

public typealias ProgressHandler = (_ done: UInt64, _ total: UInt64) -> Void
