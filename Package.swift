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
        .target(name: "ScanlineCore", dependencies: ["CUSBHost"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "scanprobe", dependencies: ["ScanlineCore"]),
        .executableTarget(name: "ScanlineHelper", dependencies: ["ScanlineCore"]),
        .executableTarget(name: "Scanline", dependencies: ["ScanlineCore"]),
        .testTarget(name: "ScanlineCoreTests", dependencies: ["ScanlineCore"]),
    ]
)
