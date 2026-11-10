import Foundation

public enum MTPError: Error, Equatable, LocalizedError {
    case truncated
    case protocolError(String)
    case response(code: UInt16, operation: UInt16)
    case noDevice
    /// An Android phone is plugged in but its USB mode is not File transfer.
    case notInFileTransferMode(device: String)
    case accessDenied
    case disconnected
    case timeout
    case cancelled
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: "The phone sent an incomplete reply."
        case .protocolError(let msg): "Protocol error: \(msg)"
        case .response(let code, let op):
            String(format: "The phone refused the request (op 0x%04X, code 0x%04X).", op, code)
        case .noDevice: "No Android phone in File Transfer mode was found."
        case .notInFileTransferMode(let device): "\(device) is connected but its USB mode is not File transfer."
        case .accessDenied: "Another app is holding the phone. Close other file-transfer apps and reconnect."
        case .disconnected: "The phone was disconnected."
        case .timeout: "The phone stopped responding."
        case .cancelled: "Cancelled."
        case .transport(let msg): "USB error: \(msg)"
        }
    }

    /// Errors that mean the connection is gone and must be re-established.
    public var isConnectionLost: Bool {
        switch self {
        case .disconnected, .timeout, .transport, .noDevice, .accessDenied, .truncated, .protocolError: true
        default: false
        }
    }
}

public enum OperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case getPartialObject = 0x101B
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
    /// Android extension: 64-bit offset partial read.
    case getPartialObject64 = 0x95C1
}

public enum ResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let sessionAlreadyOpen: UInt16 = 0x201E
}

public enum ObjectFormat {
    public static let undefined: UInt16 = 0x3000
    public static let association: UInt16 = 0x3001
}

public enum ObjectProperty {
    public static let objectSize: UInt16 = 0xDC04
    public static let fileName: UInt16 = 0xDC07
}

/// Parent handle meaning "root of the storage".
public let rootParent: UInt32 = 0xFFFF_FFFF

public struct DeviceInfo: Equatable, Sendable {
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var operationsSupported: Set<UInt16>

    public init(manufacturer: String, model: String, serialNumber: String, operationsSupported: Set<UInt16>) {
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.operationsSupported = operationsSupported
    }

    public init(dataset: Data) throws {
        var r = ByteReader(dataset)
        _ = try r.u16() // standard version
        _ = try r.u32() // vendor extension id
        _ = try r.u16() // vendor extension version
        _ = try r.string() // vendor extension desc
        _ = try r.u16() // functional mode
        operationsSupported = Set(try r.u16Array())
        _ = try r.u16Array() // events
        _ = try r.u16Array() // device properties
        _ = try r.u16Array() // capture formats
        _ = try r.u16Array() // playback formats
        manufacturer = try r.string()
        model = try r.string()
        _ = try r.string() // device version
        serialNumber = (try? r.string()) ?? ""
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u16(100); w.u32(6); w.u16(100); w.string("microsoft.com: 1.0;"); w.u16(0)
        let ops = operationsSupported.sorted()
        w.u32(UInt32(ops.count)); ops.forEach { w.u16($0) }
        for _ in 0..<4 { w.u32(0) }
        w.string(manufacturer); w.string(model); w.string("1.0"); w.string(serialNumber)
        return w.data
    }

    public func supports(_ op: OperationCode) -> Bool { operationsSupported.contains(op.rawValue) }
}

public struct StorageInfo: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var description: String
    public var volumeLabel: String
    public var capacity: UInt64
    public var freeSpace: UInt64

    public init(id: UInt32, description: String, volumeLabel: String = "", capacity: UInt64, freeSpace: UInt64) {
        self.id = id
        self.description = description
        self.volumeLabel = volumeLabel
        self.capacity = capacity
        self.freeSpace = freeSpace
    }

    public init(id: UInt32, dataset: Data) throws {
        var r = ByteReader(dataset)
        self.id = id
        _ = try r.u16() // storage type
        _ = try r.u16() // filesystem type
        _ = try r.u16() // access capability
        capacity = try r.u64()
        freeSpace = try r.u64()
        _ = try r.u32() // free space in objects
        description = try r.string()
        volumeLabel = (try? r.string()) ?? ""
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u16(0x0003); w.u16(0x0002); w.u16(0x0000)
        w.u64(capacity); w.u64(freeSpace); w.u32(0xFFFF_FFFF)
        w.string(description); w.string(volumeLabel)
        return w.data
    }

    public var displayName: String {
        let name = description.isEmpty ? volumeLabel : description
        return name.isEmpty ? String(format: "Storage %08X", id) : name
    }
}

public struct ObjectInfo: Equatable, Hashable, Sendable, Identifiable {
    public var handle: UInt32
    public var storageID: UInt32
    public var parent: UInt32
    public var format: UInt16
    public var size: UInt64
    public var name: String
    public var modified: Date?

    public var id: UInt32 { handle }
    public var isFolder: Bool { format == ObjectFormat.association }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(handle: UInt32, storageID: UInt32, parent: UInt32, format: UInt16, size: UInt64, name: String, modified: Date?) {
        self.handle = handle
        self.storageID = storageID
        self.parent = parent
        self.format = format
        self.size = size
        self.name = name
        self.modified = modified
    }

    public init(handle: UInt32, dataset: Data) throws {
        var r = ByteReader(dataset)
        self.handle = handle
        storageID = try r.u32()
        format = try r.u16()
        _ = try r.u16() // protection
        size = UInt64(try r.u32())
        _ = try r.u16() // thumb format
        for _ in 0..<6 { _ = try r.u32() } // thumb size/w/h, image w/h/depth
        parent = try r.u32()
        _ = try r.u16() // association type
        _ = try r.u32() // association desc
        _ = try r.u32() // sequence number
        name = try r.string()
        _ = try? r.string() // date created
        modified = PTPDate.parse((try? r.string()) ?? "")
    }

    /// Dataset for SendObjectInfo.
    public static func dataset(name: String, format: UInt16, size: UInt64, modified: Date?) -> Data {
        var w = ByteWriter()
        w.u32(0) // storage id (taken from the operation parameter)
        w.u16(format)
        w.u16(0) // protection
        w.u32(size > UInt64(UInt32.max) ? 0xFFFF_FFFF : UInt32(size))
        w.u16(0) // thumb format
        for _ in 0..<6 { w.u32(0) }
        w.u32(0) // parent (taken from the operation parameter)
        w.u16(format == ObjectFormat.association ? 0x0001 : 0) // generic folder
        w.u32(0)
        w.u32(0)
        w.string(name)
        let date = modified.map(PTPDate.format) ?? ""
        w.string(date)
        w.string(date)
        w.string("")
        return w.data
    }
}

/// PTP date strings: "YYYYMMDDThhmmss" with optional fractional/zone suffix.
public enum PTPDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        guard s.count >= 15 else { return nil }
        return formatter.date(from: String(s.prefix(15)))
    }

    public static func format(_ d: Date) -> String { formatter.string(from: d) }
}
