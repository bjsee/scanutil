// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scanutil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
        .executable(name: "scanutil-cli", targets: ["scanutil-cli"]),
    ],
    targets: [
        // Kleine C-Brücke für die UVC-Controls (IOKit), siehe docs/hardware-access.adoc
        .target(name: "CUVC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ScannerKit", dependencies: ["CUVC"]),
        .target(name: "ArchiveKit", dependencies: ["ScannerKit"]),
        .executableTarget(name: "scanutil-cli", dependencies: ["ScannerKit", "ArchiveKit"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit", "ScannerKit"]),
    ]
)
