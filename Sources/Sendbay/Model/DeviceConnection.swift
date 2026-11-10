import Foundation
import MTPKit
import SendbayUSB

/// Opens a transport to a phone. Real USB in production, the in-memory
/// phone for `--mock-device` (demo and UI tests).
protocol DeviceConnector: Sendable {
    func connect() throws -> (transport: MTPTransport, name: String)
}

struct USBConnector: DeviceConnector {
    func connect() throws -> (transport: MTPTransport, name: String) {
        let transport = try LibUSBTransport.openFirstDevice()
        let d = transport.device
        let name = d.product.isEmpty ? "Android phone" : d.product
        return (transport, name)
    }
}

final class MockConnector: DeviceConnector, @unchecked Sendable {
    let device = MockMTPDevice.sample()

    func connect() throws -> (transport: MTPTransport, name: String) {
        device.replug()
        return (device, "Demo Phone")
    }
}

/// Owns one open MTP session. Every call runs on a single serial queue
/// because MTP allows only one transaction at a time.
final class DeviceConnection: @unchecked Sendable {
    let name: String
    private let session: MTPSession
    private let queue = DispatchQueue(label: "app.sendbay.mtp", qos: .userInitiated)

    private init(name: String, session: MTPSession) {
        self.name = name
        self.session = session
    }

    /// Connects and opens the session off the main thread.
    static func open(using connector: DeviceConnector) async throws -> DeviceConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let (transport, name) = try connector.connect()
                    let session = MTPSession(transport: transport)
                    do {
                        try session.open()
                    } catch {
                        transport.close()
                        throw error
                    }
                    return DeviceConnection(name: name, session: session)
                })
            }
        }
    }

    func run<T>(_ body: @escaping (MTPSession) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(self.session) }) }
        }
    }

    func close() {
        queue.async { self.session.close() }
    }
}
