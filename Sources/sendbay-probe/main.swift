import Foundation
import MTPKit
import SendbayUSB

// Diagnostic tool: connects to the first MTP phone and prints what it sees.
// Usage: sendbay-probe [--download <path-on-phone> <local-file>]
let start = Date()
func elapsed() -> String { String(format: "%.0fms", Date().timeIntervalSince(start) * 1000) }

print("camera daemons running: \(CameraDaemonGuard.runningPIDs())")
do {
    let transport = try LibUSBTransport.openFirstDevice()
    let d = transport.device
    print(String(format: "claimed %@ %@ (%04x:%04x) packet=%d at %@",
                 d.manufacturer, d.product, d.vendorID, d.productID, transport.maxPacketSize, elapsed()))
    let session = MTPSession(transport: transport)
    defer { session.close() }
    try session.open()
    if let info = session.deviceInfo {
        print("device: \(info.manufacturer) \(info.model) serial=\(info.serialNumber)")
        print("partial64: \(info.supports(.getPartialObject64))")
    }
    let storages = try session.storages()
    if storages.isEmpty { print("no storages: unlock the phone and allow file access") }
    for s in storages {
        print(String(format: "storage %08x %@ free %.1f/%.1f GB", s.id, s.displayName,
                     Double(s.freeSpace) / 1e9, Double(s.capacity) / 1e9))
        let root = try session.list(storage: s.id)
        print("  \(root.count) items in root at \(elapsed()): " + root.prefix(12).map { $0.isFolder ? $0.name + "/" : $0.name }.joined(separator: ", "))
    }
    let args = CommandLine.arguments
    if args.count == 4, args[1] == "--download", let storage = storages.first {
        var parent = rootParent
        var object: ObjectInfo?
        for part in args[2].split(separator: "/") {
            object = try session.list(storage: storage.id, parent: parent).first { $0.name == part }
            guard let o = object else { print("not found: \(part)"); exit(1) }
            parent = o.handle
        }
        guard let file = object, !file.isFolder else { print("not a file"); exit(1) }
        FileManager.default.createFile(atPath: args[3], contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args[3]))
        let t0 = Date()
        try session.download(file, to: { try out.write(contentsOf: $0) })
        try out.close()
        let secs = Date().timeIntervalSince(t0)
        print(String(format: "downloaded %@ (%llu bytes) in %.2fs = %.1f MB/s", file.name, file.size, secs, Double(file.size) / secs / 1e6))
    }
} catch {
    print("FAILED: \(error) — \(error.localizedDescription)")
    exit(1)
}
