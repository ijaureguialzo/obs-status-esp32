// swift-tools-version: 6.0

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
            // The checked-in ObsStatusVersion.swift reads the version from the
            // app bundle's Info.plist (the Xcode build path, see the pbxproj's
            // synchronized folder). The SwiftPM build gets the same values
            // from the VersionGenerator plugin's generated file instead, so
            // the checked-in copy is excluded here (silences the "unhandled
            // file" warning; without it the two definitions would collide).
            exclude: [
                "Resources/Info.plist",
                "Models/ObsStatusVersion.swift",
            ],
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
            ],
            plugins: ["VersionGenerator"]
        ),
        .testTarget(
            name: "ObsStatusTests",
            dependencies: ["ObsStatus"],
            path: "Tests/ObsStatusTests"
        ),
        .plugin(
            name: "VersionGenerator",
            capability: .buildTool
        )
    ],
    // The code predates Swift 6's strict concurrency; keep the Swift 5
    // language mode for now (the tools version only unlocks manifest/API
    // features, it does not force the new checking).
    swiftLanguageModes: [.v5]
)
