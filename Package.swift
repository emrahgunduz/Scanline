// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Scanline",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ScanlineCore", targets: ["ScanlineCore"]),
        .executable(name: "scanprobe", targets: ["scanprobe"]),
        .executable(name: "ScanlineHelper", targets: ["ScanlineHelper"]),
        .executable(name: "Scanline", targets: ["Scanline"]),
    ],
    targets: [
        .target(name: "CUSBHost",
                linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit"), .linkedFramework("Foundation")]),
        // USB transport and helper wire protocol: everything the privileged helper links.
        .target(name: "ScanlineUSB", dependencies: ["CUSBHost"]),
        .target(name: "ScanlineCore", dependencies: ["ScanlineUSB"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "scanprobe", dependencies: ["ScanlineCore"]),
        .executableTarget(name: "ScanlineHelper", dependencies: ["ScanlineUSB"]),
        .executableTarget(name: "Scanline", dependencies: ["ScanlineCore"]),
        .testTarget(name: "ScanlineCoreTests", dependencies: ["ScanlineCore"]),
    ]
)
