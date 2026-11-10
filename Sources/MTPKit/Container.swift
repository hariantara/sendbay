import Foundation

public enum ContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// The 12-byte header every PTP-over-USB container starts with.
public struct ContainerHeader: Equatable {
    public static let size = 12
    /// Length value used when the payload does not fit in 32 bits.
    public static let unboundedLength: UInt32 = 0xFFFF_FFFF

    public var length: UInt32
    public var type: ContainerType
    public var code: UInt16
    public var transactionID: UInt32

    public init(length: UInt32, type: ContainerType, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    public init(parsing data: Data) throws {
        var r = ByteReader(data.prefix(Self.size))
        length = try r.u32()
        let rawType = try r.u16()
        guard let type = ContainerType(rawValue: rawType) else {
            throw MTPError.protocolError("unknown container type \(rawType)")
        }
        self.type = type
        code = try r.u16()
        transactionID = try r.u32()
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.u32(length); w.u16(type.rawValue); w.u16(code); w.u32(transactionID)
        return w.data
    }

    public var isUnbounded: Bool { length == Self.unboundedLength }
}

public enum Container {
    /// Command or response container: header plus up to five u32 parameters.
    public static func make(_ type: ContainerType, code: UInt16, transactionID: UInt32, params: [UInt32] = []) -> Data {
        let header = ContainerHeader(
            length: UInt32(ContainerHeader.size + params.count * 4),
            type: type, code: code, transactionID: transactionID
        )
        var w = ByteWriter()
        w.bytes(header.encoded())
        params.forEach { w.u32($0) }
        return w.data
    }

    public static func dataHeader(code: UInt16, transactionID: UInt32, payloadLength: UInt64) -> Data {
        let total = payloadLength + UInt64(ContainerHeader.size)
        let length = total > UInt64(UInt32.max) - 1 ? ContainerHeader.unboundedLength : UInt32(total)
        return ContainerHeader(length: length, type: .data, code: code, transactionID: transactionID).encoded()
    }

    /// Parameters carried after the header of a command/response container.
    public static func params(of data: Data) throws -> [UInt32] {
        var r = ByteReader(data.dropFirst(ContainerHeader.size))
        var out: [UInt32] = []
        while r.remaining >= 4 { out.append(try r.u32()) }
        return out
    }
}
