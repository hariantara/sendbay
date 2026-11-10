import Foundation
import IOKit
import IOKit.usb

/// Calls `onChange` on the main run loop whenever any USB device is attached
/// or removed. Event-driven, so nothing polls while idle.
public final class USBDeviceMonitor {
    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            USBDeviceMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching("IOUSBHostDevice")
            if IOServiceAddMatchingNotification(port, type, matching, callback, refcon, &iterator) == KERN_SUCCESS {
                Self.drain(iterator) // arms the notification
                iterators.append(iterator)
            }
        }
    }

    public func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }
}
