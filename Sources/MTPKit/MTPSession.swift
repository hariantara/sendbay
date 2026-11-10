import Foundation

/// One MTP session over a transport. Not thread-safe: callers must serialize
/// all calls (the app runs every session call on one serial queue).
public final class MTPSession {
    public let transport: MTPTransport
    public private(set) var deviceInfo: DeviceInfo?
    public private(set) var isOpen = false

    /// Bulk reads use a large buffer that is a multiple of every USB packet size.
    let readChunk = 512 * 1024
    let writeChunk = 512 * 1024
    /// Downloads are split into chunks so they can be cancelled and so other
    /// requests (browsing) can be interleaved between chunks.
    public var downloadChunk: UInt64 = 8 * 1024 * 1024
    public var timeout: TimeInterval = 10

    private var transactionID: UInt32 = 0
    /// Bytes read past the end of a data phase (belong to the response).
    private var pending = Data()

    public init(transport: MTPTransport) {
        self.transport = transport
    }

    // MARK: Session

    public func open() throws {
        transactionID = 0
        pending.removeAll()
        // OpenSession uses transaction id 0 by spec; session id 1.
        let response = try exchange(.openSession, params: [1], transactionID: 0)
        if response.code != ResponseCode.ok && response.code != ResponseCode.sessionAlreadyOpen {
            throw MTPError.response(code: response.code, operation: OperationCode.openSession.rawValue)
        }
        isOpen = true
        deviceInfo = try DeviceInfo(dataset: try request(.getDeviceInfo).data)
    }

    public func close() {
        if isOpen { _ = try? exchange(.closeSession) }
        isOpen = false
        transport.close()
    }

    // MARK: Browsing

    public func storageIDs() throws -> [UInt32] {
        var r = ByteReader(try request(.getStorageIDs).data)
        // Android reports 0x00010000-style placeholders for unavailable storage;
        // the low 16 bits are zero when the volume is not mounted.
        return try r.u32Array().filter { $0 & 0xFFFF != 0 }
    }

    public func storageInfo(_ id: UInt32) throws -> StorageInfo {
        try StorageInfo(id: id, dataset: try request(.getStorageInfo, params: [id]).data)
    }

    public func storages() throws -> [StorageInfo] {
        try storageIDs().map(storageInfo)
    }

    public func objectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var r = ByteReader(try request(.getObjectHandles, params: [storage, 0, parent]).data)
        return try r.u32Array()
    }

    public func objectInfo(_ handle: UInt32) throws -> ObjectInfo {
        var info = try ObjectInfo(handle: handle, dataset: try request(.getObjectInfo, params: [handle]).data)
        if info.size == UInt64(UInt32.max) && !info.isFolder {
            // >4 GB file: the real size is only available as an object property.
            if let raw = try? request(.getObjectPropValue, params: [handle, UInt32(ObjectProperty.objectSize)]).data {
                var r = ByteReader(raw)
                info.size = (try? r.u64()) ?? info.size
            }
        }
        return info
    }

    public func list(storage: UInt32, parent: UInt32 = rootParent) throws -> [ObjectInfo] {
        try objectHandles(storage: storage, parent: parent).map(objectInfo)
    }

    // MARK: Changes

    public func delete(_ handle: UInt32) throws {
        _ = try request(.deleteObject, params: [handle, 0])
    }

    public func rename(_ handle: UInt32, to name: String) throws {
        var w = ByteWriter()
        w.string(name)
        _ = try request(.setObjectPropValue, params: [handle, UInt32(ObjectProperty.fileName)], dataOut: w.data)
    }

    @discardableResult
    public func createFolder(storage: UInt32, parent: UInt32, name: String) throws -> UInt32 {
        let dataset = ObjectInfo.dataset(name: name, format: ObjectFormat.association, size: 0, modified: Date())
        let response = try request(.sendObjectInfo, params: [storage, parent], dataOut: dataset)
        guard response.params.count >= 3 else { throw MTPError.protocolError("SendObjectInfo returned no handle") }
        return response.params[2]
    }

    // MARK: Transfers

    /// Streams a file's bytes to `sink`. Uses chunked partial reads when the
    /// device supports them so the transfer can be cancelled.
    public func download(
        _ object: ObjectInfo,
        to sink: (Data) throws -> Void,
        cancel: CancelToken? = nil,
        progress: ProgressHandler? = nil
    ) throws {
        try withoutActuallyEscaping(sink) { sink in
            try download(object, escapingSink: sink, cancel: cancel, progress: progress)
        }
    }

    private func download(
        _ object: ObjectInfo,
        escapingSink sink: @escaping (Data) throws -> Void,
        cancel: CancelToken?,
        progress: ProgressHandler?
    ) throws {
        let total = object.size
        let info = deviceInfo
        let can64 = info?.supports(.getPartialObject64) ?? false
        let can32 = (info?.supports(.getPartialObject) ?? false) && total < UInt64(UInt32.max)

        guard can64 || can32 else {
            var done: UInt64 = 0
            _ = try request(.getObject, params: [object.handle], dataIn: { chunk in
                try sink(chunk)
                done += UInt64(chunk.count)
                progress?(done, total)
            })
            return
        }

        var offset: UInt64 = 0
        progress?(0, total)
        while offset < total {
            if cancel?.isCancelled == true { throw MTPError.cancelled }
            let length = UInt32(min(downloadChunk, total - offset))
            let params: [UInt32] = can64
                ? [object.handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), length]
                : [object.handle, UInt32(offset), length]
            var received: UInt64 = 0
            _ = try request(can64 ? .getPartialObject64 : .getPartialObject, params: params, dataIn: { chunk in
                try sink(chunk)
                received += UInt64(chunk.count)
                progress?(offset + received, total)
            })
            if received == 0 { throw MTPError.protocolError("device returned an empty chunk") }
            offset += received
        }
    }

    /// Uploads a file. `source(n)` must return up to `n` bytes, or empty at EOF.
    @discardableResult
    public func upload(
        storage: UInt32,
        parent: UInt32,
        name: String,
        size: UInt64,
        modified: Date?,
        source: (Int) throws -> Data,
        cancel: CancelToken? = nil,
        progress: ProgressHandler? = nil
    ) throws -> UInt32 {
        let dataset = ObjectInfo.dataset(name: name, format: ObjectFormat.undefined, size: size, modified: modified)
        let infoResponse = try request(.sendObjectInfo, params: [storage, parent], dataOut: dataset)
        guard infoResponse.params.count >= 3 else { throw MTPError.protocolError("SendObjectInfo returned no handle") }
        let handle = infoResponse.params[2]

        let tid = nextTransactionID()
        do {
            try transport.write(Container.make(.command, code: OperationCode.sendObject.rawValue, transactionID: tid), timeout: timeout)
            var sent: UInt64 = 0
            try sendDataPhase(code: OperationCode.sendObject.rawValue, transactionID: tid, length: size) { max in
                if cancel?.isCancelled == true { throw MTPError.cancelled }
                let chunk = try source(Int(min(UInt64(max), size - sent)))
                sent += UInt64(chunk.count)
                progress?(sent, size)
                return chunk
            }
            try check(try readResponse(), operation: .sendObject)
            return handle
        } catch MTPError.cancelled {
            try? transport.cancel(transactionID: tid)
            pending.removeAll()
            try? delete(handle)
            throw MTPError.cancelled
        }
    }

    // MARK: Transaction plumbing

    public struct Response {
        public var code: UInt16
        public var params: [UInt32]
        public var data: Data
    }

    /// Runs a transaction and throws unless the response is OK.
    @discardableResult
    func request(
        _ op: OperationCode,
        params: [UInt32] = [],
        dataOut: Data? = nil,
        dataIn: ((Data) throws -> Void)? = nil
    ) throws -> Response {
        let response = try exchange(op, params: params, dataOut: dataOut, dataIn: dataIn)
        try check(response, operation: op)
        return response
    }

    func exchange(
        _ op: OperationCode,
        params: [UInt32] = [],
        dataOut: Data? = nil,
        dataIn: ((Data) throws -> Void)? = nil,
        transactionID fixed: UInt32? = nil
    ) throws -> Response {
        let tid = fixed ?? nextTransactionID()
        try transport.write(Container.make(.command, code: op.rawValue, transactionID: tid, params: params), timeout: timeout)

        if let dataOut {
            var offset = 0
            try sendDataPhase(code: op.rawValue, transactionID: tid, length: UInt64(dataOut.count)) { max in
                let end = min(offset + max, dataOut.count)
                defer { offset = end }
                return dataOut.subdata(in: offset..<end)
            }
            var response = try readResponse()
            response.data = Data()
            return response
        }

        var collected = Data()
        return try receive(sink: dataIn ?? { collected.append($0) }, collected: { dataIn == nil ? collected : Data() })
    }

    private func check(_ response: Response, operation: OperationCode) throws {
        guard response.code == ResponseCode.ok else {
            throw MTPError.response(code: response.code, operation: operation.rawValue)
        }
    }

    private func nextTransactionID() -> UInt32 {
        transactionID &+= 1
        if transactionID == 0 || transactionID == 0xFFFF_FFFF { transactionID = 1 }
        return transactionID
    }

    /// Sends header + payload so that every transfer except the last is a
    /// whole number of packets, then a zero-length packet if the total is
    /// packet-aligned (otherwise the device keeps waiting for more data).
    private func sendDataPhase(code: UInt16, transactionID: UInt32, length: UInt64, next: (Int) throws -> Data) throws {
        var buffer = Container.dataHeader(code: code, transactionID: transactionID, payloadLength: length)
        var produced: UInt64 = 0
        let total = length + UInt64(ContainerHeader.size)

        while produced < length {
            let chunk = try next(writeChunk)
            if chunk.isEmpty { throw MTPError.protocolError("source ended early") }
            produced += UInt64(chunk.count)
            buffer.append(chunk)
            while buffer.count >= writeChunk {
                try transport.write(buffer.prefix(writeChunk), timeout: timeout)
                buffer.removeFirst(writeChunk)
            }
        }
        if !buffer.isEmpty { try transport.write(buffer, timeout: timeout) }
        if total % UInt64(transport.maxPacketSize) == 0 {
            try transport.write(Data(), timeout: timeout)
        }
    }

    /// Reads an optional data phase followed by the response container.
    private func receive(sink: (Data) throws -> Void, collected: () -> Data) throws -> Response {
        var first = try readNonEmpty()
        let header = try ContainerHeader(parsing: first)

        if header.type == .response {
            pending = first.dropFirst(Int(min(header.length, UInt32(first.count))))
            return try makeResponse(first.prefix(Int(header.length)), header: header, data: Data())
        }
        guard header.type == .data else {
            throw MTPError.protocolError("expected data container, got \(header.type)")
        }

        let total: UInt64? = header.isUnbounded ? nil : UInt64(header.length) - UInt64(ContainerHeader.size)
        var received: UInt64 = 0
        var lastRead = first.count

        func deliver(_ bytes: Data) throws {
            var bytes = bytes
            if let total, received + UInt64(bytes.count) > total {
                let keep = Int(total - received)
                pending = bytes.dropFirst(keep)
                bytes = bytes.prefix(keep)
            }
            if !bytes.isEmpty {
                try sink(bytes)
                received += UInt64(bytes.count)
            }
        }

        first.removeFirst(ContainerHeader.size)
        try deliver(first)

        while true {
            if let total, received >= total { break }
            // Unbounded (>4 GB) phases end with a short packet.
            if total == nil, received > 0, lastRead < readChunk { break }
            let chunk = try transport.read(maxLength: readChunk, timeout: timeout)
            lastRead = chunk.count
            if chunk.isEmpty {
                if total == nil { break }
                continue
            }
            try deliver(chunk)
        }

        var response = try readResponse()
        response.data = collected()
        return response
    }

    private func readResponse() throws -> Response {
        let raw = try readNonEmpty()
        let header = try ContainerHeader(parsing: raw)
        guard header.type == .response else {
            throw MTPError.protocolError("expected response container, got \(header.type)")
        }
        let length = Int(min(header.length, UInt32(raw.count)))
        pending = raw.dropFirst(length)
        return try makeResponse(raw.prefix(length), header: header, data: Data())
    }

    private func makeResponse(_ raw: Data, header: ContainerHeader, data: Data) throws -> Response {
        Response(code: header.code, params: try Container.params(of: Data(raw)), data: data)
    }

    /// Next container bytes, skipping zero-length packets left over from a
    /// packet-aligned data phase.
    private func readNonEmpty() throws -> Data {
        if !pending.isEmpty {
            let out = Data(pending)
            pending.removeAll()
            return try completeContainer(out)
        }
        for _ in 0..<4 {
            let chunk = try transport.read(maxLength: readChunk, timeout: timeout)
            if !chunk.isEmpty { return try completeContainer(chunk) }
        }
        throw MTPError.protocolError("device sent only empty packets")
    }

    /// Some devices split a container header across packets; make sure at
    /// least the header (and the full container for responses) is present.
    private func completeContainer(_ data: Data) throws -> Data {
        var data = data
        while data.count < ContainerHeader.size {
            data.append(try transport.read(maxLength: readChunk, timeout: timeout))
        }
        let header = try ContainerHeader(parsing: data)
        if header.type == .response {
            while data.count < Int(header.length) {
                data.append(try transport.read(maxLength: readChunk, timeout: timeout))
            }
        }
        return Data(data)
    }
}
