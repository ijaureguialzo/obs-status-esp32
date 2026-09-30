// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ObsStatus",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "obs-status",
            targets: ["ObsStatus"]
        )
    ],
    dependencies: [
        // WebSocket library (uncomment when choosing a library)
        // .package(url: "https://github.com/danielecoccha/Starscream.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ObsStatus",
            path: "obs-status-macos-ui",
            exclude: ["Resources/Info.plist"],
            sources: [
                "App/ObsStatusApp.swift",
                "App/ObsStatusMenuBar.swift",
                "UI/ContentView.swift",
                "UI/OBSConnectionView.swift",
                "UI/ESP32ConnectionView.swift",
                "UI/LEDIndicatorView.swift",
                "Services/OBSWebSocketService.swift",
                "Services/USBCDCService.swift",
                "Models/AppViewModel.swift",
                "Models/OBSConfig.swift",
                "Models/USBDevice.swift",
                "Models/AppSettings.swift",
                "Models/ObsProtocol.swift",
                "Extensions/AsyncStream+Extensions.swift",
            ]
        ),
        .testTarget(
            name: "ObsStatusTests",
            dependencies: ["ObsStatus"],
            path: "Tests/ObsStatusTests"
        )
    ]
)
