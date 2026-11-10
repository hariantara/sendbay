import Foundation

/// Little-endian writer for PTP datasets.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    public mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    public mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    public mutating func bytes(_ d: Data) { data.append(d) }

    /// PTP string: u8 char count (including the NUL), then UTF-16LE code units.
    /// An empty string is a single zero byte.
    public mutating func string(_ s: String) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16.prefix(254)) + [0]
        u8(UInt8(units.count))
        for unit in units { u16(unit) }
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

/// Little-endian reader for PTP datasets.
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) { bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try uint(2)) }
    public mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try uint(4)) }
    public mutating func u64() throws -> UInt64 { try uint(8) }

    public mutating func string() throws -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        try need(count * 2)
        return try (0..<count).map { _ in try u16() }
    }

    public mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        try need(count * 4)
        return try (0..<count).map { _ in try u32() }
    }

    private mutating func uint(_ size: Int) throws -> UInt64 {
        try need(size)
        var v: UInt64 = 0
        for i in 0..<size { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        offset += size
        return v
    }

    private func need(_ n: Int) throws {
        if n < 0 || remaining < n { throw MTPError.truncated }
    }
}
