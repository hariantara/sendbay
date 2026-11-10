import Darwin
import Foundation

/// macOS' camera daemons (`ptpcamerad`, `mscamerad-xpc`) claim the MTP
/// interface of any phone that looks like a camera, which makes every other
/// app fail with LIBUSB_ERROR_ACCESS. launchd restarts them within
/// milliseconds, so the only thing that works is SIGKILL immediately followed
/// by the claim, with nothing awaited in between.
public enum CameraDaemonGuard {
    public static let daemonNames: Set<String> = ["ptpcamerad", "mscamerad-xpc"]

    public static func runningPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var matches: [pid_t] = []
        var nameBuffer = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            guard len > 0 else { continue }
            let name = String(decoding: nameBuffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if daemonNames.contains(name) { matches.append(pid) }
        }
        return matches
    }

    /// Sends SIGKILL to every running camera daemon. Returns how many were killed.
    @discardableResult
    public static func killAll() -> Int {
        runningPIDs().reduce(0) { $0 + (kill($1, SIGKILL) == 0 ? 1 : 0) }
    }
}
