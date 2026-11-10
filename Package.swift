// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sendbay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sendbay", targets: ["Sendbay"]),
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "SendbayUSB", targets: ["SendbayUSB"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        // Pure-Swift PTP/MTP protocol. No USB code, so it is fully unit-testable.
        .target(name: "MTPKit"),
        // libusb transport, macOS camera-daemon handling, IOKit hotplug.
        .target(
            name: "SendbayUSB",
            dependencies: ["MTPKit", "CLibUSB"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Sendbay",
            dependencies: ["MTPKit", "SendbayUSB"]
        ),
        .executableTarget(
            name: "sendbay-probe",
            dependencies: ["MTPKit", "SendbayUSB"]
        ),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
    ],
    swiftLanguageModes: [.v5]
)
