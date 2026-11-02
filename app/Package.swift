// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scanutil",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
        .library(name: "ImagingKit", targets: ["ImagingKit"]),
        .library(name: "ScanutilUI", targets: ["ScanutilUI"]),
        .executable(name: "scanutil-cli", targets: ["scanutil-cli"]),
        .executable(name: "Scanutil", targets: ["Scanutil"]),
    ],
    targets: [
        // Kleine C-Brücke für die UVC-Controls (IOKit), siehe docs/hardware-access.adoc
        .target(name: "CUVC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "ScannerKit", dependencies: ["CUVC"]),
        .target(name: "ImagingKit"),
        .target(name: "ArchiveKit", dependencies: ["ScannerKit", "ImagingKit"]),
        .target(name: "ScanutilUI", dependencies: ["ScannerKit", "ArchiveKit", "ImagingKit"]),
        .executableTarget(name: "scanutil-cli", dependencies: ["ScannerKit", "ArchiveKit", "ImagingKit"]),
        .executableTarget(name: "Scanutil", dependencies: ["ScanutilUI"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "ImagingKitTests", dependencies: ["ImagingKit"]),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit", "ScannerKit", "ImagingKit"]),
        .testTarget(name: "ScanutilUITests", dependencies: ["ScanutilUI", "ScannerKit", "ArchiveKit", "ImagingKit"]),
    ]
)
