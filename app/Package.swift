// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scanutil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
        .library(name: "ScanutilUI", targets: ["ScanutilUI"]),
        .executable(name: "scanutil-cli", targets: ["scanutil-cli"]),
        .executable(name: "Scanutil", targets: ["Scanutil"]),
    ],
    targets: [
        // Kleine C-Brücke für die UVC-Controls (IOKit), siehe docs/hardware-access.adoc
        .target(name: "CUVC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ScannerKit", dependencies: ["CUVC"]),
        .target(name: "ArchiveKit", dependencies: ["ScannerKit"]),
        .target(name: "ScanutilUI", dependencies: ["ScannerKit", "ArchiveKit"]),
        .executableTarget(name: "scanutil-cli", dependencies: ["ScannerKit", "ArchiveKit"]),
        .executableTarget(name: "Scanutil", dependencies: ["ScanutilUI"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit", "ScannerKit"]),
        .testTarget(name: "ScanutilUITests", dependencies: ["ScanutilUI", "ScannerKit", "ArchiveKit"]),
    ]
)
