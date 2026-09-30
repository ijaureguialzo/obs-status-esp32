// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "obs-status-macos-ui",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "obs-status-macos-ui", targets: ["ObsStatusMacosUI"])
    ],
    targets: [
        .executableTarget(
            name: "ObsStatusMacosUI",
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("usb"),
                .linkedLibrary("iconv"),
            ]
        )
    ]
)