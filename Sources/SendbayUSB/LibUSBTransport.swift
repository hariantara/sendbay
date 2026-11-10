import CLibUSB
import Foundation
import MTPKit

/// Describes a USB device that exposes an MTP/PTP interface.
public struct USBDeviceDescription: Sendable, Equatable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var product: String
    public var manufacturer: String
    public var serial: String
}

/// MTP over libusb bulk endpoints.
public final class LibUSBTransport: MTPTransport, @unchecked Sendable {
    public let maxPacketSize: Int
    public let device: USBDeviceDescription

    private let context: OpaquePointer
    private var handle: OpaquePointer?
    private let interfaceNumber: Int32
    private let endpointIn: UInt8
    private let endpointOut: UInt8
    private var buffer: [UInt8]

    private init(context: OpaquePointer, handle: OpaquePointer, interface: MTPInterface, device: USBDeviceDescription) {
        self.context = context
        self.handle = handle
        self.interfaceNumber = interface.number
        self.endpointIn = interface.endpointIn
        self.endpointOut = interface.endpointOut
        self.maxPacketSize = interface.maxPacketSize
        self.device = device
        self.buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    }

    deinit { close() }

    // MARK: Opening

    /// Finds the first MTP device, claims its interface (evicting the macOS
    /// camera daemons if they hold it) and returns a ready transport.
    public static func openFirstDevice() throws -> LibUSBTransport {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0, let context = ctx else { throw MTPError.transport("libusb_init failed") }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { if let list { libusb_free_device_list(list, 1) } }
        guard count > 0, let list else {
            libusb_exit(context)
            throw MTPError.noDevice
        }

        var lastError: MTPError = .noDevice
        // A phone without an MTP interface is usually in "Charging only" mode.
        var androidWithoutMTP: String?
        for i in 0..<count {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            // Skip hubs and other obvious non-candidates quickly.
            if desc.bDeviceClass == UInt8(LIBUSB_CLASS_HUB.rawValue) { continue }

            var h: OpaquePointer?
            guard libusb_open(dev, &h) == 0, let handle = h else {
                if isAndroid(dev, vendor: desc.idVendor) { androidWithoutMTP = androidWithoutMTP ?? "Your phone" }
                continue
            }
            guard let interface = findMTPInterface(dev, handle) else {
                if isAndroid(dev, vendor: desc.idVendor) {
                    let name = stringDescriptor(handle, desc.iProduct)
                    androidWithoutMTP = name.isEmpty ? "Your phone" : name
                }
                libusb_close(handle)
                continue
            }
            let description = USBDeviceDescription(
                vendorID: desc.idVendor,
                productID: desc.idProduct,
                product: stringDescriptor(handle, desc.iProduct),
                manufacturer: stringDescriptor(handle, desc.iManufacturer),
                serial: stringDescriptor(handle, desc.iSerialNumber)
            )
            do {
                try claim(handle, interface.number)
                // The claim is exclusive from here on; nothing else can steal it.
                return LibUSBTransport(context: context, handle: handle, interface: interface, device: description)
            } catch let error as MTPError {
                lastError = error
                libusb_close(handle)
            }
        }
        libusb_exit(context)
        if lastError == .noDevice, let name = androidWithoutMTP {
            throw MTPError.notInFileTransferMode(device: name)
        }
        throw lastError
    }

    /// Vendors that ship Android phones, used to recognise a phone whose USB
    /// mode hides MTP. Also matches any device exposing an ADB interface.
    static let androidVendors: Set<UInt16> = [
        0x18D1, // Google (also used by many phones in MTP/ADB modes)
        0x2717, // Xiaomi
        0x04E8, // Samsung
        0x22B8, // Motorola
        0x0BB4, // HTC
        0x12D1, // Huawei
        0x2A70, // OnePlus
        0x22D9, // OPPO / realme
        0x2D95, // vivo
        0x1004, // LG
        0x0FCE, // Sony
        0x19D2, // ZTE
        0x05C6, // Qualcomm-based
        0x0E8D, // MediaTek-based
        0x17EF, // Lenovo
        0x2A45, // Meizu
        0x1EBF, // Nothing
        0x0489, // Foxconn / Nokia
    ]

    static func isAndroid(_ dev: OpaquePointer, vendor: UInt16) -> Bool {
        if androidVendors.contains(vendor) { return true }
        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &configPtr) == 0, let config = configPtr else { return false }
        defer { libusb_free_config_descriptor(config) }
        for i in 0..<Int(config.pointee.bNumInterfaces) {
            let iface = config.pointee.interface[i]
            for a in 0..<Int(iface.num_altsetting) {
                let alt = iface.altsetting[a]
                // ADB: vendor class 0xFF, subclass 0x42, protocol 0x01.
                if alt.bInterfaceClass == 0xFF && alt.bInterfaceSubClass == 0x42 && alt.bInterfaceProtocol == 0x01 {
                    return true
                }
            }
        }
        return false
    }

    /// Claims the interface; on ACCESS/BUSY kills the camera daemons and
    /// retries in a tight loop (no sleeping: launchd respawns them in ms).
    static func claim(_ handle: OpaquePointer, _ interface: Int32) throws {
        var result = libusb_claim_interface(handle, interface)
        if result == 0 { return }
        guard result == LIBUSB_ERROR_ACCESS.rawValue || result == LIBUSB_ERROR_BUSY.rawValue else {
            throw MTPError.transport(errorName(result))
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            CameraDaemonGuard.killAll()
            result = libusb_claim_interface(handle, interface)
            if result == 0 { return }
            if result != LIBUSB_ERROR_ACCESS.rawValue && result != LIBUSB_ERROR_BUSY.rawValue {
                throw MTPError.transport(errorName(result))
            }
        }
        throw MTPError.accessDenied
    }

    struct MTPInterface {
        var number: Int32
        var endpointIn: UInt8
        var endpointOut: UInt8
        var maxPacketSize: Int
    }

    /// An interface is MTP if it is Still Image class (6/1/1) or vendor
    /// specific with an "MTP" interface string, and has bulk in + out.
    static func findMTPInterface(_ dev: OpaquePointer, _ handle: OpaquePointer) -> MTPInterface? {
        var configPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        if libusb_get_active_config_descriptor(dev, &configPtr) != 0 {
            guard libusb_get_config_descriptor(dev, 0, &configPtr) == 0 else { return nil }
        }
        guard let config = configPtr else { return nil }
        defer { libusb_free_config_descriptor(config) }

        for i in 0..<Int(config.pointee.bNumInterfaces) {
            let iface = config.pointee.interface[i]
            for a in 0..<Int(iface.num_altsetting) {
                let alt = iface.altsetting[a]
                let isStillImage = alt.bInterfaceClass == 6 && alt.bInterfaceSubClass == 1
                let isVendorMTP = alt.bInterfaceClass == 0xFF && alt.iInterface != 0
                    && stringDescriptor(handle, alt.iInterface).uppercased().contains("MTP")
                guard isStillImage || isVendorMTP else { continue }

                var epIn: UInt8 = 0, epOut: UInt8 = 0, packet = 512
                for e in 0..<Int(alt.bNumEndpoints) {
                    let ep = alt.endpoint[e]
                    guard ep.bmAttributes & 0x03 == UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue) else { continue }
                    if ep.bEndpointAddress & 0x80 != 0 {
                        epIn = ep.bEndpointAddress
                        packet = Int(ep.wMaxPacketSize)
                    } else {
                        epOut = ep.bEndpointAddress
                    }
                }
                if epIn != 0 && epOut != 0 {
                    return MTPInterface(number: Int32(alt.bInterfaceNumber), endpointIn: epIn, endpointOut: epOut,
                                        maxPacketSize: max(packet, 64))
                }
            }
        }
        return nil
    }

    static func stringDescriptor(_ handle: OpaquePointer, _ index: UInt8) -> String {
        guard index != 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = libusb_get_string_descriptor_ascii(handle, index, &buf, Int32(buf.count))
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func errorName(_ code: Int32) -> String {
        String(cString: libusb_error_name(code))
    }

    // MARK: MTPTransport

    public func write(_ data: Data, timeout: TimeInterval) throws {
        guard let handle else { throw MTPError.disconnected }
        var bytes = [UInt8](data)
        var transferred: Int32 = 0
        let result = libusb_bulk_transfer(handle, endpointOut, &bytes, Int32(bytes.count), &transferred, Self.ms(timeout))
        try check(result)
        if Int(transferred) != bytes.count { throw MTPError.transport("short write") }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard let handle else { throw MTPError.disconnected }
        if buffer.count < maxLength { buffer = [UInt8](repeating: 0, count: maxLength) }
        var transferred: Int32 = 0
        let result = libusb_bulk_transfer(handle, endpointIn, &buffer, Int32(maxLength), &transferred, Self.ms(timeout))
        try check(result)
        return Data(buffer.prefix(Int(transferred)))
    }

    public func cancel(transactionID: UInt32) throws {
        guard let handle else { return }
        // Still Image class Cancel Request: code 0x4001 + transaction id.
        var payload: [UInt8] = [0x01, 0x40]
        withUnsafeBytes(of: transactionID.littleEndian) { payload.append(contentsOf: $0) }
        _ = libusb_control_transfer(handle, 0x21, 0x64, 0, UInt16(interfaceNumber), &payload, UInt16(payload.count), 2000)
        libusb_clear_halt(handle, endpointIn)
        libusb_clear_halt(handle, endpointOut)
    }

    public func close() {
        guard let h = handle else { return }
        handle = nil
        libusb_release_interface(h, interfaceNumber)
        libusb_close(h)
        libusb_exit(context)
    }

    private func check(_ result: Int32) throws {
        switch result {
        case 0: return
        case LIBUSB_ERROR_TIMEOUT.rawValue: throw MTPError.timeout
        case LIBUSB_ERROR_NO_DEVICE.rawValue: throw MTPError.disconnected
        default: throw MTPError.transport(Self.errorName(result))
        }
    }

    private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(max(1, t * 1000)) }
}
