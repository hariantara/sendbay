import Foundation

/// In-memory MTP device that speaks the real container protocol over a fake
/// bulk pipe. Used by unit tests and by the app's `--mock-device` mode.
/// It also enforces USB framing rules (short packets end a data phase,
/// packet-aligned phases need a zero-length packet) so tests catch them.
public final class MockMTPDevice: MTPTransport, @unchecked Sendable {
    public struct Node {
        public var handle: UInt32
        public var storage: UInt32
        public var parent: UInt32
        public var name: String
        public var isFolder: Bool
        public var data: Data
        public var modified: Date
    }

    public let maxPacketSize: Int
    public var supportsPartial64 = true
    public private(set) var nodes: [UInt32: Node] = [:]
    public private(set) var storages: [StorageInfo] = []
    /// Framing mistakes made by the host, for tests to assert on.
    public private(set) var violations: [String] = []
    public private(set) var cancelRequests: [UInt32] = []
    public private(set) var isClosed = false
    /// Transactions handled, by operation code.
    public private(set) var operationLog: [UInt16] = []

    private let lock = NSLock()
    private var nextHandle: UInt32 = 1
    private var outbound: [Data] = []
    private var inbound: Data?
    private var expectingData: (op: UInt16, tid: UInt32, params: [UInt32])?
    private var pendingObjectInfo: (storage: UInt32, parent: UInt32, name: String, isFolder: Bool, handle: UInt32)?
    private var sessionOpen = false

    public init(maxPacketSize: Int = 512) {
        self.maxPacketSize = maxPacketSize
    }

    // MARK: Building the fake filesystem

    public func addStorage(id: UInt32, name: String, capacity: UInt64 = 128_000_000_000, free: UInt64 = 64_000_000_000) {
        storages.append(StorageInfo(id: id, description: name, capacity: capacity, freeSpace: free))
    }

    @discardableResult
    public func addFolder(_ name: String, storage: UInt32, parent: UInt32 = rootParent) -> UInt32 {
        insert(Node(handle: 0, storage: storage, parent: parent, name: name, isFolder: true, data: Data(), modified: Date()))
    }

    @discardableResult
    public func addFile(_ name: String, storage: UInt32, parent: UInt32 = rootParent, data: Data, modified: Date = Date()) -> UInt32 {
        insert(Node(handle: 0, storage: storage, parent: parent, name: name, isFolder: false, data: data, modified: modified))
    }

    public func node(named name: String, parent: UInt32 = rootParent) -> Node? {
        lock.lock(); defer { lock.unlock() }
        return nodes.values.first { $0.name == name && $0.parent == parent }
    }

    private func insert(_ node: Node) -> UInt32 {
        var node = node
        node.handle = nextHandle
        nextHandle += 1
        nodes[node.handle] = node
        return node.handle
    }

    /// A small phone-like tree for the app's demo / UI-test mode.
    public static func sample() -> MockMTPDevice {
        let d = MockMTPDevice()
        d.addStorage(id: 0x0001_0001, name: "Internal shared storage")
        d.addStorage(id: 0x0002_0001, name: "SD card", capacity: 64_000_000_000, free: 50_000_000_000)
        let dcim = d.addFolder("DCIM", storage: 0x0001_0001)
        let camera = d.addFolder("Camera", storage: 0x0001_0001, parent: dcim)
        for i in 1...6 {
            d.addFile(String(format: "IMG_20261029_%06d.jpg", i), storage: 0x0001_0001, parent: camera,
                      data: Data(repeating: UInt8(i), count: 40_000 + i * 1_000))
        }
        d.addFile("VID_20261029_120000.mp4", storage: 0x0001_0001, parent: camera, data: Data(repeating: 7, count: 300_000))
        let download = d.addFolder("Download", storage: 0x0001_0001)
        d.addFile("invoice.pdf", storage: 0x0001_0001, parent: download, data: Data("%PDF-1.4 sample".utf8))
        d.addFile("notes.txt", storage: 0x0001_0001, parent: download, data: Data("Hello from Sendbay\n".utf8))
        d.addFolder("Music", storage: 0x0001_0001)
        let pictures = d.addFolder("Pictures", storage: 0x0001_0001)
        d.addFolder("Screenshots", storage: 0x0001_0001, parent: pictures)
        d.addFolder(".thumbnails", storage: 0x0001_0001)
        d.addFolder("Movies", storage: 0x0002_0001)
        return d
    }

    // MARK: MTPTransport

    public func write(_ data: Data, timeout: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        if isClosed { throw MTPError.disconnected }

        if var buffer = inbound, let expecting = expectingData {
            // Continuing a host->device data phase.
            buffer.append(data)
            inbound = buffer
            let header = try ContainerHeader(parsing: buffer)
            let length = Int(header.length)
            let aligned = length % maxPacketSize == 0
            if buffer.count > length { violations.append("data phase overran its length") }
            if buffer.count >= length {
                if aligned && !data.isEmpty { return } // wait for the ZLP
                if !aligned && data.isEmpty { violations.append("unexpected zero-length packet") }
                finishDataPhase(expecting, payload: buffer.subdata(in: ContainerHeader.size..<length))
            } else if data.count % maxPacketSize != 0 {
                violations.append("short packet in the middle of a data phase")
                finishDataPhase(expecting, payload: buffer.dropFirst(ContainerHeader.size))
            }
            return
        }

        if let expecting = expectingData {
            // First transfer of a data phase.
            let header = try ContainerHeader(parsing: data)
            guard header.type == .data else {
                violations.append("expected data container")
                expectingData = nil
                return
            }
            inbound = data
            let length = Int(header.length)
            if data.count >= length {
                if length % maxPacketSize == 0 { return }
                finishDataPhase(expecting, payload: data.subdata(in: ContainerHeader.size..<length))
            } else if data.count % maxPacketSize != 0 {
                violations.append("short packet in the middle of a data phase")
            }
            return
        }

        guard !data.isEmpty else { violations.append("stray zero-length packet"); return }
        let header = try ContainerHeader(parsing: data)
        guard header.type == .command else { violations.append("expected command container"); return }
        let params = try Container.params(of: data)
        operationLog.append(header.code)
        handleCommand(code: header.code, tid: header.transactionID, params: params)
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if isClosed { throw MTPError.disconnected }
        guard !outbound.isEmpty else { throw MTPError.timeout }
        var transfer = outbound.removeFirst()
        if transfer.count > maxLength {
            let head = transfer.prefix(maxLength)
            transfer.removeFirst(maxLength)
            outbound.insert(Data(transfer), at: 0)
            return Data(head)
        }
        return transfer
    }

    public func cancel(transactionID: UInt32) throws {
        lock.lock(); defer { lock.unlock() }
        cancelRequests.append(transactionID)
        inbound = nil
        expectingData = nil
        outbound.removeAll()
    }

    public func close() {
        lock.lock(); isClosed = true; lock.unlock()
    }

    /// Simulates the cable being pulled.
    public func unplug() { close() }

    /// Simulates plugging back in: the filesystem survives, the session does not.
    public func replug() {
        lock.lock(); defer { lock.unlock() }
        isClosed = false
        sessionOpen = false
        outbound.removeAll()
        inbound = nil
        expectingData = nil
    }

    // MARK: Device behaviour

    private func respond(_ code: UInt16, tid: UInt32, params: [UInt32] = []) {
        outbound.append(Container.make(.response, code: code, transactionID: tid, params: params))
    }

    private func sendData(_ payload: Data, op: UInt16, tid: UInt32) {
        var container = Container.dataHeader(code: op, transactionID: tid, payloadLength: UInt64(payload.count))
        container.append(payload)
        outbound.append(container)
        if container.count % maxPacketSize == 0 { outbound.append(Data()) }
    }

    private func handleCommand(code: UInt16, tid: UInt32, params: [UInt32]) {
        let ok = ResponseCode.ok
        func p(_ i: Int) -> UInt32 { i < params.count ? params[i] : 0 }

        guard let op = OperationCode(rawValue: code) else { respond(0x2005, tid: tid); return }
        if op != .openSession && op != .getDeviceInfo && !sessionOpen { respond(0x2003, tid: tid); return }

        switch op {
        case .getDeviceInfo:
            var ops = Set([0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B,
                           0x100C, 0x100D, 0x101B, 0x9803, 0x9804].map(UInt16.init))
            if supportsPartial64 { ops.insert(OperationCode.getPartialObject64.rawValue) }
            let info = DeviceInfo(manufacturer: "Mock", model: "Sendbay Test Phone", serialNumber: "MOCK0001", operationsSupported: ops)
            sendData(info.encoded(), op: code, tid: tid)
            respond(ok, tid: tid)
        case .openSession:
            if sessionOpen { respond(ResponseCode.sessionAlreadyOpen, tid: tid); return }
            sessionOpen = true
            respond(ok, tid: tid)
        case .closeSession:
            sessionOpen = false
            respond(ok, tid: tid)
        case .getStorageIDs:
            var w = ByteWriter()
            w.u32(UInt32(storages.count)); storages.forEach { w.u32($0.id) }
            sendData(w.data, op: code, tid: tid)
            respond(ok, tid: tid)
        case .getStorageInfo:
            guard let s = storages.first(where: { $0.id == p(0) }) else { respond(0x2008, tid: tid); return }
            sendData(s.encoded(), op: code, tid: tid)
            respond(ok, tid: tid)
        case .getObjectHandles:
            let handles = nodes.values
                .filter { $0.storage == p(0) && $0.parent == p(2) }
                .map(\.handle).sorted()
            var w = ByteWriter()
            w.u32(UInt32(handles.count)); handles.forEach { w.u32($0) }
            sendData(w.data, op: code, tid: tid)
            respond(ok, tid: tid)
        case .getObjectInfo:
            guard let n = nodes[p(0)] else { respond(0x2009, tid: tid); return }
            var dataset = ObjectInfo.dataset(
                name: n.name, format: n.isFolder ? ObjectFormat.association : ObjectFormat.undefined,
                size: UInt64(n.data.count), modified: n.modified)
            // Patch storage id and parent into the dataset.
            var sid = n.storage.littleEndian
            withUnsafeBytes(of: &sid) { dataset.replaceSubrange(0..<4, with: $0) }
            var parent = (n.parent == rootParent ? 0 : n.parent).littleEndian
            withUnsafeBytes(of: &parent) { dataset.replaceSubrange(38..<42, with: $0) }
            sendData(dataset, op: code, tid: tid)
            respond(ok, tid: tid)
        case .getObject:
            guard let n = nodes[p(0)], !n.isFolder else { respond(0x2009, tid: tid); return }
            sendData(n.data, op: code, tid: tid)
            respond(ok, tid: tid)
        case .getPartialObject, .getPartialObject64:
            guard let n = nodes[p(0)], !n.isFolder else { respond(0x2009, tid: tid); return }
            let offset = op == .getPartialObject64 ? Int(UInt64(p(1)) | UInt64(p(2)) << 32) : Int(p(1))
            let length = Int(op == .getPartialObject64 ? p(3) : p(2))
            let start = min(offset, n.data.count)
            let end = min(start + length, n.data.count)
            sendData(n.data.subdata(in: start..<end), op: code, tid: tid)
            respond(ok, tid: tid, params: [UInt32(end - start)])
        case .getObjectPropValue:
            guard let n = nodes[p(0)] else { respond(0x2009, tid: tid); return }
            var w = ByteWriter()
            if p(1) == UInt32(ObjectProperty.objectSize) { w.u64(UInt64(n.data.count)) } else { w.string(n.name) }
            sendData(w.data, op: code, tid: tid)
            respond(ok, tid: tid)
        case .deleteObject:
            guard nodes[p(0)] != nil else { respond(0x2009, tid: tid); return }
            deleteRecursively(p(0))
            respond(ok, tid: tid)
        case .sendObjectInfo, .sendObject, .setObjectPropValue:
            if op == .sendObject && pendingObjectInfo == nil { respond(0x2014, tid: tid); return }
            expectingData = (code, tid, params)
            inbound = nil
        }
    }

    private func finishDataPhase(_ expecting: (op: UInt16, tid: UInt32, params: [UInt32]), payload: Data) {
        expectingData = nil
        inbound = nil
        let payload = Data(payload)
        let tid = expecting.tid
        switch OperationCode(rawValue: expecting.op) {
        case .sendObjectInfo:
            guard let info = try? ObjectInfo(handle: 0, dataset: payload) else { respond(0x2002, tid: tid); return }
            let storage = expecting.params[0]
            let parent = expecting.params[1]
            if parent != rootParent && nodes[parent]?.isFolder != true { respond(0x201A, tid: tid); return }
            let handle = insert(Node(handle: 0, storage: storage, parent: parent, name: info.name,
                                     isFolder: info.isFolder, data: Data(), modified: info.modified ?? Date()))
            if !info.isFolder {
                pendingObjectInfo = (storage, parent, info.name, false, handle)
            }
            respond(ResponseCode.ok, tid: tid, params: [storage, parent, handle])
        case .sendObject:
            if let pendingInfo = pendingObjectInfo {
                nodes[pendingInfo.handle]?.data = payload
                pendingObjectInfo = nil
            }
            respond(ResponseCode.ok, tid: tid)
        case .setObjectPropValue:
            var r = ByteReader(payload)
            let handle = expecting.params[0]
            if nodes[handle] == nil { respond(0x2009, tid: tid); return }
            if expecting.params[1] == UInt32(ObjectProperty.fileName), let name = try? r.string() {
                nodes[handle]?.name = name
            }
            respond(ResponseCode.ok, tid: tid)
        default:
            respond(0x2002, tid: tid)
        }
    }

    private func deleteRecursively(_ handle: UInt32) {
        for child in nodes.values where child.parent == handle { deleteRecursively(child.handle) }
        nodes[handle] = nil
    }
}
